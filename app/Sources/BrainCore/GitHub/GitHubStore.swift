import Foundation
import Observation

/// The GitHub connection and the repos each project follows (CONTRACT §13.1–13.2). `data/github/account.json` (who is
/// connected; the token is in the Keychain), `data/github/repos.json` (every project's `TrackedRepo`s),
/// `data/github/last-sync.json` (the last report). Owned by `BrainEngine` as `engine.github`; `sb github` uses the same
/// files, so the app and the CLI see each other's changes (`reload()`).
///
/// With `SB_DEMO_GITHUB=1` the store shows `GitHubDemo` data and never touches the network or disk.
@MainActor @Observable public final class GitHubStore {
    public private(set) var account: GitHubAccount?
    /// All projects.
    public private(set) var repos: [TrackedRepo] = []
    /// Repo ids being synced right now.
    public private(set) var syncing: Set<String> = []
    public private(set) var lastSync: GitHubSyncReport?
    /// When the last sync of every repo finished (what `isDue` counts from).
    public private(set) var lastGlobalSyncAt: Date?
    /// A token is saved (or in `SB_GITHUB_TOKEN`). Cached so views never read the Keychain while rendering; refreshed on
    /// reload, connect, disconnect and when `credentials` / `environment` change.
    public private(set) var hasCredential = false
    /// Repos whose project folder no longer exists: not synced, not due, no checkouts for questions (Ajustes → GitHub
    /// lists them to stop following). Set by `BrainEngine` from the vault's projects.
    public private(set) var orphanedRepoIds: Set<String> = []
    public let isDemo: Bool

    @ObservationIgnored public private(set) var paths: DataPaths
    @ObservationIgnored private let configProvider: () -> AppConfig
    /// Where the token lives (Keychain in the app; memory in tests).
    @ObservationIgnored public var credentials: GitHubCredentialStorage { didSet { refreshCredential() } }
    /// The network (tests inject fixtures).
    @ObservationIgnored public var transport: HTTPTransport
    /// Tarball downloads straight to disk (nil = through `transport`, as tests do).
    @ObservationIgnored public var downloader: GitHubDownloader?
    @ObservationIgnored public var environment: [String: String] { didSet { refreshCredential() } }
    /// Longest pause for GitHub's rate limit before a sync stops with `.rateLimited`.
    @ObservationIgnored public var maxRateWait: TimeInterval = 90
    @ObservationIgnored private var myReposCache: (at: Date, repos: [GitHubRepoInfo])?
    @ObservationIgnored private var syncer: (token: String, sync: GitHubSync)?
    /// The last sync started in this process (`BrainEngine.syncGitHub` chains the next one after it).
    @ObservationIgnored var syncTail: Task<Void, Never>?

    public nonisolated static var demoRequested: Bool { ProcessInfo.processInfo.environment["SB_DEMO_GITHUB"] == "1" }
    public static let myReposCacheSeconds: TimeInterval = 300

    public init(paths: DataPaths, configProvider: @escaping () -> AppConfig = { AppConfig.load() },
                credentials: GitHubCredentialStorage = KeychainGitHubCredentialStore(), transport: @escaping HTTPTransport = HTTP.urlSession,
                downloader: GitHubDownloader? = GitHubClient.urlSessionDownload,
                environment: [String: String] = ProcessInfo.processInfo.environment, demo: Bool = GitHubStore.demoRequested) {
        self.paths = paths
        self.configProvider = configProvider
        self.credentials = credentials
        self.transport = transport
        self.downloader = downloader
        self.environment = environment
        self.isDemo = demo
        reload()
    }

    // MARK: State

    public func repos(project: String) -> [TrackedRepo] { repos.filter { $0.projectSlug == project } }
    public func repo(id: String) -> TrackedRepo? { repos.first { $0.id == id } }
    /// A token is available (Keychain or `SB_GITHUB_TOKEN`).
    public var isConnected: Bool { isDemo ? account != nil : hasCredential }

    /// The repos that are synced (their project still exists).
    public var activeRepos: [TrackedRepo] { repos.filter { !orphanedRepoIds.contains($0.id) } }
    public var orphanedRepos: [TrackedRepo] { repos.filter { orphanedRepoIds.contains($0.id) } }

    /// Marks the repos whose project is not in `known` (an empty `known` — e.g. the vault isn't reachable — marks none).
    public func markOrphans(knownProjects known: Set<String>) {
        let ids = known.isEmpty ? [] : Set(repos.filter { !known.contains($0.projectSlug) }.map(\.id))
        if ids != orphanedRepoIds { orphanedRepoIds = ids }
    }

    func refreshCredential() {
        let has = credential() != nil
        if has != hasCredential { hasCredential = has }
    }

    /// Now ≥ last global sync + `config.githubSyncMinutes` (false when that is 0 = manual, or nothing is followed).
    public var isDue: Bool { isDue(now: Date()) }

    public func isDue(now: Date) -> Bool {
        let minutes = configProvider().githubSyncMinutes
        guard minutes > 0, !activeRepos.isEmpty, isConnected else { return false }
        guard let last = lastGlobalSyncAt else { return true }
        return now >= last.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// Re-reads account.json, repos.json and last-sync.json (another process may have changed them).
    public func reload() {
        if isDemo {
            if account == nil { account = GitHubDemo.account }
            if repos.isEmpty { repos = GitHubDemo.repos() }
            return
        }
        refreshCredential()
        account = Self.read(GitHubAccount.self, paths.githubAccount)
        repos = Self.read([TrackedRepo].self, paths.githubRepos) ?? []
        if let state = Self.read(LastSyncFile.self, paths.githubLastSync) {
            lastSync = state.report
            lastGlobalSyncAt = state.globalAt
        }
    }

    /// Points the store at another data folder (`BrainEngine.reload(config:)`).
    public func reload(paths: DataPaths) {
        self.paths = paths
        syncer = nil
        myReposCache = nil
        reload()
    }

    /// Demo: put the invented repos under the vault's first project.
    public func adoptDemoProject(_ slug: String?) {
        guard isDemo, let slug else { return }
        repos = GitHubDemo.repos(projectSlug: slug)
    }

    // MARK: Connection

    func credential() -> GitHubCredential? { GitHubAuth.resolveToken(storage: credentials, environment: environment) }

    func client() throws -> GitHubClient {
        guard let cred = credential() else { throw GitHubError.notConnected }
        return GitHubClient(token: cred.token, transport: transport, downloader: downloader, maxRateWait: maxRateWait)
    }

    /// Device flow step 1 (the app shows `userCode` and opens `verificationURI`).
    public func startDeviceFlow(clientId: String) async throws -> GitHubDeviceCode {
        if isDemo {
            return GitHubDeviceCode(deviceCode: "demo", userCode: "ABCD-1234", verificationURI: URL(string: "https://github.com/login/device")!,
                                    expiresAt: Date().addingTimeInterval(900), interval: 5)
        }
        return try await GitHubAuth.requestDeviceCode(clientId: clientId, transport: transport)
    }

    /// Device flow step 2: polls until approved, saves the token and the account. Cancel by cancelling the task.
    public func finishDeviceFlow(_ code: GitHubDeviceCode) async throws -> GitHubAccount {
        if isDemo { return try await connectDemo(.deviceFlow) }
        let clientId = GitHubAuth.clientId(config: configProvider(), environment: environment) ?? ""
        let cred = try await GitHubAuth.pollForToken(code, clientId: clientId, transport: transport)
        return try await save(cred)
    }

    /// Copies the GitHub CLI's token (`gh auth token`).
    public func connectWithGHCLI() async throws -> GitHubAccount {
        if isDemo { return try await connectDemo(.ghCLI) }
        let token = try await Task.detached(priority: .userInitiated) { try GitHubAuth.ghCLIToken() }.value
        return try await connect(token: token, method: .ghCLI)
    }

    /// Checks the token with `GET /user` and saves it.
    public func connect(token: String, method: GitHubAuthMethod) async throws -> GitHubAccount {
        if isDemo { return try await connectDemo(method) }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubError.unauthorized }
        return try await save(GitHubCredential(token: trimmed, method: method))
    }

    private func save(_ cred: GitHubCredential) async throws -> GitHubAccount {
        let client = GitHubClient(token: cred.token, transport: transport, downloader: downloader, maxRateWait: maxRateWait)
        let user = try await client.user()
        try credentials.save(cred)
        let account = GitHubAccount(login: user.login, name: user.name, avatarURL: user.avatarURL, connectedAt: Date(), method: cred.method)
        try Self.write(account, to: paths.githubAccount)
        self.account = account
        syncer = nil
        myReposCache = nil
        refreshCredential()
        Log.info("github: connected as \(user.login) (\(cred.method.rawValue))")
        return account
    }

    private func connectDemo(_ method: GitHubAuthMethod) async throws -> GitHubAccount {
        try await Task.sleep(for: .milliseconds(600))
        var a = GitHubDemo.account
        a.method = method
        account = a
        return a
    }

    /// Removes the Keychain token and account.json (keeps the followed repos and what was learned).
    public func disconnect() {
        account = nil
        syncer = nil
        myReposCache = nil
        guard !isDemo else { return }
        credentials.delete()
        refreshCredential()
        try? FileManager.default.removeItem(at: paths.githubAccount)
        Log.info("github: disconnected")
    }

    // MARK: Browsing

    /// The user's repositories (cached 5 minutes unless `refresh`).
    public func listMyRepos(refresh: Bool) async throws -> [GitHubRepoInfo] {
        if isDemo { return GitHubDemo.myRepos }
        if !refresh, let cache = myReposCache, Date().timeIntervalSince(cache.at) < Self.myReposCacheSeconds { return cache.repos }
        let list = try await client().myRepos().map(\.info)
        myReposCache = (Date(), list)
        return list
    }

    public func repoInfo(owner: String, name: String) async throws -> GitHubRepoInfo {
        if isDemo {
            return GitHubDemo.myRepos.first { $0.id == "\(owner)/\(name)".lowercased() } ?? GitHubRepoInfo(owner: owner, name: name)
        }
        return try await client().repo(owner, name).info
    }

    public func branches(owner: String, name: String) async throws -> [GitHubBranchInfo] {
        if isDemo { return GitHubDemo.branches }
        return try await client().branches(owner, name).map(\.info)
    }

    /// Branches suggested next to the primary one when adding a repo (CONTRACT §13.6).
    public static let suggestedBranches = ["develop", "development", "dev", "testing", "test", "staging", "qa"]

    // MARK: Following

    /// Follows `branches` of a repo in `project` (re-adding updates the branch list). The first sync is up to the caller.
    @discardableResult
    public func add(_ info: GitHubRepoInfo, project: String, branches: [String], readCode: Bool) throws -> TrackedRepo {
        reloadIfNeeded()
        var names: [String] = []
        for b in branches.map({ $0.trimmingCharacters(in: .whitespaces) }) where !b.isEmpty && !names.contains(b) { names.append(b) }
        guard !names.isEmpty else { throw GitHubError.failed(Lang(configProvider().uiLanguage).t("Elige al menos una rama.", "Choose at least one branch.")) }
        let id = TrackedRepo.makeId(projectSlug: project, owner: info.owner, name: info.name)
        if var existing = repo(id: id) {
            existing.branches = names.map { n in existing.branches.first { $0.name == n } ?? TrackedBranch(name: n) }
            existing.readCode = readCode
            try update(existing)
            return existing
        }
        let primary = names.contains(info.defaultBranch) ? info.defaultBranch : names[0]
        let repo = TrackedRepo(projectSlug: project, owner: info.owner, name: info.name, primaryBranch: primary,
                               branches: names.map { TrackedBranch(name: $0) }, readCode: readCode, description: info.description,
                               sizeKB: info.sizeKB > 0 ? info.sizeKB : nil)
        repos.append(repo)
        try persist()
        Log.info("github: following \(repo.fullName) in \(project): \(names.joined(separator: ", "))")
        return repo
    }

    /// Changes branches / readCode / primary branch. Checkouts of branches no longer followed (or of a repo whose code
    /// is no longer read) are removed.
    public func update(_ repo: TrackedRepo) throws {
        reloadIfNeeded()
        guard let i = repos.firstIndex(where: { $0.id == repo.id }) else { throw GitHubError.notFound(repo.id) }
        var r = repo
        if !r.branches.contains(where: { $0.name == r.primaryBranch }), let first = r.branches.first { r.primaryBranch = first.name }
        repos[i] = r
        try persist()
        pruneCheckouts()
    }

    /// Stops following (also deletes its checkouts unless another project follows the same repo; the wiki stays).
    public func remove(repoId: String) throws {
        reloadIfNeeded()
        guard repos.contains(where: { $0.id == repoId }) else { throw GitHubError.notFound(repoId) }
        repos.removeAll { $0.id == repoId }
        try persist()
        pruneCheckouts()
    }

    private func reloadIfNeeded() {
        guard !isDemo else { return }
        repos = Self.read([TrackedRepo].self, paths.githubRepos) ?? repos
    }

    /// Deletes checkout folders no followed branch (with code reading on, repo not too big) needs any more, across
    /// every project. The folders are renamed away right here (instant) and deleted off the main thread.
    func pruneCheckouts() {
        guard !isDemo else { return }
        let fm = FileManager.default
        let root = paths.githubCheckouts
        var wanted: [String: Set<String>] = [:]
        for r in repos where r.readCode && (r.sizeKB ?? 0) <= GitHubLimits.maxRepoKB {
            let dir = GitHubSync.repoCheckoutDir(root: root, owner: r.owner, name: r.name).lastPathComponent
            wanted[dir, default: []].formUnion(r.branches.map { GitHubSync.branchSlug($0.name) })
        }
        var doomed: [URL] = []
        for repoDir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !repoDir.hasPrefix(".") {
            let url = root.appendingPathComponent(repoDir)
            guard let keep = wanted[repoDir] else { doomed.append(url); continue }
            for branchDir in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where !keep.contains(branchDir) {
                doomed.append(url.appendingPathComponent(branchDir))
            }
        }
        Self.trash(doomed, root: root)
    }

    /// Renames each folder to `<root>/.trash-<uuid>` and deletes it in the background (a big checkout can take seconds).
    nonisolated static func trash(_ urls: [URL], root: URL) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        var moved: [URL] = []
        for url in urls {
            let target = root.appendingPathComponent(".trash-\(UUID().uuidString.lowercased())")
            if (try? fm.moveItem(at: url, to: target)) != nil { moved.append(target) } else { moved.append(url) }
        }
        Task.detached(priority: .utility) {
            for url in moved { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Local code Claude may read while answering (`--add-dir`): one per followed branch with a checkout. nil = all projects.
    public func checkouts(project: String?) -> [RepoCheckout] {
        var out: [RepoCheckout] = []
        var seen = Set<String>()
        for r in repos where r.readCode && (project == nil || r.projectSlug == project) && !orphanedRepoIds.contains(r.id) {
            for b in r.branches {
                let dir = GitHubSync.checkoutDir(root: paths.githubCheckouts, owner: r.owner, name: r.name, branch: b.name)
                guard !seen.contains(dir.path) else { continue }
                if isDemo {
                    out.append(RepoCheckout(repo: r.fullName, branch: b.name, sha: b.lastSyncedSHA, syncedAt: b.lastSyncedAt, path: dir))
                    seen.insert(dir.path)
                    continue
                }
                guard let head = GitHubSync.checkoutHead(dir) else { continue }
                seen.insert(dir.path)
                out.append(RepoCheckout(repo: r.fullName, branch: b.name, sha: head, syncedAt: b.lastSyncedAt, path: dir))
            }
        }
        return out
    }

    // MARK: Sync bookkeeping (used by `BrainEngine.syncGitHub`)

    func makeSync(vaultRoot: URL, language: String) -> GitHubSync? {
        guard let cred = credential() else { return nil }
        if let syncer, syncer.token == cred.token, syncer.sync.vaultRoot == vaultRoot, syncer.sync.language == language,
           syncer.sync.checkoutsRoot == paths.githubCheckouts {
            return syncer.sync
        }
        let client = GitHubClient(token: cred.token, transport: transport, downloader: downloader, maxRateWait: maxRateWait)
        let sync = GitHubSync(client: client, vaultRoot: vaultRoot, checkoutsRoot: paths.githubCheckouts, language: language)
        syncer = (cred.token, sync)
        return sync
    }

    func markSyncing(_ ids: [String], _ on: Bool) {
        if on { syncing.formUnion(ids) } else { syncing.subtract(ids) }
    }

    /// Merges sync state into the current list (re-read from disk): the user may have changed branches or removed the
    /// repo while it synced; only the sync fields are taken from `synced`.
    func apply(_ synced: [TrackedRepo]) {
        guard !isDemo else { return }
        reloadIfNeeded()
        for s in synced {
            guard let i = repos.firstIndex(where: { $0.id == s.id }) else { continue }
            var r = repos[i]
            r.description = s.description
            r.sizeKB = s.sizeKB
            r.lastSyncAt = s.lastSyncAt
            r.lastActivitySync = s.lastActivitySync
            r.lastError = s.lastError
            for j in r.branches.indices {
                guard let b = s.branches.first(where: { $0.name == r.branches[j].name }) else { continue }
                r.branches[j] = b
            }
            repos[i] = r
        }
        do { try persist() } catch { Log.error("github: could not save repos.json: \(error)") }
    }

    func finishSync(_ report: GitHubSyncReport, global: Bool) {
        lastSync = report
        if global { lastGlobalSyncAt = report.finishedAt }
        guard !isDemo else { return }
        do { try Self.write(LastSyncFile(report: report, globalAt: lastGlobalSyncAt), to: paths.githubLastSync) } catch {
            Log.error("github: could not save last-sync.json: \(error)")
        }
    }

    // MARK: Files

    struct LastSyncFile: Codable {
        var report: GitHubSyncReport?
        var globalAt: Date?
    }

    private func persist() throws {
        guard !isDemo else { return }
        try Self.write(repos, to: paths.githubRepos)
    }

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder.sb.decode(T.self, from: data) } catch {
            Log.error("github: could not read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Atomic write (temp file + rename).
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.sb.encode(value).write(to: url, options: .atomic)
    }
}
