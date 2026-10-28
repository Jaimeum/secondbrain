import BrainCore
import Foundation

/// v0.7 "Abrir el original" (CONTRACT §17.7): URL building, the web link stored on import (raw `web_link:` +
/// `_thread.json`), the lazy fill of mail saved before v0.7 (DemoProvider), and the event link kept by a recording.
@MainActor func testLinks(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)

    // --- URL building.
    t.eq(OriginalLinks.gmailThread(accountEmail: "Ana@Gmail.com", threadId: "18c2f"), "https://mail.google.com/mail/u/ana@gmail.com/#all/18c2f", "Gmail URL with the account")
    t.eq(OriginalLinks.gmailThread(accountEmail: nil, threadId: "18c2f"), "https://mail.google.com/mail/u/0/#all/18c2f", "Gmail URL without account → u/0")
    t.check(OriginalLinks.split(externalId: "microsoft:AAMk=") .map { $0.provider == .microsoft && $0.messageId == "AAMk=" } == true, "split microsoft externalId")
    t.check(OriginalLinks.split(externalId: "google:abc")?.provider == .google, "split google externalId")
    t.check(OriginalLinks.split(externalId: "local:x") == nil && OriginalLinks.split(externalId: nil) == nil
            && OriginalLinks.split(externalId: "google:") == nil, "no mail provider → nil")
    t.eq(OriginalLinks.provider(forLink: "https://outlook.office365.com/owa/?ItemID=1"), .microsoft, "outlook host")
    t.eq(OriginalLinks.provider(forLink: "https://www.google.com/calendar/event?eid=x"), .google, "google host")
    t.eq(OriginalLinks.provider(forLink: "https://example.com/x"), nil, "unknown host")
    t.check(!OriginalLinks.isOpenable("javascript:alert(1)") && !OriginalLinks.isOpenable("file:///etc/passwd")
            && OriginalLinks.isOpenable("https://x.com"), "only http(s) links open")
    let ms = CalendarEvent(id: "e1", accountId: "microsoft:ana@contoso.com", title: "Kickoff", start: Date(), end: Date(),
                           webLink: "https://outlook.office365.com/owa/?itemid=e1")
    t.check(OriginalLinks.link(for: ms).map { $0.provider == .microsoft && $0.link.hasSuffix("itemid=e1") } == true, "Outlook event link")
    var gEvent = ms
    gEvent.accountId = "google:demo@gmail.com"
    gEvent.webLink = "https://www.google.com/calendar/event?eid=x"
    t.eq(OriginalLinks.link(for: gEvent)?.provider, .google, "Google Calendar htmlLink")
    var local = ms
    local.accountId = "local:calendar"
    local.webLink = "https://example.com"
    t.check(OriginalLinks.link(for: local) == nil, "Mac calendar → no button")
    t.check(OriginalLinks.link(for: CalendarEvent(id: "e2", accountId: "microsoft:a", title: "x", start: Date(), end: Date())) == nil,
            "event without webLink → no button")

    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: LinksNoTranscriber())
    engine.autoProcess = false
    engine.start()
    do {
        try engine.vault.setOwnerEmails(["ana@contoso.com"])
        let acme = try engine.projects.create(name: "Acme", description: "Cliente", emoji: "🚀")

        // --- Import from a connected account keeps the link (raw front matter + _thread.json).
        let account = DemoProvider.demoAccount(.microsoft)
        let demo = DemoProvider(account: account, language: "es")
        let first = try await demo.fetchMessage(id: "demo-m01")
        let thread = try await demo.fetchThread(id: first.summary.threadId)
        t.check(thread.count >= 2, "demo thread has several messages")
        let added = try engine.addMailMessages(thread, account: account, threadKey: nil, projectSlug: acme.slug)
        t.eq(added.count, thread.count, "all messages imported")
        guard let key = added.first?.threadKey, let raw = added.first?.rawPath else { t.check(false, "thread key"); return }
        let rawText = (try? engine.vault.read(raw)) ?? ""
        t.check(rawText.contains("web_link: \"https://outlook.office.com/mail/inbox/id/"), "raw front matter has web_link")
        var info = engine.vault.threadInfo(key: key)
        t.check(info?.messages.allSatisfy { $0.webLink?.hasPrefix("https://outlook.office.com/mail/inbox/id/") == true } == true,
                "_thread.json keeps every message's webLink")
        if let info, let last = info.messages.last {
            t.eq(OriginalLinks.latestLink(in: info)?.link, last.webLink, "thread header opens the newest message")
            t.eq(OriginalLinks.link(for: last, in: info)?.provider, .microsoft, "message link → Outlook")
        }

        // --- Lazy fill (mail saved before v0.7): links removed from _thread.json come back, one call per message.
        let folder = engine.vault.url(for: info?.folderPath ?? "")
        stripWebLinks(folder)
        info = engine.vault.threadInfo(key: key)
        t.check(info?.messages.allSatisfy { $0.webLink == nil } == true, "links stripped (pre-v0.7 thread)")
        t.check(info.flatMap { OriginalLinks.latestLink(in: $0) } == nil, "Outlook mail without link → no button yet")
        let counter = CountingProvider(demo)
        counter.offline = true
        let offline = await engine.fillMissingWebLinks(threadKey: key, accounts: [account]) { _ in counter }
        t.check(offline.added == 0 && offline.retry, "offline: nothing filled, tried again later")
        counter.offline = false
        counter.reset()
        let filled = await engine.fillMissingWebLinks(threadKey: key, accounts: [account]) { _ in counter }.added
        t.check(!(await engine.fillMissingWebLinks(threadKey: key, accounts: [account]) { _ in counter }).retry, "filled: nothing to retry")
        t.eq(filled, thread.count, "lazy fill: every missing link")
        t.eq(counter.fetches, thread.count, "one call per missing message")
        info = engine.vault.threadInfo(key: key)
        t.check(info?.messages.allSatisfy { $0.webLink?.hasPrefix("https://outlook.office.com/mail/inbox/id/") == true } == true,
                "lazy fill persisted in _thread.json")
        let again = await engine.fillMissingWebLinks(threadKey: key, accounts: [account]) { _ in counter }.added
        t.check(again == 0 && counter.fetches == thread.count, "nothing missing → no calls")
        stripWebLinks(folder)
        let none = await engine.fillMissingWebLinks(threadKey: key, accounts: []) { _ in counter }.added
        t.check(none == 0 && counter.fetches == thread.count, "Outlook account not connected → skipped")

        // --- Gmail: the link is built, no call needed; without a link the button still has the conversation URL.
        let gAccount = DemoProvider.demoAccount(.google)
        let gDemo = DemoProvider(account: gAccount, language: "es")
        let gList = try await gDemo.listMessages(since: Date().addingTimeInterval(-90 * 86_400), pageToken: nil).messages
        if let g = gList.first {
            t.check(g.webLink?.hasPrefix("https://mail.google.com/mail/u/\(gAccount.email)/#all/") == true, "demo Gmail link format")
            let gFull = try await gDemo.fetchMessage(id: g.id)
            let gAdded = try engine.addMailMessages([gFull], account: gAccount, threadKey: nil, projectSlug: acme.slug)
            if let gKey = gAdded.first?.threadKey, let gInfo = engine.vault.threadInfo(key: gKey) {
                t.eq(gInfo.messages.first?.webLink, g.webLink, "Gmail link stored")
                stripWebLinks(engine.vault.url(for: gInfo.folderPath))
                let stripped = engine.vault.threadInfo(key: gKey)
                t.eq(stripped.flatMap { OriginalLinks.latestLink(in: $0)?.link },
                     // v0.7 threads writes providerThreadIds: the fallback knows the account and the real thread id.
                     OriginalLinks.gmailThread(accountEmail: gAccount.email, threadId: g.threadId.isEmpty ? g.id : g.threadId),
                     "Gmail without link → conversation URL fallback")
                let gCounter = CountingProvider(gDemo)
                let gFilled = await engine.fillMissingWebLinks(threadKey: gKey, accounts: [gAccount]) { _ in gCounter }.added
                t.check(gFilled == 1 && gCounter.fetches == 0, "Gmail lazy fill builds the URL without calls")
                t.eq(engine.vault.threadInfo(key: gKey)?.messages.first?.webLink,
                     OriginalLinks.gmailThread(accountEmail: gAccount.email, threadId: g.id), "Gmail lazy link uses the account")
            } else { t.check(false, "Gmail message imported") }
        } else { t.check(false, "demo Gmail has messages") }

        // --- Pasted mail: no button.
        let pasted = engine.parseEmail("""
            From: Carlos <carlos@acme.com>
            To: Ana <ana@contoso.com>
            Date: 20/10/2026 10:00
            Subject: Pegado

            Un correo pegado a mano.
            """)
        let p = try engine.addEmail(pasted, threadKey: nil, projectSlug: nil, routeIfUnassigned: false)
        let pInfo = p.threadKey.flatMap { engine.vault.threadInfo(key: $0) }
        t.check(pInfo != nil && OriginalLinks.latestLink(in: pInfo!) == nil, "pasted mail → no link")
        t.check(!((try? engine.vault.read(p.rawPath ?? "")) ?? "").contains("web_link:"), "pasted raw has no web_link")

        // --- A recording tied to an event keeps the event's link.
        engine.linkCalendarEvent(sourceId: p.id, event: ms)
        t.eq(engine.source(p.id)?.webLink, ms.webLink, "recording keeps the event webLink")
        engine.linkCalendarEvent(sourceId: p.id, event: local)
        t.eq(engine.source(p.id)?.webLink, nil, "Mac calendar event → no link")
        let decoded = try? JSONDecoder().decode(SourceRecord.self, from: Data(#"{"id":"x","kind":"meeting","title":"t","status":"done","createdAt":0,"updatedAt":0}"#.utf8))
        t.check(decoded != nil && decoded?.webLink == nil, "SourceRecord without webLink decodes")

        // --- A recording made before v0.7 (event id, no link): the event is looked for once, its link kept.
        let events = try await demo.events(from: Date().addingTimeInterval(-86_400), to: Date().addingTimeInterval(7 * 86_400))
        if let event = events.first(where: { $0.webLink != nil }) {
            let manifest = SessionManifest(id: SessionManifest.newId(at: event.start), title: event.title, projectSlug: acme.slug,
                                           startedAt: event.start, micCaptured: true, calendarEventId: event.id, attendees: nil)
            engine.recordingStarted(manifest)
            t.eq(engine.source(manifest.id)?.webLink, nil, "old recording: no link yet")
            let filled = await engine.fillMeetingWebLink(sourceId: manifest.id, accounts: [account]) { _ in demo }
            t.check(filled && engine.source(manifest.id)?.webLink == event.webLink, "old recording: the event's link found and kept")
            let again = await engine.fillMeetingWebLink(sourceId: manifest.id, accounts: [account]) { _ in demo }
            t.check(!again, "already has its link: nothing to do")
        } else {
            t.check(false, "demo events with links")
        }
    } catch {
        t.check(false, "links: \(error)")
    }
}

/// Removes `webLink` from every message of `<folder>/_thread.json` (a thread saved before v0.7).
private func stripWebLinks(_ folder: URL) {
    let url = folder.appendingPathComponent("_thread.json")
    guard let data = try? Data(contentsOf: url),
          var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let messages = obj["messages"] as? [[String: Any]] else { return }
    obj["messages"] = messages.map { m -> [String: Any] in var m = m; m.removeValue(forKey: "webLink"); return m }
    if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? out.write(to: url)
    }
}

/// Counts the message fetches of a wrapped provider (the lazy fill makes one per missing link).
private final class CountingProvider: MailCalendarProvider, @unchecked Sendable {
    let inner: MailCalendarProvider
    private let lock = NSLock()
    private var count = 0
    var offline = false
    var fetches: Int { lock.withLock { count } }
    func reset() { lock.withLock { count = 0 } }
    init(_ inner: MailCalendarProvider) { self.inner = inner }
    var account: ConnectedAccount { inner.account }
    func profile() async throws -> ConnectedAccount { try await inner.profile() }
    func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        try await inner.listMessages(since: since, pageToken: pageToken)
    }
    func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        try await inner.searchMessages(query, pageToken: pageToken)
    }
    func fetchMessage(id: String) async throws -> MailMessageFull {
        if offline { throw AccountError.network("offline") }
        lock.withLock { count += 1 }
        return try await inner.fetchMessage(id: id)
    }
    func fetchThread(id: String) async throws -> [MailMessageFull] { try await inner.fetchThread(id: id) }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { try await inner.events(from: from, to: to) }
    func listAttachments(messageId: String) async throws -> [AttachmentInfo] { try await inner.listAttachments(messageId: messageId) }
    func downloadAttachment(messageId: String, id: String) async throws -> Data {
        try await inner.downloadAttachment(messageId: messageId, id: id)
    }
}

private final class LinksNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
