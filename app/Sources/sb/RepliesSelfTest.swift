import ArgumentParser
import BrainCore
import Foundation

// MARK: v0.7 replies — `sb replies selftest` (CONTRACT §17.5)

struct RepliesCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "replies", abstract: "Saved email threads followed by themselves (v0.7).",
                                                    subcommands: [RepliesSelfTestCmd.self])
}

/// `sb replies selftest [--dir <tmp>]`: the auto-add cycle follows saved threads with `DemoProvider` — the owner's own
/// reply and someone else's join the thread with no rule, earlier messages of the same conversation too, replies to
/// unsaved mail are ignored, the safety cap, older `_thread.json` without the provider thread id, and the vault
/// template rules ("Mis compromisos" from the owner's replies). No Claude, no network.
struct RepliesSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of following saved email threads.")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-replies-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await t.groupAsync("replies-follow") { await testRepliesFollow(t, root: root.appendingPathComponent("follow")) }
        await t.groupAsync("replies-earlier") { await testRepliesEarlier(t, root: root.appendingPathComponent("earlier")) }
        await t.groupAsync("replies-cap") { await testRepliesCap(t, root: root.appendingPathComponent("cap")) }
        await t.groupAsync("replies-legacy") { await testRepliesLegacy(t, root: root.appendingPathComponent("legacy")) }
        t.group("replies-template") { testRepliesTemplate(t, root: root.appendingPathComponent("template")) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

@MainActor private func repliesEngine(_ root: URL) -> BrainEngine {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: RepliesNoTranscriber())
    engine.autoProcess = false
    engine.start()
    return engine
}

@MainActor private func threadJSON(_ engine: BrainEngine, key: String) -> [String: Any]? {
    guard let info = engine.vault.threadInfo(key: key),
          let data = try? Data(contentsOf: engine.vault.url(for: info.folderPath + "/_thread.json")) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// The contract thread (demo-m11) saved by hand; Ana's reply (sent mail) and Laura's join it with no rule.
@MainActor func testRepliesFollow(_ t: Tester, root: URL) async {
    let engine = repliesEngine(root)
    do {
        try engine.vault.setOwnerEmails(["ana@contoso.com"])
        let acme = try engine.projects.create(name: "Acme", description: "Cliente de logística", emoji: "🚀")
        let account = DemoProvider.demoAccount(.microsoft)
        let google = DemoProvider.demoAccount(.google)
        let now = Date()
        let demo = DemoProvider(account: account, language: "es", now: now)
        let gdemo = DemoProvider(account: google, language: "es", now: now)
        let provide: (ConnectedAccount) -> MailCalendarProvider = { $0.provider == .google ? gdemo : demo }
        func run() async -> MailAutoImportReport {
            await engine.runMailAutoImport(now: now, accounts: [account, google], provider: provide)
        }
        func ext(_ id: String) -> String { MailImport.externalId(account: account, messageId: id) }

        // Nothing saved and no rules: idle (and no cursor).
        var report = await run()
        t.check(report.idle, "nothing saved, no rules → idle")
        t.check(!engine.hasFollowableThreads, "no followable thread yet")

        // Save the contract by hand.
        let saved = try engine.addMailMessages([try await demo.fetchMessage(id: "demo-m11")], account: account, threadKey: nil,
                                               projectSlug: acme.slug, routeIfUnassigned: false)
        guard let key = saved.first?.threadKey else {
            t.check(false, "contract saved with a thread")
            return
        }
        t.check(engine.hasFollowableThreads, "a saved message of a connected account → followable")
        let jobsBefore = engine.jobs.count

        report = await run()
        t.check(!report.idle, "the cycle runs without rules")
        t.eq(report.sourceIds, [], "nothing by rule")
        let ids = report.followedSourceIds.compactMap { engine.source($0)?.externalId }
        t.eq(ids, [ext("demo-m13"), ext("demo-m14")], "the owner's reply and Laura's joined, oldest first")
        t.eq(report.followed.count, 1, "one thread went on")
        if let entry = report.followed.first {
            t.eq(entry.threadKey, key, "report: the saved thread")
            t.eq(entry.ownReplies, 1, "report: one own reply")
            t.eq(entry.others, 1, "report: one from someone else")
            t.eq(entry.projectSlug, acme.slug, "report: the thread's project")
            t.check(entry.subject.contains("Contrato actualizado"), "report: the thread's subject (\(entry.subject))")
            t.eq(engine.source(entry.lastSourceId)?.externalId, ext("demo-m14"), "report: the newest message")
        }
        for id in report.followedSourceIds {
            let src = engine.source(id)
            t.eq(src?.threadKey, key, "\(src?.externalId ?? id) in the saved thread")
            t.eq(src?.projectSlug, acme.slug, "\(src?.externalId ?? id) in the thread's project")
            t.check(engine.jobs.contains { $0.sourceId == id && $0.kind == .ingest }, "\(src?.externalId ?? id): ingest queued")
        }
        t.check(engine.jobs.count > jobsBefore, "incremental ingests queued")
        t.check(engine.sources.first { $0.externalId == ext("demo-m13") }?.title.contains("tú") == true, "own reply titled «— tú»")

        // _thread.json: provider thread id and "Tú".
        let info = engine.vault.threadInfo(key: key)
        t.eq(info?.messageCount, 3, "thread of 3")
        t.eq(info?.providerThreadIds[account.id], "demo-m11", "providerThreadIds recorded")
        t.eq(info?.messages.map(\.isFromOwner), [false, true, false], "the owner's reply is «Tú»")
        let json = threadJSON(engine, key: key)
        let stored = (json?["messages"] as? [[String: Any]])?.compactMap { $0["isFromOwner"] as? Bool } ?? []
        t.check(stored.contains(true), "isFromOwner persisted in _thread.json")

        // Replies to unsaved mail are ignored (no rule): the owner's Gmail reply to Pablo, Sofía's Q4 thread.
        t.check(engine.emailSource(externalId: MailImport.externalId(account: google, messageId: "demo-g2")) == nil,
                "own reply to an unsaved thread: not imported")
        t.check(engine.emailSource(externalId: ext("demo-m03")) == nil, "unsaved conversation: not imported")
        t.eq(engine.sources.filter { $0.externalId != nil }.count, 3, "only the saved thread grew")
        t.check(engine.routing.settings.mailSyncCursors[account.id] != nil, "cursor saved")

        // Next cycle: nothing new. Switch off: idle.
        report = await run()
        t.eq(report.total, 0, "second cycle: nothing new")
        t.check(!report.idle, "second cycle ran")
        try engine.routing.setAutoImportEnabled(false)
        report = await run()
        t.check(report.idle, "switch off → idle")
        try engine.routing.setAutoImportEnabled(true)
        engine.routing.flush()
    } catch {
        t.check(false, "replies-follow: \(error)")
    }
}

/// Saving the newest message: the earlier ones of the same conversation join it too (§17.4: the provider's id wins).
@MainActor func testRepliesEarlier(_ t: Tester, root: URL) async {
    let engine = repliesEngine(root)
    do {
        try engine.vault.setOwnerEmails(["ana@contoso.com"])
        let acme = try engine.projects.create(name: "Acme", description: "Cliente", emoji: "🚀")
        let account = DemoProvider.demoAccount(.microsoft)
        let now = Date()
        let demo = DemoProvider(account: account, language: "es", now: now)
        func ext(_ id: String) -> String { MailImport.externalId(account: account, messageId: id) }
        let saved = try engine.addMailMessages([try await demo.fetchMessage(id: "demo-m14")], account: account, threadKey: nil,
                                               projectSlug: acme.slug, routeIfUnassigned: false)
        let key = saved.first?.threadKey
        let report = await engine.runMailAutoImport(now: now, accounts: [account], provider: { _ in demo })
        t.eq(report.followedSourceIds.compactMap { engine.source($0)?.externalId }, [ext("demo-m11"), ext("demo-m13")],
             "earlier messages of the conversation joined")
        t.check(report.followedSourceIds.allSatisfy { engine.source($0)?.threadKey == key }, "same thread")
        t.eq(engine.vault.threadInfo(key: key ?? "")?.messages.compactMap(\.externalId), [ext("demo-m11"), ext("demo-m13"), ext("demo-m14")],
             "conversation in sent order")
        t.check(engine.emailSource(externalId: ext("demo-m12")) == nil, "other conversations untouched")
        engine.routing.flush()
    } catch {
        t.check(false, "replies-earlier: \(error)")
    }
}

/// The safety cap stops the cycle before the next message (cursor stays); the next cycle adds the rest.
@MainActor func testRepliesCap(_ t: Tester, root: URL) async {
    let engine = repliesEngine(root)
    do {
        try engine.vault.setOwnerEmails(["ana@contoso.com"])
        let acme = try engine.projects.create(name: "Acme", description: "Cliente", emoji: "🚀")
        let account = DemoProvider.demoAccount(.microsoft)
        let now = Date()
        let demo = DemoProvider(account: account, language: "es", now: now)
        func ext(_ id: String) -> String { MailImport.externalId(account: account, messageId: id) }
        try engine.addMailMessages([try await demo.fetchMessage(id: "demo-m11")], account: account, threadKey: nil,
                                   projectSlug: acme.slug, routeIfUnassigned: false)
        var report = await engine.runMailAutoImport(now: now, followCap: 1, accounts: [account], provider: { _ in demo })
        t.eq(report.followedSourceIds.count, 1, "cap 1 → one message")
        t.check(report.reachedCap, "cap reached")
        let m13 = try await demo.fetchMessage(id: "demo-m13")
        t.eq(engine.routing.settings.mailSyncCursors[account.id], m13.summary.date, "cursor at the last message added")
        report = await engine.runMailAutoImport(now: now, followCap: 1, accounts: [account], provider: { _ in demo })
        t.eq(report.followedSourceIds.compactMap { engine.source($0)?.externalId }, [ext("demo-m14")], "the rest next cycle")
        t.eq(BrainEngine.threadFollowCap, 100, "safety cap 100")
        engine.routing.flush()
    } catch {
        t.check(false, "replies-cap: \(error)")
    }
}

/// A thread saved by an older version (no `providerThreadIds`) whose saved messages are behind the cursor: one fetch
/// learns its conversation id, and the replies join it.
@MainActor func testRepliesLegacy(_ t: Tester, root: URL) async {
    let engine = repliesEngine(root)
    do {
        try engine.vault.setOwnerEmails(["ana@contoso.com"])
        let acme = try engine.projects.create(name: "Acme", description: "Cliente", emoji: "🚀")
        let account = DemoProvider.demoAccount(.microsoft)
        let now = Date()
        let demo = DemoProvider(account: account, language: "es", now: now)
        func ext(_ id: String) -> String { MailImport.externalId(account: account, messageId: id) }
        let m11 = try await demo.fetchMessage(id: "demo-m11")
        let saved = try engine.addMailMessages([m11], account: account, threadKey: nil, projectSlug: acme.slug, routeIfUnassigned: false)
        guard let key = saved.first?.threadKey, let info = engine.vault.threadInfo(key: key) else {
            t.check(false, "legacy thread saved")
            return
        }
        // As an older version wrote it: no provider ids.
        let file = engine.vault.url(for: info.folderPath + "/_thread.json")
        if var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] {
            json["providerThreadIds"] = nil
            try JSONSerialization.data(withJSONObject: json).write(to: file)
        }
        t.eq(engine.vault.threadInfo(key: key)?.providerThreadIds ?? [:], [:], "no provider ids (older version)")
        // The cursor is past the saved message: the listing doesn't show it.
        try engine.routing.setMailSyncCursor(m11.summary.date.addingTimeInterval(60), for: account.id)
        let report = await engine.runMailAutoImport(now: now, accounts: [account], provider: { _ in demo })
        t.eq(report.followedSourceIds.compactMap { engine.source($0)?.externalId }, [ext("demo-m13"), ext("demo-m14")],
             "replies joined the older thread")
        t.eq(engine.vault.threadInfo(key: key)?.providerThreadIds[account.id], "demo-m11", "provider id learned and saved")
        engine.routing.flush()
    } catch {
        t.check(false, "replies-legacy: \(error)")
    }
}

/// The vault template tells Claude what to do with the owner's own replies.
@MainActor func testRepliesTemplate(_ t: Tester, root: URL) {
    let vault = VaultStore(root: root)
    do { _ = try vault.migrateIfNeeded() } catch {
        t.check(false, "install template: \(error)")
        return
    }
    let ingest = (try? vault.read(".claude/commands/ingest.md")) ?? ""
    t.check(ingest.contains("\"isFromOwner\": true"), "ingest.md: owner's sent reply via _thread.json")
    t.check(ingest.contains("The owner's own reply") && ingest.contains("Mis compromisos"), "ingest.md: promises → Mis compromisos")
    t.check(ingest.contains("respondido/enviado el"), "ingest.md: a reply that closes a task marks it done with the citation")
    let template = (try? vault.read("templates/correo-hilo.md")) ?? ""
    t.check(template.contains("Tus propias respuestas"), "correo-hilo: own replies rule")
}

private final class RepliesNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
