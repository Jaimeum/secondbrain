import Foundation

// MARK: v0.6 entity (CONTRACT §16.4): "qué sabemos de X".
//
// Every wiki page of the vault is an entity with a ficha: people/, orgs/, questions/, facts.md and every page under
// `projects/<slug>/wiki/**`. Never `raw/`, `_inbox/`, `templates/` or the CLAUDE.md schemas. The index keeps, per
// page: kind (by folder, overridden by `type:`), title, aliases, project, event date, the front-matter facts a ficha
// shows as chips (role, org, projects, status) and its resolved outgoing links; backlinks are derived. Rebuilt
// incrementally: a refresh only stats the vault and re-reads the files whose modification date changed; link
// resolution and backlinks are recomputed in memory (cheap) because one new page can change what a name resolves to.

public enum EntityKind: String, Codable, Sendable, CaseIterable {
    case person, org, project, meeting, email, document, note, url, topic, decision, question, repo, facts, page
}

/// One wiki page as the ficha sees it.
public struct Entity: Codable, Hashable, Sendable, Identifiable {
    /// Vault-relative path without `.md` (CONTRACT §16.4).
    public var id: String
    public var path: String
    public var kind: EntityKind
    public var title: String
    public var aliases: [String]
    /// The project the page lives in (`projects/<slug>/…`), nil for global pages.
    public var projectSlug: String?
    /// Front-matter `projects:` / `project:` (people, orgs, global questions).
    public var projects: [String]
    /// When it happened (`event_date:`/`date:`, else a `yyyy-MM-dd` file-name prefix).
    public var eventDate: Date?
    public var role: String?
    /// `org:` / `organization:` / `company:` as written (a name or a wikilink).
    public var org: String?
    public var status: String?
    /// Front-matter `owner: true` (the vault owner's own person page).
    public var isOwner: Bool
    /// Resolved links written in the front matter (`people:`, `topics:`, `decided_by:`, `org: [[…]]`), in order.
    public var frontLinks: [String]
    /// Resolved links of the whole page (front matter + body), deduped, canonical (a raw email → its thread page, a
    /// project's index → its overview), without itself.
    public var outgoing: [String]
    /// Navigation and maintenance pages (index, log, health, tasks, timeline): entities, but never "related".
    public var isNavigation: Bool

    /// `people/ana-garcia.md` → "ana-garcia".
    public var baseName: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

/// Where a row of a ficha goes.
public enum EntityTarget: Hashable, Sendable {
    case page(String)
    case project(String)
    case task(String)
}

public struct EntityRow: Hashable, Sendable, Identifiable {
    public var target: EntityTarget
    public var title: String
    public var kind: EntityKind
    public var projectSlug: String?
    public var date: Date?
    /// Task rows: owner name; person rows: role · org.
    public var detail: String?
    public var done = false
    public var id: String {
        switch target {
        case .page(let p): "page:\(p)"
        case .project(let s): "project:\(s)"
        case .task(let t): "task:\(t)"
        }
    }
}

/// The automatic sections of a ficha, in this order (§16.4 item 3).
public enum EntitySectionKind: String, Sendable, CaseIterable {
    case projects, meetings, emails, documents, decisions, tasks, related
}

public struct EntitySection: Hashable, Sendable, Identifiable {
    public var kind: EntitySectionKind
    public var rows: [EntityRow]
    public var id: String { kind.rawValue }
}

/// A person in a project's Personas tab (§16.2).
public struct ProjectPerson: Hashable, Sendable, Identifiable {
    public var path: String
    public var title: String
    public var role: String?
    public var org: String?
    /// Latest meeting/email with them in the project.
    public var lastContact: Date?
    /// Meetings, emails, documents and notes of the project linked with them.
    public var sources: Int
    /// Added by hand (`project.json` `people.include`) rather than found in the pages.
    public var manual: Bool
    public var id: String { path }
}

public final class EntityIndex: @unchecked Sendable {
    public let vaultRoot: URL

    /// What a ficha reads: immutable, safe to pass around.
    public struct Snapshot: Sendable {
        public let entities: [String: Entity]
        public let backlinks: [String: [String]]
        /// Tasks of every project (parsed from `tasks.md`), with the entity paths each one names (owner + links).
        public let tasks: [TaskItem]
        public let taskLinks: [String: Set<String>]
        public let projects: [Project]
        /// Bumped on every refresh that changed something (views key their tasks on it).
        public let revision: Int

        public static let empty = Snapshot(entities: [:], backlinks: [:], tasks: [], taskLinks: [:], projects: [], revision: 0)

        public func entity(_ path: String) -> Entity? { entities[path] }

        public func project(_ slug: String) -> Project? { projects.first { $0.slug == slug } }

        /// Entities this one is tied to, in both directions (outgoing ∪ backlinks), without navigation pages.
        public func neighbors(of path: String) -> [String] {
            var seen = Set<String>([path])
            var out: [String] = []
            for p in (entities[path]?.outgoing ?? []) + (backlinks[path] ?? []) where !seen.contains(p) {
                seen.insert(p)
                if let e = entities[p], !e.isNavigation { out.append(p) }
            }
            return out
        }

        /// The projects an entity touches: where it lives, its `projects:`, the projects of its neighbors, and
        /// `project.json` `people.include` (minus `exclude`) for people.
        public func projects(of path: String) -> [String] {
            guard let e = entities[path] else { return [] }
            var set = Set(e.projects)
            if let slug = e.projectSlug { set.insert(slug) }
            for n in neighbors(of: path) { if let slug = entities[n]?.projectSlug { set.insert(slug) } }
            if e.kind == .person {
                for p in projects {
                    if p.people?.include.contains(e.baseName) == true { set.insert(p.slug) }
                    if p.people?.exclude.contains(e.baseName) == true { set.remove(p.slug) }
                }
            }
            let known = Set(projects.map(\.slug))
            // Ordered like the sidebar (creation order).
            return projects.map(\.slug).filter { set.contains($0) && known.contains($0) }
        }

        /// The ficha's sections (§16.4): every non-empty group, rows newest first. `projectSlug` filters to one
        /// project (a ficha opened inside it): project pages of that project, and global entities tied to it.
        public func sections(for path: String, projectSlug: String? = nil) -> [EntitySection] {
            guard let me = entities[path] else { return [] }
            var buckets: [EntitySectionKind: [EntityRow]] = [:]

            if me.kind != .project, projectSlug == nil {
                buckets[.projects] = projects(of: path).compactMap { slug in
                    guard let p = project(slug) else { return nil }
                    return EntityRow(target: .project(slug), title: "\(p.emoji) \(p.name)", kind: .project, projectSlug: slug)
                }
            }
            for n in neighbors(of: path) {
                guard let e = entities[n], keep(e, in: projectSlug) else { continue }
                let section: EntitySectionKind
                switch e.kind {
                case .project: continue   // in Proyectos
                case .meeting: section = .meetings
                case .email: section = .emails
                case .document, .note, .url: section = .documents
                case .decision: section = .decisions
                default: section = .related
                }
                buckets[section, default: []].append(row(for: e))
            }
            let mine = tasks(of: path).filter { projectSlug == nil || $0.projectSlug == projectSlug }
            buckets[.tasks] = mine.sorted { a, b in
                if a.done != b.done { return !a.done }
                return (a.due ?? .distantFuture, a.text) < (b.due ?? .distantFuture, b.text)
            }.map { t in
                EntityRow(target: .task(t.id), title: t.text, kind: .page, projectSlug: t.projectSlug, date: t.due,
                          detail: t.ownerName, done: t.done)
            }
            return EntitySectionKind.allCases.compactMap { kind in
                guard var rows = buckets[kind], !rows.isEmpty else { return nil }
                if kind != .tasks && kind != .projects {
                    rows.sort { a, b in
                        switch (a.date, b.date) {
                        case let (x?, y?) where x != y: return x > y
                        case (.some, nil): return true
                        case (nil, .some): return false
                        default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                        }
                    }
                }
                return EntitySection(kind: kind, rows: rows)
            }
        }

        /// Tasks owned by the entity or naming it (a link in the line, or a citation of its page).
        public func tasks(of path: String) -> [TaskItem] {
            tasks.filter { taskLinks[$0.id]?.contains(path) == true }
        }

        /// Inside a project: its own pages, and global entities tied to it. Pages of other projects are left out.
        private func keep(_ e: Entity, in projectSlug: String?) -> Bool {
            guard let projectSlug else { return true }
            if let slug = e.projectSlug { return slug == projectSlug }
            return projects(of: e.path).contains(projectSlug)
        }

        func row(for e: Entity) -> EntityRow {
            var detail: String?
            if e.kind == .person { detail = [e.role, orgName(e.org)].compactMap { $0 }.joined(separator: " · ") }
            return EntityRow(target: .page(e.path), title: e.title, kind: e.kind, projectSlug: e.projectSlug,
                             date: e.eventDate, detail: detail?.isEmpty == true ? nil : detail)
        }

        /// `[[acme|Acme]]` / `orgs/acme` / "Acme" → "Acme".
        public func orgName(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            if let path = orgPath(raw), let e = entities[path] { return e.title }
            return EntityIndex.plainLinks(raw)
        }

        /// The `orgs/` page an `org:` value names (a wikilink or a plain name), if it exists.
        public func orgPath(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            let name = EntityIndex.wikilinkTargets(in: raw).first ?? raw
            let key = slugify(((name as NSString).lastPathComponent as NSString).deletingPathExtension)
            let path = "orgs/\(key).md"
            return entities[path] != nil ? path : nil
        }

        // MARK: Projects

        /// People of a project (§16.2): linked from/to its pages, listing it in `projects:`, or added by hand; minus
        /// the ones removed by hand. Sorted by last contact, then name.
        public func people(ofProject slug: String) -> [ProjectPerson] {
            let manual = Set(project(slug)?.people?.include ?? [])
            var out: [ProjectPerson] = []
            for e in entities.values where e.kind == .person && !e.isOwner {
                guard projects(of: e.path).contains(slug) else { continue }
                var last: Date?
                var count = 0
                for n in neighbors(of: e.path) {
                    guard let other = entities[n], other.projectSlug == slug else { continue }
                    switch other.kind {
                    case .meeting, .email:
                        count += 1
                        if let d = other.eventDate, d > (last ?? .distantPast) { last = d }
                    case .document, .note, .url:
                        count += 1
                    default: break
                    }
                }
                out.append(ProjectPerson(path: e.path, title: e.title, role: e.role, org: orgName(e.org),
                                         lastContact: last, sources: count,
                                         manual: manual.contains(e.baseName)))
            }
            return out.sorted { a, b in
                if a.lastContact != b.lastContact { return (a.lastContact ?? .distantPast) > (b.lastContact ?? .distantPast) }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }

        /// A project's decisions, newest first.
        public func decisions(ofProject slug: String) -> [Entity] {
            entities.values.filter { $0.projectSlug == slug && $0.kind == .decision }
                .sorted { ($0.eventDate ?? .distantPast, $0.title) > ($1.eventDate ?? .distantPast, $1.title) }
        }

        /// The project's ficha page (`overview.md`, the "En breve"), if any.
        public func overviewPath(ofProject slug: String) -> String? {
            let p = "projects/\(slug)/wiki/overview.md"
            return entities[p] != nil ? p : nil
        }

        /// Every person page (Personas), by name.
        public var allPeople: [Entity] {
            entities.values.filter { $0.kind == .person }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    // MARK: Shared instances

    nonisolated(unsafe) private static var instances: [String: EntityIndex] = [:]
    private static let instancesLock = NSLock()

    /// One index per vault (the app and the CLI share the incremental cache).
    public static func shared(vaultRoot: URL) -> EntityIndex {
        let key = vaultRoot.standardizedFileURL.path
        instancesLock.lock()
        defer { instancesLock.unlock() }
        if let hit = instances[key] { return hit }
        let index = EntityIndex(vaultRoot: vaultRoot)
        instances[key] = index
        return index
    }

    /// `shared(vaultRoot:).refresh()` off the main thread.
    public static func snapshot(vaultRoot: URL) async -> Snapshot {
        let index = shared(vaultRoot: vaultRoot)
        return await Task.detached(priority: .userInitiated) { index.refresh() }.value
    }

    public init(vaultRoot: URL) { self.vaultRoot = vaultRoot }

    // MARK: State

    /// What a file says before links are resolved (re-read only when its modification date changes).
    struct Parsed {
        var entity: Entity
        var frontTargets: [String]
        var bodyTargets: [String]
        /// `tasks.md` of a project: its task lines, parsed with the owner info of that refresh.
        var tasks: [TaskItem]
    }

    private let lock = NSLock()
    private var parsed: [String: (mtime: Date, value: Parsed)] = [:]
    private var last: Snapshot = .empty
    private var lastSignature = ""
    private var revision = 0
    private var lastOwnerKey = ""

    /// Brings the index up to date with the vault and returns it. Blocking (stats every file, reads changed ones):
    /// call it off the main thread.
    @discardableResult
    public func refresh() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let vault = VaultStore(root: vaultRoot)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        var mtimes: [String: Date] = [:]
        var allMarkdown: [String] = []
        var projectJSON: [String] = []
        if let walker = fm.enumerator(at: vaultRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard let rel = url.relativePath(from: vaultRoot) else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true { continue }
                let mtime = values?.contentModificationDate ?? .distantPast
                if url.lastPathComponent == "project.json" {
                    projectJSON.append("\(rel)@\(mtime.timeIntervalSinceReferenceDate)")
                    continue
                }
                guard url.pathExtension.lowercased() == "md" else { continue }
                allMarkdown.append(rel)
                if Self.isEntityPath(rel) { mtimes[rel] = mtime }
            }
        }
        let signature = (allMarkdown.sorted().joined(separator: "|") + "#" + projectJSON.sorted().joined(separator: "|")
            + "#" + mtimes.sorted { $0.key < $1.key }.map { "\($0.value.timeIntervalSinceReferenceDate)" }.joined(separator: ","))
        if signature == lastSignature { return last }

        // Re-read what changed; forget what is gone. The owner only matters for tasks ("Yo" → mine).
        let owner = vault.ownerInfo()
        let ownerKey = owner.slugs.sorted().joined(separator: ",") + "|" + owner.names.sorted().joined(separator: ",")
        let ownerChanged = ownerKey != lastOwnerKey
        lastOwnerKey = ownerKey
        for (path, mtime) in mtimes where parsed[path]?.mtime != mtime || (ownerChanged && path.hasSuffix("/wiki/tasks.md")) {
            guard let text = try? vault.read(path) else { continue }
            parsed[path] = (mtime, Self.parse(path: path, text: text, owner: owner))
        }
        for path in parsed.keys where mtimes[path] == nil { parsed[path] = nil }

        // Resolve every link in memory (same rules as VaultStore.resolveWikilink).
        let resolver = Resolver(all: allMarkdown)
        let projects = ProjectManager(vaultRoot: vaultRoot).list()
        var entities: [String: Entity] = [:]
        var backlinks: [String: [String]] = [:]
        for (path, item) in parsed {
            var e = item.value.entity
            let canon: (String) -> String? = { target in
                resolver.resolve(target, from: path).flatMap { Self.canonical($0, resolver: resolver) }
            }
            e.frontLinks = Self.unique(item.value.frontTargets.compactMap(canon)).filter { $0 != path && mtimes[$0] != nil }
            e.outgoing = Self.unique((item.value.frontTargets + item.value.bodyTargets).compactMap(canon))
                .filter { $0 != path && mtimes[$0] != nil }
            entities[path] = e
        }
        for e in entities.values where !e.isNavigation {
            for target in e.outgoing { backlinks[target, default: []].append(e.path) }
        }
        for key in backlinks.keys { backlinks[key]?.sort() }

        // Tasks: the owner's page and every link in the line (citations name meetings/emails, owners name people).
        var tasks: [TaskItem] = []
        var taskLinks: [String: Set<String>] = [:]
        for (path, item) in parsed where !item.value.tasks.isEmpty {
            for t in item.value.tasks {
                var linked = Set<String>()
                for link in TaskParser.wikilinks(in: t.line) {
                    if let p = resolver.resolve(link.target, from: path).flatMap({ Self.canonical($0, resolver: resolver) }) {
                        linked.insert(p)
                    }
                }
                if let owner = t.ownerSlug, let p = resolver.resolve(owner, from: path) { linked.insert(p) }
                for key in t.sourceKeys {
                    if let p = resolver.resolve(key, from: path).flatMap({ Self.canonical($0, resolver: resolver) }) { linked.insert(p) }
                }
                tasks.append(t)
                taskLinks[t.id] = linked
            }
        }
        tasks.sort { $0.id < $1.id }

        revision += 1
        last = Snapshot(entities: entities, backlinks: backlinks, tasks: tasks, taskLinks: taskLinks, projects: projects,
                        revision: revision)
        lastSignature = signature
        return last
    }

    // MARK: Parsing

    /// Wiki pages only: no raw sources, inbox, formats or schemas.
    static func isEntityPath(_ path: String) -> Bool {
        guard path.hasSuffix(".md"), !path.contains("/raw/"), !path.hasPrefix("raw/"), !path.hasPrefix("_inbox/"),
              !path.hasPrefix("templates/") else { return false }
        let name = (path as NSString).lastPathComponent
        if name == "CLAUDE.md" || name.hasPrefix("CLAUDE.v") || name == "README.md" { return false }
        let parts = path.split(separator: "/")
        if parts.count == 1 { return true }
        switch parts[0] {
        case "people", "orgs", "questions": return true
        case "projects": return parts.count >= 4 && parts[2] == "wiki"
        default: return false
        }
    }

    static func parse(path: String, text: String, owner: TaskParser.OwnerInfo) -> Parsed {
        let page = KnowledgeGraphBuilder.parse(path: path, text: text)
        let split = Frontmatter.split(text)
        let yaml = split.yaml ?? ""
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let parts = path.split(separator: "/").map(String.init)
        let projectSlug = VaultStore.projectSlug(of: path)

        var kind: EntityKind
        switch page.kind {
        case .person: kind = .person
        case .meeting: kind = .meeting
        case .email: kind = .email
        case .document: kind = .document
        case .note: kind = .note
        case .url: kind = .url
        case .topic: kind = .topic
        case .decision: kind = .decision
        case .question: kind = .question
        case .repo: kind = .repo
        case .project, .task, .page: kind = .page
        }
        let type = Frontmatter.field("type", in: text)?.lowercased()
        if parts.first == "orgs" || type == "org" || type == "organization" || type == "company" { kind = .org }
        if path == "facts.md" { kind = .facts }
        let isProjectRoot = projectSlug != nil && parts.count == 4
        if isProjectRoot && name == "overview" { kind = .project }
        let isNavigation = (isProjectRoot || parts.count == 1)
            && ["index", "log", "health", "tasks", "timeline"].contains(name)

        var date = page.date
        if date == nil, let m = name.firstMatch(of: #/^(\d{4}-\d{2}-\d{2})/#) { date = SBDate.parseISO(String(m.1))?.date }

        var projects = KnowledgeGraphBuilder.listField("projects", in: yaml)
        if let single = Frontmatter.field("project", in: text), projectSlug == nil { projects.append(single) }
        let org = Frontmatter.field("org", in: text) ?? Frontmatter.field("organization", in: text)
            ?? Frontmatter.field("company", in: text)
        let entity = Entity(
            id: String(path.dropLast(3)), path: path, kind: kind, title: page.title,
            aliases: KnowledgeGraphBuilder.listField("aliases", in: yaml), projectSlug: projectSlug,
            projects: projects.map { $0.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "") },
            eventDate: date, role: Frontmatter.field("role", in: text), org: org,
            status: Frontmatter.field("status", in: text), isOwner: Frontmatter.field("owner", in: text)?.lowercased() == "true",
            frontLinks: [], outgoing: [], isNavigation: isNavigation)
        let targets = wikilinkTargets(in: split.body)
        // A plain `org: Acme` names an org page too, when one exists (resolved like a link).
        var frontTargets = wikilinkTargets(in: yaml)
        if let org, !org.contains("[[") { frontTargets.append("orgs/\(slugify(org))") }
        var tasks: [TaskItem] = []
        if let projectSlug, isProjectRoot, name == "tasks" {
            tasks = TaskParser.parse(text, path: path, projectSlug: projectSlug, owner: owner)
        }
        return Parsed(entity: entity, frontTargets: frontTargets, bodyTargets: targets, tasks: tasks)
    }

    // MARK: Links

    static func wikilinkTargets(in text: String) -> [String] { KnowledgeGraphBuilder.wikilinkTargets(in: text) }

    /// "[[ana-garcia|Ana]] y [[acme]]" → "Ana y acme".
    static func plainLinks(_ s: String) -> String {
        s.replacingOccurrences(of: #"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    /// The first paragraph of a page as plain text (the "En breve" of a compact ficha): no front matter, headings,
    /// list markers, emphasis or link syntax; cut at a word near `max` characters.
    public static func excerpt(_ text: String, max: Int = 280) -> String {
        var paragraph: [String] = []
        for raw in Frontmatter.split(text).body.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix("---") || line.hasPrefix("|") || line.hasPrefix("```") {
                if !paragraph.isEmpty { break }
                continue
            }
            if line.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            line = line.replacingOccurrences(of: #"^\[![a-zA-Z]+\][+-]?\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            line = plainLinks(line)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(\*\*|__|\*|`)"#, with: "", options: .regularExpression)
            if !line.isEmpty { paragraph.append(line) }
        }
        let joined = paragraph.joined(separator: " ")
        guard joined.count > max else { return joined }
        let cut = joined.prefix(max)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.")) + "…"
    }

    static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// A raw email message → its thread page; a project's `index.md` → its overview (the project's ficha); other
    /// raw files → nil.
    static func canonical(_ path: String, resolver: Resolver) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 4, parts[0] == "projects", parts[2] == "raw" {
            if parts.count >= 6, parts[3] == "emails" {
                let thread = "projects/\(parts[1])/wiki/emails/\(parts[4]).md"
                return resolver.exists(thread) ? thread : nil
            }
            return nil
        }
        if parts.count == 4, parts[0] == "projects", parts[2] == "wiki", parts[3] == "index.md" {
            let overview = "projects/\(parts[1])/wiki/overview.md"
            return resolver.exists(overview) ? overview : path
        }
        return isEntityPath(path) ? path : nil
    }

    /// `VaultStore.resolveWikilink` over an in-memory list: by file name, case-insensitive; same project first, then
    /// people/orgs, then anywhere; a wiki page beats a raw file of the same name. Path-style targets are honoured.
    struct Resolver {
        private var byName: [String: [String]] = [:]
        private var byPath: [String: String] = [:]

        init(all: [String]) {
            for p in all {
                byName[((p as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased(), default: []].append(p)
                byPath[p.lowercased()] = p
            }
        }

        func exists(_ path: String) -> Bool { byPath[path.lowercased()] != nil }

        func resolve(_ target: String, from relPath: String) -> String? {
            var name = target
            if let bar = name.firstIndex(of: "|") { name = String(name[..<bar]) }
            if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
            name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }
            if name.contains("/") {
                let wanted = name.lowercased() + ".md"
                if let hit = byPath[wanted] { return hit }
                let base = ((wanted as NSString).lastPathComponent as NSString).deletingPathExtension
                return byName[base]?.first { $0.lowercased().hasSuffix("/" + wanted) }
            }
            guard let matches = byName[name.lowercased()], !matches.isEmpty else { return nil }
            let slug = VaultStore.projectSlug(of: relPath)
            func rank(_ path: String) -> Int {
                let isRaw = path.contains("/raw/") || path.hasPrefix("_inbox/")
                let sameProject = slug.map { path.hasPrefix("projects/\($0)/") } ?? false
                switch (isRaw, sameProject) {
                case (false, true): return 0
                case (false, false): return path.hasPrefix("people/") || path.hasPrefix("orgs/") ? 1 : 2
                case (true, true): return 3
                case (true, false): return 4
                }
            }
            return matches.min { (rank($0), $0) < (rank($1), $1) }
        }
    }
}

// MARK: - Project people (§16.2)

/// `project.json` `people: {include, exclude}` (slugs of `people/`): what the user decided by hand in Personas.
public struct ProjectPeople: Codable, Hashable, Sendable {
    public var include: [String]
    public var exclude: [String]
    public init(include: [String] = [], exclude: [String] = []) { self.include = include; self.exclude = exclude }
}

public extension ProjectManager {
    /// "+ Agregar persona" (`included: true`) / "Quitar del proyecto" (`false`): one list gains the slug, the other
    /// loses it, so the latest choice wins.
    @discardableResult
    func setPerson(_ personSlug: String, included: Bool, in projectSlug: String) throws -> Project {
        guard var project = get(projectSlug) else { throw ProjectError.notFound(projectSlug) }
        var people = project.people ?? ProjectPeople()
        people.include.removeAll { $0 == personSlug }
        people.exclude.removeAll { $0 == personSlug }
        if included { people.include.append(personSlug) } else { people.exclude.append(personSlug) }
        project.people = people.include.isEmpty && people.exclude.isEmpty ? nil : people
        try update(project)
        return project
    }
}
