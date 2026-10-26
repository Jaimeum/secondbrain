import Foundation
import Observation

// TEMPORARY skeleton of the public API in docs/CONTRACT.md §5.3–5.6 so other targets compile from day one.
// Agent C replaces this file with real implementations (keep the same public signatures) and deletes it.

@MainActor @Observable public final class BrainEngine {
    public private(set) var config: AppConfig
    public let paths: DataPaths
    public let vault: VaultStore
    public let projects: ProjectManager
    public let history: HistoryStore
    public let claude: ClaudeRunner
    public private(set) var sources: [SourceRecord] = []
    public private(set) var jobs: [Job] = []
    public private(set) var isProcessing = false
    public var onEvent: ((EngineEvent) -> Void)?

    public init(config: AppConfig, transcriber: Transcribing) {
        self.config = config
        self.paths = DataPaths(root: config.dataURL)
        self.vault = VaultStore(root: config.vaultURL)
        self.projects = ProjectManager(vaultRoot: config.vaultURL)
        self.history = HistoryStore(vaultRoot: config.vaultURL, historyDir: DataPaths(root: config.dataURL).history)
        let c = config
        self.claude = ClaudeRunner(configProvider: { c }, vaultURL: config.vaultURL)
    }
    public func start() { fatalError("TODO") }
    public func updateConfig(_ c: AppConfig) throws { fatalError("TODO") }
    public func recordingStarted(_ m: SessionManifest) { fatalError("TODO") }
    public func recordingFinished(_ m: SessionManifest) { fatalError("TODO") }
    public func importFile(_ url: URL, projectSlug: String?) throws { fatalError("TODO") }
    public func importURL(_ url: URL, projectSlug: String?) async throws { fatalError("TODO") }
    public func addNote(title: String, body: String, projectSlug: String?) throws { fatalError("TODO") }
    public func assign(sourceId: String, to projectSlug: String) throws { fatalError("TODO") }
    public func retry(sourceId: String) { fatalError("TODO") }
    public func delete(sourceId: String) throws { fatalError("TODO") }
    public func ask(_ question: String, projectSlug: String?) -> AsyncThrowingStream<ClaudeEvent, Error> { fatalError("TODO") }
    public func saveAnswer(question: String, answer: String, projectSlug: String?) { fatalError("TODO") }
    public func lint(projectSlug: String?) { fatalError("TODO") }
    public func undo(historyId: String) throws { fatalError("TODO") }
    public func runUntilIdle() async { fatalError("TODO") }
}

public final class ClaudeRunner: @unchecked Sendable {
    public init(configProvider: @escaping @Sendable () -> AppConfig, vaultURL: URL) {}
    public func run(command: String, arguments: String, mode: ClaudeMode, model: String) -> AsyncThrowingStream<ClaudeEvent, Error> { fatalError("TODO") }
    public func runPrompt(_ prompt: String, mode: ClaudeMode, model: String) -> AsyncThrowingStream<ClaudeEvent, Error> { fatalError("TODO") }
}

public enum ClaudeSetup {
    public static func locate(config: AppConfig) -> URL? { fatalError("TODO") }
    public static func install(log: @escaping @Sendable (String) -> Void) async throws -> URL { fatalError("TODO") }
    public static func checkAuth(config: AppConfig) async -> Bool { fatalError("TODO") }
    public static func saveToken(_ token: String) throws { fatalError("TODO") }
    public static func loadToken() -> String? { fatalError("TODO") }
    public static func extractToken(from terminalOutput: String) -> String? { fatalError("TODO") }
}

public enum HistoryError: Error { case conflict([String]), notFound }
public struct HistorySnapshot: Sendable {}

public final class HistoryStore: @unchecked Sendable {
    public init(vaultRoot: URL, historyDir: URL) {}
    public func begin(title: String, kind: JobKind, sourceId: String?, projectSlug: String?) throws -> HistorySnapshot { fatalError("TODO") }
    public func commit(_ snapshot: HistorySnapshot) throws -> HistoryEntry? { fatalError("TODO") }
    public func entries() -> [HistoryEntry] { fatalError("TODO") }
    public func diff(entryId: String, path: String) -> (before: String?, after: String?) { fatalError("TODO") }
    public func undo(entryId: String, force: Bool = false) throws { fatalError("TODO") }
}

public final class ProjectManager: @unchecked Sendable {
    public init(vaultRoot: URL) {}
    public func list() -> [Project] { fatalError("TODO") }
    public func create(name: String, description: String, emoji: String) throws -> Project { fatalError("TODO") }
    public func update(_ project: Project) throws { fatalError("TODO") }
}

public final class VaultStore: @unchecked Sendable {
    public init(root: URL) {}
    public func installTemplateIfNeeded() throws { fatalError("TODO") }
    public func pages(projectSlug: String?) -> [WikiPage] { fatalError("TODO") }
    public func read(_ relPath: String) throws -> String { fatalError("TODO") }
    public func resolveWikilink(_ target: String, from relPath: String) -> String? { fatalError("TODO") }
    public func backlinks(to relPath: String) -> [WikiPage] { fatalError("TODO") }
    public func url(for relPath: String) -> URL { fatalError("TODO") }
}
