import Foundation

// Knowledge graph of the vault (CONTRACT §12.2).
//
// Nodes: every wiki page of every project (`projects/<slug>/wiki/**`, minus the navigation pages index/log/health),
// people (`people/*.md` minus README), companies (`orgs/*.md` minus README, v0.6 §16.4), global saved answers
// (`questions/**`) and the global `index.md`. Never `raw/`.
// Edges: wikilinks resolved with `VaultStore.resolveWikilinks` (one vault walk per project, since resolution only
// depends on the project of the linking page), undirected, deduped, weight = repetitions. A link to a raw email
// message counts as a link to its thread page; a link to a project's `index.md` counts as a link to the project.
// Each project gets a synthetic hub node `project:<slug>` tied to its overview and to its loose pages, so every
// project forms its own cluster and people sit between the projects they take part in.
// v0.6 (§16.5): a project's graph also holds the global people and companies linked to it (`linkedGlobals`).

public extension BrainEngine {
    /// Nodes and edges of the whole brain (`projectSlug == nil`) or of one project. Runs off the main thread and is
    /// cached by a cheap vault signature (file count + latest modification), so reopening the tab is instant.
    func graph(projectSlug: String?) async -> KnowledgeGraph {
        let root = vault.root
        return await Task.detached(priority: .userInitiated) {
            KnowledgeGraphBuilder.cachedGraph(vaultRoot: root, projectSlug: projectSlug)
        }.value
    }
}

public enum KnowledgeGraphBuilder {
    // MARK: Cache

    private struct CacheKey: Hashable { let root: String; let slug: String? }
    private struct CacheEntry { let signature: String; let graph: KnowledgeGraph }
    nonisolated(unsafe) private static var cache: [CacheKey: CacheEntry] = [:]
    private static let lock = NSLock()

    /// Builds (or returns the cached) graph. Blocking: call it off the main thread.
    public static func cachedGraph(vaultRoot: URL, projectSlug: String?) -> KnowledgeGraph {
        let signature = vaultSignature(vaultRoot)
        let key = CacheKey(root: vaultRoot.standardizedFileURL.path, slug: projectSlug)
        lock.lock()
        if let hit = cache[key], hit.signature == signature {
            lock.unlock()
            return hit.graph
        }
        lock.unlock()
        let graph = build(vaultRoot: vaultRoot, projectSlug: projectSlug)
        lock.lock()
        cache[key] = CacheEntry(signature: signature, graph: graph)
        lock.unlock()
        return graph
    }

    /// "<markdown file count>:<latest mtime>:<projects/ mtime>": changes whenever a page is added, removed or edited.
    /// Only stats files (no reads), so it is cheap even for thousands of pages.
    public static func vaultSignature(_ root: URL) -> String {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        var count = 0
        var latest: TimeInterval = 0
        var latestDir: TimeInterval = 0
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return "0"
        }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let mtime = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            if values?.isDirectory == true {
                latestDir = max(latestDir, mtime)   // deletions and renames only touch the folder
                continue
            }
            guard url.pathExtension.lowercased() == "md" || url.lastPathComponent == "project.json" else { continue }
            count += 1
            latest = max(latest, mtime)
        }
        return "\(count):\(latest):\(latestDir)"
    }

    // MARK: Build

    struct Page {
        let path: String
        let title: String
        let kind: GraphNodeKind
        let projectSlug: String?
        let date: Date?
        let targets: [String]
        /// `projects:` of a person or company page (global pages only).
        let personProjects: [String]
    }

    /// Person or company: global pages that a project's graph includes when they are linked to it.
    static func isGlobalEntity(_ path: String) -> Bool { path.hasPrefix("people/") || path.hasPrefix("orgs/") }

    /// Builds the graph from disk (no cache). Blocking: call it off the main thread.
    public static func build(vaultRoot: URL, projectSlug: String?) -> KnowledgeGraph {
        let vault = VaultStore(root: vaultRoot)
        let projects = ProjectManager(vaultRoot: vaultRoot).list()
        let allSlugs = projects.map(\.slug)

        // 1. Pages in scope.
        var paths: [String] = []
        for slug in allSlugs where projectSlug == nil || projectSlug == slug {
            paths += vault.markdownFiles(under: "projects/\(slug)/wiki").filter { isGraphPage($0) }
        }
        let globalPaths = ["people", "orgs"].flatMap { folder in
            vault.markdownFiles(under: folder).filter { !$0.hasSuffix("/README.md") && isGraphPage($0) }
        }
        paths += globalPaths
        if projectSlug == nil {
            paths += vault.markdownFiles(under: "questions").filter { isGraphPage($0) }
            if FileManager.default.fileExists(atPath: vault.url(for: "index.md").path) { paths.append("index.md") }
        }

        var pages: [String: Page] = [:]
        for path in paths {
            guard let text = try? vault.read(path) else { continue }
            pages[path] = parse(path: path, text: text)
        }

        // 2. Resolve links: one vault walk per linking project (resolution only depends on the linker's project).
        let byProject = Dictionary(grouping: pages.values, by: { $0.projectSlug ?? "" })
        var resolvedByProject: [String: [String: String]] = [:]
        for (slug, group) in byProject {
            let targets = Array(Set(group.flatMap(\.targets)))
            guard !targets.isEmpty else { continue }
            let representative = slug.isEmpty ? "index.md" : "projects/\(slug)/wiki/overview.md"
            resolvedByProject[slug] = vault.resolveWikilinks(targets, from: representative)
        }

        // 3. People and companies in a project's graph (`linkedGlobals`); the others leave it.
        var nodeIds = Set(pages.keys)
        if let projectSlug {
            let keep = linkedGlobals(projectSlug: projectSlug, pages: pages, resolvedByProject: resolvedByProject,
                                     vaultRoot: vaultRoot)
            for path in globalPaths where !keep.contains(path) { nodeIds.remove(path); pages[path] = nil }
        }

        // 4. Edges (undirected, deduped, weight = repetitions).
        let hubSlugs = projectSlug.map { [$0] } ?? allSlugs
        var weights: [String: Int] = [:]   // "a\u{1}b" with a < b
        func addEdge(_ a: String, _ b: String, _ w: Int = 1) {
            guard a != b else { return }
            let key = a < b ? "\(a)\u{1}\(b)" : "\(b)\u{1}\(a)"
            weights[key, default: 0] += w
        }
        for page in pages.values {
            let resolved = resolvedByProject[page.projectSlug ?? ""] ?? [:]
            for target in page.targets {
                guard let raw = resolved[target], let path = canonical(raw, hubs: hubSlugs, vault: vault) else { continue }
                if path.hasPrefix("project:") || nodeIds.contains(path) { addEdge(page.path, path) }
            }
        }

        // 5. Project hubs: tied to overview.md and to every page with ≤ 1 link, so each project is one cluster.
        var degree: [String: Int] = [:]
        for (key, _) in weights {
            let parts = key.components(separatedBy: "\u{1}")
            degree[parts[0], default: 0] += 1
            degree[parts[1], default: 0] += 1
        }
        var hubs: [GraphNode] = []
        for project in projects where hubSlugs.contains(project.slug) {
            let hub = "project:\(project.slug)"
            let own = pages.values.filter { $0.projectSlug == project.slug }
            guard !own.isEmpty else { continue }
            hubs.append(GraphNode(id: hub, title: "\(project.emoji) \(project.name)", kind: .project, projectSlug: project.slug))
            for page in own where page.path.hasSuffix("/wiki/overview.md") || degree[page.path, default: 0] <= 1 {
                addEdge(hub, page.path)
            }
        }
        let hubIds = Set(hubs.map(\.id))

        var edges: [GraphEdge] = []
        degree = [:]
        for (key, w) in weights {
            let parts = key.components(separatedBy: "\u{1}")
            let (a, b) = (parts[0], parts[1])
            guard nodeIds.contains(a) || hubIds.contains(a), nodeIds.contains(b) || hubIds.contains(b) else { continue }
            edges.append(GraphEdge(source: a, target: b, weight: w))
            degree[a, default: 0] += 1
            degree[b, default: 0] += 1
        }
        edges.sort { ($0.source, $0.target) < ($1.source, $1.target) }

        var nodes = hubs.map { hub -> GraphNode in
            var hub = hub
            hub.links = degree[hub.id, default: 0]
            return hub
        }
        for page in pages.values where nodeIds.contains(page.path) {
            nodes.append(GraphNode(id: page.path, title: page.title, kind: page.kind, projectSlug: page.projectSlug,
                                   date: page.date, links: degree[page.path, default: 0]))
        }
        nodes.sort { $0.id < $1.id }
        return KnowledgeGraph(nodes: nodes, edges: edges)
    }

    /// The people and companies (`people/`, `orgs/`) a project's graph shows: listing the project in `projects:`,
    /// linked from one of its pages, or linking to one; `project.json` `people: {include, exclude}` (slugs of
    /// `people/`, §16.2) has the last word on people; then the companies those people link to (Ana → Acme).
    static func linkedGlobals(projectSlug: String, pages: [String: Page], resolvedByProject: [String: [String: String]],
                              vaultRoot: URL) -> Set<String> {
        var keep = Set<String>()
        let globals = pages.values.filter { isGlobalEntity($0.path) }
        for page in globals where page.personProjects.contains(projectSlug) { keep.insert(page.path) }
        let resolved = resolvedByProject[projectSlug] ?? [:]
        for page in pages.values where page.projectSlug == projectSlug {
            for t in page.targets { if let p = resolved[t], isGlobalEntity(p) { keep.insert(p) } }
        }
        let resolvedGlobal = resolvedByProject[""] ?? [:]
        for page in globals where page.targets.contains(where: { (resolvedGlobal[$0] ?? "").hasPrefix("projects/\(projectSlug)/") }) {
            keep.insert(page.path)
        }
        let people = projectPeople(vaultRoot: vaultRoot, slug: projectSlug)
        for slug in people.include where pages["people/\(slug).md"] != nil { keep.insert("people/\(slug).md") }
        for slug in people.exclude { keep.remove("people/\(slug).md") }
        for path in keep where path.hasPrefix("people/") {
            for t in pages[path]?.targets ?? [] {
                if let p = resolvedGlobal[t], p.hasPrefix("orgs/"), pages[p] != nil { keep.insert(p) }
            }
        }
        return keep
    }

    /// `project.json` → `people: {include: [slug], exclude: [slug]}` (§16.2). Read loosely: the field is optional and
    /// the rest of the file belongs to `ProjectManager`.
    static func projectPeople(vaultRoot: URL, slug: String) -> (include: [String], exclude: [String]) {
        let url = vaultRoot.appendingPathComponent("projects/\(slug)/project.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let people = json["people"] as? [String: Any] else { return ([], []) }
        return (people["include"] as? [String] ?? [], people["exclude"] as? [String] ?? [])
    }

    /// Navigation and maintenance pages are not knowledge: they would tie everything to everything.
    static func isGraphPage(_ path: String) -> Bool {
        guard path.hasSuffix(".md"), !path.contains("/raw/"), !path.hasPrefix("_inbox/") else { return false }
        let name = (path as NSString).lastPathComponent
        if name == "CLAUDE.md" || name.hasPrefix("CLAUDE.v") { return false }
        if path.hasPrefix("projects/") { return !["index.md", "log.md", "health.md"].contains(name) }
        return !["log.md", "health.md"].contains(name)
    }

    /// Maps a resolved link to the node it stands for: a raw email message → its thread page; a project's index →
    /// its hub. Other raw files and navigation pages → nil.
    static func canonical(_ path: String, hubs: [String], vault: VaultStore) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 4, parts[0] == "projects" {
            let slug = parts[1]
            if parts[2] == "raw" {
                if parts.count >= 6, parts[3] == "emails" {
                    let thread = "projects/\(slug)/wiki/emails/\(parts[4]).md"
                    return FileManager.default.fileExists(atPath: vault.url(for: thread).path) ? thread : nil
                }
                return nil
            }
            if parts.count == 4, parts[2] == "wiki", parts[3] == "index.md" { return hubs.contains(slug) ? "project:\(slug)" : nil }
        }
        return isGraphPage(path) ? path : nil
    }

    // MARK: Page parsing

    private static let wikilinkRegex =
        try! NSRegularExpression(pattern: #"\[\[([^\[\]\|#\n]+)(?:#[^\[\]\|\n]*)?(?:\|[^\[\]\n]*)?\]\]"#)

    static func wikilinkTargets(in text: String) -> [String] {
        let ns = text as NSString
        return wikilinkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
    }

    static func parse(path: String, text: String) -> Page {
        let parts = Frontmatter.split(text)
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var title: String?
        for line in parts.body.components(separatedBy: "\n") where line.hasPrefix("# ") {
            let t = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { title = t; break }
        }
        let type = Frontmatter.field("type", in: text)?.lowercased()
        let sourceType = Frontmatter.field("source_type", in: text)?.lowercased()
        let kind = kindFor(path: path, type: type, sourceType: sourceType)
        var date: Date?
        if let raw = Frontmatter.field("event_date", in: text) ?? Frontmatter.field("date", in: text) {
            date = SBDate.parseISO(raw)?.date
        }
        var personProjects: [String] = []
        var targets = wikilinkTargets(in: text)
        if isGlobalEntity(path), let yaml = parts.yaml {
            personProjects = listField("projects", in: yaml)
            // A person's company written as a plain name (`org: Acme`, `organization: "Acme"`): its `orgs/` page.
            for key in ["org", "organization"] {
                for value in listField(key, in: yaml) where !value.contains("[[") {
                    let slug = slugify(value)
                    if !slug.isEmpty { targets.append("orgs/\(slug)") }
                }
            }
        }
        // Links in the frontmatter (people:, topics:, decided_by:) count too: they are the page's explicit relations.
        return Page(path: path, title: title ?? Frontmatter.field("title", in: text) ?? fallback, kind: kind,
                    projectSlug: VaultStore.projectSlug(of: path), date: date, targets: targets,
                    personProjects: personProjects)
    }

    /// `projects: ["a", "b"]` or a block list (`- a`).
    static func listField(_ key: String, in yaml: String) -> [String] {
        let lines = yaml.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) else { return [] }
        let clean: (String) -> String = {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'[]")).trimmingCharacters(in: .whitespaces)
        }
        let inline = String(lines[i].dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if !inline.isEmpty {
            return inline.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { clean(String($0)) }
                .filter { !$0.isEmpty && $0 != "null" }
        }
        var out: [String] = []
        for line in lines[(i + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { break }
            out.append(clean(String(t.dropFirst(2))))
        }
        return out.filter { !$0.isEmpty }
    }

    /// Kind by folder, overridden by the frontmatter `type:` when it names one.
    static func kindFor(path: String, type: String?, sourceType: String?) -> GraphNodeKind {
        var kind: GraphNodeKind = .page
        let parts = path.split(separator: "/").map(String.init)
        if parts.first == "people" {
            kind = .person
        } else if parts.first == "orgs" {
            kind = .org
        } else if parts.first == "questions" {
            kind = .question
        } else if parts.count >= 5, parts[0] == "projects", parts[2] == "wiki" {
            switch parts[3] {
            case "meetings": kind = .meeting
            case "emails": kind = .email
            case "sources": kind = sourceType == "url" ? .url : sourceType == "note" ? .note : .document
            case "topics": kind = .topic
            case "decisions": kind = .decision
            case "questions": kind = .question
            case "repos": kind = .repo   // MARK: v0.4 github
            default: kind = .page
            }
        }
        switch type {
        case "meeting": return .meeting
        case "email", "email-thread", "thread": return .email
        case "source": return sourceType == "url" ? .url : sourceType == "note" ? .note : .document
        case "document": return .document
        case "note": return .note
        case "url": return .url
        case "person": return .person
        case "org", "organization", "company": return .org
        case "topic": return .topic
        case "decision": return .decision
        case "question": return .question
        case "task": return .task
        case "repo", "github-repo", "repo-branch": return .repo   // MARK: v0.4 github
        case "overview", "tasks", "timeline", "index", "people": return .page
        default: return kind
        }
    }
}
