import Foundation

// MARK: v0.6 scope (CONTRACT §16): "el lugar fija el ámbito".

/// Where something lives or is asked: the whole brain, or one project. Every screen that exists at both levels
/// (Preguntar, Grafo, Pendientes, fichas) takes one of these; there is no scope switch on screen. Codable so a saved
/// conversation (`ChatThread.scope`, §16.3) can keep it.
public enum Scope: Hashable, Sendable, Codable {
    case brain
    case project(String)

    /// nil for `.brain`.
    public init(projectSlug: String?) {
        self = projectSlug.map { .project($0) } ?? .brain
    }

    public var projectSlug: String? {
        if case .project(let slug) = self { return slug }
        return nil
    }

    public var isBrain: Bool { self == .brain }

    /// "brain" / "project:<slug>": a stable key for caches, task ids and file names.
    public var key: String { projectSlug.map { "project:\($0)" } ?? "brain" }

    /// The project a vault-relative path belongs to (`projects/<slug>/…`), else nil.
    public static func projectSlug(ofPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2, parts[0] == "projects" else { return nil }
        return String(parts[1])
    }
}
