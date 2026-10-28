import CryptoKit
import Foundation
import NaturalLanguage

// MARK: v0.6 ask (CONTRACT §16.3): saved conversations of Preguntar and "Guardar como página".

/// One saved conversation of Preguntar. `data/chats/<vault>/brain/<id>.json` or
/// `data/chats/<vault>/projects/<slug>/<id>.json` (`<vault>` = `ChatStore.vaultKey`).
public struct ChatThread: Codable, Identifiable, Sendable, Equatable {
    /// A question or an answer. Live progress (the "Leyendo «…»" steps, streaming) is never saved.
    public struct Message: Codable, Identifiable, Sendable, Equatable {
        public enum Role: String, Codable, Sendable { case user, assistant }

        public var id: String
        public var role: Role
        public var text: String
        /// The question an answer replies to ("Guardar como página" titles the page with it).
        public var question: String?
        /// Why an answer has no text: "notConnected", "rateLimited", "other" (the app maps it back).
        public var failure: String?
        /// The vault page this answer was saved as (§16.3), once saved.
        public var savedPath: String?

        public init(id: String = UUID().uuidString, role: Role, text: String, question: String? = nil,
                    failure: String? = nil, savedPath: String? = nil) {
            self.id = id; self.role = role; self.text = text; self.question = question
            self.failure = failure; self.savedPath = savedPath
        }
    }

    public var id: String
    public var scope: Scope
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [Message]

    public init(id: String = ChatStore.newId(), scope: Scope, title: String, createdAt: Date = Date(),
                updatedAt: Date? = nil, messages: [Message] = []) {
        self.id = id; self.scope = scope; self.title = title; self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt; self.messages = messages
    }
}

/// Saved conversations on disk, one JSON file per conversation (atomic writes; files never shared between scopes).
/// Safe from any thread. The folder lives in the data folder, next to `sources/` and `history/`, one per vault: the
/// conversations cite that vault's pages, so switching vault shows the new vault's conversations (§16.3).
public final class ChatStore: @unchecked Sendable {
    public let dir: URL
    private let lock = NSLock()

    /// `dataRoot` = `AppConfig.dataURL`, `vaultRoot` = `AppConfig.vaultURL`: the store uses
    /// `<dataRoot>/chats/<vaultKey>/`. Conversations saved before they were per vault (`chats/brain`, `chats/projects`)
    /// are moved into the first vault that opens them.
    public init(dataRoot: URL, vaultRoot: URL) {
        let chats = dataRoot.appendingPathComponent("chats")
        dir = chats.appendingPathComponent(Self.vaultKey(vaultRoot))
        Self.adoptUnscoped(in: chats, into: dir)
    }

    /// `<folder name>-<8 hex of the path>`: readable, and distinct for two vaults with the same folder name.
    public static func vaultKey(_ vaultRoot: URL) -> String {
        let path = vaultRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = String(vaultRoot.lastPathComponent.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "-" }).prefix(40)
        return (name.isEmpty || name.hasPrefix(".") ? "vault" : String(name)) + "-" + hash
    }

    private static func adoptUnscoped(in chats: URL, into dir: URL) {
        let fm = FileManager.default
        for name in ["brain", "projects"] {
            let old = chats.appendingPathComponent(name)
            let new = dir.appendingPathComponent(name)
            guard fm.isDirectory(old), !fm.fileExists(atPath: new.path) else { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: new)
        }
    }

    /// `20261027-153012-a1b2`: sorts by creation, safe as a file name.
    public static func newId(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + "-" + UUID().uuidString.prefix(4).lowercased()
    }

    /// Ids and slugs come from files, notifications and the CLI: only plain names reach the file system.
    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 120 && !s.hasPrefix(".")
            && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// The folder of a scope, nil for a slug that isn't a plain name.
    public func folder(for scope: Scope) -> URL? {
        switch scope {
        case .brain: return dir.appendingPathComponent("brain")
        case .project(let slug):
            guard Self.isSafeName(slug) else { return nil }
            return dir.appendingPathComponent("projects").appendingPathComponent(slug)
        }
    }

    private func fileURL(id: String, scope: Scope) -> URL? {
        guard Self.isSafeName(id) else { return nil }
        return folder(for: scope)?.appendingPathComponent(id + ".json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The scope's conversations, most recently updated first. Unreadable files are skipped.
    public func list(scope: Scope) -> [ChatThread] {
        guard let folder = folder(for: scope) else { return [] }
        let files = lock.withLock { (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in lock.withLock { try? Data(contentsOf: url) }.flatMap { try? Self.decoder.decode(ChatThread.self, from: $0) } }
            // A file moved by hand into another scope's folder keeps showing where it lives.
            .map { var t = $0; t.scope = scope; return t }
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    public func listAsync(scope: Scope) async -> [ChatThread] {
        await Task.detached(priority: .userInitiated) { self.list(scope: scope) }.value
    }

    /// The project scopes that have a folder (for `sb chat list` without `--project`).
    public func projectSlugs() -> [String] {
        let root = dir.appendingPathComponent("projects")
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(Self.isSafeName).sorted()
    }

    public func load(id: String, scope: Scope) -> ChatThread? {
        guard let url = fileURL(id: id, scope: scope) else { return nil }
        return lock.withLock { try? Data(contentsOf: url) }.flatMap { try? Self.decoder.decode(ChatThread.self, from: $0) }
    }

    public func save(_ thread: ChatThread) throws {
        guard let url = fileURL(id: thread.id, scope: thread.scope) else { throw CocoaError(.fileWriteInvalidFileName) }
        let data = try Self.encoder.encode(thread)
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    public func delete(id: String, scope: Scope) throws {
        guard let url = fileURL(id: id, scope: scope) else { return }
        try lock.withLock {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Renames without touching `updatedAt` (the list order doesn't jump). Returns the saved conversation.
    @discardableResult
    public func rename(id: String, scope: Scope, to title: String) throws -> ChatThread? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var thread = load(id: id, scope: scope) else { return nil }
        thread.title = clean
        try save(thread)
        return thread
    }

    /// A conversation's title from its first question: at most six words, without the question marks
    /// ("¿Quién aprueba el presupuesto de Q1 este año?" → "Quién aprueba el presupuesto de Q1…").
    public static func title(forQuestion question: String) -> String {
        let words = question
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "¿?¡!\"'«»“”")) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        var title = words.prefix(6).joined(separator: " ")
        while let last = title.last, ",;:.".contains(last) { title.removeLast() }
        if words.count > 6 { title += "…" }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}

// MARK: - "Guardar como página" (§16.3)

public enum SavedAnswers {
    /// Where an answer asked in `scope` is saved: the project's `wiki/questions/`, or the global `questions/`.
    public static func folder(for scope: Scope) -> String {
        scope.projectSlug.map { "projects/\($0)/wiki/questions" } ?? "questions"
    }

    /// The page for a saved answer (CLAUDE.md §8.6 question template, `origin: chat`): the answer is kept as given,
    /// citations included, and its [[links]] are listed under "Fuentes".
    public static func page(question: String, answer: String, scope: Scope, date: Date = Date()) -> String {
        let day = String(SBDate.iso(date).prefix(10))
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let yamlTitle = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        var front = ["---", "type: question", "title: \"\(yamlTitle)\""]
        if let slug = scope.projectSlug { front.append("project: \(slug)") }
        front += ["date: \(day)", "status: answered", "origin: chat", "language: \(language(of: q + "\n" + answer))",
                  "updated: \(day)", "---"]
        var body = ["", "# \(q.replacingOccurrences(of: "\n", with: " "))", "", "## Respuesta", "",
                    answer.trimmingCharacters(in: .whitespacesAndNewlines)]
        let links = wikilinkTargets(in: answer)
        if !links.isEmpty {
            body += ["", "## Fuentes", ""] + links.map { "- [[\($0)]]" }
        }
        return (front + body).joined(separator: "\n") + "\n"
    }

    /// `YYYY-MM-DD-<slug>.md` in the scope's folder, with `-2`, `-3`… when taken. Vault-relative.
    public static func newPath(question: String, scope: Scope, vault: VaultStore, date: Date = Date()) -> String {
        let day = String(SBDate.iso(date).prefix(10))
        let slug = slugify(question, maxLength: 60)
        let base = folder(for: scope) + "/" + day + "-" + (slug.isEmpty ? "pregunta" : slug)
        var path = base + ".md"
        var n = 2
        while FileManager.default.fileExists(atPath: vault.url(for: path).path) {
            path = base + "-\(n).md"
            n += 1
        }
        return path
    }

    /// Writes the page through the history (one undoable "manual edit" entry) and returns its vault path.
    @discardableResult
    public static func save(question: String, answer: String, scope: Scope, vault: VaultStore, history: HistoryStore,
                            title: String, date: Date = Date()) throws -> String {
        let path = newPath(question: question, scope: scope, vault: vault, date: date)
        let text = page(question: question, answer: answer, scope: scope, date: date)
        try history.recordManualEdit(title: title, projectSlug: scope.projectSlug, path: path, before: nil, after: text)
        return path
    }

    /// Distinct `[[target]]`s in order (alias and heading kept as written, so the link reads the same).
    static func wikilinkTargets(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for match in text.matches(of: #/\[\[([^\]\n]+)\]\]/#) {
            let target = String(match.1).trimmingCharacters(in: .whitespaces)
            let key = target.split(separator: "|").first.map { $0.lowercased() } ?? target.lowercased()
            if !target.isEmpty, seen.insert(key).inserted { out.append(target) }
        }
        return out
    }

    /// "es" / "en" (the vault's two languages); Spanish when unsure.
    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .english]
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english ? "en" : "es"
    }
}
