import CryptoKit
import Foundation

/// Parser for `wiki/tasks.md` (vault CLAUDE.md §8.7, Obsidian Tasks format):
///
///     ## Abiertas
///     ### Yo — [[jaime-ruiz|Jaime Ruiz]]
///     - [ ] Preparar la demo — [[jaime-ruiz|Jaime]] · 📅 2026-10-30 · ([[2026-10-26-1530-kickoff]] 00:15:20)
///     ### [[ana-garcia|Ana García]]
///     - [x] Reservar sala — [[ana-garcia|Ana]] · 📅 2026-10-28 · ✅ 2026-10-27 · ([[a]] 00:20:10; [[b]])
///     ## Sin dueño
///     ## Hechas
///
/// Tolerant: Claude doesn't always write the line exactly (extra notes, owner as plain text, "(antes …)").
public enum TaskParser {
    /// Who the vault owner is, to decide `isMine`.
    public struct OwnerInfo: Sendable {
        public var slugs: Set<String>      // person pages with `owner: true`
        public var names: Set<String>      // lowercased display names / first names
        public init(slugs: Set<String> = [], names: Set<String> = []) { self.slugs = slugs; self.names = names }
    }

    private enum Section { case open, unowned, done, other }

    public static func parse(_ text: String, path: String, projectSlug: String, owner: OwnerInfo) -> [TaskItem] {
        var items: [TaskItem] = []
        var section = Section.other
        var group: (slug: String?, name: String?, mine: Bool)?
        var seen: [String: Int] = [:]
        for rawLine in Frontmatter.split(text).body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                section = sectionKind(String(line.dropFirst(3)))
                group = nil
                continue
            }
            if line.hasPrefix("### ") {
                group = ownerGroup(String(line.dropFirst(4)), owner: owner)
                continue
            }
            guard var item = parseLine(rawLine, projectSlug: projectSlug, owner: owner) else { continue }
            if item.ownerSlug == nil, item.ownerName == nil || isMeWord(item.ownerName!), let g = group, section != .unowned {
                item.ownerSlug = g.slug
                item.ownerName = g.name ?? item.ownerName
                item.isMine = item.isMine || g.mine
            } else if let g = group, g.mine, item.ownerSlug == g.slug || item.ownerSlug == nil {
                item.isMine = true
            }
            if section == .unowned, item.ownerSlug == nil { item.ownerName = nil; item.isMine = false }
            let key = normalize(item.text)
            let n = (seen[key] ?? 0) + 1
            seen[key] = n
            item.id = "\(path)#\(hash(key))" + (n > 1 ? "-\(n)" : "")
            items.append(item)
        }
        return items
    }

    /// One `- [ ] …` line → task (id left empty; `parse` assigns it).
    public static func parseLine(_ rawLine: String, projectSlug: String, owner: OwnerInfo = OwnerInfo()) -> TaskItem? {
        guard let m = EmailParser.firstMatch(#"^\s*[-*+]\s+\[([ xX])\]\s+(.*)$"#, in: rawLine, options: []),
              let rest = m[2]?.trimmingCharacters(in: .whitespaces), !rest.isEmpty else { return nil }
        let done = m[1]?.lowercased() == "x"
        var segments = splitSegments(rest)
        var due: Date?, doneDate: Date?
        var sourceKeys: [String] = []
        var head = segments.removeFirst()
        var extras: [String] = []
        for seg in segments {
            let t = seg.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("📅"), due == nil, let d = firstDay(in: t) { due = d; continue }
            if t.hasPrefix("✅"), let d = firstDay(in: t) { doneDate = d; continue }
            extras.append(t)
        }
        // A line without " · " separators: dates and citations inline.
        if due == nil, let r = head.range(of: #"📅\s*\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            due = firstDay(in: String(head[r]))
            head.removeSubrange(r)
        }
        if doneDate == nil, let r = head.range(of: #"✅\s*\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            doneDate = firstDay(in: String(head[r]))
            head.removeSubrange(r)
        }
        // Owner: "text — [[slug|Name]]" / "text — Ana" / "text — Yo".
        var ownerSlug: String?, ownerName: String?
        var text = head.trimmingCharacters(in: .whitespaces)
        if let dash = text.range(of: " — ", options: .backwards) ?? text.range(of: " – ", options: .backwards) {
            let after = text[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            let links = wikilinks(in: after)
            if let link = links.first, after.hasPrefix("[[") {
                ownerSlug = slugOf(link.target)
                ownerName = link.label ?? link.target
                text = String(text[..<dash.lowerBound])
            } else if !after.isEmpty, after.count <= 40, !after.contains("("), !after.contains("[[") {
                ownerName = after
                text = String(text[..<dash.lowerBound])
            }
        }
        // Citations: wikilinks in the remaining segments (and in the head, when Claude put them there).
        let ownerTarget = ownerSlug
        for seg in extras + [text] {
            for link in wikilinks(in: seg) {
                let key = slugOf(link.target)
                if key == ownerTarget || link.target.hasPrefix("people/") { continue }
                if !sourceKeys.contains(key) { sourceKeys.append(key) }
            }
        }
        // The action itself: no trailing citation in parentheses, wikilinks shown as their label.
        text = text.replacingOccurrences(of: #"\s*\((?:[^()]*\[\[[^()]*)\)\s*$"#, with: "", options: .regularExpression)
        text = plainLinks(text).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("·") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty else { return nil }
        var mine = false
        if let s = ownerSlug, owner.slugs.contains(s) { mine = true }
        if let n = ownerName?.lowercased(), isMeWord(n) || owner.names.contains(n) || owner.names.contains(firstWord(n)) { mine = true }
        return TaskItem(id: "", projectSlug: projectSlug, text: text, ownerSlug: ownerSlug, ownerName: ownerName,
                        isMine: mine, due: due, done: done, doneDate: doneDate, sourceKeys: sourceKeys,
                        line: rawLine)
    }

    // MARK: Editing

    /// The same line toggled: `[ ]`↔`[x]`, adding ` · ✅ YYYY-MM-DD` before the citation, or removing it.
    public static func toggled(_ line: String, done: Bool, on date: Date = Date()) -> String {
        guard let r = line.range(of: #"\[[ xX]\]"#, options: .regularExpression) else { return line }
        // A CRLF file split on "\n" leaves "\r" on each line: keep it so the file's line endings stay as they were.
        if line.hasSuffix("\r") { return toggled(String(line.dropLast()), done: done, on: date) + "\r" }
        var out = line
        out.replaceSubrange(r, with: done ? "[x]" : "[ ]")
        // Drop any existing ✅ segment (or inline ✅ date).
        out = out.replacingOccurrences(of: #"\s*·\s*✅\s*\d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s*✅\s*\d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
        guard done else { return out }
        let stamp = "✅ " + Fmt.local(date, "yyyy-MM-dd")
        // Before the trailing citation segment "· ([[…]] …)" when there is one.
        if let cite = out.range(of: #"\s*·\s*\((?:[^()]|\([^()]*\))*\[\[(?:[^()]|\([^()]*\))*\)\s*$"#, options: .regularExpression) {
            out.insert(contentsOf: " · \(stamp)", at: cite.lowerBound)
        } else {
            out = out.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + " · \(stamp)"
        }
        return out
    }

    // MARK: Helpers

    public static func normalize(_ text: String) -> String {
        plainLinks(text).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func sectionKind(_ title: String) -> Section {
        let t = title.lowercased()
        if t.hasPrefix("abiert") || t.hasPrefix("open") || t.hasPrefix("pendiente") { return .open }
        if t.hasPrefix("sin dueño") || t.hasPrefix("sin dueno") || t.hasPrefix("unowned") || t.hasPrefix("no owner") { return .unowned }
        if t.hasPrefix("hech") || t.hasPrefix("done") || t.hasPrefix("complet") || t.hasPrefix("terminad") { return .done }
        return .other
    }

    /// `### Yo — [[jaime-ruiz|Jaime Ruiz]]`, `### Yo`, `### [[ana-garcia|Ana García]]`, `### Diego`.
    private static func ownerGroup(_ heading: String, owner: OwnerInfo) -> (slug: String?, name: String?, mine: Bool) {
        let h = heading.trimmingCharacters(in: .whitespaces)
        let link = wikilinks(in: h).first
        let slug = link.map { slugOf($0.target) }
        let plain = plainLinks(h)
        let first = plain.components(separatedBy: CharacterSet(charactersIn: " —–-(")).first?.lowercased() ?? ""
        var mine = isMeWord(first) || plain.lowercased().contains("(yo)") || plain.lowercased().contains("(me)")
        if let slug, owner.slugs.contains(slug) { mine = true }
        var name = link?.label ?? link?.target ?? plain
        if link == nil, mine { name = plain.components(separatedBy: " — ").last ?? plain }
        let lname = name.lowercased()
        if owner.names.contains(lname) || owner.names.contains(firstWord(lname)) { mine = true }
        return (slug, name.trimmingCharacters(in: .whitespaces), mine)
    }

    static func isMeWord(_ s: String) -> Bool { ["yo", "me", "mí", "mi", "myself"].contains(s.lowercased().trimmingCharacters(in: .whitespaces)) }

    private static func firstWord(_ s: String) -> String { s.components(separatedBy: " ").first ?? s }

    /// Splits on " · " outside wikilinks/parentheses.
    private static func splitSegments(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "[" || c == "(" { depth += 1 }
            if c == "]" || c == ")" { depth = max(0, depth - 1) }
            if c == "·", depth == 0 {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out.filter { !$0.isEmpty }.isEmpty ? [s] : out.filter { !$0.isEmpty }
    }

    private static func firstDay(in s: String) -> Date? {
        EmailParser.firstMatch(#"(\d{4}-\d{2}-\d{2})"#, in: s).flatMap { $0[1] }.flatMap(SBDate.day)
    }

    struct Link { var target: String; var label: String? }

    static func wikilinks(in s: String) -> [Link] {
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\]\|\n]+)(?:\|([^\]\n]*))?\]\]"#) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let t = Range(m.range(at: 1), in: s) else { return nil }
            var target = String(s[t]).trimmingCharacters(in: .whitespaces)
            if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
            let label = Range(m.range(at: 2), in: s).map { String(s[$0]).trimmingCharacters(in: .whitespaces) }
            return Link(target: target, label: label?.isEmpty == false ? label : nil)
        }
    }

    /// `people/ana-garcia` / `projects/x/raw/emails/t/2026-…-ana.md` → last component without `.md`.
    static func slugOf(_ target: String) -> String {
        var name = (target as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }
        return name
    }

    /// `[[x|Label]]` → `Label`, `[[x]]` → `x`.
    static func plainLinks(_ s: String) -> String {
        s.replacingOccurrences(of: #"\[\[(?:[^\]\|\n]*\|)?([^\]\n]*)\]\]"#, with: "$1", options: .regularExpression)
    }
}

// MARK: - Filters (CONTRACT §16.8)

/// A person the Pendientes "Persona ▾" filter can pick: a `people/<slug>.md` page, or an owner Claude wrote as plain
/// text ("— Diego") with no page yet.
public struct TaskPerson: Codable, Hashable, Sendable {
    public var slug: String?
    public var name: String
    public init(slug: String?, name: String) { self.slug = slug; self.name = name }
    /// Same person whether the page or only the name is known ("ana-garcia" / "Ana García").
    public var key: String { slug?.lowercased() ?? "name:" + TaskParser.normalize(name) }
}

/// How a task relates to the picked person: anything with them, what I owe them ("Lo que le debo a…" = my tasks
/// that mention them), what they owe me ("Lo que me debe…" = tasks they own).
public enum TaskRelation: String, Codable, Sendable, CaseIterable { case any, iOwe, owesMe }

/// The global Pendientes filters (projects, person, text), persisted by the app. Segments and Origen are separate.
public struct TaskFilter: Codable, Equatable, Sendable {
    public var projects: Set<String> = []        // empty = every project
    public var person: TaskPerson?
    public var relation: TaskRelation = .any
    public var text: String = ""
    public init(projects: Set<String> = [], person: TaskPerson? = nil, relation: TaskRelation = .any, text: String = "") {
        self.projects = projects; self.person = person; self.relation = relation; self.text = text
    }

    public var isActive: Bool { !projects.isEmpty || person != nil || !query.isEmpty }
    private var query: String { TaskParser.normalize(text) }

    /// `projectName` lets the text search find a task by its project's name too.
    public func matches(_ task: TaskItem, projectName: String? = nil) -> Bool {
        if !projects.isEmpty, !projects.contains(task.projectSlug) { return false }
        if let person {
            let owns = TaskPeople.isOwner(person, of: task)
            switch relation {
            case .any: if !owns && !TaskPeople.mentions(person, in: task) { return false }
            case .owesMe: if !owns { return false }
            case .iOwe: if !task.isMine || !TaskPeople.mentions(person, in: task) { return false }
            }
        }
        let q = query
        if !q.isEmpty {
            let haystack = TaskParser.normalize([task.text, task.ownerName ?? "", projectName ?? ""].joined(separator: " "))
            // Every word, in any order: "acme plan" finds "Enviar a Acme el plan".
            for word in q.split(separator: " ") where !haystack.contains(word) { return false }
        }
        return true
    }
}

public enum TaskPeople {
    /// The task is theirs (never one of mine, even if my page is picked).
    public static func isOwner(_ person: TaskPerson, of task: TaskItem) -> Bool {
        guard !task.isMine else { return false }
        if let slug = person.slug, let owner = task.ownerSlug { return owner.lowercased() == slug.lowercased() }
        guard let name = task.ownerName.map(TaskParser.normalize), !name.isEmpty else { return false }
        let full = TaskParser.normalize(person.name)
        return name == full || name == firstName(full)
    }

    /// The task names them: a wikilink to their page anywhere in the line other than the owner, or their name
    /// (full, or first name of 3+ letters) as whole words in the text.
    public static func mentions(_ person: TaskPerson, in task: TaskItem) -> Bool {
        if let slug = person.slug?.lowercased(), task.ownerSlug?.lowercased() != slug {
            if TaskParser.wikilinks(in: task.line).contains(where: { TaskParser.slugOf($0.target).lowercased() == slug }) { return true }
        }
        let words = " " + TaskParser.normalize(task.text) + " "
        let full = TaskParser.normalize(person.name)
        guard !full.isEmpty else { return false }
        if words.contains(" \(full) ") { return true }
        let first = firstName(full)
        return first.count >= 3 && words.contains(" \(first) ")
    }

    /// The people the Persona menu offers: those that own or are mentioned in at least one task, most tasks first.
    /// `directory` = the person pages; plain-text owners without a page are added by name.
    public static func people(in tasks: [TaskItem], directory: [TaskPerson]) -> [TaskPerson] {
        var counts: [String: (person: TaskPerson, n: Int)] = [:]
        for person in directory {
            let n = tasks.filter { isOwner(person, of: $0) || mentions(person, in: $0) }.count
            if n > 0 { counts[person.key] = (person, n) }
        }
        for task in tasks where !task.isMine {
            guard let name = task.ownerName, !name.isEmpty else { continue }
            let person = TaskPerson(slug: task.ownerSlug, name: name)
            // An owner already covered by a page (by slug, or by its name / first name) is not repeated.
            if directory.contains(where: { isOwner($0, of: task) }) || counts.values.contains(where: { isOwner($0.person, of: task) }) {
                continue
            }
            counts[person.key] = (person, tasks.filter { isOwner(person, of: $0) }.count)
        }
        return counts.values.sorted {
            $0.n != $1.n ? $0.n > $1.n : $0.person.name.localizedCaseInsensitiveCompare($1.person.name) == .orderedAscending
        }.map(\.person)
    }

    private static func firstName(_ normalized: String) -> String {
        normalized.split(separator: " ").first.map(String.init) ?? normalized
    }
}

// MARK: - Engine

public extension BrainEngine {
    /// Person pages (`people/*.md`, without the owner's own page) for the Pendientes "Persona ▾" filter.
    func taskPeopleDirectory() async -> [TaskPerson] {
        let vault = self.vault
        return await Task.detached(priority: .userInitiated) {
            let owner = vault.ownerInfo()
            return vault.pages(projectSlug: nil)
                .filter { $0.path.hasPrefix("people/") }
                .compactMap { page -> TaskPerson? in
                    let slug = TaskParser.slugOf(page.path)
                    guard !owner.slugs.contains(slug) else { return nil }
                    return TaskPerson(slug: slug, name: page.title)
                }
        }.value
    }

    /// Tasks of a project's `wiki/tasks.md` (nil = every project), parsed off the main thread.
    func tasks(projectSlug: String?) async -> [TaskItem] {
        let vault = self.vault, projects = self.projects
        return await Task.detached(priority: .userInitiated) {
            let slugs = projectSlug.map { [$0] } ?? projects.list().map(\.slug)
            let owner = vault.ownerInfo()
            return slugs.flatMap { vault.tasks(projectSlug: $0, owner: owner) }
        }.value
    }

    /// Tasks whose citation mentions this source (its raw file key; for an email, any message of its thread).
    func tasks(forSourceId id: String) async -> [TaskItem] {
        guard let src = source(id), let slug = src.projectSlug else { return [] }
        let keys = sourceKeys(for: src)
        guard !keys.isEmpty else { return [] }
        return await tasks(projectSlug: slug).filter { task in task.sourceKeys.contains { keys.contains($0.lowercased()) } }
    }

    /// Lowercased citation keys that identify a source: its raw file name; for an email, every message of its thread
    /// plus the thread key (the thread page).
    internal func sourceKeys(for src: SourceRecord) -> Set<String> {
        var keys: Set<String> = []
        if let raw = src.rawPath { keys.insert(((raw as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()) }
        if src.kind == .email, let thread = src.threadKey {
            keys.insert(thread.lowercased())
            for e in emails(inThread: thread) {
                if let raw = e.rawPath { keys.insert(((raw as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()) }
            }
        }
        return keys
    }

    /// Checks/unchecks a task in `tasks.md` (CONTRACT §11.2), recorded in Activity as a `.manualEdit` (undoable).
    /// Refused with `EngineError.busy` while Claude is editing that project. If Claude rewrote the line meanwhile, the
    /// task is found again by id / normalized text; if it is gone → `EngineError.taskNotFound`.
    func setTask(_ task: TaskItem, done: Bool) throws {
        let editing: Set<JobKind> = [.ingest, .lint, .saveAnswer, .reformat]
        guard !runningAnywhere({ editing.contains($0.kind) && ($0.projectSlug == nil || $0.projectSlug == task.projectSlug) }) else {
            throw EngineError.busy
        }
        let rel = "projects/\(task.projectSlug)/wiki/tasks.md"
        let url = vault.url(for: rel)
        guard let before = try? String(contentsOf: url, encoding: .utf8) else { throw EngineError.taskNotFound(task.text) }
        var lines = before.components(separatedBy: "\n")
        var index = lines.firstIndex(of: task.line)
        if index == nil {
            let parsed = TaskParser.parse(before, path: rel, projectSlug: task.projectSlug, owner: vault.ownerInfo())
            let wanted = TaskParser.normalize(task.text)
            let match = parsed.first { $0.id == task.id } ?? parsed.first { TaskParser.normalize($0.text) == wanted }
            index = match.flatMap { m in lines.firstIndex(of: m.line) }
        }
        guard let i = index else { throw EngineError.taskNotFound(task.text) }
        let newLine = TaskParser.toggled(lines[i], done: done)
        guard newLine != lines[i] else { return }
        lines[i] = newLine
        let after = lines.joined(separator: "\n")
        let short = task.text.count > 60 ? String(task.text.prefix(57)) + "…" : task.text
        let title = done ? lang.t("Marcaste como hecho: \(short)", "Marked as done: \(short)")
                         : lang.t("Marcaste como pendiente: \(short)", "Marked as not done: \(short)")
        let entry = try history.recordManualEdit(title: title, projectSlug: task.projectSlug, path: rel, before: before, after: after)
        onEvent?(.historyAdded(entry))
        Log.info("task \(done ? "done" : "reopened") in \(rel): \(short)")
    }

    /// A checklist (markdown) grouped Míos / De los demás / Sin dueño, with due and done dates.
    func exportTasks(_ tasks: [TaskItem], title: String) -> String {
        var out = "# \(title)\n"
        let groups: [(String, [TaskItem])] = [
            (lang.t("Míos", "Mine"), tasks.filter(\.isMine)),
            (lang.t("De los demás", "Others'"), tasks.filter { !$0.isMine && ($0.ownerName != nil || $0.ownerSlug != nil) }),
            (lang.t("Sin dueño", "No owner"), tasks.filter { !$0.isMine && $0.ownerName == nil && $0.ownerSlug == nil }),
        ]
        for (heading, items) in groups where !items.isEmpty {
            out += "\n## \(heading)\n\n"
            let sorted = items.sorted { a, b in
                if a.done != b.done { return !a.done }
                return (a.due ?? .distantFuture, a.text) < (b.due ?? .distantFuture, b.text)
            }
            for t in sorted { out += taskLine(t, showOwner: !t.isMine) + "\n" }
        }
        if tasks.isEmpty { out += "\n" + lang.t("_No hay pendientes._", "_No tasks._") + "\n" }
        return out
    }

    internal func taskLine(_ t: TaskItem, showOwner: Bool) -> String {
        var line = "- [\(t.done ? "x" : " ")] \(t.text)"
        if showOwner, let name = t.ownerName { line += " — \(name)" }
        if let due = t.due { line += " · " + lang.t("para el ", "due ") + SBDate.human(due, hasTime: false, language: config.uiLanguage) }
        if t.done, let d = t.doneDate { line += " · " + lang.t("hecho el ", "done ") + SBDate.human(d, hasTime: false, language: config.uiLanguage) }
        return line
    }
}

extension VaultStore {
    /// Who "me" is for tasks: person pages with `owner: true`, the README name and the link in it.
    func ownerInfo() -> TaskParser.OwnerInfo {
        var info = TaskParser.OwnerInfo()
        if let name = ownerName()?.lowercased() {
            info.names.insert(name)
            if let first = name.components(separatedBy: " ").first { info.names.insert(first) }
        }
        if let readme = try? read(Self.ownerFile),
           let line = readme.components(separatedBy: "\n").first(where: { $0.contains("**Nombre:**") || $0.contains("**Name:**") }) {
            for link in TaskParser.wikilinks(in: line) { info.slugs.insert(TaskParser.slugOf(link.target)) }
        }
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: url(for: "people").path)) ?? [] where file.hasSuffix(".md") && file != "README.md" {
            guard let text = try? read("people/\(file)"), Frontmatter.field("owner", in: text)?.lowercased() == "true" else { continue }
            info.slugs.insert(String(file.dropLast(3)))
            if let title = Frontmatter.field("title", in: text)?.lowercased() {
                info.names.insert(title)
            }
        }
        return info
    }

    func tasks(projectSlug: String, owner: TaskParser.OwnerInfo) -> [TaskItem] {
        let rel = "projects/\(projectSlug)/wiki/tasks.md"
        guard let text = try? read(rel) else { return [] }
        return TaskParser.parse(text, path: rel, projectSlug: projectSlug, owner: owner)
    }
}
