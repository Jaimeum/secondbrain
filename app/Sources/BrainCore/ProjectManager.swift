import Foundation

public enum ProjectError: Error, LocalizedError {
    case emptyName
    case notFound(String)

    public var errorDescription: String? {
        let lang = Lang(AppConfig.load().uiLanguage)
        switch self {
        case .emptyName: return lang.t("El proyecto necesita un nombre.", "The project needs a name.")
        case .notFound(let slug): return lang.t("No encontré el proyecto «\(slug)».", "Project not found: \(slug)")
        }
    }
}

/// Projects live in `projects/<slug>/` with a `project.json` (CONTRACT §5.6).
public final class ProjectManager: @unchecked Sendable {
    public let vaultRoot: URL
    private var projectsDir: URL { vaultRoot.appendingPathComponent("projects") }

    public init(vaultRoot: URL) { self.vaultRoot = vaultRoot }

    public func list() -> [Project] {
        let fm = FileManager.default
        let slugs = (try? fm.contentsOfDirectory(atPath: projectsDir.path)) ?? []
        return slugs.compactMap { get($0) }.sorted { ($0.createdAt, $0.slug) < ($1.createdAt, $1.slug) }
    }

    /// `list()` on a background task.
    public func listAsync() async -> [Project] {
        await Task.detached(priority: .userInitiated) { self.list() }.value
    }

    public func get(_ slug: String) -> Project? {
        let url = projectsDir.appendingPathComponent(slug).appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.sb.decode(Project.self, from: data)
    }

    public func create(name: String, description: String, emoji: String) throws -> Project {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        let fm = FileManager.default
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let base = slugify(name).isEmpty ? "proyecto" : slugify(name)
        var slug = base
        var n = 2
        while fm.fileExists(atPath: projectsDir.appendingPathComponent(slug).path) {
            slug = "\(base)-\(n)"
            n += 1
        }
        let project = Project(slug: slug, name: name, description: description, emoji: emoji.isEmpty ? "📁" : emoji)
        let dir = projectsDir.appendingPathComponent(slug)
        let date = Fmt.local(project.createdAt, "yyyy-MM-dd")
        // Placeholders inside quoted YAML values (`title: "{{PROJECT_NAME}} — índice"`) need `"` and `\` escaped.
        func substitute(_ line: String, quoted: Bool) -> String {
            let escape: (String) -> String = {
                quoted ? $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") : $0
            }
            return line.replacingOccurrences(of: "{{PROJECT_NAME}}", with: escape(name))
                .replacingOccurrences(of: "{{PROJECT_SLUG}}", with: slug)
                .replacingOccurrences(of: "{{PROJECT_DESCRIPTION}}", with: escape(description))
                .replacingOccurrences(of: "{{DATE}}", with: date)
        }
        let fill: (String) -> String = { text in
            let yamlEnd = Frontmatter.split(text).yaml.map { $0.components(separatedBy: "\n").count + 1 } ?? 0
            return text.components(separatedBy: "\n").enumerated().map { i, line in
                substitute(line, quoted: i <= yamlEnd && line.contains("\"{{"))
            }.joined(separator: "\n")
        }
        if let template = VaultStore.templateURL?.appendingPathComponent("project"), fm.isDirectory(template) {
            try VaultStore.copyTree(from: template, to: dir, overwrite: false, transform: fill)
        } else {
            Log.error("project template not found; creating bare structure")
        }
        for sub in ["raw/meetings", "raw/docs", "raw/notes", "raw/assets",
                    "wiki/meetings", "wiki/topics", "wiki/decisions", "wiki/questions"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let index = dir.appendingPathComponent("wiki/index.md")
        if !fm.fileExists(atPath: index.path) {
            try "# \(name)\n\n\(description)\n".write(to: index, atomically: true, encoding: .utf8)
        }
        try save(project)
        try addToGlobalIndex(project)
        Log.info("created project \(slug)")
        return project
    }

    public func update(_ project: Project) throws {
        guard FileManager.default.fileExists(atPath: projectsDir.appendingPathComponent(project.slug).path) else {
            throw ProjectError.notFound(project.slug)
        }
        try save(project)
    }

    private func save(_ project: Project) throws {
        let url = projectsDir.appendingPathComponent(project.slug).appendingPathComponent("project.json")
        try JSONEncoder.sb.encode(project).write(to: url, options: .atomic)
    }

    /// Adds a link line under the "## Proyectos"/"## Projects" section of the global index.md.
    private func addToGlobalIndex(_ project: Project) throws {
        let url = vaultRoot.appendingPathComponent("index.md")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Index\n"
        var line = "- [[projects/\(project.slug)/wiki/index|\(project.emoji) \(project.name)]]"
        if !project.description.isEmpty { line += " — \(project.description)" }

        var lines = text.components(separatedBy: "\n")
        if let header = lines.firstIndex(where: { Self.isProjectsHeading($0) }) {
            var insertAt = header + 1
            var i = header + 1
            while i < lines.count, !lines[i].hasPrefix("#") {
                if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { insertAt = i + 1 }
                i += 1
            }
            // Keep a blank line after the heading when the section was empty.
            if insertAt == header + 1 {
                lines.insert("", at: insertAt)
                insertAt += 1
            }
            lines.insert(line, at: insertAt)
            text = lines.joined(separator: "\n")
        } else {
            while text.hasSuffix("\n\n") { text.removeLast() }
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n## Proyectos\n\n\(line)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func isProjectsHeading(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix("## ") else { return false }
        let title = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return title.hasPrefix("proyectos") || title.hasPrefix("projects")
    }
}
