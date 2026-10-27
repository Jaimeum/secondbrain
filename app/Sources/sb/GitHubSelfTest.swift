import ArgumentParser
import BrainCore
import Foundation

/// `sb github selftest [--dir <tmp>]`: the GitHub connector against an in-process fake GitHub (no network).
struct GitHubSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of the GitHub connector.")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-github-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await t.groupAsync("github") { await testGitHub(t, root: root) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

/// CONTRACT §13: URL parsing, Link pagination, error mapping (rate limit, org restrictions), rate-limit pause, device
/// flow, backward-compatible decoding, and the sync algorithm end to end: first sync, 304 no-op, normal delta,
/// force-push / rebase, gone branch, code checkout from a real .tar.gz, and the engine wiring (source + ingest job).
@MainActor func testGitHub(_ t: Tester, root: URL) async {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    testGitHubParsing(t)
    testGitHubDecoding(t)
    await testGitHubClient(t)
    await testGitHubDeviceFlow(t)
    await testGitHubSync(t, root: root.appendingPathComponent("sync"))
    await testGitHubEngine(t, root: root.appendingPathComponent("engine"))
}

// MARK: - Fake GitHub

/// Routes by path (plus `@sha` for `/commits?sha=` and `#page=N` for paginated pages); unknown paths → 404. Replies
/// with an `ETag` answer 304 when the request's `If-None-Match` matches.
final class FakeGitHub: @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }
    private let lock = NSLock()
    private var routes: [String: Reply] = [:]
    private var log: [URLRequest] = []

    func set(_ key: String, _ json: String, status: Int = 200, headers: [String: String] = [:]) {
        lock.withLock { routes[key] = Reply(status: status, headers: headers, body: Data(json.utf8)) }
    }
    func setData(_ key: String, _ data: Data) { lock.withLock { routes[key] = Reply(body: data) } }
    func remove(_ key: String) { _ = lock.withLock { routes.removeValue(forKey: key) } }
    func reset() { lock.withLock { log = [] } }
    var requests: [URLRequest] { lock.withLock { log } }
    func paths() -> [String] { requests.map { Self.key($0.url!) } }

    static func key(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var key = url.path
        if let sha = items.first(where: { $0.name == "sha" })?.value { key += "@" + sha }
        if let page = items.first(where: { $0.name == "page" })?.value, page != "1" { key += "#page=" + page }
        return key
    }

    var transport: HTTPTransport {
        { [self] request in
            let url = request.url!
            let reply: Reply? = lock.withLock {
                log.append(request)
                return routes[Self.key(url)]
            }
            guard var reply else {
                return (Data(#"{"message":"Not Found"}"#.utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            }
            if let etag = reply.headers["ETag"], request.value(forHTTPHeaderField: "If-None-Match") == etag {
                reply.status = 304
                reply.body = Data()
            }
            var headers = reply.headers
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
            return (reply.body, HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

private func sha(_ tag: String) -> String { (tag + String(repeating: "0", count: 40)).prefix(40).description }

private func commitJSON(_ s: String, _ message: String, name: String = "Ana García", email: String = "ana@acme.com",
                        login: String? = "ana", date: Date = Date().addingTimeInterval(-3_600)) -> String {
    let author = login.map { #"{"login":"\#($0)"}"# } ?? "null"
    return #"{"sha":"\#(s)","commit":{"message":"\#(message)","author":{"name":"\#(name)","email":"\#(email)","date":"\#(iso(date))"}},"author":\#(author),"html_url":"https://github.com/acme/app/commit/\#(s)"}"#
}

private func branchJSON(_ name: String, _ s: String) -> String {
    let commit = commitJSON(s, "head of " + name)
    return #"{"name":"\#(name)","commit":\#(commit),"protected":false}"#
}

private func compareJSON(_ status: String, ahead: Int, behind: Int, commits: [String], files: String = "[]") -> String {
    #"{"status":"\#(status)","ahead_by":\#(ahead),"behind_by":\#(behind),"total_commits":\#(commits.count),"commits":[\#(commits.joined(separator: ","))],"files":\#(files)}"#
}

private func errorName(_ error: Error?) -> String {
    switch error {
    case nil: return "none"
    case GitHubError.unauthorized?: return "unauthorized"
    case GitHubError.rateLimited?: return "rateLimited"
    case GitHubError.orgRestricted(let org)?: return "orgRestricted(\(org ?? "nil"))"
    case GitHubError.notFound?: return "notFound"
    case GitHubError.deviceFlowExpired?: return "deviceFlowExpired"
    case GitHubError.deviceFlowDenied?: return "deviceFlowDenied"
    case GitHubError.notConfigured?: return "notConfigured"
    case GitHubError.network?: return "network"
    case GitHubError.failed(let m)?: return "failed(\(m))"
    default: return "other(\(error!))"
    }
}

// MARK: - Parsing & decoding

@MainActor private func testGitHubParsing(_ t: Tester) {
    let cases: [(String, String?)] = [
        ("acme/app", "acme/app"),
        ("  acme/app  ", "acme/app"),
        ("https://github.com/acme/app", "acme/app"),
        ("https://github.com/acme/app.git", "acme/app"),
        ("https://github.com/acme/app/tree/main/src", "acme/app"),
        ("http://github.com/acme/app", "acme/app"),
        ("github.com/acme/app", "acme/app"),
        ("git@github.com:acme/app.git", "acme/app"),
        ("ssh://git@github.com/acme/my.repo.git", "acme/my.repo"),
        ("acme", nil),
        ("acme/ap p", nil),
        ("", nil),
    ]
    for (input, expected) in cases {
        let got = GitHubRepoInfo.parse(input).map { "\($0.owner)/\($0.name)" }
        t.check(got == expected, "parse \(input.debugDescription): got \(got ?? "nil"), expected \(expected ?? "nil")")
    }
    let link = #"<https://api.github.com/repositories/1/branches?per_page=100&page=2>; rel="next", <https://api.github.com/repositories/1/branches?per_page=100&page=5>; rel="last""#
    t.eq(GitHubResponse.nextLink(link)?.absoluteString, "https://api.github.com/repositories/1/branches?per_page=100&page=2", "Link rel=next")
    t.check(GitHubResponse.nextLink(#"<https://x/a?page=1>; rel="prev""#) == nil, "no next link")
    t.eq(GitHubSync.branchSlug("feature/login"), "feature__login", "branch slug with slash")
    t.eq(GitHubSync.branchSlug(".hidden"), "_.hidden", "branch slug never hidden")
    t.eq(TrackedRepo.makeId(projectSlug: "Atlas", owner: "Acme", name: "App"), "atlas:acme/app", "repo id lowercased")
}

@MainActor private func testGitHubDecoding(_ t: Tester) {
    // repos.json written by an older build (only the required keys).
    let old = #"[{"id":"p:acme/app","projectSlug":"p","owner":"acme","name":"app","primaryBranch":"main","branches":[{"name":"main"}]}]"#
    if let repos = try? JSONDecoder.sb.decode([TrackedRepo].self, from: Data(old.utf8)), let r = repos.first {
        t.check(r.readCode && r.branches.first?.state == .pending && r.branches.first?.knownCommits == [] && r.lastSyncAt == nil,
                "old repos.json decodes with defaults")
    } else {
        t.check(false, "old repos.json decodes")
    }
    let odd = #"[{"id":"p:acme/app","projectSlug":"p","owner":"acme","name":"app","primaryBranch":"main","branches":[{"name":"main","state":"weird"}],"readCode":"yes"}]"#
    let oddRepos = try? JSONDecoder.sb.decode([TrackedRepo].self, from: Data(odd.utf8))
    t.check(oddRepos?.first?.branches.first?.state == .pending && oddRepos?.first?.readCode == true, "bad values fall back")

    // config.json without the v0.4 key → 60 minutes; values survive a round trip.
    let v03 = """
    {"vaultPath":"~/v","dataPath":"~/d","whisperModel":"large-v3","ingestModel":"sonnet","queryModel":"opus","uiLanguage":"es",
     "captureMic":true,"gitEnabled":false,"hotkeyEnabled":true,"onboardingComplete":true,"appearance":"dark",
     "oauth":{"microsoftClientId":"ms"}}
    """
    let c = try? JSONDecoder.sb.decode(AppConfig.self, from: Data(v03.utf8))
    t.check(c?.githubSyncMinutes == 60 && c?.appearance == "dark" && c?.oauth.microsoftClientId == "ms" && c?.oauth.githubClientId == nil,
            "v0.3 config.json → githubSyncMinutes 60, rest kept")
    let negative = v03.replacingOccurrences(of: "\"appearance\":\"dark\"", with: "\"appearance\":\"dark\",\"githubSyncMinutes\":-5")
    t.eq((try? JSONDecoder.sb.decode(AppConfig.self, from: Data(negative.utf8)))?.githubSyncMinutes, 60, "negative minutes → 60")
    var c4 = AppConfig.default
    c4.githubSyncMinutes = 15
    c4.oauth.githubClientId = "Iv1.abc"
    if let data = try? JSONEncoder.sb.encode(c4), let back = try? JSONDecoder.sb.decode(AppConfig.self, from: data) {
        t.eq(back, c4, "v0.4 config round trip")
    } else {
        t.check(false, "v0.4 config encodes")
    }
    t.eq(GitHubAuth.clientId(config: c4, environment: [:]), "Iv1.abc", "client id from config")
    t.eq(GitHubAuth.clientId(config: c4, environment: ["SB_GITHUB_CLIENT_ID": "Iv1.env"]), "Iv1.env", "SB_GITHUB_CLIENT_ID wins")

    // Credentials: saved token first, then SB_GITHUB_TOKEN.
    let mem = MemoryGitHubCredentialStore()
    t.check(GitHubAuth.resolveToken(storage: mem, environment: [:]) == nil, "no token anywhere")
    t.eq(GitHubAuth.resolveToken(storage: mem, environment: ["SB_GITHUB_TOKEN": " env "])?.token, "env", "env token")
    try? mem.save(GitHubCredential(token: "saved", method: .ghCLI))
    t.eq(GitHubAuth.resolveToken(storage: mem, environment: ["SB_GITHUB_TOKEN": "env"])?.token, "saved", "saved token wins")

    // MeetingPrep mentions repos only when the project has them.
    let ev = CalendarEvent(id: "e", accountId: "a", title: "Demo", start: Date(), end: Date().addingTimeInterval(1_800))
    t.check(MeetingPrep.prepPrompt(event: ev, language: "es", repos: ["acme/app"]).contains("acme/app"), "prep prompt lists repos")
    t.check(!MeetingPrep.prepPrompt(event: ev, language: "es").contains("repos:"), "prep prompt without repos")

    // The repos block appended to `ask`.
    let block = BrainEngine.reposBlock([RepoCheckout(repo: "acme/app", branch: "main", sha: sha("abc1234"), syncedAt: Date(),
                                                     path: URL(fileURLWithPath: "/tmp/co/acme__app/main"))])
    t.check(block.hasPrefix("\n\nrepos:\n- acme/app@main (abc1234, synced ") && block.hasSuffix(" → /tmp/co/acme__app/main"), "repos block: \(block)")
    t.eq(BrainEngine.reposBlock([]), "", "no repos block without checkouts")
}

// MARK: - Client

@MainActor private func testGitHubClient(_ t: Tester) async {
    let fake = FakeGitHub()
    let client = GitHubClient(token: "tok", transport: fake.transport, downloader: nil, maxRateWait: 0)

    // Headers and ETag.
    fake.set("/repos/acme/app/branches/main", branchJSON("main", sha("m1")), headers: ["ETag": "\"e1\""])
    let first = try? await client.branch("acme", "app", "main", etag: nil)
    t.check(first?.branch?.commit.sha == sha("m1") && first?.etag == "\"e1\"", "branch head + ETag")
    let req = fake.requests.last
    t.eq(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok", "bearer token")
    t.eq(req?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json", "Accept header")
    t.eq(req?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28", "API version header")
    t.eq(req?.httpMethod, "GET", "only GET")
    let second = try? await client.branch("acme", "app", "main", etag: "\"e1\"")
    t.check(second != nil && second?.branch == nil && second?.etag == "\"e1\"", "304 → unchanged")
    t.eq(fake.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"e1\"", "If-None-Match sent")

    // Pagination through Link.
    fake.set("/repos/acme/app/branches", "[\(#"{"name":"main","commit":{"sha":"\#(sha("m1"))"},"protected":true}"#),\(#"{"name":"dev","commit":{"sha":"\#(sha("d1"))"}}"#)]",
             headers: ["Link": #"<https://api.github.com/repos/acme/app/branches?per_page=100&page=2>; rel="next""#])
    fake.set("/repos/acme/app/branches#page=2", "[\(#"{"name":"testing","commit":{"sha":"\#(sha("t1"))"}}"#)]")
    fake.reset()
    let branches = (try? await client.branches("acme", "app")) ?? []
    t.eq(branches.map(\.name), ["main", "dev", "testing"], "branches over 2 pages")
    t.eq(fake.requests.count, 2, "2 requests for 2 pages")
    t.check(branches.first?.info.isProtected == true, "protected flag")

    // Error mapping.
    func expect(_ status: Int, _ body: String, headers: [String: String] = [:], _ expected: String, _ what: String) async {
        fake.set("/repos/acme/err", body, status: status, headers: headers)
        // A fresh client each time: a rate-limit answer pauses the client that saw it.
        let client = GitHubClient(token: "tok", transport: fake.transport, downloader: nil, maxRateWait: 0)
        do { _ = try await client.repo("acme", "err"); t.check(false, "\(what): no error") } catch {
            t.eq(errorName(error), expected, what)
        }
    }
    let reset = Int(Date().addingTimeInterval(1_800).timeIntervalSince1970)
    await expect(401, #"{"message":"Bad credentials"}"#, "unauthorized", "401 → unauthorized")
    await expect(403, #"{"message":"API rate limit exceeded for user."}"#,
                 headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(reset)"], "rateLimited", "403 + remaining 0 → rateLimited")
    await expect(429, #"{"message":"You have exceeded a secondary rate limit."}"#, headers: ["Retry-After": "60"], "rateLimited", "429 → rateLimited")
    await expect(403, #"{"message":"Although you appear to have the correct authorization credentials, the `acme` organization has enabled OAuth App access restrictions, meaning that data access to third-parties is limited."}"#,
                 "orgRestricted(acme)", "OAuth App access restrictions → orgRestricted")
    await expect(403, #"{"message":"Resource protected by organization SAML enforcement. You must grant your Personal Access token access to this organization."}"#,
                 headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme-corp/sso?authorization_request=x"],
                 "orgRestricted(acme-corp)", "SAML SSO → orgRestricted(org)")
    await expect(404, #"{"message":"Not Found"}"#, "notFound", "404 → notFound")
    await expect(502, "bad gateway", "network", "5xx → network")
    do {
        let client = GitHubClient(token: "tok", transport: fake.transport, downloader: nil, maxRateWait: 0)
        fake.set("/repos/acme/err", #"{"message":"Not Found"}"#, status: 404)
        _ = try await client.repo("acme", "err")
    } catch GitHubError.notFound(let path) {
        t.check(path.contains("/repos/acme/err"), "notFound carries the path")
    } catch { t.check(false, "notFound expected: \(error)") }
    let rateError = GitHubClient.mapError(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"], body: Data(), path: "/x")
    t.eq(rateError, .rateLimited(resetAt: Date(timeIntervalSince1970: TimeInterval(reset))), "rateLimited carries the reset date")

    // Below 100 requests left: the next request waits for the reset, or (beyond maxRateWait) stops.
    let low = FakeGitHub()
    low.set("/user", #"{"login":"jaime","name":"Jaime"}"#, headers: ["X-RateLimit-Remaining": "42", "X-RateLimit-Reset": "\(reset)"])
    let gated = GitHubClient(token: "tok", transport: low.transport, downloader: nil, maxRateWait: 0)
    let user = try? await gated.user()
    t.eq(user?.login, "jaime", "user decoded")
    do { _ = try await gated.user(); t.check(false, "low quota pauses / stops") } catch {
        t.eq(errorName(error), "rateLimited", "remaining < 100 → rateLimited before the next request")
    }
    t.eq(low.requests.count, 1, "no request sent while paused")
    let past = Int(Date().addingTimeInterval(-5).timeIntervalSince1970)
    let expired = FakeGitHub()
    expired.set("/user", #"{"login":"jaime"}"#, headers: ["X-RateLimit-Remaining": "3", "X-RateLimit-Reset": "\(past)"])
    let after = GitHubClient(token: "tok", transport: expired.transport, downloader: nil, maxRateWait: 0)
    _ = try? await after.user()
    t.check((try? await after.user()) != nil, "reset already passed → no pause")

    // Network errors from the transport.
    let broken = GitHubClient(token: "tok", transport: { _ in throw AccountError.network("offline") }, downloader: nil)
    do { _ = try await broken.user() } catch { t.eq(errorName(error), "network", "transport error → network") }
}

// MARK: - Device flow

@MainActor private func testGitHubDeviceFlow(_ t: Tester) async {
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String]
        var sleeps: [TimeInterval] = []
        var bodies: [String] = []
        init(_ replies: [String]) { self.replies = replies }
    }
    let codeJSON = #"{"device_code":"dc-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
    func transport(_ s: Script) -> HTTPTransport {
        { request in
            let url = request.url!
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let reply: String = s.lock.withLock {
                s.bodies.append(body)
                if url.path == "/login/device/code" { return codeJSON }
                return s.replies.isEmpty ? #"{"error":"authorization_pending"}"# : s.replies.removeFirst()
            }
            return (Data(reply.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
    }
    let ok = Script([#"{"error":"authorization_pending"}"#, #"{"error":"slow_down"}"#, #"{"access_token":"gho_x","token_type":"bearer","scope":"repo,read:org"}"#])
    do {
        let code = try await GitHubAuth.requestDeviceCode(clientId: "Iv1.test", transport: transport(ok))
        t.check(code.userCode == "ABCD-1234" && code.interval == 5 && code.verificationURI.absoluteString == "https://github.com/login/device",
                "device code parsed")
        t.check(ok.bodies.first?.contains("client_id=Iv1.test") == true && ok.bodies.first?.contains("scope=repo%20read%3Aorg") == true,
                "device code request: client id + scopes")
        let cred = try await GitHubAuth.pollForToken(code, clientId: "Iv1.test", transport: transport(ok),
                                                     sleep: { s in ok.lock.withLock { ok.sleeps.append(s) } })
        t.check(cred.token == "gho_x" && cred.method == .deviceFlow && cred.scopes == ["repo", "read:org"], "device flow token")
        t.eq(ok.sleeps, [5, 5, 10], "pending keeps the interval, slow_down adds 5 s")
        t.check(ok.bodies.last?.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code") == true, "device grant type")

        let denied = Script([#"{"error":"access_denied"}"#])
        do { _ = try await GitHubAuth.pollForToken(code, clientId: "x", transport: transport(denied), sleep: { _ in }); t.check(false, "denied throws") }
        catch { t.eq(errorName(error), "deviceFlowDenied", "access_denied") }
        let expiredScript = Script([#"{"error":"expired_token"}"#])
        do { _ = try await GitHubAuth.pollForToken(code, clientId: "x", transport: transport(expiredScript), sleep: { _ in }); t.check(false, "expired throws") }
        catch { t.eq(errorName(error), "deviceFlowExpired", "expired_token") }
        var old = code
        old.expiresAt = Date().addingTimeInterval(-1)
        do { _ = try await GitHubAuth.pollForToken(old, clientId: "x", transport: transport(Script([])), sleep: { _ in }); t.check(false, "past expiry throws") }
        catch { t.eq(errorName(error), "deviceFlowExpired", "code past expiresAt") }
        let cancelTask = Task {
            try await GitHubAuth.pollForToken(code, clientId: "x", transport: transport(Script([])), sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        }
        cancelTask.cancel()
        do { _ = try await cancelTask.value; t.check(false, "cancel stops polling") } catch { t.check(error is CancellationError, "polling is cancellable") }
    } catch {
        t.check(false, "device flow: \(error)")
    }
    do { _ = try await GitHubAuth.requestDeviceCode(clientId: "", transport: transport(Script([]))); t.check(false, "empty client id") }
    catch { t.eq(errorName(error), "notConfigured", "no client id → notConfigured") }
}

// MARK: - Sync

/// A real gzip tarball like GitHub's: one top folder with code, node_modules, .git, a big file and a symlink.
private func makeTarball(_ dir: URL, top: String, marker: String) throws -> Data {
    let fm = FileManager.default
    let src = dir.appendingPathComponent("tar-src-\(marker)")
    try? fm.removeItem(at: src)
    let base = src.appendingPathComponent(top)
    for sub in ["src", "node_modules/left-pad", ".git", "docs"] {
        try fm.createDirectory(at: base.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try Data("# Atlas \(marker)\n".utf8).write(to: base.appendingPathComponent("README.md"))
    try Data("let version = \"\(marker)\"\n".utf8).write(to: base.appendingPathComponent("src/App.swift"))
    try Data("module.exports = 1\n".utf8).write(to: base.appendingPathComponent("node_modules/left-pad/index.js"))
    try Data("[core]\n".utf8).write(to: base.appendingPathComponent(".git/config"))
    try Data(count: GitHubLimits.maxFileBytesInCheckout + 10).write(to: base.appendingPathComponent("docs/video.bin"))
    try fm.createSymbolicLink(atPath: base.appendingPathComponent("secrets").path, withDestinationPath: "/etc/passwd")
    let out = dir.appendingPathComponent("fixture-\(marker).tar.gz")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    p.arguments = ["-czf", out.path, "-C", src.path, top]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw CLIError("tar fixture failed") }
    return try Data(contentsOf: out)
}

@MainActor private func testGitHubSync(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let vault = root.appendingPathComponent("vault"), checkouts = root.appendingPathComponent("checkouts")
    let fake = FakeGitHub()
    let client = GitHubClient(token: "tok", transport: fake.transport, downloader: nil, maxRateWait: 0)
    let sync = GitHubSync(client: client, vaultRoot: vault, checkoutsRoot: checkouts, language: "es")
    let rawDir = vault.appendingPathComponent("projects/p1/raw/github/acme-app")
    func rawCount() -> Int { ((try? fm.contentsOfDirectory(atPath: rawDir.path)) ?? []).filter { $0.hasSuffix(".md") }.count }
    let r = "/repos/acme/app"
    let M0 = sha("m0"), M1 = sha("m1"), M1b = sha("m1b"), M2 = sha("m2"), D0 = sha("d0"), D1 = sha("d1"), D2 = sha("d2")
    let now = Date()

    var repo = TrackedRepo(projectSlug: "p1", owner: "acme", name: "app", primaryBranch: "main",
                           branches: [TrackedBranch(name: "main"), TrackedBranch(name: "development")], readCode: true)

    // --- 1. First sync: summary, activity of followed branches only, cross-branch compare, code checkouts.
    fake.set(r + "/branches/main", branchJSON("main", M1), headers: ["ETag": "\"e-m1\""])
    fake.set(r + "/branches/development", branchJSON("development", D1), headers: ["ETag": "\"e-d1\""])
    fake.set(r + "/commits@" + M1, "[\(commitJSON(M1, "Login con Face ID", login: "ana")),\(commitJSON(M0, "Primer commit", name: "Luis Torres", email: "luis@acme.com", login: nil))]")
    fake.set(r + "/commits@" + D1, "[\(commitJSON(D1, "Pagos en desarrollo")),\(commitJSON(D0, "WIP pagos")),\(commitJSON(M0, "Primer commit"))]")
    fake.set(r, #"{"name":"app","owner":{"login":"acme"},"description":"App Atlas","default_branch":"main","private":true,"size":120,"topics":["ios","react-native"],"html_url":"https://github.com/acme/app"}"#)
    fake.set(r + "/readme", #"{"content":"\#(Data("# Atlas\nLa app de Acme.\n".utf8).base64EncodedString())","encoding":"base64"}"#)
    fake.set(r + "/git/trees/" + M1, #"{"sha":"\#(M1)","tree":[{"path":"README.md","type":"blob"},{"path":"src","type":"tree","sha":"t-src"},{"path":"docs","type":"tree","sha":"t-docs"}]}"#)
    fake.set(r + "/git/trees/t-docs", #"{"sha":"t-docs","tree":[{"path":"arquitectura.md","type":"blob"}]}"#)
    fake.set(r + "/languages", #"{"TypeScript":900,"Swift":100}"#)
    let recent = iso(now.addingTimeInterval(-3_600))
    fake.set(r + "/pulls", #"[{"number":5,"title":"Onboarding nuevo","state":"open","body":"Cambia el flujo según lo que pidió Ana.","user":{"login":"sofia"},"base":{"ref":"development"},"head":{"ref":"feature/onboarding"},"updated_at":"\#(recent)","merged_at":null,"draft":false,"html_url":"https://github.com/acme/app/pull/5"},{"number":6,"title":"Rama ajena","state":"open","body":null,"user":{"login":"x"},"base":{"ref":"release"},"head":{"ref":"hotfix"},"updated_at":"\#(recent)","merged_at":null}]"#)
    fake.set(r + "/issues", #"[{"number":7,"title":"Crash al pagar","state":"open","body":"Pasa en iOS 18.","user":{"login":"luis"},"labels":[{"name":"bug"}],"updated_at":"\#(recent)","html_url":"https://github.com/acme/app/issues/7"},{"number":5,"title":"Onboarding nuevo","state":"open","user":{"login":"sofia"},"updated_at":"\#(recent)","pull_request":{"url":"x"}}]"#)
    fake.set(r + "/releases", #"[{"tag_name":"v1.0","name":"Primera versión","body":"Lanzamiento.","published_at":"\#(iso(now.addingTimeInterval(-86_400 * 2)))","draft":false,"prerelease":false},{"tag_name":"v0.1","published_at":"\#(iso(now.addingTimeInterval(-86_400 * 90)))"}]"#)
    fake.set(r + "/compare/main...development", compareJSON("diverged", ahead: 2, behind: 1, commits: [commitJSON(D0, "WIP pagos"), commitJSON(D1, "Pagos en desarrollo")]))
    do {
        fake.setData(r + "/tarball/" + M1, try makeTarball(root, top: "acme-app-\(M1.prefix(7))", marker: "m1"))
        fake.setData(r + "/tarball/" + D1, try makeTarball(root, top: "acme-app-\(D1.prefix(7))", marker: "d1"))
    } catch { t.check(false, "tarball fixture: \(error)") }

    var out = await sync.run([repo])
    guard var o = out.first else { t.check(false, "first sync outcome"); return }
    t.check(o.result.error == nil, "first sync without error: \(o.result.error ?? "")")
    t.check(o.result.changed && o.raw != nil, "first sync writes a raw")
    t.eq(rawCount(), 1, "one raw per repo per sync")
    t.check(o.raw?.relativePath.hasPrefix("projects/p1/raw/github/acme-app/") == true && o.raw?.relativePath.hasSuffix("-sync.md") == true,
            "raw path: \(o.raw?.relativePath ?? "-")")
    t.eq(o.raw?.externalId, "github:acme/app@\(M1.prefix(7)),\(D1.prefix(7))", "externalId github:owner/repo@short shas")
    let raw1 = (o.raw.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) }) ?? ""
    for part in ["type: github-sync", "project: p1", "repo: acme/app", "branches: [\"main\", \"development\"]",
                 "heads: {\"main\": \"\(M1)\", \"development\": \"\(D1)\"}", "rewritten: []", "gone: []",
                 "source_url: \"https://github.com/acme/app\"", "first_sync: true",
                 "## Resumen inicial del repositorio", "TypeScript 90%", "ios, react-native", "### README", "> # Atlas",
                 "`docs/arquitectura.md`", "`src/`", "### Últimos commits (2)", "Login con Face ID — Ana García (@ana, ana@acme.com)",
                 "Primer commit — Luis Torres (luis@acme.com)", "## Diferencias entre ramas",
                 "`development` va 2 commits adelante / 1 atrás de `main`", "#5 [abierto] **Onboarding nuevo**", "`development` ← `feature/onboarding`",
                 "> Cambia el flujo", "#7 [abierto] **Crash al pagar**", "bug", "## Versiones", "**v1.0** — Primera versión"] {
        t.check(raw1.contains(part), "first raw contains \(part.debugDescription)")
    }
    t.check(!raw1.contains("#6"), "PR on branches not followed is ignored")
    t.check(!raw1.contains("Issues\n- #5") && raw1.components(separatedBy: "#5 ").count == 2, "PRs are not listed again as issues")
    t.check(!raw1.contains("v0.1"), "old releases skipped")
    repo = o.repo
    let main1 = repo.branches[0], dev1 = repo.branches[1]
    t.check(main1.state == .ok && main1.lastSyncedSHA == M1 && main1.etag == "\"e-m1\"" && main1.knownCommits == [M1, M0], "main synced state")
    t.check(dev1.ahead == 2 && dev1.behind == 1 && main1.ahead == nil, "development ahead/behind of main")
    t.check(repo.lastSyncAt != nil && repo.lastActivitySync != nil && repo.sizeKB == 120 && repo.description == "App Atlas", "repo sync fields")
    t.eq(Set(o.result.codeUpdated), ["main", "development"], "both checkouts written")
    let coMain = GitHubSync.checkoutDir(root: checkouts, owner: "acme", name: "app", branch: "main")
    t.eq(GitHubSync.checkoutHead(coMain), M1, ".sb-head holds the sha")
    t.check(fm.fileExists(atPath: coMain.appendingPathComponent("src/App.swift").path)
            && fm.fileExists(atPath: coMain.appendingPathComponent("README.md").path), "code extracted without the top folder")
    t.check(!fm.fileExists(atPath: coMain.appendingPathComponent("node_modules").path), "node_modules pruned")
    t.check(!fm.fileExists(atPath: coMain.appendingPathComponent(".git").path), ".git pruned")
    t.check(!fm.fileExists(atPath: coMain.appendingPathComponent("docs/video.bin").path), "files > 2 MB pruned")
    t.check((try? fm.destinationOfSymbolicLink(atPath: coMain.appendingPathComponent("secrets").path)) == nil, "symlinks pruned")
    t.check(((try? fm.contentsOfDirectory(atPath: checkouts.path)) ?? []).allSatisfy { !$0.hasPrefix(".tmp-") }, "no temp folders left")

    // --- 2. Nothing changed: 304 on every branch, no activity → no raw, no compare, no tarball.
    fake.set(r + "/issues", "[]")
    fake.reset()
    out = await sync.run([repo])
    o = out[0]
    t.check(o.result.error == nil && !o.result.changed && o.raw == nil, "304 → unchanged, no raw: \(o.result.error ?? "")")
    t.eq(rawCount(), 1, "no new raw on a no-op sync")
    let sent = fake.requests
    t.check(sent.filter { $0.url!.path.hasPrefix(r + "/branches/") }.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") != nil },
            "branch checks send If-None-Match")
    t.check(!fake.paths().contains { $0.contains("/compare/") || $0.contains("/tarball/") || $0 == r }, "no compare/tarball/meta when nothing changed: \(fake.paths())")
    repo = o.repo

    // --- 3. Normal delta on main: 2 new commits, changed files, checkout refreshed.
    fake.set(r + "/branches/main", branchJSON("main", M2), headers: ["ETag": "\"e-m2\""])
    fake.set(r + "/compare/\(M1)...\(M2)", compareJSON("ahead", ahead: 2, behind: 0,
                                                       commits: [commitJSON(M1b, "Arregla el login", name: "Diego Pérez", email: "diego@acme.com", login: "diego"),
                                                                 commitJSON(M2, "Agrega pagos con Apple Pay")],
                                                       files: #"[{"filename":"src/App.swift","status":"modified","additions":3,"deletions":1},{"filename":"src/Pay.swift","status":"added","additions":40,"deletions":0}]"#))
    fake.set(r + "/compare/main...development", compareJSON("diverged", ahead: 2, behind: 3, commits: [commitJSON(D1, "Pagos en desarrollo")]))
    do { fake.setData(r + "/tarball/" + M2, try makeTarball(root, top: "acme-app-\(M2.prefix(7))", marker: "m2")) } catch { t.check(false, "tarball m2") }
    out = await sync.run([repo])
    o = out[0]
    t.check(o.result.changed && o.result.error == nil, "delta → changed")
    t.eq(o.result.newCommits, 2, "2 new commits counted")
    t.eq(o.result.codeUpdated, ["main"], "only main's checkout refreshed")
    let raw3 = (o.raw.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) }) ?? ""
    for part in ["### Commits nuevos (2)", "Arregla el login — Diego Pérez (@diego, diego@acme.com)", "Head: `\(M2.prefix(7))` (antes `\(M1.prefix(7))`)",
                 "### Archivos cambiados (2)", "- modified `src/App.swift` (+3 −1)", "- added `src/Pay.swift`",
                 "`development` va 2 commits adelante / 3 atrás de `main`"] {
        t.check(raw3.contains(part), "delta raw contains \(part.debugDescription)")
    }
    t.check(!raw3.contains("Resumen inicial") && !raw3.contains("first_sync") && !raw3.contains("## Rama `development`"),
            "delta raw: no summary, unchanged branch not listed")
    t.check(raw3.range(of: "Apple Pay")!.lowerBound < raw3.range(of: "Arregla el login")!.lowerBound, "new commits newest first")
    repo = o.repo
    t.eq(repo.branches[0].knownCommits.prefix(3).map { $0 }, [M2, M1b, M1], "knownCommits newest first")
    t.eq(repo.branches[1].behind, 3, "behind updated")
    t.eq(GitHubSync.checkoutHead(coMain), M2, "checkout swapped to the new head")
    t.check((try? String(contentsOf: coMain.appendingPathComponent("src/App.swift"), encoding: .utf8))?.contains("m2") == true, "new code in place")

    // --- 4. Force-push on development (old sha gone → 404) and main reset backwards ("behind").
    fake.set(r + "/branches/development", branchJSON("development", D2), headers: ["ETag": "\"e-d2\""])
    fake.set(r + "/commits@" + D2, "[\(commitJSON(D2, "Pagos reescritos")),\(commitJSON(M0, "Primer commit"))]")
    fake.set(r + "/branches/main", branchJSON("main", M1), headers: ["ETag": "\"e-m1-again\""])
    fake.set(r + "/compare/\(M2)...\(M1)", compareJSON("behind", ahead: 0, behind: 2, commits: []))
    fake.set(r + "/commits@" + M1, "[\(commitJSON(M1, "Login con Face ID")),\(commitJSON(M0, "Primer commit"))]")
    do { fake.setData(r + "/tarball/" + D2, try makeTarball(root, top: "acme-app-\(D2.prefix(7))", marker: "d2")) } catch { t.check(false, "tarball d2") }
    out = await sync.run([repo])
    o = out[0]
    t.eq(o.result.rewrittenBranches, ["main", "development"], "both rewrites detected (behind + 404 old sha)")
    repo = o.repo
    t.check(repo.branches.allSatisfy { $0.state == .rewritten }, "state rewritten")
    t.eq(repo.branches[1].knownCommits, [D2, M0], "knownCommits replaced by the branch's real history")
    let raw4 = (o.raw.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) }) ?? ""
    for part in ["rewritten: [\"main\", \"development\"]", "### ⚠ Historial reescrito (force-push o rebase)",
                 "Commits que ya no están en la rama (2):", "- `\(D1.prefix(7))`", "- `\(D0.prefix(7))`", "- `\(M2.prefix(7))`", "- `\(M1b.prefix(7))`",
                 "Pagos reescritos"] {
        t.check(raw4.contains(part), "rewrite raw contains \(part.debugDescription)")
    }
    t.check(!raw4.contains("- `\(M0.prefix(7))`\n"), "commits still on the branch are not reported as dropped")

    // --- 5. development deleted on GitHub → gone (once), info kept.
    fake.remove(r + "/branches/development")
    out = await sync.run([repo])
    o = out[0]
    t.eq(o.result.goneBranches, ["development"], "gone branch reported")
    repo = o.repo
    t.check(repo.branches[1].state == .gone && repo.branches[1].lastSyncedSHA == D2 && repo.branches[1].knownCommits == [D2, M0], "gone keeps what was learned")
    let raw5 = (o.raw.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) }) ?? ""
    t.check(raw5.contains("gone: [\"development\"]") && raw5.contains("## Rama `development` — ya no existe en GitHub"), "gone raw")
    let before = rawCount()
    out = await sync.run([out[0].repo])
    t.check(!out[0].result.changed && out[0].result.goneBranches.isEmpty && rawCount() == before, "still gone → no new raw")
    repo = out[0].repo

    // --- 6. A failing repo (GitHub 5xx): error on the repo, nothing written, the others still sync.
    fake.set(r + "/branches/main", "upstream error", status: 502)
    var other = TrackedRepo(projectSlug: "p1", owner: "acme", name: "other", primaryBranch: "main", branches: [TrackedBranch(name: "main")], readCode: false)
    other.sizeKB = 1
    let rawBefore = rawCount()
    let fake2Count = fake.requests.count
    _ = fake2Count
    fake.set("/repos/acme/other/branches/main", branchJSON("main", sha("o1")), headers: ["ETag": "\"o1\""])
    fake.set("/repos/acme/other/commits@" + sha("o1"), "[\(commitJSON(sha("o1"), "Init"))]")
    fake.set("/repos/acme/other", #"{"name":"other","owner":{"login":"acme"},"size":1}"#)
    fake.set("/repos/acme/other/pulls", "[]")
    fake.set("/repos/acme/other/issues", "[]")
    fake.set("/repos/acme/other/releases", "[]")
    out = await sync.run([repo, other])
    t.eq(out.count, 2, "both repos reported")
    t.check(out[0].result.error != nil && out[0].repo.lastError != nil && !out[0].result.changed, "5xx → error on the repo")
    t.eq(rawCount(), rawBefore, "failed repo writes nothing")
    t.check(out[1].result.error == nil && out[1].result.changed, "the other repo still syncs")
    t.check(out[1].result.codeUpdated.isEmpty && !fm.fileExists(atPath: GitHubSync.checkoutDir(root: checkouts, owner: "acme", name: "other", branch: "main").path),
            "readCode off → no checkout")

    // --- 7. Rate limit (token-wide): the sync stops with .rateLimited on the repo and writes nothing.
    let reset = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
    fake.set(r + "/branches/main", #"{"message":"API rate limit exceeded"}"#, status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(reset)"])
    let limitedSync = GitHubSync(client: GitHubClient(token: "tok", transport: fake.transport, downloader: nil, maxRateWait: 0),
                                 vaultRoot: vault, checkoutsRoot: checkouts, language: "es")
    out = await limitedSync.run([repo])
    t.check(out[0].result.error != nil && !out[0].result.changed && out[0].repo.branches[0].lastSyncedSHA == repo.branches[0].lastSyncedSHA,
            "rate limit → error, state untouched")
    t.eq(rawCount(), rawBefore, "rate limited repo writes nothing")
    fake.reset()
    out = await limitedSync.run([repo])
    t.check(fake.requests.isEmpty && out[0].result.error != nil, "paused until the reset: no further requests")

    // --- 8. Organization restriction surfaces as the repo's error.
    fake.set(r + "/branches/main", #"{"message":"Although you appear to have the correct authorization credentials, the `acme` organization has enabled OAuth App access restrictions."}"#, status: 403)
    out = await GitHubSync(client: GitHubClient(token: "tok", transport: fake.transport, downloader: nil, maxRateWait: 0),
                           vaultRoot: vault, checkoutsRoot: checkouts, language: "es").run([repo])
    t.check(out[0].result.error?.contains("acme") == true, "org restriction message names the org: \(out[0].result.error ?? "-")")
}

// MARK: - Engine wiring

private final class GitHubNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}

@MainActor private func testGitHubEngine(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "en"
    let engine = BrainEngine(config: config, transcriber: GitHubNoTranscriber())
    engine.autoProcess = false
    engine.start()
    let fake = FakeGitHub()
    let store = engine.github
    store.credentials = MemoryGitHubCredentialStore()
    store.environment = [:]
    store.transport = fake.transport
    store.downloader = nil
    t.check(!store.isConnected && store.account == nil, "starts disconnected")
    let report0 = await engine.syncGitHub()
    t.check(report0.repos.isEmpty, "nothing to sync without repos")

    fake.set("/user", #"{"login":"jaime","name":"Jaime Ruiz","avatar_url":"https://avatars/x"}"#)
    do {
        let account = try await store.connect(token: " ghp_test ", method: .personalToken)
        t.check(account.login == "jaime" && store.isConnected, "connect with a token")
        t.eq(store.credentials.load()?.token, "ghp_test", "token saved trimmed")
        t.eq(fake.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_test", "token checked with /user")
        t.check(fm.fileExists(atPath: engine.paths.githubAccount.path), "account.json written")

        let atlas = try engine.projects.create(name: "Atlas", description: "", emoji: "🚀")
        let info = GitHubRepoInfo(owner: "acme", name: "api", description: "API", defaultBranch: "main", sizeKB: 10)
        let tracked = try store.add(info, project: atlas.slug, branches: ["main", "development", "main"], readCode: false)
        t.eq(tracked.branches.map(\.name), ["main", "development"], "branches deduplicated")
        t.eq(tracked.id, "atlas:acme/api", "tracked id")
        t.check(fm.fileExists(atPath: engine.paths.githubRepos.path), "repos.json written")
        t.check(store.isDue, "never synced → due")

        let r = "/repos/acme/api"
        let a1 = sha("a1"), b1 = sha("b1")
        fake.set(r + "/branches/main", branchJSON("main", a1), headers: ["ETag": "\"a\""])
        fake.set(r + "/branches/development", branchJSON("development", b1), headers: ["ETag": "\"b\""])
        fake.set(r + "/commits@" + a1, "[\(commitJSON(a1, "Init API"))]")
        fake.set(r + "/commits@" + b1, "[\(commitJSON(b1, "Dev work")),\(commitJSON(a1, "Init API"))]")
        fake.set(r, #"{"name":"api","owner":{"login":"acme"},"size":10,"default_branch":"main"}"#)
        fake.set(r + "/git/trees/" + a1, #"{"tree":[{"path":"main.go","type":"blob"}]}"#)
        fake.set(r + "/languages", #"{"Go":100}"#)
        fake.set(r + "/pulls", "[]")
        fake.set(r + "/issues", "[]")
        fake.set(r + "/releases", "[]")
        fake.set(r + "/compare/main...development", compareJSON("ahead", ahead: 1, behind: 0, commits: [commitJSON(b1, "Dev work")]))

        let report = await engine.syncGitHub(project: atlas.slug)
        guard let result = report.repos.first else { t.check(false, "engine sync result"); return }
        t.check(result.changed && result.error == nil, "engine sync changed: \(result.error ?? "")")
        let src = result.sourceId.flatMap(engine.source)
        t.eq(src?.kind, .github, "source kind github")
        t.check(src?.externalId?.hasPrefix("github:acme/api@") == true, "source externalId")
        t.check(src?.rawPath?.hasPrefix("projects/atlas/raw/github/acme-api/") == true, "source rawPath")
        t.check(src?.status == .queued && engine.jobs.contains { $0.kind == .ingest && $0.sourceId == src?.id }, "ingest job queued")
        let raw = (src?.rawPath).flatMap { try? engine.vault.read($0) } ?? ""
        t.check(raw.contains("## Initial repository summary") && raw.contains("`development` is 1 commits ahead / 0 behind `main`"),
                "English headings when uiLanguage is en")
        let saved = GitHubStore(paths: engine.paths, credentials: MemoryGitHubCredentialStore(), environment: [:], demo: false)
        t.check(saved.repos.first?.branches.first?.lastSyncedSHA == a1 && saved.repos.first?.branches.last?.ahead == 1, "sync state persisted")
        t.check(saved.lastSync?.repos.first?.changed == true, "last-sync.json persisted")
        t.check(store.lastGlobalSyncAt == nil, "a project sync is not the global one")
        t.check(store.syncing.isEmpty, "syncing cleared")

        _ = await engine.syncGitHub()
        t.check(store.lastGlobalSyncAt != nil && !store.isDue, "global sync resets isDue")
        t.check(engine.sources.filter { $0.kind == .github }.count == 1, "no-op sync adds no source")
        let timeline = await engine.timeline(projectSlug: atlas.slug)
        t.check(!timeline.contains { $0.sourceId == src?.id }, "repo syncs stay off the timeline")

        // Checkouts: only with readCode and an existing .sb-head.
        t.check(store.checkouts(project: atlas.slug).isEmpty, "no checkouts with readCode off")
        var changed = store.repos[0]
        changed.readCode = true
        changed.branches.removeAll { $0.name == "development" }
        try store.update(changed)
        let dir = GitHubSync.checkoutDir(root: engine.paths.githubCheckouts, owner: "acme", name: "api", branch: "main")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((a1 + "\n").utf8).write(to: dir.appendingPathComponent(".sb-head"))
        let devDir = GitHubSync.checkoutDir(root: engine.paths.githubCheckouts, owner: "acme", name: "api", branch: "development")
        try fm.createDirectory(at: devDir, withIntermediateDirectories: true)
        try store.update(store.repos[0])
        t.check(!fm.fileExists(atPath: devDir.path), "checkout of an unfollowed branch removed")
        let cos = store.checkouts(project: nil)
        t.check(cos.count == 1 && cos.first?.repo == "acme/api" && cos.first?.branch == "main" && cos.first?.sha == a1, "checkouts list")
        t.check(store.checkouts(project: "other").isEmpty, "checkouts per project")

        try store.remove(repoId: tracked.id)
        t.check(store.repos.isEmpty && !fm.fileExists(atPath: dir.path), "remove drops the repo and its checkouts")
        store.disconnect()
        t.check(!store.isConnected && store.account == nil && !fm.fileExists(atPath: engine.paths.githubAccount.path), "disconnect")
    } catch {
        t.check(false, "engine github flow: \(error)")
    }

    // Demo store: invented data, no network, nothing written.
    let demo = GitHubStore(paths: DataPaths(root: root.appendingPathComponent("demo")), credentials: MemoryGitHubCredentialStore(), environment: [:], demo: true)
    t.check(demo.account?.login == "jaime-ruiz" && demo.repos.count == 2, "demo account + 2 repos")
    t.check(demo.repos.flatMap(\.branches).contains { $0.state == .rewritten } && demo.repos.flatMap(\.branches).contains { $0.state == .gone },
            "demo has a rewritten and a gone branch")
    let demoBranches = (try? await demo.branches(owner: "acme", name: "atlas-app")) ?? []
    t.check(demoBranches.contains { $0.name == "development" }, "demo branches")
    t.check(!fm.fileExists(atPath: root.appendingPathComponent("demo").path), "demo writes nothing")
}
