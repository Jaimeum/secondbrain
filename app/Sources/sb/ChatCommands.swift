import ArgumentParser
import BrainCore
import Foundation

// MARK: v0.6 ask (CONTRACT §16.3): Preguntar's saved conversations from the terminal.

/// `sb chat list [--project <slug>]` and `sb chat selftest`.
struct ChatCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chat", abstract: "Saved conversations of Preguntar.",
                                                    subcommands: [List.self, ChatSelfTestCmd.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List saved conversations (the whole brain's and every project's).")
        @Option(help: "Only this project") var project: String?
        @Flag(help: "Only the whole brain's") var brain = false

        @MainActor func run() async throws {
            let store = ChatStore(dataRoot: AppConfig.load().dataURL)
            var scopes: [Scope] = []
            if let project {
                scopes = [.project(project)]
            } else {
                scopes = [.brain]
                if !brain { scopes += store.projectSlugs().map { .project($0) } }
            }
            var total = 0
            for scope in scopes {
                let threads = store.list(scope: scope)
                guard !threads.isEmpty else { continue }
                print("\(scope.projectSlug.map { "[\($0)]" } ?? "[brain]") \(threads.count)")
                for t in threads {
                    let answers = t.messages.filter { $0.role == .assistant }.count
                    let saved = t.messages.filter { $0.savedPath != nil }.count
                    print("  \(t.id)  \(stamp(t.updatedAt))  \(t.title)  (\(answers) answers" + (saved > 0 ? ", \(saved) saved" : "") + ")")
                }
                total += threads.count
            }
            if total == 0 { print("No saved conversations" + (project.map { " in \($0)" } ?? "") + ".") }
        }
    }
}

/// `sb chat selftest [--dir <tmp>]`: persistence of conversations, titles, and "Guardar como página".
struct ChatSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of saved conversations.")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-chat-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        t.group("chat-store") { testChatStore(t, root: root.appendingPathComponent("data")) }
        t.group("chat-title") { testChatTitles(t) }
        t.group("chat-save-page") { testSavedAnswers(t, root: root.appendingPathComponent("save")) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

@MainActor func testChatStore(_ t: Tester, root: URL) {
    let store = ChatStore(dataRoot: root)
    let fm = FileManager.default
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    var brain = ChatThread(id: ChatStore.newId(t0), scope: .brain, title: "Quién aprueba el presupuesto", createdAt: t0,
                           messages: [.init(role: .user, text: "¿Quién aprueba el presupuesto?"),
                                      .init(role: .assistant, text: "Ana ([[ana-garcia]]).", question: "¿Quién aprueba el presupuesto?")])
    let project = ChatThread(id: ChatStore.newId(t0.addingTimeInterval(60)), scope: .project("kickoff"), title: "Fechas",
                             createdAt: t0.addingTimeInterval(60),
                             messages: [.init(role: .user, text: "¿Fechas?"),
                                        .init(role: .assistant, text: "", question: "¿Fechas?", failure: "rateLimited")])
    do {
        try store.save(brain)
        try store.save(project)
    } catch { t.check(false, "save threw \(error)") }

    // Files where §16.3 says.
    t.check(fm.fileExists(atPath: root.appendingPathComponent("chats/brain/\(brain.id).json").path), "brain thread in data/chats/brain/")
    t.check(fm.fileExists(atPath: root.appendingPathComponent("chats/projects/kickoff/\(project.id).json").path),
            "project thread in data/chats/projects/<slug>/")

    // Scopes never mix; a fresh store (a restart) reads the same.
    let reopened = ChatStore(dataRoot: root)
    t.eq(reopened.list(scope: .brain).map(\.id), [brain.id], "brain list")
    t.eq(reopened.list(scope: .project("kickoff")).map(\.id), [project.id], "project list")
    t.eq(reopened.list(scope: .project("otro")).count, 0, "other project empty")
    t.eq(reopened.projectSlugs(), ["kickoff"], "project folders")
    let loaded = reopened.load(id: brain.id, scope: .brain)
    t.eq(loaded, brain, "round trip (messages, dates, scope)")
    t.eq(reopened.load(id: project.id, scope: .project("kickoff"))?.messages.last?.failure, "rateLimited", "failure kept")
    t.check(reopened.load(id: brain.id, scope: .project("kickoff")) == nil, "a brain thread isn't found in a project")

    // Most recently updated first.
    var second = ChatThread(id: ChatStore.newId(t0.addingTimeInterval(120)), scope: .brain, title: "Segunda",
                            createdAt: t0.addingTimeInterval(120))
    try? store.save(second)
    t.eq(store.list(scope: .brain).map(\.id), [second.id, brain.id], "newest first")
    brain.updatedAt = t0.addingTimeInterval(300)
    brain.messages.append(.init(role: .user, text: "¿Y el de Q2?"))
    try? store.save(brain)
    t.eq(store.list(scope: .brain).map(\.id), [brain.id, second.id], "an updated conversation moves up")
    t.eq(store.load(id: brain.id, scope: .brain)?.messages.count, 3, "update overwrites the file")

    // Rename keeps the order; delete removes the file.
    _ = try? store.rename(id: second.id, scope: .brain, to: "  Renombrada  ")
    second = store.load(id: second.id, scope: .brain) ?? second
    t.eq(second.title, "Renombrada", "rename (trimmed)")
    t.eq(store.list(scope: .brain).first?.id, brain.id, "rename doesn't reorder")
    t.check((try? store.rename(id: second.id, scope: .brain, to: "   ")) == nil || store.load(id: second.id, scope: .brain)?.title == "Renombrada",
            "empty name ignored")
    try? store.delete(id: second.id, scope: .brain)
    t.eq(store.list(scope: .brain).map(\.id), [brain.id], "delete")
    t.check(!fm.fileExists(atPath: root.appendingPathComponent("chats/brain/\(second.id).json").path), "deleted file gone")

    // Unsafe ids / slugs never reach the file system; a corrupt file is skipped.
    t.check(store.folder(for: .project("../x")) == nil, "slug with .. rejected")
    t.check(store.load(id: "../../etc/passwd", scope: .brain) == nil, "id with / rejected")
    var evil = brain
    evil.id = "../evil"
    t.check((try? store.save(evil)) == nil, "saving an unsafe id throws")
    try? "{not json".write(to: root.appendingPathComponent("chats/brain/broken.json"), atomically: true, encoding: .utf8)
    t.eq(store.list(scope: .brain).map(\.id), [brain.id], "corrupt file skipped")
    t.check(ChatStore.newId() != ChatStore.newId(), "ids are unique")
}

@MainActor func testChatTitles(_ t: Tester) {
    t.eq(ChatStore.title(forQuestion: "¿Quién aprueba el presupuesto de Q1 este año?"), "Quién aprueba el presupuesto de Q1…", "≤ 6 words")
    t.eq(ChatStore.title(forQuestion: "¿qué decidimos?"), "Qué decidimos", "no question marks, capitalized")
    t.eq(ChatStore.title(forQuestion: "  hola,\n  mundo  "), "Hola, mundo", "whitespace and newlines")
    t.eq(ChatStore.title(forQuestion: "uno dos tres cuatro cinco seis, siete"), "Uno dos tres cuatro cinco seis…", "trailing comma dropped")
    t.eq(ChatStore.title(forQuestion: "¿?"), "", "empty")
}

@MainActor func testSavedAnswers(_ t: Tester, root: URL) {
    let vaultRoot = root.appendingPathComponent("vault")
    let fm = FileManager.default
    try? fm.createDirectory(at: vaultRoot.appendingPathComponent("people"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: vaultRoot.appendingPathComponent("projects/kickoff/wiki/questions"), withIntermediateDirectories: true)
    try? "# Ana García\n".write(to: vaultRoot.appendingPathComponent("people/ana-garcia.md"), atomically: true, encoding: .utf8)
    try? "# Índice\n".write(to: vaultRoot.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    let vault = VaultStore(root: vaultRoot)
    let history = HistoryStore(vaultRoot: vaultRoot, historyDir: root.appendingPathComponent("history"))
    let day = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-27 (UTC midday-ish)
    let iso = String(SBDate.iso(day).prefix(10))
    let answer = "Claro. Lo aprueba Ana ([[ana-garcia]]) según el comité ✉️ ([[2026-10-21-comite|Comité]]), y otra vez [[ana-garcia]]."

    // Folders by scope (§16.3).
    t.eq(SavedAnswers.folder(for: .brain), "questions", "brain → questions/")
    t.eq(SavedAnswers.folder(for: .project("kickoff")), "projects/kickoff/wiki/questions", "project → wiki/questions/")

    // The page: §8.6 question front-matter, the answer as given, its links under Fuentes (once each).
    let page = SavedAnswers.page(question: "¿Quién \"aprueba\" el presupuesto?", answer: answer, scope: .project("kickoff"), date: day)
    t.check(page.hasPrefix("---\ntype: question\n"), "front-matter first")
    t.check(page.contains("title: \"¿Quién \\\"aprueba\\\" el presupuesto?\""), "title quoted and escaped")
    t.check(page.contains("project: kickoff\n"), "project field")
    t.check(page.contains("status: answered\n") && page.contains("origin: chat\n") && page.contains("date: \(iso)\n"), "status/origin/date")
    t.check(page.contains("language: es\n"), "language es")
    t.check(page.contains("\n# ¿Quién \"aprueba\" el presupuesto?\n"), "h1 = question")
    t.check(page.contains("## Respuesta\n\n" + answer), "answer kept as given")
    t.check(page.contains("## Fuentes\n\n- [[ana-garcia]]\n- [[2026-10-21-comite|Comité]]\n"), "sources listed once each")
    let global = SavedAnswers.page(question: "Who approves the budget?", answer: "Ana approves the budget for the whole company this year.",
                                   scope: .brain, date: day)
    t.check(!global.contains("project:"), "brain page has no project")
    t.check(global.contains("language: en\n"), "language en")
    t.check(!global.contains("## Fuentes"), "no Fuentes without links")

    // Saving: the right folder, a unique name, through the history (undoable), and listed as a global page.
    do {
        let p1 = try SavedAnswers.save(question: "¿Quién aprueba el presupuesto?", answer: answer, scope: .brain, vault: vault,
                                       history: history, title: "Guardé una respuesta", date: day)
        t.eq(p1, "questions/\(iso)-quien-aprueba-el-presupuesto.md", "brain path")
        let p2 = try SavedAnswers.save(question: "¿Quién aprueba el presupuesto?", answer: answer, scope: .brain, vault: vault,
                                       history: history, title: "Guardé una respuesta", date: day)
        t.eq(p2, "questions/\(iso)-quien-aprueba-el-presupuesto-2.md", "same question again → -2")
        let p3 = try SavedAnswers.save(question: "¿Fechas del kickoff?", answer: "El 3 de noviembre.", scope: .project("kickoff"),
                                       vault: vault, history: history, title: "Guardé una respuesta", date: day)
        t.eq(p3, "projects/kickoff/wiki/questions/\(iso)-fechas-del-kickoff.md", "project path")
        t.check(fm.fileExists(atPath: vault.url(for: p3).path), "project page written")

        let globalPages = vault.pages(projectSlug: nil).map(\.path)
        t.check(globalPages.contains(p1) && globalPages.contains(p2), "questions/ in VaultStore.pages(projectSlug: nil)")
        t.check(!globalPages.contains(p3), "project question not global")
        t.check(vault.pages(projectSlug: "kickoff").map(\.path).contains(p3), "project question in the project's pages")
        t.eq(vault.title(of: p1), "¿Quién aprueba el presupuesto?", "page title")

        let entries = history.entries()
        t.eq(entries.count, 3, "one history entry per saved page")
        if let entry = entries.first(where: { $0.changes.contains { $0.path == p2 } }) {
            t.eq(entry.kind, .manualEdit, "manual edit entry")
            try history.undo(entryId: entry.id)
            t.check(!fm.fileExists(atPath: vault.url(for: p2).path), "undo removes the saved page")
            t.check(fm.fileExists(atPath: vault.url(for: p1).path), "undo leaves the other page")
        } else {
            t.check(false, "history entry for \(p2)")
        }
    } catch {
        t.check(false, "save threw \(error)")
    }
}
