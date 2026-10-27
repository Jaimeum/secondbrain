import Foundation

// Shared v0.3 types (docs/CONTRACT.md §12). Same rule as Models.swift / ModelsV2.swift: owners may add members,
// never change or remove existing public ones.

// MARK: - Knowledge graph (§12.2)

public enum GraphNodeKind: String, Codable, Sendable {
    case project, meeting, email, document, note, url, person, topic, decision, question, task, page
    case repo   // MARK: v0.4 github — wiki/repos/
}

public struct GraphNode: Codable, Identifiable, Hashable, Sendable {
    public var id: String          // vault-relative path; project node = "project:<slug>"
    public var title: String
    public var kind: GraphNodeKind
    public var projectSlug: String?
    public var date: Date?         // frontmatter `date:` (when it happened) or nil
    public var links: Int          // degree (incoming + outgoing)
    public init(id: String, title: String, kind: GraphNodeKind, projectSlug: String? = nil, date: Date? = nil, links: Int = 0) {
        self.id = id; self.title = title; self.kind = kind; self.projectSlug = projectSlug; self.date = date; self.links = links
    }
}

public struct GraphEdge: Codable, Hashable, Sendable {
    public var source: String
    public var target: String
    public var weight: Int
    public init(source: String, target: String, weight: Int = 1) {
        self.source = source; self.target = target; self.weight = weight
    }
}

public struct KnowledgeGraph: Codable, Sendable {
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    public init(nodes: [GraphNode] = [], edges: [GraphEdge] = []) { self.nodes = nodes; self.edges = edges }
    public static let empty = KnowledgeGraph()
    public var isEmpty: Bool { nodes.isEmpty }
}

// MARK: - Connected accounts (§12.3)

public enum AccountProvider: String, Codable, CaseIterable, Sendable {
    case microsoft, google
    /// The Mac's own Calendar (EventKit): calendar only, no mail, no OAuth. Account id is always "local:calendar".
    case local

    /// Human product name ("Microsoft 365", "Google", "Calendario de la Mac").
    public var displayName: String {
        switch self {
        case .microsoft: "Microsoft 365"
        case .google: "Google"
        case .local: "Mac Calendar"
        }
    }

    /// Mail is only available on OAuth providers; `.local` only has a calendar.
    public var hasMail: Bool { self != .local }
    public var needsOAuth: Bool { self != .local }

    /// Read-only scopes requested at sign-in (§12.3).
    public var scopes: [String] {
        switch self {
        case .microsoft: ["User.Read", "Mail.Read", "Calendars.Read", "offline_access"]
        case .google: ["openid", "email", "profile",
                       "https://www.googleapis.com/auth/gmail.readonly",
                       "https://www.googleapis.com/auth/calendar.readonly"]
        case .local: []
        }
    }
}

public struct ConnectedAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: String            // "<provider>:<email>"
    public var provider: AccountProvider
    public var email: String
    public var displayName: String?
    public var connectedAt: Date
    public var scopes: [String]
    public init(provider: AccountProvider, email: String, displayName: String? = nil, connectedAt: Date = Date(),
                scopes: [String] = []) {
        let email = email.lowercased()
        self.id = Self.makeId(provider: provider, email: email)
        self.provider = provider; self.email = email; self.displayName = displayName
        self.connectedAt = connectedAt; self.scopes = scopes
    }
    public static func makeId(provider: AccountProvider, email: String) -> String { "\(provider.rawValue):\(email.lowercased())" }
}

public struct OAuthTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String
    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.scope = scope
    }
    /// Expired or about to (1 minute margin).
    public func isExpired(at now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 60 }
}

/// Ids of the registered OAuth app. Empty strings count as missing.
public struct OAuthAppRegistration: Codable, Equatable, Sendable {
    public var microsoftClientId: String?   // tenant "common"
    public var googleClientId: String?
    public var googleClientSecret: String?  // Google requires it for desktop apps; not a real secret
    // Straight from Google's downloaded client_secret_….json (optional; the app has defaults for all of them).
    public var googleProjectId: String?
    public var googleAuthURI: String?       // "auth_uri"
    public var googleTokenURI: String?      // "token_uri"
    // MARK: v0.4 github — the GitHub OAuth App for the device flow (no secret).
    public var githubClientId: String?
    public init(microsoftClientId: String? = nil, googleClientId: String? = nil, googleClientSecret: String? = nil,
                googleProjectId: String? = nil, googleAuthURI: String? = nil, googleTokenURI: String? = nil,
                githubClientId: String? = nil) {
        self.microsoftClientId = microsoftClientId; self.googleClientId = googleClientId; self.googleClientSecret = googleClientSecret
        self.googleProjectId = googleProjectId; self.googleAuthURI = googleAuthURI; self.googleTokenURI = googleTokenURI
        self.githubClientId = githubClientId
    }

    public static let empty = OAuthAppRegistration()

    public func clientId(for provider: AccountProvider) -> String? {
        switch provider {
        case .microsoft: microsoftClientId.nonEmpty
        case .google: googleClientId.nonEmpty
        case .local: nil
        }
    }

    /// The provider can start a sign-in (Google also needs its desktop "secret").
    public func isConfigured(_ provider: AccountProvider) -> Bool {
        switch provider {
        case .microsoft: microsoftClientId.nonEmpty != nil
        case .google: googleClientId.nonEmpty != nil && googleClientSecret.nonEmpty != nil
        case .local: true
        }
    }

    /// What sign-in uses: env `SB_MS_CLIENT_ID` / `SB_GOOGLE_CLIENT_ID` / `SB_GOOGLE_CLIENT_SECRET`, then the user's
    /// config (Ajustes → Cuentas → Avanzado), then the compiled-in `OAuthDefaults`.
    public static func effective(config: AppConfig,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> OAuthAppRegistration {
        OAuthAppRegistration(
            microsoftClientId: environment["SB_MS_CLIENT_ID"].nonEmpty ?? config.oauth.microsoftClientId.nonEmpty
                ?? OAuthDefaults.microsoftClientId.nonEmptyString,
            googleClientId: environment["SB_GOOGLE_CLIENT_ID"].nonEmpty ?? config.oauth.googleClientId.nonEmpty
                ?? OAuthDefaults.googleClientId.nonEmptyString,
            googleClientSecret: environment["SB_GOOGLE_CLIENT_SECRET"].nonEmpty ?? config.oauth.googleClientSecret.nonEmpty
                ?? OAuthDefaults.googleClientSecret.nonEmptyString,
            googleProjectId: config.oauth.googleProjectId.nonEmpty ?? OAuthDefaults.bundled.googleProjectId.nonEmpty,
            googleAuthURI: config.oauth.googleAuthURI.nonEmpty ?? OAuthDefaults.bundled.googleAuthURI.nonEmpty,
            googleTokenURI: config.oauth.googleTokenURI.nonEmpty ?? OAuthDefaults.bundled.googleTokenURI.nonEmpty,
            // MARK: v0.4 github
            githubClientId: environment["SB_GITHUB_CLIENT_ID"].nonEmpty ?? config.oauth.githubClientId.nonEmpty
                ?? OAuthDefaults.githubClientId.nonEmptyString
        )
    }
}

/// Client ids of SecondBrain's own app registrations (Azure "Accounts in any directory + personal", Google "Desktop
/// app"). They are NOT in the source: `scripts/build-app.sh` copies them into the app bundle as
/// `Contents/Resources/oauth-defaults.json` from the git-ignored `secrets/` (or `~/.config/secondbrain/`) at build time, so git never holds the
/// Google desktop "secret". Without that file (plain `swift build`, the `sb` CLI) they are empty and sign-in shows the
/// "not registered" help. Override for tests/dev: env `SB_OAUTH_DEFAULTS=<path to such a json>`.
public enum OAuthDefaults {
    public static var microsoftClientId: String { bundled.microsoftClientId ?? "" }
    public static var googleClientId: String { bundled.googleClientId ?? "" }
    public static var googleClientSecret: String { bundled.googleClientSecret ?? "" }
    public static var githubClientId: String { bundled.githubClientId ?? "" }   // MARK: v0.4 github

    /// Where the bundled file is looked for: `SB_OAUTH_DEFAULTS`, then `<app bundle>/Contents/Resources/oauth-defaults.json`.
    public static var fileURL: URL? {
        if let override = ProcessInfo.processInfo.environment["SB_OAUTH_DEFAULTS"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("oauth-defaults.json")
    }

    public static let bundled: OAuthAppRegistration = {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let reg = try? JSONDecoder().decode(OAuthAppRegistration.self, from: data) else { return .empty }
        return reg
    }()
}

public enum AccountError: Error {
    case notConfigured(AccountProvider)
    case cancelled
    case consentRequired(AccountProvider, detail: String)
    case network(String)
    case unauthorized
    case failed(String)
}

extension AccountError: LocalizedError {
    public var errorDescription: String? {
        let lang = Lang(AppConfig.load().uiLanguage)
        switch self {
        case .notConfigured(let p):
            return lang.t("Falta configurar la conexión con \(p.displayName).", "The \(p.displayName) connection isn't set up yet.")
        case .cancelled: return lang.t("Se canceló el inicio de sesión.", "Sign-in was cancelled.")
        case .consentRequired:
            return lang.t("Tu organización tiene que aprobar SecondBrain.", "Your organization needs to approve SecondBrain.")
        case .network(let msg): return lang.t("No pude conectarme: \(msg)", "I couldn't connect: \(msg)")
        case .unauthorized:
            return lang.t("La sesión expiró. Vuelve a conectar la cuenta.", "The session expired. Connect the account again.")
        case .failed(let msg): return msg
        }
    }
}

/// Read-only mail + calendar of one connected account. Implementations refresh tokens on their own.
public protocol MailCalendarProvider: AnyObject, Sendable {
    var account: ConnectedAccount { get }
    func profile() async throws -> ConnectedAccount
    func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?)
    func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?)
    func fetchMessage(id: String) async throws -> MailMessageFull
    func fetchThread(id: String) async throws -> [MailMessageFull]         // chronological
    func events(from: Date, to: Date) async throws -> [CalendarEvent]
}

public struct MailMessageSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var threadId: String
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var subject: String
    public var snippet: String
    public var date: Date
    public var isRead: Bool
    public var hasAttachments: Bool
    public var webLink: String?
    public init(id: String, threadId: String, from: EmailAddress, to: [EmailAddress], subject: String, snippet: String,
                date: Date, isRead: Bool = true, hasAttachments: Bool = false, webLink: String? = nil) {
        self.id = id; self.threadId = threadId; self.from = from; self.to = to; self.subject = subject
        self.snippet = snippet; self.date = date; self.isRead = isRead; self.hasAttachments = hasAttachments; self.webLink = webLink
    }
}

public struct MailMessageFull: Codable, Sendable {
    public var summary: MailMessageSummary
    public var cc: [EmailAddress]
    public var bodyText: String       // plain text (HTML already stripped)
    public init(summary: MailMessageSummary, cc: [EmailAddress] = [], bodyText: String) {
        self.summary = summary; self.cc = cc; self.bodyText = bodyText
    }
}

public struct CalendarEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var accountId: String
    public var seriesId: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var joinURL: URL?
    public var organizer: EmailAddress?
    public var attendees: [EmailAddress]
    public var notes: String?
    public var webLink: String?
    /// Ids of the same meeting seen through other accounts (`MeetingAgenda.dedupe` merged them into this one).
    public var aliasIds: [String] = []
    public init(id: String, accountId: String, seriesId: String? = nil, title: String, start: Date, end: Date,
                isAllDay: Bool = false, location: String? = nil, joinURL: URL? = nil, organizer: EmailAddress? = nil,
                attendees: [EmailAddress] = [], notes: String? = nil, webLink: String? = nil) {
        self.id = id; self.accountId = accountId; self.seriesId = seriesId; self.title = title; self.start = start
        self.end = end; self.isAllDay = isAllDay; self.location = location; self.joinURL = joinURL
        self.organizer = organizer; self.attendees = attendees; self.notes = notes; self.webLink = webLink
    }

    /// This event's id and the ids of the copies merged into it.
    public var allIds: [String] { [id] + aliasIds }

    /// Whether `eventId` names this event (or a copy merged into it).
    public func matches(_ eventId: String?) -> Bool {
        guard let eventId else { return false }
        return eventId == id || aliasIds.contains(eventId)
    }

    /// §12.5 "En curso": now ∈ [start − 2 min, end].
    public func isInProgress(at now: Date = Date()) -> Bool {
        !isAllDay && now >= start.addingTimeInterval(-120) && now <= end
    }
}

// MARK: - Helpers

extension Optional where Wrapped == String {
    /// nil for nil, empty or whitespace-only strings.
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

extension String {
    var nonEmptyString: String? { Optional(self).nonEmpty }
}
