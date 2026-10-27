import Foundation

/// Read-only GitHub REST client (CONTRACT §13.1, §13.3): `GET` only, bearer token, `Link` pagination, `ETag` /
/// `If-None-Match` (a 304 costs no quota), rate-limit pause, and GitHub's errors mapped to `GitHubError`. Every request
/// goes through an injectable `HTTPTransport`, so `sb github selftest` runs offline.
public struct GitHubClient: Sendable {
    public static let apiBase = "https://api.github.com"
    /// Below this many requests left, wait for the reset (or stop with `.rateLimited`).
    public static let rateLimitFloor = 100

    public let token: String
    public let transport: HTTPTransport
    /// Streams a large download (tarballs) straight to disk. nil = through `transport` (tests).
    public let downloader: GitHubDownloader?
    public let base: String
    let gate: GitHubRateGate

    /// `maxRateWait`: longest pause for the rate limit to reset before giving up with `.rateLimited` (the next
    /// scheduled sync picks up where this one stopped).
    public init(token: String, transport: @escaping HTTPTransport = HTTP.urlSession, downloader: GitHubDownloader? = GitHubClient.urlSessionDownload,
                base: String = GitHubClient.apiBase, maxRateWait: TimeInterval = 90) {
        self.token = token; self.transport = transport; self.downloader = downloader; self.base = base
        self.gate = GitHubRateGate(maxWait: maxRateWait)
    }

    // MARK: Requests

    /// One `GET`. 2xx and 304 come back; anything else throws a mapped `GitHubError`.
    public func get(_ path: String, query: [(String, String)] = [], etag: String? = nil, accept: String = "application/vnd.github+json") async throws -> GitHubResponse {
        try await get(url: url(path, query: query), etag: etag, accept: accept)
    }

    public func get(url: URL, etag: String? = nil, accept: String = "application/vnd.github+json") async throws -> GitHubResponse {
        try Task.checkCancellation()
        try await gate.waitIfNeeded()
        let request = makeRequest(url, etag: etag, accept: accept)
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch let error as AccountError {
            if case .network(let msg) = error { throw GitHubError.network(msg) }
            throw GitHubError.network(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
        let response = GitHubResponse(data: data, http: http)
        await gate.record(remaining: response.rateRemaining, reset: response.rateReset, serverDate: response.serverDate)
        if response.status == 304 || (200..<300).contains(response.status) { return response }
        throw Self.mapError(status: response.status, headers: response.headers, body: data, path: url.path)
    }

    /// Decoded JSON of a `GET` (no ETag).
    public func json<T: Decodable>(_ type: T.Type, _ path: String, query: [(String, String)] = []) async throws -> T {
        try decode(T.self, try await get(path, query: query).data)
    }

    /// Follows `Link: <…>; rel="next"` until there is no next page, `maxItems` are collected or `stop` says so
    /// (checked per item, items in page order; the stopping item is not included).
    public func paginate<T: Decodable>(_ type: T.Type, _ path: String, query: [(String, String)] = [], maxItems: Int = 1_000,
                                       maxPages: Int = 20, stop: ((T) -> Bool)? = nil) async throws -> [T] {
        var out: [T] = []
        var next: URL? = url(path, query: query)
        var pages = 0
        while let page = next, pages < maxPages, out.count < maxItems {
            let response = try await get(url: page)
            pages += 1
            for item in try decode([T].self, response.data) {
                if let stop, stop(item) { return out }
                out.append(item)
                if out.count >= maxItems { return out }
            }
            next = response.nextPage
        }
        return out
    }

    /// GitHub's clock (`Date` header) at the latest response this client received; nil before any.
    public func lastServerDate() async -> Date? { await gate.serverDate }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try GitHubJSON.decoder.decode(T.self, from: data) } catch {
            throw GitHubError.failed("Unexpected GitHub response (\(error.localizedDescription))")
        }
    }

    func url(_ path: String, query: [(String, String)] = []) -> URL {
        HTTP.url(path.hasPrefix("http") ? path : base + path, query: query)
    }

    func makeRequest(_ url: URL, etag: String? = nil, accept: String = "application/vnd.github+json") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SecondBrain-mac", forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// `owner/name` path segment, each part percent-encoded.
    static func repoPath(_ owner: String, _ name: String) -> String { "/repos/\(seg(owner))/\(seg(name))" }
    /// Branch names may contain `/`: keep it, encode the rest.
    static func seg(_ s: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Endpoints

    public func user() async throws -> GHUser { try await json(GHUser.self, "/user") }

    /// The user's repositories, most recently pushed first.
    public func myRepos(maxItems: Int = 1_000) async throws -> [GHRepo] {
        try await paginate(GHRepo.self, "/user/repos", query: [("per_page", "100"), ("sort", "pushed"),
                                                              ("affiliation", "owner,collaborator,organization_member")], maxItems: maxItems)
    }

    public func repo(_ owner: String, _ name: String) async throws -> GHRepo {
        try await json(GHRepo.self, Self.repoPath(owner, name))
    }

    public func branches(_ owner: String, _ name: String) async throws -> [GHBranch] {
        try await paginate(GHBranch.self, Self.repoPath(owner, name) + "/branches", query: [("per_page", "100")])
    }

    /// One branch head with its ETag. `nil` branch = 304 (unchanged since `etag`). 404 throws `.notFound`.
    public func branch(_ owner: String, _ name: String, _ branch: String, etag: String?) async throws -> (branch: GHBranchDetail?, etag: String?) {
        let response = try await get(Self.repoPath(owner, name) + "/branches/" + Self.seg(branch, keepSlash: true), etag: etag)
        if response.status == 304 { return (nil, etag) }
        return (try decode(GHBranchDetail.self, response.data), response.etag)
    }

    public func compare(_ owner: String, _ name: String, base: String, head: String) async throws -> GHCompare {
        try await json(GHCompare.self, Self.repoPath(owner, name) + "/compare/" + Self.seg(base, keepSlash: true) + "..." + Self.seg(head, keepSlash: true),
                       query: [("per_page", "100")])
    }

    /// Commits reachable from `sha`, newest first.
    public func commits(_ owner: String, _ name: String, sha: String, perPage: Int = 100) async throws -> [GHCommit] {
        try await json([GHCommit].self, Self.repoPath(owner, name) + "/commits", query: [("sha", sha), ("per_page", String(perPage))])
    }

    /// Pull requests by last update (newest first) until one older than `since`.
    public func pulls(_ owner: String, _ name: String, since: Date?, maxItems: Int = 100) async throws -> [GHPull] {
        try await paginate(GHPull.self, Self.repoPath(owner, name) + "/pulls",
                           query: [("state", "all"), ("sort", "updated"), ("direction", "desc"), ("per_page", "50")],
                           maxItems: maxItems, maxPages: 4) { pr in since.map { pr.updatedAt < $0 } ?? false }
    }

    /// Issues (pull requests excluded) updated since `since`, newest first. Pages until `maxItems` real issues are
    /// collected or the list ends (GitHub mixes PRs into /issues).
    public func issues(_ owner: String, _ name: String, since: Date?, maxItems: Int = GitHubLimits.maxIssuesPerSync,
                       maxPages: Int = 5) async throws -> [GHIssue] {
        var query = [("state", "all"), ("sort", "updated"), ("direction", "desc"), ("per_page", "100")]
        if let since { query.append(("since", GitHubJSON.iso(since))) }
        var out: [GHIssue] = []
        var next: URL? = url(Self.repoPath(owner, name) + "/issues", query: query)
        var pages = 0
        while let page = next, pages < maxPages, out.count < maxItems {
            let response = try await get(url: page)
            pages += 1
            out += try decode([GHIssue].self, response.data).filter { $0.pullRequest == nil }
            next = response.nextPage
        }
        return Array(out.prefix(maxItems))
    }

    public func releases(_ owner: String, _ name: String, perPage: Int = 10) async throws -> [GHRelease] {
        try await json([GHRelease].self, Self.repoPath(owner, name) + "/releases", query: [("per_page", String(perPage))])
    }

    /// The README as text (nil when the repo has none).
    public func readme(_ owner: String, _ name: String, ref: String?) async throws -> String? {
        do {
            let r = try await json(GHContent.self, Self.repoPath(owner, name) + "/readme", query: ref.map { [("ref", $0)] } ?? [])
            guard let content = r.content, let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return nil }
            return HTTP.text(data)
        } catch GitHubError.notFound { return nil }
    }

    /// One level of a tree (`recursive` off).
    public func tree(_ owner: String, _ name: String, sha: String) async throws -> GHTree {
        try await json(GHTree.self, Self.repoPath(owner, name) + "/git/trees/" + Self.seg(sha, keepSlash: true))
    }

    /// Bytes of code per language.
    public func languages(_ owner: String, _ name: String) async throws -> [String: Int] {
        try await json([String: Int].self, Self.repoPath(owner, name) + "/languages")
    }

    /// Downloads `tarball/{sha}` (gzip) to `file`.
    public func downloadTarball(_ owner: String, _ name: String, sha: String, to file: URL) async throws {
        let url = self.url(Self.repoPath(owner, name) + "/tarball/" + Self.seg(sha, keepSlash: true))
        try? FileManager.default.removeItem(at: file)
        if let downloader {
            try await gate.waitIfNeeded()
            let http = try await downloader(makeRequest(url, accept: "application/vnd.github+json"), file)
            guard (200..<300).contains(http.statusCode) else {
                let body = (try? Data(contentsOf: file)) ?? Data()
                try? FileManager.default.removeItem(at: file)
                throw Self.mapError(status: http.statusCode, headers: GitHubResponse.headers(of: http), body: body, path: url.path)
            }
            return
        }
        let response = try await get(url: url)
        try response.data.write(to: file, options: .atomic)
    }

    // MARK: Errors

    /// 401 → `.unauthorized`; 403/429 with no requests left (or a secondary limit) → `.rateLimited`; OAuth App access
    /// restrictions / SAML SSO → `.orgRestricted`; 404 → `.notFound`; 5xx → `.network`.
    public static func mapError(status: Int, headers: [String: String], body: Data, path: String) -> GitHubError {
        let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["message"] as? String
            ?? String(HTTP.text(body).prefix(300))
        let lower = message.lowercased()
        if status == 401 { return .unauthorized }
        if status == 403 || status == 404 || status == 451 {
            if let sso = headers["x-github-sso"] { return .orgRestricted(org: orgFromSSO(sso) ?? orgFromMessage(message)) }
            if lower.contains("oauth app access restrictions") || lower.contains("saml") || lower.contains("sso") {
                return .orgRestricted(org: orgFromMessage(message))
            }
        }
        if status == 403 || status == 429 {
            let reset = headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            if headers["x-ratelimit-remaining"] == "0" { return .rateLimited(resetAt: reset) }
            if lower.contains("rate limit") || status == 429 {
                let retry = headers["retry-after"].flatMap(TimeInterval.init).map { Date().addingTimeInterval($0) }
                return .rateLimited(resetAt: retry ?? reset)
            }
        }
        if status == 404 { return .notFound(path) }
        if (500...599).contains(status) { return .network("GitHub HTTP \(status)") }
        return .failed(message.isEmpty ? "GitHub HTTP \(status)" : "GitHub HTTP \(status): \(message)")
    }

    /// "… the `acme` organization has enabled OAuth App access restrictions …" / "… by the acme organization …".
    static func orgFromMessage(_ message: String) -> String? {
        if let m = message.firstMatch(of: #/`([A-Za-z0-9-]+)` organization/#) { return String(m.1) }
        if let m = message.firstMatch(of: #/organization[s]? `?([A-Za-z0-9-]+)`?/#), !["has", "saml", "the"].contains(String(m.1).lowercased()) {
            return String(m.1)
        }
        return nil
    }

    /// `X-GitHub-SSO: required; url=https://github.com/orgs/acme/sso?authorization_request=…`
    static func orgFromSSO(_ header: String) -> String? {
        header.firstMatch(of: #/orgs\/([A-Za-z0-9-]+)\/sso/#).map { String($0.1) }
    }

    // MARK: Download

    public typealias Downloader = GitHubDownloader

    /// Real network: `URLSession.download` moved to `file` (no repo tarball held in memory).
    public static let urlSessionDownload: GitHubDownloader = { request, file in
        do {
            let (temp, response) = try await HTTP.session.download(for: request)
            guard let http = response as? HTTPURLResponse else { throw GitHubError.network("no HTTP response") }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temp, to: file)
            return http
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw GitHubError.network(error.localizedDescription)
        }
    }
}

/// Saves the response body of `request` to the file URL and returns the response.
public typealias GitHubDownloader = @Sendable (URLRequest, URL) async throws -> HTTPURLResponse

/// A response with the headers the client cares about (names lowercased).
public struct GitHubResponse: Sendable {
    public var data: Data
    public var status: Int
    public var headers: [String: String]
    public init(data: Data, http: HTTPURLResponse) {
        self.data = data; self.status = http.statusCode; self.headers = Self.headers(of: http)
    }
    static func headers(of http: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields { out[String(describing: k).lowercased()] = String(describing: v) }
        return out
    }
    public var etag: String? { headers["etag"] }
    public var rateRemaining: Int? { headers["x-ratelimit-remaining"].flatMap { Int($0) } }
    public var rateReset: Date? { headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) } }
    public var nextPage: URL? { headers["link"].flatMap(Self.nextLink) }
    /// `Date: Tue, 27 Oct 2026 14:02:03 GMT` (GitHub's clock).
    public var serverDate: Date? { headers["date"].flatMap { Self.httpDate.date(from: $0) } }

    static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// `<https://api.github.com/…&page=2>; rel="next", <…>; rel="last"` → the `next` URL.
    public static func nextLink(_ header: String) -> URL? {
        for part in header.components(separatedBy: ",") {
            let pieces = part.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == "rel=\"next\"" }) else { continue }
            let target = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: target)
        }
        return nil
    }
}

/// Shared by every request of one client: pauses while fewer than `GitHubClient.rateLimitFloor` requests are left.
actor GitHubRateGate {
    let maxWait: TimeInterval
    private var remaining: Int?
    private var reset: Date?
    private(set) var serverDate: Date?
    init(maxWait: TimeInterval) { self.maxWait = maxWait }

    func record(remaining: Int?, reset: Date?, serverDate: Date? = nil) {
        if let remaining { self.remaining = remaining }
        if let reset { self.reset = reset }
        if let serverDate { self.serverDate = max(serverDate, self.serverDate ?? serverDate) }
    }

    func waitIfNeeded() async throws {
        guard let remaining, remaining < GitHubClient.rateLimitFloor, let reset else { return }
        let wait = reset.timeIntervalSinceNow
        if wait <= 0 { self.remaining = nil; return }
        guard wait <= maxWait else { throw GitHubError.rateLimited(resetAt: reset) }
        Log.info("github: \(remaining) requests left, pausing \(Int(wait)) s until the reset")
        try await Task.sleep(for: .seconds(wait + 1))
        self.remaining = nil
    }
}

enum GitHubJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = SBDate.parseISO(s)?.date { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
        }
        return d
    }()

    static func iso(_ date: Date) -> String { SBDate.iso(date, timeZone: TimeZone(identifier: "UTC")!) }
}

// MARK: - Wire types (only the fields SecondBrain reads)

public struct GHUser: Codable, Sendable {
    public var login: String
    public var name: String?
    public var email: String?
    public var avatarURL: String?
    enum CodingKeys: String, CodingKey { case login, name, email, avatarURL = "avatar_url" }
}

public struct GHRepo: Codable, Sendable {
    public struct Owner: Codable, Sendable { public var login: String }
    public var name: String
    public var owner: Owner
    public var description: String?
    public var defaultBranch: String?
    public var isPrivate: Bool?
    public var size: Int?
    public var pushedAt: Date?
    public var htmlURL: String?
    public var topics: [String]?
    public var archived: Bool?
    enum CodingKeys: String, CodingKey {
        case name, owner, description, size, topics, archived
        case defaultBranch = "default_branch", isPrivate = "private", pushedAt = "pushed_at", htmlURL = "html_url"
    }
    public var info: GitHubRepoInfo {
        GitHubRepoInfo(owner: owner.login, name: name, description: description, defaultBranch: defaultBranch ?? "main",
                       isPrivate: isPrivate ?? false, sizeKB: size ?? 0, pushedAt: pushedAt, htmlURL: htmlURL)
    }
}

public struct GHBranch: Codable, Sendable {
    public struct Commit: Codable, Sendable { public var sha: String }
    public var name: String
    public var commit: Commit
    public var protected: Bool?
    public var info: GitHubBranchInfo { GitHubBranchInfo(name: name, sha: commit.sha, isProtected: protected ?? false) }
}

public struct GHBranchDetail: Codable, Sendable {
    public var name: String
    public var commit: GHCommit
}

public struct GHCommit: Codable, Sendable, Equatable {
    public struct Person: Codable, Sendable, Equatable { public var name: String?; public var email: String?; public var date: Date? }
    public struct Detail: Codable, Sendable, Equatable { public var message: String; public var author: Person? }
    public struct Account: Codable, Sendable, Equatable { public var login: String }
    public var sha: String
    public var commit: Detail
    public var author: Account?
    public var htmlURL: String?
    enum CodingKeys: String, CodingKey { case sha, commit, author, htmlURL = "html_url" }
    public var title: String { commit.message.components(separatedBy: "\n").first ?? "" }
}

public struct GHCompare: Codable, Sendable {
    public struct File: Codable, Sendable {
        public var filename: String
        public var status: String
        public var additions: Int?
        public var deletions: Int?
    }
    public var status: String            // ahead | behind | diverged | identical
    public var aheadBy: Int
    public var behindBy: Int
    public var totalCommits: Int
    public var commits: [GHCommit]       // oldest first
    public var files: [File]?
    enum CodingKeys: String, CodingKey {
        case status, commits, files
        case aheadBy = "ahead_by", behindBy = "behind_by", totalCommits = "total_commits"
    }
}

public struct GHPull: Codable, Sendable {
    public struct Ref: Codable, Sendable { public var ref: String }
    public var number: Int
    public var title: String
    public var state: String
    public var body: String?
    public var user: GHCommit.Account?
    public var base: Ref
    public var head: Ref
    public var updatedAt: Date
    public var mergedAt: Date?
    public var draft: Bool?
    public var htmlURL: String?
    enum CodingKeys: String, CodingKey {
        case number, title, state, body, user, base, head, draft
        case updatedAt = "updated_at", mergedAt = "merged_at", htmlURL = "html_url"
    }
}

public struct GHIssue: Codable, Sendable {
    public struct Label: Codable, Sendable { public var name: String }
    public struct PullMarker: Codable, Sendable { public var url: String? }
    public var number: Int
    public var title: String
    public var state: String
    public var body: String?
    public var user: GHCommit.Account?
    public var labels: [Label]?
    public var updatedAt: Date
    public var htmlURL: String?
    public var pullRequest: PullMarker?
    enum CodingKeys: String, CodingKey {
        case number, title, state, body, user, labels
        case updatedAt = "updated_at", htmlURL = "html_url", pullRequest = "pull_request"
    }
}

public struct GHRelease: Codable, Sendable {
    public var tagName: String
    public var name: String?
    public var body: String?
    public var publishedAt: Date?
    public var draft: Bool?
    public var prerelease: Bool?
    public var htmlURL: String?
    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease
        case tagName = "tag_name", publishedAt = "published_at", htmlURL = "html_url"
    }
}

public struct GHContent: Codable, Sendable {
    public var content: String?
    public var encoding: String?
}

public struct GHTree: Codable, Sendable {
    public struct Entry: Codable, Sendable { public var path: String; public var type: String; public var sha: String? }
    public var sha: String?
    public var tree: [Entry]
    public var truncated: Bool?
}
