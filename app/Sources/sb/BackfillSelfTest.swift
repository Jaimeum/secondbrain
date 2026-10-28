import ArgumentParser
import BrainCore
import Foundation

// MARK: v0.7 backfill — `sb backfill selftest` (CONTRACT §17.6)

struct BackfillCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "backfill", abstract: "Mail saved backwards (v0.7).",
                                                    subcommands: [BackfillSelfTestCmd.self])
}

/// `sb backfill selftest [--dir <tmp>]`: "Traer anteriores" (search hint, rule evaluation with priority, 90-day window,
/// cap), whole conversations saved once (already-saved skipped, a conversation in a project stays there) and the
/// attachment preselection, against DemoProvider on a temp vault. No Claude, no network.
struct BackfillSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of multi-select and \"Traer anteriores\".")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-backfill-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        t.group("backfill-hint") { testBackfillHint(t) }
        t.group("backfill-preselect") { testBackfillPreselect(t) }
        await t.groupAsync("backfill-search") { await testBackfillSearch(t) }
        await t.groupAsync("backfill-save") { await testBackfillSave(t, root: root.appendingPathComponent("save")) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

@MainActor func testBackfillHint(_ t: Tester) {
    t.eq(MailBackfill.searchHint(for: RoutingRule(.senderDomain, .is, "@acme.com", projectSlug: "a")), "acme.com", "domain without @")
    t.eq(MailBackfill.searchHint(for: RoutingRule(.senderDomain, .is, "*.acme.com", projectSlug: "a")), "acme.com", "domain without *.")
    t.eq(MailBackfill.searchHint(for: RoutingRule(.senderEmail, .is, "ana@acme.com", projectSlug: "a")), "ana@acme.com", "address as is")
    t.eq(MailBackfill.searchHint(for: RoutingRule(.subject, .contains, "Contrato \"marco\"", projectSlug: "a")), "Contrato  marco", "quotes dropped")
    t.eq(MailBackfill.searchHint(for: RoutingRule(.subject, .contains, "x", projectSlug: "a")), nil, "a one-letter value lists instead")
    let meeting = RoutingRule(.organizerEmail, .is, "ana@acme.com", projectSlug: "a")
    t.check(!MailBackfill.isMailRule(meeting), "an organizer rule is meetings-only")
    t.check(MailBackfill.isMailRule(RoutingRule(.title, .contains, "Weekly", projectSlug: "a")), "a title rule also catches mail")
    t.eq(MailBackfill.threadIds([
        MailMessageSummary(id: "1", threadId: "a", from: EmailAddress(name: nil, email: "x@y.z"), to: [], subject: "", snippet: "", date: Date(timeIntervalSince1970: 1)),
        MailMessageSummary(id: "2", threadId: "b", from: EmailAddress(name: nil, email: "x@y.z"), to: [], subject: "", snippet: "", date: Date(timeIntervalSince1970: 3)),
        MailMessageSummary(id: "3", threadId: "a", from: EmailAddress(name: nil, email: "x@y.z"), to: [], subject: "", snippet: "", date: Date(timeIntervalSince1970: 2)),
    ]), ["b", "a"], "conversations once, newest first")
}

@MainActor func testBackfillPreselect(_ t: Tester) {
    let message = MailMessageFull(summary: MailMessageSummary(id: "m", threadId: "m", from: EmailAddress(name: nil, email: "a@b.c"),
                                                              to: [], subject: "", snippet: "", date: Date()), bodyText: "x")
    let list = [AttachmentInfo(id: "pdf", name: "Contrato.pdf", mimeType: "application/pdf", size: 200_000),
                AttachmentInfo(id: "ref", name: "Link.url", mimeType: "", size: 0, isDownloadable: false)]
    let rows = MailBackfill.preselection(list, message: message)
    t.eq(rows.count, 2, "one row per attachment")
    t.check(rows.first { $0.info.id == "pdf" }?.checked == rows.first { $0.info.id == "pdf" }?.decision.preselected,
            "a file starts as the triage says")
    t.check(rows.first { $0.info.id == "ref" }?.checked == false, "what is not a file never starts ticked")
    t.check(AttachmentDecision.keep.preselected && AttachmentDecision.ask.preselected, "keep ✓ ambiguous ✓")
    t.check(!AttachmentDecision.tooBig.preselected && !AttachmentDecision.discard(.inlineImage).preselected, "too big ☐ discard ☐")
}

@MainActor func testBackfillSearch(_ t: Tester) async {
    let account = DemoProvider.demoAccount(.microsoft)
    let now = Date()
    let demo = DemoProvider(account: account, language: "es", now: now)
    let owners = ["ana@contoso.com"]
    let acme = RoutingRule(.senderDomain, .is, "acmelogistics.com", projectSlug: "acme")
    do {
        let found = try await MailBackfill.findMatches(rule: acme, rules: [acme], provider: demo, ownerEmails: owners, now: now)
        t.check(!found.isEmpty, "finds the demo's acmelogistics.com mail (\(found.count))")
        t.check(found.allSatisfy { $0.from.email?.hasSuffix("@acmelogistics.com") == true }, "only what the rule catches")
        t.check(zip(found, found.dropFirst()).allSatisfy { $0.date >= $1.date }, "newest first")
        // The search hint finds mail where the domain is only in the body; the rule (sender) still decides.
        let capped = try await MailBackfill.findMatches(rule: acme, rules: [acme], provider: demo, ownerEmails: owners, now: now, limit: 1)
        t.eq(capped.count, 1, "cap")
        // A rule above it that catches the same mail wins: the new rule would never have caught it.
        let above = RoutingRule(.senderEmail, .contains, "sofia.herrera", projectSlug: "other")
        let shadowed = try await MailBackfill.findMatches(rule: acme, rules: [above, acme], provider: demo, ownerEmails: owners, now: now)
        t.eq(shadowed.count, 0, "a higher-priority rule takes them")
        var disabled = above
        disabled.enabled = false
        let notShadowed = try await MailBackfill.findMatches(rule: acme, rules: [disabled, acme], provider: demo, ownerEmails: owners, now: now)
        t.eq(notShadowed.count, found.count, "a disabled rule above doesn't")
        // The window: nothing older than `days` (the demo's mail is from the last 10 days).
        let short = try await MailBackfill.findMatches(rule: acme, rules: [acme], provider: demo, ownerEmails: owners,
                                                       now: now.addingTimeInterval(400 * 86_400))
        t.eq(short.count, 0, "older than 90 days → nothing")
        // No usable value: the window is listed and the rule evaluated on every message.
        let tiny = RoutingRule(conditions: [RuleCondition(field: .senderDomain, op: .is, value: "acmelogistics.com"),
                                            RuleCondition(field: .subject, op: .contains, value: "")], projectSlug: "acme")
        let listed = try await MailBackfill.findMatches(rule: tiny, rules: [tiny], provider: demo, ownerEmails: owners, now: now)
        t.eq(listed.count, 0, "a rule with an empty condition never matches")
        let subjectRule = RoutingRule(.anyText, .contains, "kickoff", projectSlug: "acme")
        let bySubject = try await MailBackfill.findMatches(rule: subjectRule, rules: [subjectRule], provider: demo, ownerEmails: owners, now: now)
        t.check(bySubject.contains { $0.subject.localizedCaseInsensitiveContains("kickoff") }, "a text rule through the search")
    } catch {
        t.check(false, "search: \(error)")
    }
}

@MainActor func testBackfillSave(_ t: Tester, root: URL) async {
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: BackfillNoTranscriber())
    engine.autoProcess = false
    engine.start()
    let account = DemoProvider.demoAccount(.microsoft)
    let demo = DemoProvider(account: account, language: "es", now: Date())
    func ext(_ id: String) -> String { MailImport.externalId(account: account, messageId: id) }
    do {
        try engine.vault.setOwnerEmails(["ana@contoso.com"])
        let acme = try engine.projects.create(name: "Acme", description: "Logística", emoji: "🚀")
        let norte = try engine.projects.create(name: "Norte", description: "Diseño", emoji: "🎨")
        let thread = try await demo.fetchThread(id: "demo-thread-acme")
        t.check(thread.count >= 3, "demo conversation (\(thread.count) messages)")
        t.check(engine.storedThread(of: thread, account: account) == nil, "not in the brain yet")

        // One message saved by hand to Norte: the rest of the conversation joins it there, whatever was picked.
        try engine.addMailMessages([thread[0]], account: account, threadKey: nil, projectSlug: norte.slug, routeIfUnassigned: false)
        let stored = engine.storedThread(of: thread, account: account)
        t.eq(stored?.projectSlug, norte.slug, "stored thread found by any of its messages")
        t.eq(engine.unsavedMessages(thread, account: account).count, thread.count - 1, "what is missing")
        let added = try engine.saveMailConversation(thread, account: account, projectSlug: acme.slug)
        t.eq(added.count, thread.count - 1, "only the missing ones are saved")
        t.check(added.allSatisfy { $0.projectSlug == norte.slug }, "a conversation in a project stays there")
        t.check(added.allSatisfy { $0.threadKey == stored?.key }, "same thread")
        t.eq(try engine.saveMailConversation(thread, account: account, projectSlug: acme.slug).count, 0, "saving again adds nothing")
        t.eq(Set(thread.map { ext($0.summary.id) }).count, engine.sources.filter { $0.externalId.map { e in thread.contains { ext($0.summary.id) == e } } ?? false }.count,
             "each message once")

        // A new conversation goes to the chosen project; a rule never overrides it (explicit Sin asignar too).
        let kickoff = try await demo.fetchThread(id: "demo-thread-kickoff")
        try engine.routing.add(RoutingRule(.senderDomain, .is, "contoso.com", projectSlug: norte.slug))
        let toInbox = try engine.saveMailConversation(kickoff, account: account, projectSlug: nil)
        t.check(!toInbox.isEmpty && toInbox.allSatisfy { $0.projectSlug == nil }, "explicit Sin asignar is not routed")
        // A conversation in Sin asignar moves with the new messages to the chosen project.
        let single = try await demo.fetchMessage(id: "demo-m11")
        try engine.addMailMessages([single], account: account, threadKey: nil, projectSlug: nil, routeIfUnassigned: false)
        t.eq(try engine.saveMailConversation([single], account: account, projectSlug: acme.slug).count, 0, "fully saved → nothing")

        // The attachment step is the attach area's (v0.7 integration point): nothing ticked → nothing to do.
        if let src = added.first, let message = thread.first(where: { ext($0.summary.id) == src.externalId }) {
            let n = try await engine.backfillSaveAttachments([], confirmed: [], of: message, emailSource: src, account: account, provider: demo)
            t.eq(n, 0, "no attachments → 0")
        }
    } catch {
        t.check(false, "save: \(error)")
    }
}

private final class BackfillNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
