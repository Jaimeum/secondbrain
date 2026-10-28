import Foundation

/// Read access to the markdown vault plus template installation (CONTRACT §5.6).
public final class VaultStore: @unchecked Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `vault-template/` from the BrainCore bundle. `SB_VAULT_TEMPLATE` overrides it (tests).
    public static var templateURL: URL? {
        if let override = ProcessInfo.processInfo.environment["SB_VAULT_TEMPLATE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return Bundle.module.url(forResource: "vault-template", withExtension: nil)
    }

    /// Recursively copies files, creating folders; existing files are kept unless `overwrite`.
    /// `transform` may rewrite text of .md files on the way.
    static func copyTree(from src: URL, to dest: URL, overwrite: Bool, transform: ((String) -> String)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in walker {
            guard let rel = url.relativePath(from: src), url.lastPathComponent != ".DS_Store" else { continue }
            let target = dest.appendingPathComponent(rel)
            if fm.isDirectory(url) {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            if fm.fileExists(atPath: target.path) {
                guard overwrite else { continue }
                try fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let transform, url.pathExtension == "md", let text = try? String(contentsOf: url, encoding: .utf8) {
                try transform(text).write(to: target, atomically: true, encoding: .utf8)
            } else {
                try fm.copyItem(at: url, to: target)
            }
        }
    }

    // MARK: Pages

    /// Wiki pages of a project (`projects/<slug>/wiki/**`), or the global ones (index.md, log.md, people/…).
    public func pages(projectSlug: String?) -> [WikiPage] {
        let paths: [String]
        if let slug = projectSlug {
            paths = markdownFiles(under: "projects/\(slug)/wiki")
        } else {
            let fm = FileManager.default
            let rootFiles = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasSuffix(".md") && $0 != "CLAUDE.md" && $0 != "README.md" }
            // v0.6: `orgs/` (global companies, §16.4) next to `people/`.
            paths = rootFiles + (markdownFiles(under: "people") + markdownFiles(under: "orgs")).filter { !$0.hasSuffix("/README.md") }
        }
        func rank(_ p: String) -> Int {
            switch (p as NSString).lastPathComponent {
            case "index.md": return 0
            case "overview.md": return 1
            case "tasks.md": return 2
            case "timeline.md": return 3
            case "log.md": return 4
            default: return 5
            }
        }
        return paths
            .sorted { (rank($0), $0.lowercased()) < (rank($1), $1.lowercased()) }
            .map { WikiPage(path: $0, title: title(of: $0)) }
    }

    public func read(_ relPath: String) throws -> String {
        try String(contentsOf: url(for: relPath), encoding: .utf8)
    }

    public func url(for relPath: String) -> URL { root.appendingPathComponent(relPath) }

    /// First `# ` heading, else frontmatter `title`, else the file name.
    public func title(of relPath: String) -> String {
        let fallback = ((relPath as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let text = try? read(relPath) else { return fallback }
        for line in Frontmatter.split(text).body.components(separatedBy: "\n") where line.hasPrefix("# ") {
            let t = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return Frontmatter.field("title", in: text) ?? fallback
    }

    // MARK: Links

    /// Resolves `[[target]]` (alias/heading stripped) by file name, case-insensitive:
    /// same project first, then global pages, then anywhere. Path-style targets are honoured.
    public func resolveWikilink(_ target: String, from relPath: String) -> String? {
        resolveWikilink(target, from: relPath, in: allMarkdown())
    }

    /// Resolves many targets with a single walk of the vault (target → path; unresolved ones are left out).
    public func resolveWikilinks(_ targets: [String], from relPath: String) -> [String: String] {
        let all = allMarkdown()
        var out: [String: String] = [:]
        for target in Set(targets) { out[target] = resolveWikilink(target, from: relPath, in: all) }
        return out
    }

    private func resolveWikilink(_ target: String, from relPath: String, in all: [String]) -> String? {
        var name = target
        if let bar = name.firstIndex(of: "|") { name = String(name[..<bar]) }
        if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }

        if name.contains("/") {
            let wanted = name.lowercased() + ".md"
            return all.first { $0.lowercased() == wanted } ?? all.first { $0.lowercased().hasSuffix("/" + wanted) }
        }
        let wanted = name.lowercased()
        let matches = all.filter { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == wanted }
        // A source's wiki page and its raw file share a name: the wiki page wins (CONTRACT [D]).
        let slug = Self.projectSlug(of: relPath)
        func rank(_ path: String) -> Int {
            let isRaw = path.contains("/raw/") || path.hasPrefix("_inbox/")
            let sameProject = slug.map { path.hasPrefix("projects/\($0)/") } ?? false
            switch (isRaw, sameProject) {
            case (false, true): return 0
            case (false, false): return path.hasPrefix("people/") ? 1 : 2
            case (true, true): return 3
            case (true, false): return 4
            }
        }
        return matches.min { rank($0) < rank($1) }
    }

    public func backlinks(to relPath: String) -> [WikiPage] {
        let name = ((relPath as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let pathName = (relPath as NSString).deletingPathExtension.lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#) else { return [] }
        var result: [WikiPage] = []
        let all = allMarkdown()
        for path in all where path != relPath && !path.contains("/raw/") {
            guard let text = try? read(path) else { continue }
            let lower = text.lowercased()
            guard lower.contains(name) || lower.contains(pathName) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let links = regex.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            if links.contains(where: { resolveWikilink($0, from: path, in: all) == relPath }) {
                result.append(WikiPage(path: path, title: title(of: path)))
            }
        }
        return result.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    // MARK: Background variants (vault-wide scans; call these from the UI)

    public func pagesAsync(projectSlug: String?) async -> [WikiPage] {
        await Task.detached(priority: .userInitiated) { self.pages(projectSlug: projectSlug) }.value
    }

    public func backlinksAsync(to relPath: String) async -> [WikiPage] {
        await Task.detached(priority: .userInitiated) { self.backlinks(to: relPath) }.value
    }

    public func resolveWikilinksAsync(_ targets: [String], from relPath: String) async -> [String: String] {
        await Task.detached(priority: .userInitiated) { self.resolveWikilinks(targets, from: relPath) }.value
    }

    static func projectSlug(of relPath: String) -> String? {
        let parts = relPath.split(separator: "/")
        return parts.count > 2 && parts[0] == "projects" ? String(parts[1]) : nil
    }

    // MARK: Files

    func markdownFiles(under rel: String) -> [String] {
        let fm = FileManager.default
        let base = root.appendingPathComponent(rel)
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            if let p = url.relativePath(from: root) { out.append(p) }
        }
        return out
    }

    /// Every markdown file in the vault (vault-relative), except hidden folders and CLAUDE.md schemas.
    public func allMarkdownPaths() -> [String] { allMarkdown() }

    /// Every markdown file in the vault except hidden folders and CLAUDE.md schemas.
    func allMarkdown() -> [String] {
        markdownFiles(under: "").filter { ($0 as NSString).lastPathComponent != "CLAUDE.md" }
    }
}
