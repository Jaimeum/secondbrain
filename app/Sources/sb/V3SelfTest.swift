import BrainCore
import Foundation

/// v0.3 checks (CONTRACT §12): backward-compatible decoding of persisted types, OAuth registration precedence,
/// the demo provider and the account store skeleton.
@MainActor func testV3Models(_ t: Tester, root: URL) async {
    // AppConfig: a v0.1 config.json (no v0.3 keys) keeps every value.
    let v01 = """
    {"vaultPath":"~/secondbrain/vault","dataPath":"~/secondbrain/data","whisperModel":"large-v3-v20240930_turbo",
     "ingestModel":"opus","queryModel":"sonnet","uiLanguage":"en","captureMic":false,"gitEnabled":true,
     "hotkeyEnabled":false,"onboardingComplete":true}
    """
    if let c = try? JSONDecoder.sb.decode(AppConfig.self, from: Data(v01.utf8)) {
        t.check(c.vaultPath == "~/secondbrain/vault" && c.uiLanguage == "en" && c.onboardingComplete && !c.captureMic
                && c.gitEnabled && c.claudePath == nil, "v0.1 config keeps its values")
        t.eq(c.appearance, "system", "v0.1 config → appearance default")
        t.eq(c.oauth, OAuthAppRegistration.empty, "v0.1 config → oauth default")
        t.check(c.lastMailProjectSlug == nil, "v0.1 config → lastMailProjectSlug nil")
    } else {
        t.check(false, "v0.1 config.json decodes")
    }
    var c3 = AppConfig.default
    c3.appearance = "dark"
    c3.oauth = OAuthAppRegistration(microsoftClientId: "ms-id", googleClientId: "g-id", googleClientSecret: "g-secret")
    c3.lastMailProjectSlug = "xfiles"
    if let data = try? JSONEncoder.sb.encode(c3), let back = try? JSONDecoder.sb.decode(AppConfig.self, from: data) {
        t.eq(back, c3, "v0.3 config round trip")
    } else {
        t.check(false, "v0.3 config encodes/decodes")
    }
    let odd = v01.replacingOccurrences(of: "\"onboardingComplete\":true", with: "\"onboardingComplete\":true,\"appearance\":\"neon\",\"oauth\":42")
    let oddConfig = try? JSONDecoder.sb.decode(AppConfig.self, from: Data(odd.utf8))
    t.check(oddConfig?.appearance == "system" && oddConfig?.oauth == .empty && oddConfig?.onboardingComplete == true,
            "bad v0.3 values fall back without resetting the config")

    // SourceRecord / SessionManifest without the v0.3 keys.
    var record = SourceRecord(id: "s1", kind: .email, title: "Hola", projectSlug: nil, status: .done,
                              createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    if let data = try? JSONEncoder.sb.encode(record), let back = try? JSONDecoder.sb.decode(SourceRecord.self, from: data) {
        t.check(back.externalId == nil && back.calendarEventId == nil && back.title == "Hola", "SourceRecord without v0.3 keys")
        t.check(!(String(data: data, encoding: .utf8) ?? "").contains("externalId"), "nil externalId not written")
    }
    record.externalId = "microsoft:AAMk1"
    record.calendarEventId = "evt-1"
    if let data = try? JSONEncoder.sb.encode(record), let back = try? JSONDecoder.sb.decode(SourceRecord.self, from: data) {
        t.eq(back, record, "SourceRecord v0.3 round trip")
    }
    let manifestJSON = """
    {"id":"20261026-153000-abcd","startedAt":"2026-10-26T15:30:00Z","sampleRate":16000,"chunkSeconds":300,
     "tracks":{"mic":["mic_000.wav"]},"micCaptured":true}
    """
    let manifest = try? JSONDecoder.sb.decode(SessionManifest.self, from: Data(manifestJSON.utf8))
    t.check(manifest != nil && manifest?.calendarEventId == nil && manifest?.attendees == nil, "v0.1 session.json decodes")
    var m3 = SessionManifest(id: "x", title: "Kickoff", projectSlug: nil, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                             micCaptured: true, calendarEventId: "evt", attendees: ["Laura Méndez", "Diego Torres"])
    m3.endedAt = m3.startedAt.addingTimeInterval(60)
    if let data = try? JSONEncoder.sb.encode(m3), let back = try? JSONDecoder.sb.decode(SessionManifest.self, from: data) {
        t.eq(back, m3, "SessionManifest v0.3 round trip")
    }

    // OAuth registration precedence: env > config > OAuthDefaults; blanks count as missing.
    var cfg = AppConfig.default
    cfg.oauth = OAuthAppRegistration(microsoftClientId: "cfg-ms", googleClientId: "  ", googleClientSecret: "cfg-secret")
    let eff = OAuthAppRegistration.effective(config: cfg, environment: ["SB_GOOGLE_CLIENT_ID": "env-g", "SB_MS_CLIENT_ID": ""])
    t.eq(eff.microsoftClientId, "cfg-ms", "config used when env blank")
    t.eq(eff.googleClientId, "env-g", "env overrides config")
    t.eq(eff.googleClientSecret, "cfg-secret", "config secret")
    t.check(eff.isConfigured(.microsoft) && eff.isConfigured(.google), "both configured")
    let none = OAuthAppRegistration.effective(config: .default, environment: [:])
    t.check(!none.isConfigured(.microsoft) && !none.isConfigured(.google), "nothing configured by default (OAuthDefaults empty)")

    // Demo provider (§12.3): 12 emails / 5 people / threads; 8 events, one in progress with a Teams link.
    let now = Date()
    let ms = DemoProvider(account: DemoProvider.demoAccount(.microsoft), language: "es", now: now)
    do {
        var all: [MailMessageSummary] = []
        var token: String? = nil
        repeat {
            let page = try await ms.listMessages(since: now.addingTimeInterval(-30 * 86_400), pageToken: token)
            all += page.messages
            token = page.next
        } while token != nil
        t.eq(all.count, 14, "demo: 14 emails (paged)")   // v0.7: + the owner's reply and Laura's in the contract thread
        t.check(all.allSatisfy { $0.date >= now.addingTimeInterval(-10 * 86_400) && $0.date <= now }, "demo: emails within the last 10 days")
        let senders = Set(all.compactMap(\.from.email)).subtracting(["ana@contoso.com"])
        t.eq(senders.count, 5, "demo: 5 other people")
        let thread = try await ms.fetchThread(id: "demo-thread-acme")
        t.check(thread.count == 3 && thread.first!.summary.date < thread.last!.summary.date, "demo: chronological thread of 3")
        let parsed = EmailParser.parse(thread[1].bodyText, ownerEmails: ["ana@contoso.com"], ownerName: "Ana García", now: now)
        t.check(parsed.quotedHistory != nil, "demo: replies carry quoted history")
        let hits = try await ms.searchMessages("puebla", pageToken: nil)
        t.check(!hits.messages.isEmpty, "demo: search")
        let events = try await ms.events(from: now.addingTimeInterval(-2 * 86_400), to: now.addingTimeInterval(8 * 86_400))
        t.eq(events.count, 8, "demo: 8 events")
        let live = events.filter { $0.isInProgress(at: now) }
        t.check(live.count == 1 && live[0].joinURL?.host?.contains("teams") == true && !live[0].attendees.isEmpty,
                "demo: one meeting in progress with Teams link and attendees")
        let en = DemoProvider(account: DemoProvider.demoAccount(.microsoft), language: "en", now: now)
        let enFirst = try await en.fetchMessage(id: "demo-m01")
        t.eq(enFirst.summary.subject, "Q4 logistics proposal", "demo: English data")
    } catch {
        t.check(false, "demo provider threw \(error)")
    }

    // AccountStore skeleton.
    let demoStore = AccountStore(fileURL: root.appendingPathComponent("demo-accounts.json"), demo: true)
    t.eq(demoStore.accounts.map(\.id), ["microsoft:ana@contoso.com", "google:demo@gmail.com"], "demo store accounts")
    t.check(demoStore.provider(for: demoStore.accounts[0]) is DemoProvider, "demo store → DemoProvider")
    let file = root.appendingPathComponent("accounts.json")
    let store = AccountStore(fileURL: file, demo: false)
    t.check(store.accounts.isEmpty, "empty store")
    do {
        _ = try await store.connect(.microsoft, registration: .empty) { _ in }
        t.check(false, "connect without registration should throw")
    } catch AccountError.notConfigured(.microsoft) {
        t.check(true, "")
    } catch {
        t.check(false, "connect threw \(error)")
    }
    store.upsert(ConnectedAccount(provider: .google, email: "Someone@Example.com"))
    t.eq(AccountStore(fileURL: file, demo: false).accounts.map(\.id), ["google:someone@example.com"], "accounts persisted")
    try? store.disconnect("google:someone@example.com")
    t.check(AccountStore(fileURL: file, demo: false).accounts.isEmpty, "disconnect persisted")
}
