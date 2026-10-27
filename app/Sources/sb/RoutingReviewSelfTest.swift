import BrainCore
import Foundation

/// v0.4 routing review fixes (CONTRACT §14.2–§14.5): no offer that a rule already shadows, domain spellings seen as the
/// same rule, rules from a newer version kept on save, reorder applied to what is on disk, organizer rules for meetings
/// only, subjects without "RE:", rules to a deleted project neither decide nor count nor auto-add, and an auto-add that
/// fails keeps its cursor.
@MainActor func testRoutingReview(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    func a(_ email: String) -> EmailAddress { EmailAddress(name: nil, email: email) }
    let owner = "ana@contoso.com"
    func mail(_ from: String, _ subject: String, to: [String] = [owner]) -> RoutingSubject {
        RoutingSubject(kind: .mail, sender: a(from), recipients: to.map(a), subject: subject, text: "", ownerEmails: [owner])
    }
    func same(_ x: RoutingRule, _ y: RoutingRule) -> Bool { x.hasSameConditions(as: y) }

    // --- §14.3: never offer a rule that an existing rule would always beat.
    let by2027 = RoutingRule(.subject, .contains, "2027", projectSlug: "migracion")
    let budget = mail("luis@acme.com", "Budget 2027")
    t.check(RoutingStore.offeredRule(for: budget, projectSlug: "atlas", existing: [by2027], language: "es") == nil,
            "offer: overriding a rule's choice → nothing (the new rule could never fire)")
    t.eq(RoutingStore.offeredRule(for: mail("luis@acme.com", "Hola"), projectSlug: "atlas", existing: [by2027], language: "es")?.conditions,
         [RuleCondition(field: .senderDomain, op: .is, value: "acme.com")], "offer: no rule matches → offered")
    let newsletters = RoutingRule(.senderDomain, .is, "news.io", projectSlug: nil)
    t.check(RoutingStore.offeredRule(for: mail("hola@news.io", "Boletín"), projectSlug: "atlas", existing: [newsletters], language: "es") == nil,
            "offer: mail an explicit Sin asignar rule put there → nothing")
    var off2027 = by2027
    off2027.enabled = false
    t.check(RoutingStore.offeredRule(for: budget, projectSlug: "atlas", existing: [off2027], language: "es") != nil,
            "offer: a disabled rule doesn't block it")
    let meetingByLuis = CalendarEvent(id: "m1", accountId: "local:calendar", title: "Revisión 2027", start: Date(),
                                      end: Date().addingTimeInterval(1800), organizer: a("luis@acme.com"), attendees: [a(owner)])
    t.check(MeetingRuleOffers.forMeeting(meetingByLuis, projectSlug: "atlas", previous: nil, ownerEmails: [owner], existing: [by2027],
                                         language: "es") == nil, "meeting offer: a rule matches the meeting → nothing")

    // --- Equivalent rules: domain spellings.
    let domain = RoutingRule(.senderDomain, .is, "acme.com", projectSlug: "x")
    t.check(same(RoutingRule(.senderDomain, .is, "@acme.com", projectSlug: "y"), domain), "same: senderDomain @acme.com")
    t.check(same(RoutingRule(.senderDomain, .is, "*.Acme.com.", projectSlug: "y"), domain), "same: senderDomain *.acme.com.")
    t.check(same(RoutingRule(.senderEmail, .is, "acme.com", projectSlug: "y"), domain), "same: senderEmail is <domain>")
    t.check(same(RoutingRule(.senderEmail, .is, "@acme.com", projectSlug: "y"), domain), "same: senderEmail is @<domain>")
    t.check(!same(RoutingRule(.senderEmail, .is, "luis@acme.com", projectSlug: "y"), domain), "not same: an address")
    t.check(!same(RoutingRule(.senderEmail, .contains, "acme.com", projectSlug: "y"), domain), "not same: contains on the address")
    t.check(same(RoutingRule(.attendeeEmail, .is, "@banco.mx", projectSlug: "y"), RoutingRule(.attendeeDomain, .is, "banco.mx", projectSlug: "x")),
            "same: attendeeEmail is <domain>")
    t.check(same(RoutingRule(.recipient, .is, "@cliente.mx", projectSlug: "y"), RoutingRule(.recipient, .is, "cliente.mx", projectSlug: "x")),
            "same: recipient @domain")
    t.check(!same(RoutingRule(.organizerEmail, .is, "acme.com", projectSlug: "y"), domain), "not same: organizer (meetings only)")
    var atDomain = RoutingRule(.senderDomain, .is, "@acme.com", projectSlug: "atlas")
    atDomain.enabled = false   // so it doesn't match: only the equivalence check can stop the offer
    t.check(RoutingStore.offeredRule(for: mail("luis@acme.com", "x"), projectSlug: "atlas", existing: [atDomain], language: "es") == nil,
            "offer: an equivalent @acme.com rule exists → nothing")

    // --- organizerEmail: meetings only.
    let organizer = RoutingRule(.organizerEmail, .is, "laura@contoso.com", projectSlug: "x")
    t.check(!RuleMatcher.matches(organizer, mail("laura@contoso.com", "Hola")), "organizer rule doesn't sort Laura's mail")
    let byLaura = CalendarEvent(id: "m2", accountId: "local:calendar", title: "Sync", start: Date(), end: Date().addingTimeInterval(1800),
                                organizer: a("laura@contoso.com"), attendees: [a(owner)])
    t.check(RuleMatcher.matches(organizer, .meeting(byLaura, ownerEmails: [owner])), "organizer rule takes her meetings")
    t.check(RuleMatcher.matches(RoutingRule(.senderEmail, .is, "laura@contoso.com", projectSlug: "x"), .meeting(byLaura, ownerEmails: [owner])),
            "senderEmail still covers meetings she organizes")

    // --- Subjects: replies and forwards follow the rule.
    let weekly = RoutingRule(.subject, .is, "Weekly sync", projectSlug: "x")
    for s in ["Weekly sync", "RE: Weekly sync", "Fwd: RV: Weekly sync", "re:  weekly SYNC"] {
        t.check(RuleMatcher.matches(weekly, mail("x@y.com", s)), "subject is: «\(s)»")
    }
    t.check(!RuleMatcher.matches(weekly, mail("x@y.com", "Weekly sync notes")), "subject is: not a longer subject")
    t.check(RuleMatcher.matches(RoutingRule(.subject, .startsWith, "weekly", projectSlug: "x"), mail("x@y.com", "Fwd: Weekly sync")),
            "subject startsWith after Fwd:")
    t.check(RuleMatcher.matches(RoutingRule(.subject, .startsWith, "re:", projectSlug: "x"), mail("x@y.com", "RE: algo")),
            "subject as written still matches")
    t.check(RuleMatcher.matches(RoutingRule(.anyText, .startsWith, "weekly", projectSlug: "x"), mail("x@y.com", "RE: Weekly")),
            "anyText: subject without prefix")

    // --- Wording.
    t.eq(RoutingStore.generatedName(conditions: [RuleCondition(field: .subject, op: .contains, value: "2027")], projectLabel: "☁️ Nube",
                                    language: "en"), "The subject contains “2027” → ☁️ Nube", "English names use English quotes")
    t.eq(RoutingStore.generatedName(conditions: [RuleCondition(field: .subject, op: .contains, value: "2027")], projectLabel: "☁️ Nube",
                                    language: "es"), "El asunto contiene «2027» → ☁️ Nube", "Spanish names keep «»")

    // --- Store: rules from a newer version survive a save; reorder and refresh follow the disk.
    let file = root.appendingPathComponent("vault/.secondbrain/routing.json")
    try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        let newer = """
        {"rules":[{"id":"a","conditions":[{"field":"subject","op":"contains","value":"hola"}],"projectSlug":"p"},
                  {"id":"future","conditions":[{"field":"githubRepo","op":"is","value":"acme/app"}],"projectSlug":"p","weight":2.5},
                  {"id":"b","conditions":[{"field":"senderDomain","op":"regex","value":".*"}]},
                  {"id":"c","conditions":[{"field":"senderDomain","op":"is","value":"acme.com"}],"projectSlug":"q"}],
         "defaultProjectSlug":"g","futureSetting":{"x":[1,true,null,"s"]}}
        """
        try Data(newer.utf8).write(to: file)
        let store = RoutingStore(fileURL: file)
        t.eq(store.rules.map(\.id), ["a", "c"], "unreadable rules hidden from this version")
        t.check(!fm.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("routing.corrupt.json").path),
                "a readable file with newer rules is not treated as corrupt")
        _ = store.route(mail("x@acme.com", "x"))
        store.flush()
        try store.add(RoutingRule(.subject, .contains, "nubia", projectSlug: "n"))
        func diskIds() -> [String] {
            let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
            return ((obj?["rules"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        }
        let ids = diskIds()
        t.eq(Array(ids.prefix(4)), ["a", "future", "b", "c"], "newer rules written back in place after a hit and an add")
        t.eq(ids.count, 5, "and the new rule after them")
        let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        t.check(obj?["futureSetting"] != nil, "unknown top-level key kept")
        let future = ((obj?["rules"] as? [[String: Any]]) ?? []).first { $0["id"] as? String == "future" }
        t.eq(future?["weight"] as? Double, 2.5, "unknown rule kept as written")
        t.eq(RoutingStore(fileURL: file).rule(id: "c")?.hits, 1, "hit still counted on the readable rule")
        try store.remove(id: "a")
        t.eq(Array(diskIds().prefix(3)), ["future", "b", "c"], "a newer rule whose neighbour was removed stays put")

        // Reorder by id onto the disk: a rule added meanwhile by another process survives.
        let other = RoutingStore(fileURL: file)
        let external = RoutingRule(.senderDomain, .is, "banco.mx", projectSlug: "n")
        try other.add(external)
        let shown = store.rules.map(\.id)   // the app still shows the old list
        t.check(!shown.contains(external.id), "the app hasn't seen the external rule yet")
        try store.move(fromOffsets: IndexSet(integer: shown.count - 1), toOffset: 0)
        t.check(store.rule(id: external.id) != nil && RoutingStore(fileURL: file).rule(id: external.id) != nil,
                "move keeps the rule another process added")
        t.eq(store.rules.first?.id, shown.last, "move applied")
        t.check(diskIds().contains("future"), "move keeps newer rules too")
        // refresh: picks up what changed on disk, without writing.
        let late = RoutingRule(.subject, .contains, "tarde", projectSlug: nil)
        try other.add(late)
        t.check(store.rule(id: late.id) == nil, "not seen before refresh")
        store.refresh()
        t.check(store.rule(id: late.id) != nil, "refresh reads the external change")
    } catch {
        t.check(false, "store: \(error)")
    }

    // --- Engine: a rule to a deleted project neither decides nor counts; auto-add skips it; failed adds keep the cursor.
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("engine/vault").path
    config.dataPath = root.appendingPathComponent("engine/data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: ReviewNoTranscriber())
    engine.autoProcess = false
    engine.start()
    do {
        try engine.vault.setOwnerEmails([owner])
        let general = try engine.projects.create(name: "General", description: "Todo", emoji: "📦")
        var ghost = RoutingRule(.senderDomain, .is, "ghost.io", projectSlug: "ghost")
        ghost.autoAddMail = true
        ghost.createdAt = Date().addingTimeInterval(-86_400)
        try engine.routing.add(ghost)
        try engine.routing.setDefaultProject(general.slug)
        let ghostMail = mail("g@ghost.io", "Bu")
        let preview = engine.routingPreview(ghostMail)
        t.check(preview.decision == nil && preview.projectSlug == general.slug, "preview: rule to a deleted project skipped → default")
        let added = try engine.addEmail(engine.parseEmail("From: G <g@ghost.io>\nTo: \(owner)\nDate: 24/10/2026 10:00\nSubject: Bu\n\nHola."),
                                        threadKey: nil, projectSlug: nil)
        t.eq(added.projectSlug, general.slug, "rule to a deleted project → default project")
        t.eq(engine.routing.rule(id: ghost.id)?.hits ?? -1, 0, "and it counts no hit")

        let account = ConnectedAccount(provider: .google, email: owner)
        let now = Date()
        let stub = StubMailProvider(account: account, messages: [
            ("s1", "g@ghost.io", "Uno", now.addingTimeInterval(-3_600)),
            ("s2", "laura@cliente.mx", "Dos", now.addingTimeInterval(-1_800)),
            ("s3", "laura@cliente.mx", "Tres", now.addingTimeInterval(-900)),
        ])
        var report = await engine.runMailAutoImport(now: now, accounts: [account], provider: { _ in stub })
        t.check(report.idle && report.total == 0, "auto-add: only a rule to a deleted project → idle, nothing added")

        // A destination that can't be written: nothing added, the cursor doesn't pass the message.
        let locked = try engine.projects.create(name: "Cerrado", description: "Sin permiso", emoji: "🔒")
        let lockedDir = engine.vault.root.appendingPathComponent("projects/\(locked.slug)/raw/emails")
        try fm.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        var cliente = RoutingRule(.senderDomain, .is, "cliente.mx", projectSlug: locked.slug)
        cliente.autoAddMail = true
        cliente.createdAt = now.addingTimeInterval(-86_400)
        try engine.routing.add(cliente)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)
        report = await engine.runMailAutoImport(now: now, accounts: [account], provider: { _ in stub })
        t.eq(report.total, 0, "auto-add: the write failed → nothing added")
        let cursor = engine.routing.settings.mailSyncCursors[account.id]
        t.check(cursor.map { $0 < now.addingTimeInterval(-1_800) } ?? true, "the cursor stays before the failed message")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        report = await engine.runMailAutoImport(now: now, accounts: [account], provider: { _ in stub })
        t.eq(report.total, 2, "next cycle retries and adds both")
        t.eq(engine.routing.settings.mailSyncCursors[account.id], now.addingTimeInterval(-900), "then the cursor moves on")
        engine.routing.flush()
    } catch {
        t.check(false, "engine: \(error)")
    }
}

private final class StubMailProvider: MailCalendarProvider, @unchecked Sendable {
    let account: ConnectedAccount
    let all: [MailMessageFull]
    init(account: ConnectedAccount, messages: [(String, String, String, Date)]) {
        self.account = account
        all = messages.map { id, from, subject, date in
            MailMessageFull(summary: MailMessageSummary(id: id, threadId: "t-\(id)", from: EmailAddress(name: nil, email: from),
                                                        to: [EmailAddress(name: nil, email: account.email)], subject: subject,
                                                        snippet: subject, date: date),
                            bodyText: "Mensaje \(subject).")
        }
    }
    func profile() async throws -> ConnectedAccount { account }
    func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        (all.map(\.summary).filter { $0.date >= since }, nil)
    }
    func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) { ([], nil) }
    func fetchMessage(id: String) async throws -> MailMessageFull {
        guard let m = all.first(where: { $0.summary.id == id }) else { throw AccountError.unauthorized }
        return m
    }
    func fetchThread(id: String) async throws -> [MailMessageFull] { all.filter { $0.summary.threadId == id } }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { [] }
}

private final class ReviewNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
