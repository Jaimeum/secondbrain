import Foundation

// Shared types from docs/CONTRACT.md. Public signatures here are the contract between modules:
// owners may add members but must not change or remove existing ones.

// MARK: - Config

public struct AppConfig: Codable, Equatable, Sendable {
    public var vaultPath: String
    public var dataPath: String
    public var whisperModel: String
    public var claudePath: String?
    public var ingestModel: String
    public var queryModel: String
    public var uiLanguage: String
    public var captureMic: Bool
    public var gitEnabled: Bool
    public var hotkeyEnabled: Bool
    public var onboardingComplete: Bool
    // v0.3 (CONTRACT §12): optional-with-default; decoded with decodeIfPresent so older config.json files keep loading.
    /// "system" (default) | "light" | "dark".
    public var appearance: String = "system"
    /// The user's own OAuth app registration (Ajustes → Cuentas → Avanzado); empty = use env/`OAuthDefaults`.
    public var oauth: OAuthAppRegistration = .empty
    /// Last project chosen in Correo's "Agregar al cerebro".
    public var lastMailProjectSlug: String? = nil
    // MARK: v0.4 github
    /// Minutes between automatic GitHub syncs (CONTRACT §13.4); 0 = only by hand.
    public var githubSyncMinutes: Int = 60
    // MARK: v0.6 capture
    /// Global ⌃⌥Space opens "Captura rápida" (CONTRACT §16.10).
    public var captureHotkeyEnabled: Bool = true

    public static let `default` = AppConfig(
        vaultPath: "~/Documents/SecondBrain",
        dataPath: "~/Library/Application Support/SecondBrain/data",
        whisperModel: "large-v3",
        claudePath: nil,
        ingestModel: "sonnet",
        queryModel: "opus",
        uiLanguage: "es",
        captureMic: true,
        gitEnabled: false,
        hotkeyEnabled: true,
        onboardingComplete: false
    )

    private enum CodingKeys: String, CodingKey {
        case vaultPath, dataPath, whisperModel, claudePath, ingestModel, queryModel, uiLanguage, captureMic, gitEnabled,
             hotkeyEnabled, onboardingComplete, appearance, oauth, lastMailProjectSlug,
             githubSyncMinutes,  // MARK: v0.4 github
             captureHotkeyEnabled  // MARK: v0.6 capture
    }

    public init(vaultPath: String, dataPath: String, whisperModel: String, claudePath: String?, ingestModel: String,
                queryModel: String, uiLanguage: String, captureMic: Bool, gitEnabled: Bool, hotkeyEnabled: Bool,
                onboardingComplete: Bool, appearance: String = "system", oauth: OAuthAppRegistration = .empty,
                lastMailProjectSlug: String? = nil, githubSyncMinutes: Int = 60, captureHotkeyEnabled: Bool = true) {
        self.vaultPath = vaultPath; self.dataPath = dataPath; self.whisperModel = whisperModel; self.claudePath = claudePath
        self.ingestModel = ingestModel; self.queryModel = queryModel; self.uiLanguage = uiLanguage; self.captureMic = captureMic
        self.gitEnabled = gitEnabled; self.hotkeyEnabled = hotkeyEnabled; self.onboardingComplete = onboardingComplete
        self.appearance = appearance; self.oauth = oauth; self.lastMailProjectSlug = lastMailProjectSlug
        self.githubSyncMinutes = githubSyncMinutes   // MARK: v0.4 github
        self.captureHotkeyEnabled = captureHotkeyEnabled   // MARK: v0.6 capture
    }

    /// v0.1 fields are required; everything added later falls back to its default when missing, so an older
    /// config.json never resets the user's settings (`load()` returns `.default` when decoding fails).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vaultPath = try c.decode(String.self, forKey: .vaultPath)
        dataPath = try c.decode(String.self, forKey: .dataPath)
        whisperModel = try c.decode(String.self, forKey: .whisperModel)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        ingestModel = try c.decode(String.self, forKey: .ingestModel)
        queryModel = try c.decode(String.self, forKey: .queryModel)
        uiLanguage = try c.decode(String.self, forKey: .uiLanguage)
        captureMic = try c.decode(Bool.self, forKey: .captureMic)
        gitEnabled = try c.decode(Bool.self, forKey: .gitEnabled)
        hotkeyEnabled = try c.decode(Bool.self, forKey: .hotkeyEnabled)
        onboardingComplete = try c.decode(Bool.self, forKey: .onboardingComplete)
        // Later fields: a missing or malformed value never makes the whole config fall back to defaults.
        if let mode = try? c.decodeIfPresent(String.self, forKey: .appearance), ["system", "light", "dark"].contains(mode) {
            appearance = mode
        } else {
            appearance = "system"
        }
        oauth = (try? c.decodeIfPresent(OAuthAppRegistration.self, forKey: .oauth)) ?? .empty
        lastMailProjectSlug = try? c.decodeIfPresent(String.self, forKey: .lastMailProjectSlug)
        // MARK: v0.4 github
        if let minutes = try? c.decodeIfPresent(Int.self, forKey: .githubSyncMinutes), minutes >= 0 {
            githubSyncMinutes = minutes
        } else {
            githubSyncMinutes = 60
        }
        // MARK: v0.6 capture
        captureHotkeyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .captureHotkeyEnabled)) ?? true
    }

    public static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["SB_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SecondBrain/config.json")
    }

    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder.sb.decode(AppConfig.self, from: data) else { return .default }
        return config
    }

    public func save() throws {
        let url = Self.configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.sb.encode(self).write(to: url, options: .atomic)
    }

    public var vaultURL: URL { URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath) }
    public var dataURL: URL { URL(fileURLWithPath: (dataPath as NSString).expandingTildeInPath) }
}

public struct DataPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public var sessions: URL { root.appendingPathComponent("sessions") }
    public var sources: URL { root.appendingPathComponent("sources") }
    public var jobs: URL { root.appendingPathComponent("jobs") }
    public var history: URL { root.appendingPathComponent("history") }
    public var models: URL { root.appendingPathComponent("models") }
    public var logs: URL { root.appendingPathComponent("logs") }
    /// v0.3: connected accounts (tokens live in the Keychain, not here).
    public var accounts: URL { root.appendingPathComponent("accounts.json") }
    /// v0.3: calendar event / series → project links (`MeetingLinks`).
    public var meetings: URL { root.appendingPathComponent("meetings.json") }
    // MARK: v0.4 github
    /// `data/github/`: account.json, repos.json, last-sync.json and the code checkouts (CONTRACT §13).
    public var github: URL { root.appendingPathComponent("github") }
    public var githubAccount: URL { github.appendingPathComponent("account.json") }
    public var githubRepos: URL { github.appendingPathComponent("repos.json") }
    public var githubLastSync: URL { github.appendingPathComponent("last-sync.json") }
    /// `data/github/checkouts/<owner>__<repo>/<branch-slug>/` (outside the vault: no graph, no history).
    public var githubCheckouts: URL { github.appendingPathComponent("checkouts") }
    /// `flock` held for a whole sync, so the app and `sb github sync` (cron) never sync the same repos at once.
    public var githubSyncLock: URL { github.appendingPathComponent("sync.lock") }

    public func ensureExist() throws {
        for dir in [sessions, sources, jobs, history, models, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Recording

public struct SessionManifest: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var projectSlug: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var sampleRate: Int
    public var chunkSeconds: Int
    public var tracks: [String: [String]]
    public var micCaptured: Bool
    // v0.3 (§12.5): the calendar event this recording belongs to, and its attendees' names.
    public var calendarEventId: String?
    public var attendees: [String]?

    public init(id: String, title: String?, projectSlug: String?, startedAt: Date, endedAt: Date? = nil,
                sampleRate: Int = 16000, chunkSeconds: Int = 300, tracks: [String: [String]] = [:], micCaptured: Bool,
                calendarEventId: String? = nil, attendees: [String]? = nil) {
        self.id = id; self.title = title; self.projectSlug = projectSlug; self.startedAt = startedAt
        self.endedAt = endedAt; self.sampleRate = sampleRate; self.chunkSeconds = chunkSeconds
        self.tracks = tracks; self.micCaptured = micCaptured
        self.calendarEventId = calendarEventId; self.attendees = attendees
    }

    /// `yyyyMMdd-HHmmss-xxxx`
    public static func newId(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + "-" + String(format: "%04x", UInt16.random(in: 0...UInt16.max))
    }

    public static func load(from dir: URL) throws -> SessionManifest {
        let data = try Data(contentsOf: dir.appendingPathComponent("session.json"))
        return try JSONDecoder.sb.decode(SessionManifest.self, from: data)
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.sb.encode(self).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }
}

// MARK: - Sources, jobs, history

public enum SourceKind: String, Codable, Sendable {
    case meeting, document, note, url, email
    case github   // MARK: v0.4 github — one raw per repo sync (CONTRACT §13.3)
}

public enum SourceStatus: String, Codable, Sendable {
    case recording, queued, transcribing, needsProject, ingesting, done, failed
}

public struct SourceRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: SourceKind
    public var title: String
    public var projectSlug: String?
    public var status: SourceStatus
    public var rawPath: String?
    public var historyId: String?
    public var suggestedProject: String?
    public var suggestionReason: String?
    public var error: String?
    public var progress: Double?
    public var createdAt: Date
    public var updatedAt: Date
    public var durationSeconds: Double?
    // v0.2 (CONTRACT §11): when it happened vs. createdAt = when it was added.
    public var eventDate: Date?
    public var templateId: String?
    public var threadKey: String?
    // v0.3 (§12.3/§12.5): "<provider>:<messageId>" for mail added from a connected account; linked calendar event.
    public var externalId: String?
    public var calendarEventId: String?

    /// The date the timeline uses: when it happened, falling back to when it was added.
    public var timelineDate: Date { eventDate ?? createdAt }

    public init(id: String, kind: SourceKind, title: String, projectSlug: String?, status: SourceStatus,
                rawPath: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.title = title; self.projectSlug = projectSlug; self.status = status
        self.rawPath = rawPath; self.createdAt = createdAt; self.updatedAt = createdAt
    }
}

public enum JobKind: String, Codable, Sendable { case transcribe, ingest, classify, lint, saveAnswer, reformat, makeTemplate, manualEdit }
public enum JobStatus: String, Codable, Sendable { case queued, running, done, failed, cancelled }

public struct Job: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: JobKind
    public var status: JobStatus
    public var sourceId: String?
    public var projectSlug: String?
    public var payload: [String: String]
    public var attempts: Int
    public var notBefore: Date?
    public var error: String?
    public var message: String?
    public var progress: Double?
    public var historyId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(kind: JobKind, sourceId: String? = nil, projectSlug: String? = nil, payload: [String: String] = [:]) {
        let now = Date()
        self.id = UUID().uuidString.lowercased(); self.kind = kind; self.status = .queued
        self.sourceId = sourceId; self.projectSlug = projectSlug; self.payload = payload
        self.attempts = 0; self.createdAt = now; self.updatedAt = now
    }
}

public enum ChangeType: String, Codable, Sendable { case added, modified, deleted }

public struct FileChange: Codable, Equatable, Sendable {
    public var path: String
    public var change: ChangeType
    public init(path: String, change: ChangeType) { self.path = path; self.change = change }
}

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: JobKind
    public var sourceId: String?
    public var projectSlug: String?
    public var changes: [FileChange]
    public var createdAt: Date
    public var undone: Bool
}

// MARK: - Transcription interface

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String   // "me" | "S1", "S2", ... | "S?"
    public var track: String     // "mic" | "system"
    public var text: String
    public init(start: Double, end: Double, speaker: String, track: String, text: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.track = track; self.text = text
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var language: String?
    public var durationSeconds: Double
    public var segments: [TranscriptSegment]
    public init(language: String?, durationSeconds: Double, segments: [TranscriptSegment]) {
        self.language = language; self.durationSeconds = durationSeconds; self.segments = segments
    }
}

public struct ModelPrepProgress: Sendable {
    public var fraction: Double
    public var message: String
    public init(fraction: Double, message: String) { self.fraction = fraction; self.message = message }
}

public protocol Transcribing: AnyObject, Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws
    var isReady: Bool { get }
    func transcribe(sessionDir: URL, manifest: SessionManifest,
                    progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript
}

// MARK: - Claude

public enum ClaudeEvent: Sendable, Equatable {
    case text(String)
    case tool(name: String, detail: String)
    case done(result: String, isError: Bool)
}

public enum ClaudeMode: Sendable { case readOnly, edit }

public enum ClaudeError: Error {
    case notInstalled, notAuthenticated
    case rateLimited(resetAt: Date?)
    case failed(String)
}

// MARK: - Vault

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var slug: String
    public var name: String
    public var description: String
    public var emoji: String
    public var createdAt: Date
    public var defaultTemplate: String?   // v0.2: template id for meetings/emails of this project
    public var id: String { slug }
    public init(slug: String, name: String, description: String, emoji: String, createdAt: Date = Date()) {
        self.slug = slug; self.name = name; self.description = description; self.emoji = emoji; self.createdAt = createdAt
    }
}

public struct WikiPage: Identifiable, Hashable, Sendable {
    public var path: String
    public var title: String
    public var id: String { path }
    public init(path: String, title: String) { self.path = path; self.title = title }
}

public enum EngineEvent: Sendable {
    case sourceUpdated(SourceRecord)
    case jobFailed(Job)
    case rateLimited(until: Date)
    case historyAdded(HistoryEntry)
}

// MARK: - Coding

public extension JSONEncoder {
    static var sb: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

public extension JSONDecoder {
    static var sb: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
