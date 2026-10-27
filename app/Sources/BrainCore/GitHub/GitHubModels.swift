import Foundation

// Shared GitHub types (CONTRACT §13). Members may be added; public ones are never changed or removed.
// Everything persisted decodes new fields with decodeIfPresent so older files keep loading.

/// The connected GitHub user (`data/github/account.json`; the token itself lives in the Keychain).
public struct GitHubAccount: Codable, Hashable, Sendable {
    public var login: String
    public var name: String?
    public var avatarURL: String?
    public var connectedAt: Date
    public var method: GitHubAuthMethod
    public init(login: String, name: String? = nil, avatarURL: String? = nil, connectedAt: Date = Date(), method: GitHubAuthMethod) {
        self.login = login; self.name = name; self.avatarURL = avatarURL; self.connectedAt = connectedAt; self.method = method
    }
}

public enum GitHubAuthMethod: String, Codable, Sendable { case deviceFlow, ghCLI, personalToken, environment }

/// Keychain value (service "app.secondbrain.mac", account "github-token").
public struct GitHubCredential: Codable, Sendable {
    public var token: String
    public var method: GitHubAuthMethod
    public var scopes: [String]
    public init(token: String, method: GitHubAuthMethod, scopes: [String] = []) {
        self.token = token; self.method = method; self.scopes = scopes
    }
}

/// Device-flow step shown to the user: the code to type at `verificationURI`.
public struct GitHubDeviceCode: Codable, Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: URL
    public var expiresAt: Date
    public var interval: Int
    public init(deviceCode: String, userCode: String, verificationURI: URL, expiresAt: Date, interval: Int) {
        self.deviceCode = deviceCode; self.userCode = userCode; self.verificationURI = verificationURI
        self.expiresAt = expiresAt; self.interval = interval
    }
}

public enum GitHubError: Error, Equatable, Sendable {
    case notConnected
    case notConfigured                     // no OAuth App client id for the device flow
    case unauthorized                      // 401: token revoked/expired
    case rateLimited(resetAt: Date?)
    case orgRestricted(org: String?)       // OAuth App access restrictions / SAML SSO not authorized
    case notFound(String)                  // repo/branch missing or no access
    case deviceFlowExpired
    case deviceFlowDenied
    case network(String)
    case failed(String)
}

/// One repository from the user's list or a pasted URL.
public struct GitHubRepoInfo: Codable, Hashable, Identifiable, Sendable {
    public var owner: String
    public var name: String
    public var fullName: String { "\(owner)/\(name)" }
    public var id: String { fullName.lowercased() }
    public var description: String?
    public var defaultBranch: String
    public var isPrivate: Bool
    public var sizeKB: Int
    public var pushedAt: Date?
    public var htmlURL: String
    public init(owner: String, name: String, description: String? = nil, defaultBranch: String = "main", isPrivate: Bool = false,
                sizeKB: Int = 0, pushedAt: Date? = nil, htmlURL: String? = nil) {
        self.owner = owner; self.name = name; self.description = description; self.defaultBranch = defaultBranch
        self.isPrivate = isPrivate; self.sizeKB = sizeKB; self.pushedAt = pushedAt
        self.htmlURL = htmlURL ?? "https://github.com/\(owner)/\(name)"
    }

    /// Accepts `owner/name`, `https://github.com/owner/name(.git)(/...)`, `git@github.com:owner/name(.git)`.
    public static func parse(_ text: String) -> (owner: String, name: String)? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:", "ssh://git@github.com/"]
        where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !parts[0].isEmpty, !name.isEmpty,
              parts[0].unicodeScalars.allSatisfy(valid.contains), name.unicodeScalars.allSatisfy(valid.contains) else { return nil }
        return (parts[0], name)
    }
}

public struct GitHubBranchInfo: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var sha: String
    public var isProtected: Bool
    public var id: String { name }
    public init(name: String, sha: String, isProtected: Bool = false) { self.name = name; self.sha = sha; self.isProtected = isProtected }
}

public enum TrackedBranchState: String, Codable, Sendable {
    case pending        // never synced
    case ok
    case rewritten      // last sync found force-push / rebase
    case gone           // branch no longer exists on GitHub
    case error
}

/// A branch the user chose to follow. Branches not chosen are ignored entirely.
public struct TrackedBranch: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var id: String { name }
    public var lastSyncedSHA: String?
    public var lastSyncedAt: Date?
    public var state: TrackedBranchState
    public var etag: String?
    /// Recent commit SHAs seen on this branch (newest first, ≤ 300) to tell which ones a rewrite dropped.
    public var knownCommits: [String]
    /// vs. the repo's primary branch (nil for the primary itself or before the first sync).
    public var ahead: Int?
    public var behind: Int?
    public init(name: String, lastSyncedSHA: String? = nil, lastSyncedAt: Date? = nil, state: TrackedBranchState = .pending,
                etag: String? = nil, knownCommits: [String] = [], ahead: Int? = nil, behind: Int? = nil) {
        self.name = name; self.lastSyncedSHA = lastSyncedSHA; self.lastSyncedAt = lastSyncedAt; self.state = state
        self.etag = etag; self.knownCommits = knownCommits; self.ahead = ahead; self.behind = behind
    }

    enum CodingKeys: String, CodingKey { case name, lastSyncedSHA, lastSyncedAt, state, etag, knownCommits, ahead, behind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        lastSyncedSHA = try c.decodeIfPresent(String.self, forKey: .lastSyncedSHA)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        state = (try? c.decodeIfPresent(TrackedBranchState.self, forKey: .state)) ?? .pending
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        knownCommits = (try? c.decodeIfPresent([String].self, forKey: .knownCommits)) ?? []
        ahead = try c.decodeIfPresent(Int.self, forKey: .ahead)
        behind = try c.decodeIfPresent(Int.self, forKey: .behind)
    }
}

/// A repository followed by one project (`data/github/repos.json`). The same repo in two projects = two records.
public struct TrackedRepo: Codable, Hashable, Identifiable, Sendable {
    public var id: String               // "<projectSlug>:<owner>/<name>" lowercased
    public var projectSlug: String
    public var owner: String
    public var name: String
    public var fullName: String { "\(owner)/\(name)" }
    public var primaryBranch: String
    public var branches: [TrackedBranch]
    public var readCode: Bool
    public var description: String?
    public var sizeKB: Int?
    public var addedAt: Date
    public var lastSyncAt: Date?
    /// PR/issue/release activity was read up to here.
    public var lastActivitySync: Date?
    public var lastError: String?
    public init(projectSlug: String, owner: String, name: String, primaryBranch: String, branches: [TrackedBranch],
                readCode: Bool = true, description: String? = nil, sizeKB: Int? = nil, addedAt: Date = Date()) {
        self.id = Self.makeId(projectSlug: projectSlug, owner: owner, name: name)
        self.projectSlug = projectSlug; self.owner = owner; self.name = name; self.primaryBranch = primaryBranch
        self.branches = branches; self.readCode = readCode; self.description = description; self.sizeKB = sizeKB
        self.addedAt = addedAt
    }
    public static func makeId(projectSlug: String, owner: String, name: String) -> String {
        "\(projectSlug):\(owner)/\(name)".lowercased()
    }
    /// Wiki / raw folder name: "owner-name" lowercased.
    public var slug: String { "\(owner)-\(name)".lowercased() }

    enum CodingKeys: String, CodingKey {
        case id, projectSlug, owner, name, primaryBranch, branches, readCode, description, sizeKB, addedAt, lastSyncAt, lastActivitySync, lastError
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectSlug = try c.decode(String.self, forKey: .projectSlug)
        owner = try c.decode(String.self, forKey: .owner)
        name = try c.decode(String.self, forKey: .name)
        primaryBranch = try c.decode(String.self, forKey: .primaryBranch)
        branches = (try? c.decodeIfPresent([TrackedBranch].self, forKey: .branches)) ?? []
        readCode = (try? c.decodeIfPresent(Bool.self, forKey: .readCode)) ?? true
        description = try c.decodeIfPresent(String.self, forKey: .description)
        sizeKB = try c.decodeIfPresent(Int.self, forKey: .sizeKB)
        addedAt = (try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? Date()
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastActivitySync = try c.decodeIfPresent(Date.self, forKey: .lastActivitySync)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

public enum GitHubLimits {
    public static let maxRepoKB = 512_000          // code checkout skipped above this
    public static let maxListedCommits = 100
    public static let maxChangedFiles = 200
    public static let maxBodyChars = 2_000
    public static let maxReadmeChars = 8_000
    public static let maxKnownCommits = 300
    public static let maxIssuesPerSync = 50
    public static let maxFileBytesInCheckout = 2_000_000
    public static let syncIntervalChoices = [15, 60, 360, 1440, 0]   // minutes; 0 = manual only
}

/// Result of one sync run, per repo.
public struct GitHubSyncReport: Codable, Sendable, Equatable {
    public struct RepoResult: Codable, Sendable, Equatable {
        public var repoId: String
        public var changed: Bool               // a raw file was written and an ingest queued
        public var rawPath: String?
        public var sourceId: String?
        public var newCommits: Int
        public var rewrittenBranches: [String]
        public var goneBranches: [String]
        public var codeUpdated: [String]       // branches whose checkout was refreshed
        public var error: String?
        public init(repoId: String, changed: Bool = false, rawPath: String? = nil, sourceId: String? = nil, newCommits: Int = 0,
                    rewrittenBranches: [String] = [], goneBranches: [String] = [], codeUpdated: [String] = [], error: String? = nil) {
            self.repoId = repoId; self.changed = changed; self.rawPath = rawPath; self.sourceId = sourceId; self.newCommits = newCommits
            self.rewrittenBranches = rewrittenBranches; self.goneBranches = goneBranches; self.codeUpdated = codeUpdated; self.error = error
        }
    }
    public var startedAt: Date
    public var finishedAt: Date
    public var repos: [RepoResult]
    public init(startedAt: Date, finishedAt: Date, repos: [RepoResult]) { self.startedAt = startedAt; self.finishedAt = finishedAt; self.repos = repos }
}

/// A local code checkout Claude may read while answering (`--add-dir`).
public struct RepoCheckout: Sendable, Equatable {
    public var repo: String        // owner/name
    public var branch: String
    public var sha: String?
    public var syncedAt: Date?
    public var path: URL
    public init(repo: String, branch: String, sha: String?, syncedAt: Date?, path: URL) {
        self.repo = repo; self.branch = branch; self.sha = sha; self.syncedAt = syncedAt; self.path = path
    }
}

/*
 Façade the app and `sb` use (implemented in GitHubStore.swift / GitHubSync.swift / GitHubAuth.swift, CONTRACT §13):

 @MainActor @Observable public final class GitHubStore {          // owned by BrainEngine as `engine.github`
     public private(set) var account: GitHubAccount?
     public private(set) var repos: [TrackedRepo]                  // all projects
     public private(set) var syncing: Set<String>                  // repo ids being synced right now
     public private(set) var lastSync: GitHubSyncReport?
     public func repos(project: String) -> [TrackedRepo]
     public func startDeviceFlow(clientId: String) async throws -> GitHubDeviceCode
     public func finishDeviceFlow(_ code: GitHubDeviceCode) async throws -> GitHubAccount   // polls; cancellable
     public func connectWithGHCLI() async throws -> GitHubAccount
     public func connect(token: String, method: GitHubAuthMethod) async throws -> GitHubAccount
     public func disconnect()                                      // removes Keychain token + account.json (keeps repos)
     public func listMyRepos(refresh: Bool) async throws -> [GitHubRepoInfo]
     public func repoInfo(owner: String, name: String) async throws -> GitHubRepoInfo
     public func branches(owner: String, name: String) async throws -> [GitHubBranchInfo]
     public func add(_ info: GitHubRepoInfo, project: String, branches: [String], readCode: Bool) throws -> TrackedRepo
     public func update(_ repo: TrackedRepo) throws                // change branches / readCode
     public func remove(repoId: String) throws                     // also deletes its checkouts (not the wiki)
     public func checkouts(project: String?) -> [RepoCheckout]     // nil = all projects
     public var isDue: Bool                                        // now ≥ last global sync + config.githubSyncMinutes (false if 0)
 }
 BrainEngine (MARK: v0.4 github):
     public let github: GitHubStore
     public func syncGitHub(project: String? = nil, repoId: String? = nil) async -> GitHubSyncReport   // writes raws, queues ingests
 Client is built with an injectable `HTTPTransport` (BrainCore/Accounts/HTTP.swift) so `sb github selftest` runs offline.
*/
