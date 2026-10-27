import BrainCore
import Foundation

/// v0.4 routing on the mail side (CONTRACT §14.3, §14.5): `routingSubject(forSourceId:)` from a stored email and a
/// recording tied to an event, and the auto-add cycle against `DemoProvider` on a temp vault (only `autoAddMail`
/// rules, cap, cursor, dedupe, thread precedence, switch, failing account).
@MainActor func testRoutingMail(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    func a(_ email: String, _ name: String? = nil) -> EmailAddress { EmailAddress(name: name, email: email) }

    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: RoutingMailNoTranscriber())
    engine.autoProcess = false
    engine.start()
    do {
        try engine.vault.setOwnerEmails(["ana@contoso.com"])
        let acme = try engine.projects.create(name: "Acme", description: "Cliente de logística", emoji: "🚀")
        let norte = try engine.projects.create(name: "Norte", description: "Estudio de diseño", emoji: "🎨")

        // --- routingSubject(forSourceId:) from a stored (pasted) email: a comma inside a quoted name stays one address.
        let pasted = engine.parseEmail("""
            From: "Ruiz, Carlos" <carlos@acme.com>
            To: Ana <ana@contoso.com>, "Pérez, Luis" <luis@norte.mx>
            Cc: legal@acme.com
            Date: 20/10/2026 10:00
            Subject: Contrato marco

            Va el contrato marco para revisión.
            """)
        let stored = try engine.addEmail(pasted, threadKey: nil, projectSlug: nil, routeIfUnassigned: false)
        t.eq(stored.projectSlug, nil, "pasted email in the inbox")
        let subject = engine.routingSubject(forSourceId: stored.id)
        t.check(subject?.kind == .mail, "email subject kind")
        t.eq(subject?.sender?.email, "carlos@acme.com", "sender from the raw")
        t.eq(subject?.recipients.compactMap(\.email) ?? [], ["ana@contoso.com", "luis@norte.mx", "legal@acme.com"], "to + cc from the raw")
        t.eq(subject?.subject, "Contrato marco", "subject from the raw")
        t.check(subject?.text.contains("contrato marco") == true, "body as text")
        t.check(subject?.ownerEmails.contains("ana@contoso.com") == true, "owner emails carried")
        if let subject {
            let rule = RoutingStore.suggestedRule(for: subject, projectSlug: acme.slug, language: "es")
            t.eq(rule?.conditions, [RuleCondition(field: .senderDomain, op: .is, value: "acme.com")], "offer from a stored email: sender domain")
        }
        // A colleague (the owner's own domain) is proposed by address, never "everything from @contoso.com".
        let colleague = RoutingSubject(kind: .mail, sender: a("diego@contoso.com"), recipients: [a("ana@contoso.com")], subject: "x", text: "",
                                       ownerEmails: ["ana@contoso.com"])
        t.eq(RoutingStore.suggestedRule(for: colleague, projectSlug: acme.slug, language: "es")?.conditions,
             [RuleCondition(field: .senderEmail, op: .is, value: "diego@contoso.com")], "colleague → senderEmail")
        let toColleague = RoutingSubject(kind: .mail, sender: a("ana@contoso.com"), recipients: [a("diego@contoso.com")], subject: "x",
                                         text: "", ownerEmails: ["ana@contoso.com"])
        t.eq(RoutingStore.suggestedRule(for: toColleague, projectSlug: acme.slug, language: "es")?.conditions,
             [RuleCondition(field: .recipient, op: .is, value: "diego@contoso.com")], "owner → colleague: recipient address")
        t.check(engine.routingSubject(forSourceId: "nope") == nil, "unknown source → nil")
        // After "Asignar" the raw moved with the thread: still readable.
        try engine.assign(sourceId: stored.id, to: acme.slug)
        t.eq(engine.routingSubject(forSourceId: stored.id)?.sender?.email, "carlos@acme.com", "subject after the move")

        // A recording tied to a calendar event: only with that event.
        let event = CalendarEvent(id: "ev-1", accountId: "local:calendar", title: "Revisión Norte", start: Date(),
                                  end: Date().addingTimeInterval(1800), organizer: a("mariana@estudionorte.mx"),
                                  attendees: [a("ana@contoso.com"), a("mariana@estudionorte.mx")])
        var recording = SourceRecord(id: "rec-1", kind: .meeting, title: "Revisión", projectSlug: nil, status: .needsProject)
        t.check(engine.meetingRoutingSubject(recording, event: event, ownerEmails: ["ana@contoso.com"]) == nil, "meeting without calendarEventId → nil")
        recording.calendarEventId = "ev-1"
        let meeting = engine.meetingRoutingSubject(recording, event: event, ownerEmails: ["ana@contoso.com"])
        t.check(meeting?.kind == .meeting && meeting?.sender?.email == "mariana@estudionorte.mx", "meeting subject from its event")
        t.check(engine.meetingRoutingSubject(recording, event: nil, ownerEmails: []) == nil, "meeting without the cached event → nil")
        var other = event
        other.id = "ev-2"
        t.check(engine.meetingRoutingSubject(recording, event: other, ownerEmails: []) == nil, "another event → nil")

        // --- Auto-add (§14.5) with DemoProvider.
        let account = DemoProvider.demoAccount(.microsoft)
        let now = Date()
        let demo = DemoProvider(account: account, language: "es", now: now)
        let provide: (ConnectedAccount) -> MailCalendarProvider = { _ in demo }
        func run(cap: Int = BrainEngine.mailAutoImportCap, accounts: [ConnectedAccount]? = nil) async -> MailAutoImportReport {
            await engine.runMailAutoImport(now: now, cap: cap, accounts: accounts ?? [account], provider: provide)
        }
        let window = now.addingTimeInterval(-BrainEngine.mailAutoImportLookback)
        var all: [MailMessageSummary] = []
        var token: String?
        repeat {
            let page = try await demo.listMessages(since: window, pageToken: token)
            all += page.messages
            token = page.next
        } while token != nil
        func ext(_ id: String) -> String { MailImport.externalId(account: account, messageId: id) }
        // senderDomain contoso.com also takes the owner's own messages (ana@contoso.com): the rules don't special-case them.
        let contoso = all.filter { $0.from.email?.hasSuffix("@contoso.com") == true }
        t.check(contoso.count >= 3, "demo: several contoso.com messages in the last 7 days (\(contoso.count))")

        // Nothing without auto rules (a plain rule doesn't add).
        let plain = RoutingRule(.senderDomain, .is, "estudionorte.mx", projectSlug: norte.slug)
        try engine.routing.add(plain)
        var report = await run()
        t.check(report.idle && report.total == 0, "no auto rule → idle")
        t.check(engine.routing.settings.mailSyncCursors.isEmpty, "idle: no cursor")

        // An auto rule created a month ago: the first cycle looks back 7 days at most.
        var auto = RoutingRule(.senderDomain, .is, "contoso.com", projectSlug: acme.slug)
        auto.autoAddMail = true
        auto.createdAt = now.addingTimeInterval(-30 * 86_400)
        try engine.routing.add(auto)
        // Dedupe: one of them is already in the brain (added by hand to Norte, so its conversation stays there).
        let manual = contoso[0]
        try engine.addMailMessages([try await demo.fetchMessage(id: manual.id)], account: account, threadKey: nil,
                                   projectSlug: norte.slug, routeIfUnassigned: false)
        t.check(engine.emailSource(externalId: ext(manual.id)) != nil, "manual message stored")

        report = await run(cap: 1)
        t.eq(report.total, 1, "cap 1 → one message")
        t.check(report.reachedCap, "cap reached")
        let cursor1 = engine.routing.settings.mailSyncCursors[account.id]
        t.check(cursor1 != nil, "cursor saved")
        let firstAdded = report.sourceIds.first.flatMap { engine.source($0) }
        t.check(firstAdded?.externalId.map { e in contoso.contains { ext($0.id) == e } } == true, "added one of the contoso.com messages")
        if let cursor1, let firstAdded, let date = all.first(where: { ext($0.id) == firstAdded.externalId })?.date {
            t.eq(cursor1, date, "cursor stops at the last message looked at")
        }

        report = await run()
        let expected = contoso.count - 1 - 1   // minus the manual one and the one of the first cycle
        t.eq(report.total, expected, "second cycle adds the rest")
        t.check(!report.reachedCap, "below the cap")
        let added = contoso.compactMap { engine.emailSource(externalId: ext($0.id)) }
        t.eq(added.count, contoso.count, "every contoso.com message is in the brain once")
        t.check(engine.sources.filter { $0.externalId == ext(manual.id) }.count == 1, "the manual one wasn't duplicated")
        let fromNorte = all.filter { $0.from.email?.hasSuffix("@estudionorte.mx") == true }
        t.check(fromNorte.allSatisfy { engine.emailSource(externalId: ext($0.id)) == nil }, "a plain (non-auto) rule never adds")
        // Destination: the rule's project, except a conversation already in a project keeps it (§14.2 step 2).
        for m in contoso where m.id != manual.id {
            guard let src = engine.emailSource(externalId: ext(m.id)) else { continue }
            let sameThreadAsManual = m.threadId == manual.threadId
            t.eq(src.projectSlug, sameThreadAsManual ? norte.slug : acme.slug, "auto-added \(m.id) → \(sameThreadAsManual ? "thread's project" : "rule's project")")
        }
        t.check(report.added.allSatisfy { $0.projectSlug != nil }, "report per project")
        t.check((engine.routing.rule(id: auto.id)?.hits ?? 0) >= 1, "auto-add counts hits")
        let newest = all.map(\.date).max()
        t.eq(engine.routing.settings.mailSyncCursors[account.id], newest, "cursor at the newest message after a full cycle")

        // Third cycle: nothing new.
        report = await run()
        t.eq(report.total, 0, "third cycle: dedupe, nothing added")
        t.check(!report.idle, "third cycle ran")

        // A message older than the cursor isn't looked at again even if a new rule would take it.
        var autoNorte = RoutingRule(.senderDomain, .is, "estudionorte.mx", projectSlug: norte.slug)
        autoNorte.autoAddMail = true
        try engine.routing.remove(id: plain.id)
        try engine.routing.add(autoNorte)
        let atCursor = fromNorte.filter { $0.date >= (newest ?? now) }.count   // the cursor's own minute is listed again
        report = await run()
        t.eq(report.total, atCursor, "behind the cursor: not re-scanned")
        // Forgetting the cursor (e.g. a new account) scans the window again and only adds the new rule's mail.
        try engine.routing.setMailSyncCursor(nil, for: account.id)
        report = await run()
        t.eq(report.total, fromNorte.count - atCursor, "new auto rule after a cursor reset")
        for m in fromNorte {
            // A reply in a conversation that is already in the brain joins it (demo-m05 answers Laura's thread in Acme).
            let stored = contoso.first { $0.threadId == m.threadId }.flatMap { engine.emailSource(externalId: ext($0.id)) }
            t.eq(engine.emailSource(externalId: ext(m.id))?.projectSlug, stored?.projectSlug ?? norte.slug,
                 "\(m.id) → \(stored == nil ? "Norte by the rule" : "its conversation's project")")
        }
        t.check(fromNorte.contains { m in !contoso.contains { $0.threadId == m.threadId } }, "demo: a Norte message outside any stored thread")

        // Switch off, no accounts, a failing account.
        try engine.routing.setAutoImportEnabled(false)
        t.check(!RoutingStore(fileURL: engine.routing.fileURL).settings.autoImportEnabled, "switch persisted")
        report = await run()
        t.check(report.idle, "switch off → idle")
        try engine.routing.setAutoImportEnabled(true)
        report = await run(accounts: [])
        t.check(report.idle, "no accounts → idle")
        let broken = ConnectedAccount(provider: .google, email: "x@gmail.com")
        report = await engine.runMailAutoImport(now: now, accounts: [broken], provider: { _ in FailingMailProvider(account: broken) })
        t.eq(report.failedAccounts, [broken.id], "failing account reported, no throw")
        t.check(engine.routing.settings.mailSyncCursors[broken.id] == nil, "failing account: cursor untouched")
        // Old JSON without the switch decodes as on.
        let legacy = try JSONDecoder().decode(RoutingSettings.self, from: Data(#"{"rules":[]}"#.utf8))
        t.check(legacy.autoImportEnabled, "autoImportEnabled defaults to true")
        engine.routing.flush()
    } catch {
        t.check(false, "routing-mail: \(error)")
    }
}

private final class FailingMailProvider: MailCalendarProvider, @unchecked Sendable {
    let account: ConnectedAccount
    init(account: ConnectedAccount) { self.account = account }
    func profile() async throws -> ConnectedAccount { throw AccountError.unauthorized }
    func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) { throw AccountError.unauthorized }
    func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) { throw AccountError.unauthorized }
    func fetchMessage(id: String) async throws -> MailMessageFull { throw AccountError.unauthorized }
    func fetchThread(id: String) async throws -> [MailMessageFull] { throw AccountError.unauthorized }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { [] }
}

private final class RoutingMailNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
