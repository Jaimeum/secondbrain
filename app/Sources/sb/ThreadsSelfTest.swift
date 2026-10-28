import ArgumentParser
import BrainCore
import Foundation

// MARK: v0.7 threads (CONTRACT §17.4, §17.8)

/// `sb threads list [--dir vault]` · `sb threads selftest [--dir tmp]`.
struct ThreadsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "threads", abstract: "Email threads as one unit (v0.7).",
                                                    subcommands: [List.self, ThreadsSelfTestCmd.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Saved threads, newest first.")
        @Option(help: "Vault folder (default: the configured vault)") var dir: String?

        func run() async throws {
            let root = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? AppConfig.load().vaultURL
            for t in VaultStore(root: root).allThreads() {
                let who = t.senderNames(you: "Tú").joined(separator: ", ")
                print("\(t.key) · \(t.subject) · \(t.messageCount) · \(t.projectSlug ?? "_inbox") · \(who)")
            }
        }
    }
}

struct ThreadsSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of email threads.")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-threads-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await t.groupAsync("threads") { await testThreads(t, root: root) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

/// Grouping by the provider's conversation id (over the subject), what `_thread.json` keeps per message, replies (mine
/// and others') joining without a rule, one timeline entry per thread, the thread as ONE graph node tied to its people,
/// company and project, and a citation of a single message resolving to that node (graph and entity index).
@MainActor func testThreads(_ t: Tester, root: URL) async {
    let account = DemoProvider.demoAccount(.microsoft)
    let demo = DemoProvider(account: account, language: "es")
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: ThreadsNoTranscriber())
    engine.autoProcess = false
    engine.start()
    let vault = engine.vault
    let fm = FileManager.default
    func write(_ rel: String, _ text: String) {
        let url = vault.url(for: rel)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    do {
        try vault.setOwnerEmails(["ana@contoso.com"])
        let acme = try engine.projects.create(name: "Acme", description: "Logística", emoji: "🚚")
        let m1 = try await demo.fetchMessage(id: "demo-m01")
        let m2 = try await demo.fetchMessage(id: "demo-m02")
        let m3 = try await demo.fetchMessage(id: "demo-m03")

        // --- Grouping: the first email starts the thread and records the provider conversation.
        guard let first = try engine.addMailMessages([m1], account: account, threadKey: nil, projectSlug: acme.slug).first,
              let key = first.threadKey else {
            t.check(false, "first message added")
            return
        }
        t.eq(vault.threadKey(accountId: account.id, providerThreadId: "demo-thread-acme"), key, "providerThreadIds recorded")
        t.eq(vault.threadKey(accountId: "google:other@x.com", providerThreadId: "demo-thread-acme"), nil,
             "provider ids are per account")

        // My reply, alone, no threadKey and no rule: joins by conversation id (mine → isFromOwner).
        let mine = try engine.addMailMessages([m2], account: account, threadKey: nil, projectSlug: nil, routeIfUnassigned: false)
        t.eq(mine.first?.threadKey, key, "my reply joins the thread by conversation id")
        t.eq(mine.first?.projectSlug, acme.slug, "and keeps the thread's project")

        // Their reply with an unrelated subject: the conversation id wins over the subject heuristic.
        var renamed = m3
        renamed.summary.subject = "Contrato firmado (otro asunto)"
        let theirs = try engine.addMailMessages([renamed], account: account, threadKey: nil, projectSlug: nil, routeIfUnassigned: false)
        t.eq(theirs.first?.threadKey, key, "a reply with another subject joins by conversation id")

        // Same subject, another conversation: a new thread (the subject alone doesn't group connected mail).
        var other = m1
        other.summary.id = "demo-other-1"
        other.summary.threadId = "demo-thread-other"
        other.bodyText = "Otra conversación con el mismo asunto, sobre otra cosa distinta."
        let separate = try engine.addMailMessages([other], account: account, threadKey: nil, projectSlug: acme.slug)
        t.check(separate.first?.threadKey != nil && separate.first?.threadKey != key, "same subject, other conversation → its own thread")

        // A batch mixing conversations: each message to its own saved thread.
        var a4 = m3
        a4.summary.id = "demo-m04"
        a4.summary.webLink = "https://outlook.office.com/mail/inbox/id/demo-m04"
        a4.summary.date = m3.summary.date.addingTimeInterval(3_600)
        a4.bodyText = "Confirmo: firmamos el lunes."
        var o2 = other
        o2.summary.id = "demo-other-2"
        o2.summary.date = other.summary.date.addingTimeInterval(60)
        o2.bodyText = "Seguimiento de la otra conversación."
        let mixed = try engine.addMailMessages([a4, o2], account: account, threadKey: nil, projectSlug: acme.slug)
        let byMessage = Dictionary(mixed.map { ($0.externalId ?? "-", $0.threadKey ?? "-") }, uniquingKeysWith: { a, _ in a })
        t.eq(byMessage["microsoft:demo-m04"], key, "mixed batch: a reply to the saved thread joins it")
        t.eq(byMessage["microsoft:demo-other-2"], separate.first?.threadKey, "mixed batch: the other one joins its own thread")

        // --- _thread.json → ThreadInfo.
        guard let info = vault.threadInfo(key: key) else {
            t.check(false, "threadInfo(key:)")
            return
        }
        t.eq(info.messageCount, 4, "4 messages in the thread")
        t.eq(info.projectSlug, acme.slug, "thread project")
        t.eq(info.providerThreadIds[account.id], "demo-thread-acme", "ThreadInfo.providerThreadIds")
        t.eq(info.messages.map { $0.externalId ?? "-" },
             ["microsoft:demo-m01", "microsoft:demo-m02", "microsoft:demo-m03", "microsoft:demo-m04"], "chronological, externalId kept")
        t.eq(info.messages.map(\.isFromOwner), [false, true, false, false], "isFromOwner per message")
        t.check(info.messages.allSatisfy { ($0.webLink ?? "").hasPrefix("https://outlook.office.com/") }, "webLink per message")
        t.eq(info.messages.first?.provider, .microsoft, "provider from externalId")
        t.eq(info.senderNames(you: "Tú"), ["Sofía", "Tú"], "senders in order, mine as Tú")
        t.eq(info.lastWebLink, "https://outlook.office.com/mail/inbox/id/demo-m04", "newest link")
        let reply = info.messages[1]
        let text = vault.newText(of: reply, in: info)
        t.check(text.hasPrefix("Gracias, Sofía.") && !text.contains("Te comparto"), "new text only, no quoted history: \(text.prefix(40))")
        t.check(vault.allThreads().first?.key == key, "allThreads newest first")

        // The cache follows the file: a pasted email changes the count at once.
        _ = try engine.addEmail(ParsedEmail(subject: "RE: Propuesta", from: EmailAddress(name: "Laura Méndez", email: "laura.mendez@contoso.com"), to: [EmailAddress(name: "Ana García", email: "ana@contoso.com")], cc: [],
                                            date: a4.summary.date.addingTimeInterval(600), body: "Yo también confirmo.",
                                            quotedHistory: nil, raw: "", isFromOwner: false),
                                threadKey: key, projectSlug: nil)
        t.eq(vault.threadInfo(key: key)?.messageCount, 5, "cached _thread.json reloads after a write")
        t.eq(vault.threadInfo(key: key)?.messages.last?.externalId, nil, "a pasted email has no externalId")

        // --- One timeline entry per thread.
        let timeline = await engine.timeline(projectSlug: acme.slug)
        let mailEntries = timeline.filter { $0.kind == .email }
        t.eq(mailEntries.count, 2, "two threads → two entries (not one per email)")
        let entry = mailEntries.first { $0.thread?.key == key }
        t.eq(entry?.id, "thread:\(key)", "entry id thread:<key>")
        t.eq(entry?.thread?.messageCount, 5, "entry message count")
        t.eq(entry?.title, "Propuesta de logística Q4", "entry title = subject")
        t.eq(entry?.thread?.senders, ["Sofía", "Tú", "Laura"], "entry senders")

        // --- Graph: one node per thread, message citations resolve to it.
        let raws = info.messages.map { (($0.file as NSString).deletingPathExtension) }
        let page = "projects/\(acme.slug)/wiki/emails/\(key).md"
        write(page, "---\ntype: email-thread\ntitle: Propuesta de logística Q4\n---\n\n# Propuesta de logística Q4\n\nHilo con Sofía.\n")
        write("people/sofia-herrera.md", "---\ntype: person\ntitle: Sofía Herrera\norg: \"[[acme-logistics]]\"\n---\n\n# Sofía Herrera\n\n- **Correo:** sofia.herrera@acmelogistics.com\n")
        write("orgs/acme-logistics.md", "---\ntype: org\ntitle: Acme Logistics\ndomain: acmelogistics.com\n---\n\n# Acme Logistics\n")
        write("orgs/contoso.md", "---\ntype: org\ntitle: Contoso\nweb: https://www.contoso.com\n---\n\n# Contoso\n")
        let topic = "projects/\(acme.slug)/wiki/topics/tarifas.md"
        write(topic, "---\ntype: topic\ntitle: Tarifas\n---\n\n# Tarifas\n\nPuebla dos veces por semana ([[\(raws[2])]]).\n")
        let graph = KnowledgeGraphBuilder.build(vaultRoot: vault.root, projectSlug: nil, language: "es")
        let node = graph.nodes.first { $0.id == page }
        t.eq(node?.kind, .emailThread, "thread node kind emailThread")
        t.eq(node?.title, "Propuesta de logística Q4 · 5 correos", "label asunto · n correos")
        t.check(!graph.nodes.contains { $0.id.contains("/raw/") }, "emails are not nodes")
        t.eq(graph.nodes.filter { $0.kind == .emailThread }.count, 1, "one node per thread with a page")
        func linked(_ a: String, _ b: String) -> Bool {
            graph.edges.contains { ($0.source == a && $0.target == b) || ($0.source == b && $0.target == a) }
        }
        t.check(linked(page, topic), "a citation of one message → the thread node")
        t.check(linked(page, "people/sofia-herrera.md"), "thread → participant")
        t.check(linked(page, "orgs/acme-logistics.md"), "thread → company (by domain / person)")
        t.check(!linked(page, "orgs/contoso.md"), "the owner's own company is left out")
        t.check(linked(page, "project:\(acme.slug)"), "thread → project")
        let english = KnowledgeGraphBuilder.build(vaultRoot: vault.root, projectSlug: nil, language: "en")
        t.eq(english.nodes.first { $0.id == page }?.title, "Propuesta de logística Q4 · 5 emails", "English label")
        let scoped = KnowledgeGraphBuilder.build(vaultRoot: vault.root, projectSlug: acme.slug, language: "es")
        t.check(scoped.nodes.contains { $0.id == "people/sofia-herrera.md" }, "project graph keeps the thread's participants")

        // --- Entity index and search: kind emailThread; the citation lands on the thread's ficha.
        let snap = EntityIndex(vaultRoot: vault.root).refresh()
        t.eq(snap.entity(page)?.kind, .emailThread, "entity kind emailThread")
        t.check(snap.entity(topic)?.outgoing.contains(page) == true, "entity index: message citation → thread page")
        t.check(snap.sections(for: topic).contains { $0.kind == .emails && $0.rows.contains { $0.target == .page(page) } },
                "the topic's ficha lists the thread under Correos")
        t.eq(FullTextIndex.kind(of: page), .emailThread, "search kind emailThread")
    } catch {
        t.check(false, "threads: \(error)")
    }
}

private final class ThreadsNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
