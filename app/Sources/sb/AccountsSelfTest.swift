import BrainCore
import CryptoKit
import Foundation

/// Connected accounts (CONTRACT §12.3, §12.7): PKCE, authorize URLs, callback/state checks, token parsing and refresh,
/// error mapping, Graph / Gmail / Google Calendar fixtures, join links, the loopback server and a full sign-in against
/// fixtures (no real network, no browser, no EventKit prompt).
@MainActor func testAccounts(_ t: Tester, root: URL) async {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    testPKCE(t)
    testAuthURLs(t)
    testCallbackAndTokens(t)
    testErrorMapping(t)
    testBase64AndEntities(t)
    testJoinLinks(t)
    await testGraphFixtures(t)
    await testGmailFixtures(t)
    testGoogleCalendarFixtures(t)
    testLocalCalendarMapping(t)
    await testTokenManager(t)
    await testLoopbackServer(t)
    await testAuthorizeFlow(t)
    await testAccountStoreFlow(t, root: root)
}

// MARK: - Helpers

private func errorKind(_ error: Error?) -> String {
    guard let error else { return "none" }
    switch error {
    case AccountError.notConfigured: return "notConfigured"
    case AccountError.cancelled: return "cancelled"
    case AccountError.consentRequired: return "consentRequired"
    case AccountError.network: return "network"
    case AccountError.unauthorized: return "unauthorized"
    case AccountError.failed: return "failed"
    case is CancellationError: return "cancellation"
    default: return "other(\(error))"
    }
}

private func errorKind(_ body: () throws -> Void) -> String {
    do { try body(); return "none" } catch { return errorKind(error) }
}

private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func localDate(_ y: Int, _ mo: Int, _ d: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: mo, day: d))!
}

private func query(_ url: URL) -> [String: String] {
    var out: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
    return out
}

private func formFields(_ request: URLRequest) -> [String: String] {
    let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    var out: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        if kv.count == 2 { out[kv[0]] = kv[1] }
    }
    return out
}

private func response(_ url: URL, _ status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
}

/// Fake network: routes requests by path, records them, and can be reconfigured between steps.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(match: String, reply: @Sendable (URLRequest) -> (Int, String))] = []
    private(set) var requests: [URLRequest] = []

    func on(_ match: String, _ reply: @escaping @Sendable (URLRequest) -> (Int, String)) {
        lock.withLock { routes.insert((match, reply), at: 0) }
    }
    func on(_ match: String, status: Int = 200, _ body: String) { on(match) { _ in (status, body) } }

    func count(_ match: String) -> Int { lock.withLock { requests.filter { $0.url!.absoluteString.contains(match) }.count } }
    func last(_ match: String) -> URLRequest? { lock.withLock { requests.last { $0.url!.absoluteString.contains(match) } } }

    var transport: HTTPTransport {
        { [self] request in
            let route = lock.withLock { () -> ((URLRequest) -> (Int, String))? in
                requests.append(request)
                return routes.first { request.url!.absoluteString.contains($0.match) }?.reply
            }
            guard let route else { return (Data("{\"error\":{\"code\":\"NotFound\",\"message\":\"no fixture\"}}".utf8), response(request.url!, 404)) }
            let (status, body) = route(request)
            return (Data(body.utf8), response(request.url!, status))
        }
    }
}

/// Plays the browser: follows the authorize URL straight to the loopback redirect with `code` and the right state.
private final class FakeBrowser: @unchecked Sendable {
    private let lock = NSLock()
    var code = "abc123"
    var overrideState: String?
    private(set) var authorizeURL: URL?
    private(set) var page: String?
    private(set) var pageStatus: Int?

    var open: @Sendable (URL) -> Void {
        { [self] url in
            lock.withLock { authorizeURL = url }
            let q = query(url)
            let state = lock.withLock { overrideState } ?? q["state"] ?? ""
            let redirect = q["redirect_uri"] ?? ""
            let code = lock.withLock { self.code }
            Task.detached {
                guard let target = URL(string: "\(redirect)/?code=\(code)&state=\(state)") else { return }
                if let (data, resp) = try? await URLSession.shared.data(from: target) {
                    self.lock.withLock {
                        self.page = String(decoding: data, as: UTF8.self)
                        self.pageStatus = (resp as? HTTPURLResponse)?.statusCode
                    }
                }
            }
        }
    }
}

// MARK: - PKCE and URLs

@MainActor private func testPKCE(_ t: Tester) {
    // RFC 7636 Appendix B.
    let v = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    t.eq(v.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE RFC 7636 vector")
    let g = PKCE.generate()
    t.eq(g.verifier.count, 43, "PKCE verifier length")
    t.check(g.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, "PKCE verifier is base64url")
    t.eq(g.challenge, PKCE.challenge(for: g.verifier), "PKCE challenge = S256(verifier)")
    t.check(PKCE.generate().verifier != g.verifier, "PKCE verifiers are random")
}

@MainActor private func testAuthURLs(_ t: Tester) {
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    let ms = OAuthEndpoint.microsoft(clientId: "ms-client")
    t.eq(ms.redirectURI(port: 5555), "http://localhost:5555", "Microsoft redirect = localhost:port")
    let msURL = OAuthClient.authorizationURL(ms, redirectURI: ms.redirectURI(port: 5555), state: "st8", pkce: pkce)
    let mq = query(msURL)
    t.eq(msURL.host, "login.microsoftonline.com", "MS authorize host")
    t.eq(msURL.path, "/common/oauth2/v2.0/authorize", "MS authorize path (tenant common)")
    t.eq(mq["client_id"], "ms-client", "MS client_id")
    t.eq(mq["response_type"], "code", "MS response_type")
    t.eq(mq["redirect_uri"], "http://localhost:5555", "MS redirect_uri")
    t.eq(mq["scope"], "User.Read Mail.Read Calendars.Read offline_access", "MS scopes")
    t.eq(mq["state"], "st8", "MS state")
    t.eq(mq["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "MS code_challenge")
    t.eq(mq["code_challenge_method"], "S256", "MS challenge method")
    t.eq(mq["response_mode"], "query", "MS response_mode")
    t.check(msURL.absoluteString.contains("scope=User.Read%20Mail.Read"), "scope spaces are %20: \(msURL)")
    t.check(msURL.absoluteString.contains("redirect_uri=http:%2F%2F") || msURL.absoluteString.contains("redirect_uri=http://"),
            "redirect_uri encoded")
    t.eq(ms.tokenURL, "https://login.microsoftonline.com/common/oauth2/v2.0/token", "MS token endpoint")

    let g = OAuthEndpoint.google(clientId: "g-client.apps.googleusercontent.com", clientSecret: "g-secret")
    t.eq(g.redirectURI(port: 61000), "http://127.0.0.1:61000", "Google redirect = 127.0.0.1:port")
    let gURL = OAuthClient.authorizationURL(g, redirectURI: g.redirectURI(port: 61000), state: "s", pkce: pkce, loginHint: "a@b.com")
    let gq = query(gURL)
    t.eq(gURL.host, "accounts.google.com", "Google authorize host")
    t.eq(gURL.path, "/o/oauth2/v2/auth", "Google authorize path")
    t.eq(gq["access_type"], "offline", "Google access_type=offline")
    t.eq(gq["prompt"], "consent", "Google prompt=consent")
    t.eq(gq["scope"], "openid email profile https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.readonly",
         "Google scopes")
    t.eq(gq["login_hint"], "a@b.com", "Google login_hint")
    t.check(gq["client_secret"] == nil, "client secret never goes in the browser URL")
    t.eq(g.tokenURL, "https://oauth2.googleapis.com/token", "Google token endpoint")

    t.eq(errorKind { _ = try OAuthEndpoint.make(.microsoft, registration: .empty) }, "notConfigured", "no MS id → notConfigured")
    t.eq(errorKind { _ = try OAuthEndpoint.make(.google, registration: OAuthAppRegistration(googleClientId: "x")) }, "notConfigured",
         "Google without secret → notConfigured")
    t.eq(errorKind { _ = try OAuthEndpoint.make(.microsoft, registration: OAuthAppRegistration(microsoftClientId: " id ")) }, "none",
         "MS id configured")

    // Provider API URLs.
    let since = utcDate(2026, 9, 26)
    let list = MicrosoftGraphProvider.listURL(since: since)
    let lq = query(list)
    t.eq(list.path, "/v1.0/me/messages", "Graph list path")
    t.eq(lq["$top"], "50", "Graph $top")
    t.eq(lq["$filter"], "receivedDateTime ge 2026-09-26T00:00:00Z", "Graph $filter")
    t.eq(lq["$orderby"], "receivedDateTime desc", "Graph $orderby")
    t.eq(query(MicrosoftGraphProvider.searchURL("contrato \"Acme\""))["$search"], "\"contrato  Acme \"", "Graph $search quoted")
    t.eq(query(MicrosoftGraphProvider.threadURL(conversationId: "AA'Q="))["$filter"], "conversationId eq 'AA''Q='", "Graph thread filter")
    let cal = query(MicrosoftGraphProvider.calendarURL(from: since, to: utcDate(2026, 10, 3)))
    t.eq(cal["startDateTime"], "2026-09-26T00:00:00Z", "Graph calendarView start")
    t.eq(cal["endDateTime"], "2026-10-03T00:00:00Z", "Graph calendarView end")
    t.check(cal["$select"]?.contains("onlineMeeting") == true && cal["$select"]?.contains("seriesMasterId") == true, "Graph event fields")
    let gnow = Date()
    t.eq(GoogleProvider.recentQuery(since: gnow.addingTimeInterval(-30 * 86_400), now: gnow), "newer_than:30d", "Gmail newer_than:30d")
    let gl = query(GoogleProvider.listURL(query: "newer_than:30d", pageToken: "p2"))
    t.eq(gl["q"], "newer_than:30d", "Gmail q")
    t.eq(gl["pageToken"], "p2", "Gmail pageToken")
    let ge = query(GoogleProvider.eventsURL(from: since, to: utcDate(2026, 10, 3)))
    t.eq(ge["singleEvents"], "true", "Calendar singleEvents")
    t.eq(ge["orderBy"], "startTime", "Calendar orderBy")
    t.eq(ge["timeMin"], "2026-09-26T00:00:00Z", "Calendar timeMin")
    t.check(HTTP.url("https://x.test/a", query: [("q", "a+b c&d")]).absoluteString == "https://x.test/a?q=a%2Bb%20c%26d",
            "query encoding keeps + and & literal")
}

// MARK: - Callback, tokens, errors

@MainActor private func testCallbackAndTokens(_ t: Tester) {
    t.eq(errorKind { _ = try OAuthClient.validateCallback(["code": "c", "state": "other"], expectedState: "mine", provider: .google) },
         "failed", "state mismatch rejected")
    t.eq(errorKind { _ = try OAuthClient.validateCallback(["code": "c"], expectedState: "mine", provider: .google) },
         "failed", "missing state rejected")
    t.eq((try? OAuthClient.validateCallback(["code": "c1", "state": "mine"], expectedState: "mine", provider: .google)) ?? "-",
         "c1", "matching state → code")
    t.eq(errorKind { _ = try OAuthClient.validateCallback(["error": "access_denied", "state": "mine"], expectedState: "mine", provider: .google) },
         "cancelled", "Google callback error=access_denied (user pressed Cancel) → cancelled")
    t.eq(errorKind { _ = try OAuthClient.validateCallback(["error": "access_denied", "state": "mine"], expectedState: "mine", provider: .microsoft) },
         "consentRequired", "Microsoft callback error=access_denied → consentRequired")
    t.eq(errorKind { _ = try OAuthClient.validateCallback(["error": "access_denied", "error_description": "AADSTS65004: User declined to consent",
                                                           "state": "mine"], expectedState: "mine", provider: .microsoft) },
         "cancelled", "AADSTS65004 (user declined) → cancelled")

    let now = utcDate(2026, 10, 26, 12)
    let body = #"{"token_type":"Bearer","access_token":"at1","expires_in":3599,"refresh_token":"rt1","scope":"Mail.Read User.Read"}"#
    if let tok = try? OAuthClient.parseTokenResponse(Data(body.utf8), provider: .microsoft, now: now) {
        t.eq(tok.accessToken, "at1", "token access")
        t.eq(tok.refreshToken, "rt1", "token refresh")
        t.eq(tok.expiresAt, now.addingTimeInterval(3599), "token expiry = now + expires_in")
        t.eq(tok.scope, "Mail.Read User.Read", "token scope")
    } else { t.check(false, "token response parses") }
    let stringExpiry = #"{"access_token":"at2","expires_in":"120"}"#
    t.eq((try? OAuthClient.parseTokenResponse(Data(stringExpiry.utf8), provider: .google, now: now, previousRefreshToken: "old"))?.refreshToken,
         "old", "Google refresh without new refresh_token keeps the old one")
    t.eq((try? OAuthClient.parseTokenResponse(Data(stringExpiry.utf8), provider: .google, now: now))?.expiresAt,
         now.addingTimeInterval(120), "expires_in as string")
    t.eq(errorKind { _ = try OAuthClient.parseTokenResponse(Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8),
                                                             status: 400, provider: .google) }, "unauthorized", "invalid_grant → unauthorized")
    t.eq(errorKind { _ = try OAuthClient.parseTokenResponse(Data(#"{"error":"invalid_grant","error_description":"AADSTS65001: The user or administrator has not consented to use the application"}"#.utf8),
                                                             status: 400, provider: .microsoft) }, "consentRequired", "token AADSTS65001 → consentRequired")
    t.eq(errorKind { _ = try OAuthClient.parseTokenResponse(Data("<html>oops</html>".utf8), status: 502, provider: .google) },
         "network", "token 502 → network")

    // Refresh decision: within 2 minutes of expiry.
    func tokens(_ seconds: TimeInterval) -> OAuthTokens { OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(seconds), scope: "") }
    t.check(TokenManager.shouldRefresh(tokens(60), now: now), "refresh when 60 s left")
    t.check(TokenManager.shouldRefresh(tokens(119), now: now), "refresh when 119 s left")
    t.check(!TokenManager.shouldRefresh(tokens(121), now: now), "no refresh when 121 s left")
    t.check(!TokenManager.shouldRefresh(tokens(3000), now: now), "no refresh when 50 min left")
    t.check(TokenManager.shouldRefresh(tokens(-10), now: now), "refresh when expired")
}

@MainActor private func testErrorMapping(_ t: Tester) {
    func kind(_ e: String?, _ d: String?, _ p: AccountProvider = .microsoft) -> String { errorKind(AccountErrorMapper.map(provider: p, error: e, description: d)) }
    t.eq(kind("invalid_client", "AADSTS65001: The user or administrator has not consented"), "consentRequired", "AADSTS65001")
    t.eq(kind("access_denied", "AADSTS90094: The grant requires admin permission."), "consentRequired", "AADSTS90094")
    t.eq(kind("invalid_request", "AADSTS650052: The app needs access to a service"), "consentRequired", "AADSTS650052")
    t.eq(kind("unauthorized_client", "AADSTS7000112: Application is disabled."), "consentRequired", "AADSTS7000112")
    t.eq(kind("consent_required", nil), "consentRequired", "consent_required")
    t.eq(kind("access_denied", nil, .google), "cancelled", "Google bare access_denied = user cancel")
    t.eq(kind("access_denied", "", .google), "cancelled", "Google access_denied, empty description = user cancel")
    t.eq(kind("access_denied", "admin_policy_enforced", .google), "consentRequired", "Google access_denied with org detail")
    t.eq(kind("access_denied", nil), "consentRequired", "Microsoft bare access_denied stays a block")
    t.eq(kind("org_internal", "This client is restricted to users within its organization.", .google), "consentRequired", "org_internal")
    t.eq(kind("admin_policy_enforced", nil, .google), "consentRequired", "admin_policy_enforced")
    t.eq(kind("disallowed_useragent", nil, .google), "consentRequired", "disallowed_useragent")
    t.eq(kind("invalid_grant", "bad"), "unauthorized", "invalid_grant")
    t.eq(kind("server_error", "boom"), "failed", "other OAuth error → failed")
    if case .consentRequired(let p, let detail) = AccountErrorMapper.map(provider: .google, error: "org_internal", description: "Restricted") {
        t.eq(p, .google, "consentRequired carries the provider")
        t.eq(detail, "Restricted", "consentRequired carries the detail")
    } else { t.check(false, "org_internal maps with detail") }

    func http(_ status: Int, _ body: String, _ p: AccountProvider = .microsoft) -> String {
        errorKind(AccountErrorMapper.map(provider: p, status: status, body: Data(body.utf8)))
    }
    t.eq(http(401, #"{"error":{"code":"InvalidAuthenticationToken","message":"Access token has expired"}}"#), "unauthorized", "Graph 401")
    t.eq(http(403, #"{"error":{"code":"ErrorAccessDenied","message":"Access is denied."}}"#), "failed", "Graph 403 access denied → failed")
    t.eq(http(429, #"{"error":{"code":"TooManyRequests","message":"Slow down"}}"#), "network", "429 → network")
    t.eq(http(503, ""), "network", "503 → network")
    t.eq(http(403, #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED","errors":[{"reason":"insufficientPermissions"}]}}"#, .google),
         "failed", "Google 403 scopes → failed")
    t.eq(http(403, #"{"error":{"code":403,"message":"Access denied by admin policy.","status":"PERMISSION_DENIED","errors":[{"reason":"access_denied"}]}}"#, .google),
         "consentRequired", "Google 403 access_denied reason → consentRequired (not cancel)")
    t.eq(http(400, #"{"error":"admin_policy_enforced","error_description":"Blocked by admin"}"#, .google), "consentRequired", "Google 400 admin policy")
}

@MainActor private func testBase64AndEntities(_ t: Tester) {
    t.eq(HTTP.base64urlDecode("wr9RdcOpIHRhbD8gPj4-IH5-fiBvaw").map { String(decoding: $0, as: UTF8.self) }, "¿Qué tal? >>> ~~~ ok",
         "base64url with - and _ , no padding")
    t.eq(HTTP.base64urlDecode("aGk").map { String(decoding: $0, as: UTF8.self) }, "hi", "base64url unpadded")
    t.eq(HTTP.base64urlDecode("aGk=").map { String(decoding: $0, as: UTF8.self) }, "hi", "base64url padded")
    t.eq(HTTP.base64url(Data([0xfb, 0xff, 0xfe])), "-__-", "base64url encode")
    t.eq(HTTP.base64urlDecode("-__-"), Data([0xfb, 0xff, 0xfe]), "base64url decode bytes")
    t.eq(HTTP.decodeEntities("Tom &amp; Jerry&#39;s &lt;b&gt; &#xBF;s&iacute;? &x"), "Tom & Jerry's <b> ¿s&iacute;? &x", "HTML entities")
}

@MainActor private func testJoinLinks(_ t: Tester) {
    t.eq(JoinLink.find(in: ["Únete: https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=abc."])?.host,
         "teams.microsoft.com", "Teams link")
    t.eq(JoinLink.find(in: ["Teams: https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=abc."])?.absoluteString,
         "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=abc", "Teams link without trailing period")
    t.eq(JoinLink.find(in: [nil, "Sala 2", "Meet: https://meet.google.com/abc-defg-hij"])?.absoluteString,
         "https://meet.google.com/abc-defg-hij", "Meet link in second text")
    t.eq(JoinLink.find(in: ["(https://us02web.zoom.us/j/8765432?pwd=xYz)"])?.absoluteString, "https://us02web.zoom.us/j/8765432?pwd=xYz",
         "Zoom link inside parentheses")
    t.eq(JoinLink.find(in: ["Oficina 3, piso 2", "https://example.com/agenda"]), nil, "no join link in plain text")
    t.check(JoinLink.isJoinLink(URL(string: "https://zoom.us/j/1")), "zoom URL is a join link")
    for bad in ["smb://attacker.example/share?x=https://zoom.us/j/123", "file:///tmp/x?https://zoom.us/j/1",
                "zoommtg://zoom.us/join?confno=1#https://zoom.us/j/1", "https://evil.example/?u=https://zoom.us/j/1"] {
        t.check(!JoinLink.isJoinLink(URL(string: bad)), "not a join link: \(bad)")
    }
    t.eq(JoinLink.https("smb://attacker.example/x#https://meet.google.com/abc-defg-hij"), nil, "provider join URL must be https")
    t.eq(JoinLink.https(" https://meet.google.com/abc-defg-hij ")?.host, "meet.google.com", "https provider join URL kept")
}

// MARK: - Fixtures

private let graphList = #"""
{"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/messages?$skip=50",
 "value":[{"id":"AAMk1","conversationId":"conv1","subject":"Propuesta Acme","bodyPreview":"Hola Ana,\r\n te mando   la propuesta",
  "receivedDateTime":"2026-10-20T14:03:00Z","isRead":false,"hasAttachments":true,"webLink":"https://outlook.office365.com/owa/?ItemID=AAMk1",
  "from":{"emailAddress":{"name":"Laura Méndez","address":"Laura.Mendez@contoso.com"}},
  "toRecipients":[{"emailAddress":{"name":"Ana García","address":"ana@contoso.com"}},{"emailAddress":{"name":"Diego","address":"diego.torres@contoso.com"}}]},
 {"id":"AAMk2","subject":"Sin remitente","receivedDateTime":"2026-10-19T09:00:00.123Z","from":null,"toRecipients":[]}]}
"""#

private let graphMessageText = #"""
{"id":"AAMk1","conversationId":"conv1","subject":"Propuesta Acme","bodyPreview":"Hola Ana","receivedDateTime":"2026-10-20T14:03:00Z",
 "from":{"emailAddress":{"name":"Laura Méndez","address":"laura.mendez@contoso.com"}},"toRecipients":[],
 "ccRecipients":[{"emailAddress":{"name":"Carlos Ruiz","address":"carlos.ruiz@contoso.com"}}],
 "body":{"contentType":"text","content":"Hola Ana,\r\n\r\nTe mando la propuesta.\r\n\r\n\r\n\r\nSaludos"}}
"""#

private let graphMessageHTML = #"""
{"id":"AAMk3","subject":"HTML","receivedDateTime":"2026-10-21T10:00:00Z","from":{"emailAddress":{"address":"x@contoso.com"}},
 "body":{"contentType":"html","content":"<html><head><style>p{color:red}</style></head><body><p>Hola <b>Ana</b></p><p>Nos vemos el lunes</p></body></html>"}}
"""#

private let graphThread = #"""
{"value":[
 {"id":"m2","conversationId":"conv1","subject":"RE: Propuesta","receivedDateTime":"2026-10-21T09:00:00Z","from":{"emailAddress":{"address":"ana@contoso.com"}},"body":{"contentType":"text","content":"Gracias"}},
 {"id":"m1","conversationId":"conv1","subject":"Propuesta","receivedDateTime":"2026-10-20T14:03:00Z","from":{"emailAddress":{"address":"laura.mendez@contoso.com"}},"body":{"contentType":"text","content":"Va la propuesta"}}]}
"""#

private let graphEvents = #"""
{"value":[
 {"id":"ev1","subject":"Kickoff Acme","start":{"dateTime":"2026-10-27T15:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-10-27T16:00:00.0000000","timeZone":"UTC"},
  "isAllDay":false,"isCancelled":false,"location":{"displayName":"Microsoft Teams Meeting"},
  "onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d"},
  "organizer":{"emailAddress":{"name":"Laura Méndez","address":"laura.mendez@contoso.com"}},
  "attendees":[{"type":"required","emailAddress":{"name":"Ana García","address":"ana@contoso.com"}},{"type":"resource","emailAddress":{"name":"Sala 3","address":"sala3@contoso.com"}}],
  "bodyPreview":"Agenda: alcance","webLink":"https://outlook.office365.com/owa/?itemid=ev1","seriesMasterId":"master1","type":"occurrence"},
 {"id":"ev2","subject":"Revisión semanal","start":{"dateTime":"2026-10-28T17:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-10-28T17:30:00.0000000","timeZone":"UTC"},
  "location":{"displayName":"https://contoso.zoom.us/j/123456789?pwd=abc"},"bodyPreview":"","onlineMeeting":null},
 {"id":"ev3","subject":"Feriado","isAllDay":true,"start":{"dateTime":"2026-11-02T00:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-11-03T00:00:00.0000000","timeZone":"UTC"}},
 {"id":"ev4","subject":"Cancelada","isCancelled":true,"start":{"dateTime":"2026-10-29T17:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-10-29T18:00:00.0000000","timeZone":"UTC"}},
 {"id":"ev5","subject":"Meet en notas","start":{"dateTime":"2026-10-30T17:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-10-30T18:00:00.0000000","timeZone":"UTC"},
  "bodyPreview":"Liga: https://meet.google.com/abc-defg-hij gracias"}]}
"""#

@MainActor private func testGraphFixtures(_ t: Tester) async {
    do {
        let (msgs, next) = try GraphParser.messageList(Data(graphList.utf8))
        t.eq(msgs.count, 2, "Graph list count")
        t.eq(next, "https://graph.microsoft.com/v1.0/me/messages?$skip=50", "Graph nextLink")
        let m = msgs[0]
        t.eq(m.id, "AAMk1", "Graph id")
        t.eq(m.threadId, "conv1", "Graph threadId = conversationId")
        t.eq(m.from.email, "laura.mendez@contoso.com", "Graph from lowercased")
        t.eq(m.from.name, "Laura Méndez", "Graph from name")
        t.eq(m.to.count, 2, "Graph to")
        t.eq(m.subject, "Propuesta Acme", "Graph subject")
        t.eq(m.snippet, "Hola Ana, te mando la propuesta", "Graph snippet collapsed")
        t.eq(m.date, utcDate(2026, 10, 20, 14, 3), "Graph date")
        t.check(!m.isRead && m.hasAttachments, "Graph flags")
        t.eq(m.webLink, "https://outlook.office365.com/owa/?ItemID=AAMk1", "Graph webLink")
        t.eq(msgs[1].threadId, "AAMk2", "Graph missing conversationId → id")
        t.check(abs(msgs[1].date.timeIntervalSince(utcDate(2026, 10, 19, 9, 0)) - 0.123) < 0.001, "Graph fractional date")
    } catch { t.check(false, "Graph list parses: \(error)") }
    do {
        let full = try await GraphParser.message(Data(graphMessageText.utf8))
        t.eq(full.bodyText, "Hola Ana,\n\nTe mando la propuesta.\n\nSaludos", "Graph text body")
        t.eq(full.cc.first?.email, "carlos.ruiz@contoso.com", "Graph cc")
        let html = try await GraphParser.message(Data(graphMessageHTML.utf8))
        t.check(html.bodyText.contains("Hola Ana") && html.bodyText.contains("Nos vemos el lunes") && !html.bodyText.contains("<")
                && !html.bodyText.contains("color:red"), "Graph HTML body → text: \(html.bodyText)")
        let thread = try await GraphParser.thread(Data(graphThread.utf8))
        t.eq(thread.map(\.summary.id), ["m1", "m2"], "Graph thread oldest first")
    } catch { t.check(false, "Graph message parses: \(error)") }
    do {
        let (events, _) = try GraphParser.events(Data(graphEvents.utf8), accountId: "microsoft:ana@contoso.com")
        t.eq(events.map(\.id), ["ev1", "ev2", "ev3", "ev5"], "Graph events (cancelled skipped)")
        let e = events[0]
        t.eq(e.start, utcDate(2026, 10, 27, 15), "Graph event start UTC")
        t.eq(e.end, utcDate(2026, 10, 27, 16), "Graph event end UTC")
        t.eq(e.joinURL?.host, "teams.microsoft.com", "Graph Teams joinUrl")
        t.eq(e.attendees.map { $0.email ?? "" }, ["ana@contoso.com"], "Graph attendees without rooms")
        t.eq(e.organizer?.email, "laura.mendez@contoso.com", "Graph organizer")
        t.eq(e.seriesId, "master1", "Graph seriesMasterId")
        t.eq(e.location, "Microsoft Teams Meeting", "Graph location")
        t.eq(e.notes, "Agenda: alcance", "Graph notes = bodyPreview")
        t.eq(e.accountId, "microsoft:ana@contoso.com", "Graph accountId")
        t.eq(events[1].joinURL?.absoluteString, "https://contoso.zoom.us/j/123456789?pwd=abc", "Graph Zoom link from location")
        t.check(events[2].isAllDay && events[2].start == localDate(2026, 11, 2) && events[2].end == localDate(2026, 11, 3),
                "Graph all-day keeps its local day")
        t.eq(events[3].joinURL?.absoluteString, "https://meet.google.com/abc-defg-hij", "Graph Meet link from notes")
        t.eq(events[1].seriesId, nil, "Graph single event has no series")
    } catch { t.check(false, "Graph events parse: \(error)") }
    t.eq(errorKind { _ = try GraphParser.messageList(Data("[]".utf8)) }, "failed", "Graph bad JSON → failed")
}

private func gmailHeaders(_ pairs: [(String, String)]) -> String {
    "[" + pairs.map { #"{"name":"\#($0.0)","value":"\#($0.1)"}"# }.joined(separator: ",") + "]"
}

@MainActor private func testGmailFixtures(_ t: Tester) async {
    let account = ConnectedAccount(provider: .google, email: "demo@gmail.com")
    let ms = Int(utcDate(2026, 10, 26, 14).timeIntervalSince1970 * 1000)
    let headers = gmailHeaders([("From", #"\"Ruiz, Carlos\" <Carlos.Ruiz@contoso.com>"#), ("To", "Ana García <demo@gmail.com>, pablo.diaz@gmail.com"),
                                ("Subject", "Contrato"), ("Date", "Sun, 26 Oct 2026 14:00:00 +0000")])
    let metadata = #"{"id":"g1","threadId":"t1","labelIds":["INBOX","UNREAD"],"snippet":"Te comparto el contrato &amp; los anexos, &#39;ok&#39;","internalDate":"\#(ms)","payload":{"mimeType":"multipart/mixed","headers":\#(headers)}}"#
    do {
        let ids = try GmailParser.idList(Data(#"{"messages":[{"id":"g1","threadId":"t1"},{"id":"g2","threadId":"t1"}],"nextPageToken":"np","resultSizeEstimate":2}"#.utf8))
        t.eq(ids.ids, ["g1", "g2"], "Gmail ids")
        t.eq(ids.next, "np", "Gmail nextPageToken")
        t.eq(try GmailParser.idList(Data(#"{"resultSizeEstimate":0}"#.utf8)).ids, [], "Gmail empty list")
        let s = try GmailParser.summary(Data(metadata.utf8), account: account)
        t.eq(s.id, "g1", "Gmail id")
        t.eq(s.threadId, "t1", "Gmail threadId")
        t.eq(s.from.email, "carlos.ruiz@contoso.com", "Gmail from email")
        t.eq(s.from.name, "Ruiz, Carlos", "Gmail from quoted name with comma")
        t.eq(s.to.compactMap(\.email), ["demo@gmail.com", "pablo.diaz@gmail.com"], "Gmail to list")
        t.eq(s.subject, "Contrato", "Gmail subject")
        t.eq(s.snippet, "Te comparto el contrato & los anexos, 'ok'", "Gmail snippet entities")
        t.eq(s.date, utcDate(2026, 10, 26, 14), "Gmail internalDate")
        t.check(!s.isRead, "Gmail UNREAD → not read")
        t.check(s.hasAttachments, "Gmail multipart/mixed → attachments")
        t.check(s.webLink?.contains("#all/t1") == true && s.webLink?.contains("authuser=demo%40gmail.com") == true, "Gmail webLink \(s.webLink ?? "-")")
    } catch { t.check(false, "Gmail metadata parses: \(error)") }

    let plain = "SG9sYSBBbmEsDQoNCsK_UmV2aXNhcyBlbCBjb250cmF0bz8gVmEgY29uIGFuZXhvcyA-PiBvay4NCg0KQ2FybG9z"
    let html = HTTP.base64url(Data("<div>Hola <b>Ana</b><br>Nos vemos el lunes</div>".utf8))
    let fullJSON = #"""
    {"id":"g1","threadId":"t1","labelIds":["INBOX"],"snippet":"Hola","internalDate":"\#(ms)","payload":{"mimeType":"multipart/mixed","headers":\#(gmailHeaders([("From", "Carlos <carlos.ruiz@contoso.com>"), ("Cc", "lucia@x.com"), ("Subject", "Contrato")])),
     "parts":[{"mimeType":"multipart/alternative","parts":[
        {"mimeType":"text/plain","headers":[{"name":"Content-Type","value":"text/plain; charset=UTF-8"}],"body":{"size":60,"data":"\#(plain)"}},
        {"mimeType":"text/html","body":{"size":60,"data":"\#(html)"}}]},
      {"mimeType":"application/pdf","filename":"contrato.pdf","body":{"size":1234,"attachmentId":"att1"}}]}}
    """#
    let htmlOnly = #"{"id":"g3","threadId":"t3","internalDate":"\#(ms)","payload":{"mimeType":"text/html","headers":[],"body":{"size":10,"data":"\#(html)"}}}"#
    do {
        let full = try await GmailParser.message(Data(fullJSON.utf8), account: account)
        t.eq(full.bodyText, "Hola Ana,\n\n¿Revisas el contrato? Va con anexos >> ok.\n\nCarlos", "Gmail text/plain part preferred")
        t.check(full.summary.hasAttachments && full.summary.isRead, "Gmail attachment part + read")
        t.eq(full.cc.compactMap(\.email), ["lucia@x.com"], "Gmail cc")
        let h = try await GmailParser.message(Data(htmlOnly.utf8), account: account)
        t.check(h.bodyText.contains("Hola Ana") && h.bodyText.contains("Nos vemos el lunes") && !h.bodyText.contains("<"),
                "Gmail HTML-only → text: \(h.bodyText)")
        let ms2 = ms - 3_600_000
        let thread = #"{"id":"t1","messages":[\#(fullJSON),{"id":"g0","threadId":"t1","internalDate":"\#(ms2)","payload":{"mimeType":"text/plain","headers":[],"body":{"data":"\#(HTTP.base64url(Data("primero".utf8)))"}}}]}"#
        let msgs = try await GmailParser.thread(Data(thread.utf8), account: account)
        t.eq(msgs.map(\.summary.id), ["g0", "g1"], "Gmail thread oldest first")
        t.eq(msgs.first?.bodyText, "primero", "Gmail single-part body")
        let draft = #"{"id":"gd","threadId":"t1","labelIds":["DRAFT"],"internalDate":"\#(ms)","payload":{"mimeType":"text/plain","headers":[],"body":{"data":"\#(HTTP.base64url(Data("borrador".utf8)))"}}}"#
        let withDraft = #"{"id":"t1","messages":[\#(fullJSON),\#(draft)]}"#
        t.eq(try await GmailParser.thread(Data(withDraft.utf8), account: account).map(\.summary.id), ["g1"], "Gmail thread leaves drafts out")
        t.check(try GmailParser.visibleSummary(Data(draft.utf8), account: account) == nil, "Gmail list leaves drafts out")
        let graphDraft = #"{"value":[{"id":"a","conversationId":"c","receivedDateTime":"2026-10-01T10:00:00Z","body":{"contentType":"text","content":"hola"}},{"id":"b","conversationId":"c","isDraft":true,"receivedDateTime":"2026-10-01T11:00:00Z","body":{"contentType":"text","content":"borrador"}}]}"#
        t.eq(try await GraphParser.thread(Data(graphDraft.utf8)).map(\.summary.id), ["a"], "Graph thread leaves drafts out")
        t.eq(try GraphParser.messageList(Data(graphDraft.utf8)).messages.map(\.id), ["a"], "Graph list leaves drafts out")
    } catch { t.check(false, "Gmail full parses: \(error)") }
    do {
        let me = try GmailParser.profile(Data(#"{"sub":"1","email":"Demo@Gmail.com","name":"Ana García","email_verified":true}"#.utf8),
                                         scopes: AccountProvider.google.scopes)
        t.eq(me.id, "google:demo@gmail.com", "Google profile id")
        t.eq(me.displayName, "Ana García", "Google profile name")
        let graphMe = try GraphParser.profile(Data(#"{"displayName":"Ana","mail":null,"userPrincipalName":"ana@contoso.onmicrosoft.com"}"#.utf8), scopes: [])
        t.eq(graphMe.email, "ana@contoso.onmicrosoft.com", "Graph profile falls back to UPN")
    } catch { t.check(false, "profiles parse: \(error)") }
}

private let googleEvents = #"""
{"items":[
 {"id":"gev1","status":"confirmed","summary":"Café con Pablo","start":{"dateTime":"2026-10-27T10:00:00-06:00"},"end":{"dateTime":"2026-10-27T11:00:00-06:00"},
  "hangoutLink":"https://meet.google.com/abc-defg-hij","attendees":[{"email":"pablo.diaz@gmail.com","displayName":"Pablo"},{"email":"sala@resource.calendar.google.com","resource":true},{"email":"demo@gmail.com","self":true}],
  "organizer":{"email":"demo@gmail.com","self":true},"htmlLink":"https://www.google.com/calendar/event?eid=x","recurringEventId":"rec1","location":"Café Rule"},
 {"id":"gev2","summary":"Zoom con Lucía","start":{"dateTime":"2026-10-28T09:00:00Z"},"end":{"dateTime":"2026-10-28T09:45:00Z"},
  "description":"Únete: <a href=\"https://us02web.zoom.us/j/8765?pwd=x\">https://us02web.zoom.us/j/8765?pwd=x</a><br>Contraseña: 1234 &amp; listo"},
 {"id":"gev3","summary":"Vacaciones","start":{"date":"2026-11-02"},"end":{"date":"2026-11-03"}},
 {"id":"gev4","status":"cancelled","start":{"dateTime":"2026-10-29T09:00:00Z"},"end":{"dateTime":"2026-10-29T10:00:00Z"}},
 {"id":"gev5","summary":"Meet por conferenceData","start":{"dateTime":"2026-10-30T09:00:00.000Z"},"end":{"dateTime":"2026-10-30T10:00:00Z"},
  "conferenceData":{"entryPoints":[{"entryPointType":"phone","uri":"tel:+1-555-0100"},{"entryPointType":"video","uri":"https://meet.google.com/xyz-abcd-efg"}]}},
 {"id":"gev6","start":{"dateTime":"2026-10-31T09:00:00Z"},"end":{"dateTime":"2026-10-31T10:00:00Z"},"location":"https://teams.microsoft.com/l/meetup-join/19%3a1"}
],"nextPageToken":"np"}
"""#

@MainActor private func testGoogleCalendarFixtures(_ t: Tester) {
    do {
        let (events, next) = try GoogleCalendarParser.events(Data(googleEvents.utf8), accountId: "google:demo@gmail.com")
        t.eq(events.map(\.id), ["gev1", "gev2", "gev3", "gev5", "gev6"], "Google events (cancelled skipped)")
        t.eq(next, "np", "Google events nextPageToken")
        let e = events[0]
        t.eq(e.start, utcDate(2026, 10, 27, 16), "Google start with offset")
        t.eq(e.joinURL?.absoluteString, "https://meet.google.com/abc-defg-hij", "Google hangoutLink")
        t.eq(e.attendees.compactMap(\.email), ["pablo.diaz@gmail.com", "demo@gmail.com"], "Google attendees without rooms")
        t.eq(e.seriesId, "rec1", "Google recurringEventId")
        t.eq(e.location, "Café Rule", "Google location")
        t.eq(e.webLink, "https://www.google.com/calendar/event?eid=x", "Google htmlLink")
        t.eq(events[1].joinURL?.host, "us02web.zoom.us", "Google Zoom from description")
        t.eq(events[1].notes, "Únete: https://us02web.zoom.us/j/8765?pwd=x\nContraseña: 1234 & listo", "Google description → text")
        t.check(events[2].isAllDay && events[2].start == localDate(2026, 11, 2), "Google all-day date")
        t.eq(events[3].joinURL?.absoluteString, "https://meet.google.com/xyz-abcd-efg", "Google conferenceData video entry")
        t.eq(events[3].start, utcDate(2026, 10, 30, 9), "Google fractional seconds")
        t.eq(events[4].joinURL?.host, "teams.microsoft.com", "Google Teams link from location")
        t.check(!events[4].title.isEmpty, "untitled event gets a title")
    } catch { t.check(false, "Google events parse: \(error)") }
}

@MainActor private func testLocalCalendarMapping(_ t: Tester) {
    // Pure mapping only: EventKit itself (and its permission prompt) is never touched by the self-tests unless asked.
    let start = utcDate(2026, 10, 27, 15)
    let recurring = LocalCalendarProvider.event(from: .init(identifier: "E1", externalIdentifier: "X1", isRecurring: true, title: "Standup",
                                                            start: start, end: start.addingTimeInterval(900),
                                                            location: "https://meet.google.com/abc-defg-hij",
                                                            attendees: [EmailAddress(name: "Ana", email: "ana@x.com")]))
    t.eq(recurring.id, "E1@\(Int(start.timeIntervalSince1970))", "local recurring id includes the start")
    t.eq(recurring.seriesId, "X1", "local seriesId = external identifier")
    t.eq(recurring.accountId, "local:calendar", "local accountId")
    t.eq(recurring.joinURL?.host, "meet.google.com", "local Meet link from location")
    let single = LocalCalendarProvider.event(from: .init(identifier: "E2", title: nil, start: start, end: start.addingTimeInterval(3600),
                                                         url: URL(string: "https://zoom.us/j/99"),
                                                         notes: "Teams: https://teams.microsoft.com/l/meetup-join/19%3ax"))
    t.eq(single.id, "E2", "local single id")
    t.eq(single.seriesId, nil, "local single has no series")
    t.eq(single.joinURL?.absoluteString, "https://zoom.us/j/99", "local URL field wins when it is a call link")
    t.check(!single.title.isEmpty, "local untitled event gets a title")
    let notes = LocalCalendarProvider.event(from: .init(identifier: "E3", title: "X", start: start, end: start,
                                                        url: URL(string: "https://example.com"),
                                                        notes: "Teams: https://teams.microsoft.com/l/meetup-join/19%3ax"))
    t.eq(notes.joinURL?.host, "teams.microsoft.com", "local Teams link from notes")
    t.eq(LocalCalendarProvider.makeAccount().id, "local:calendar", "local account id")
    if ProcessInfo.processInfo.environment["SB_TEST_EVENTKIT"] == "1" {
        print("  (EventKit access: \(LocalCalendarProvider.hasAccess))")
    }
}

// MARK: - Token manager, loopback, full flow

@MainActor private func testTokenManager(_ t: Tester) async {
    let server = FakeServer()
    let storage = MemoryTokenStore()
    let endpoint = OAuthEndpoint.microsoft(clientId: "ms-id")
    let expired = OAuthTokens(accessToken: "old", refreshToken: "rt-old", expiresAt: Date().addingTimeInterval(30), scope: "")
    try? storage.save(expired, for: "k")
    server.on("/oauth2/v2.0/token") { req in
        let f = formFields(req)
        return f["grant_type"] == "refresh_token" && f["refresh_token"] == "rt-old" && f["client_id"] == "ms-id"
            ? (200, #"{"access_token":"new","refresh_token":"rt-new","expires_in":3600}"#) : (400, #"{"error":"invalid_request"}"#)
    }
    final class Flag: @unchecked Sendable { var hit = 0 }
    let flag = Flag()
    let manager = TokenManager(key: "k", provider: .microsoft, endpoint: endpoint, storage: storage, transport: server.transport,
                               onReauthRequired: { flag.hit += 1 })
    do {
        let token = try await manager.accessToken()
        t.eq(token, "new", "expiring token refreshed")
        t.eq(storage.load("k")?.refreshToken, "rt-new", "refreshed tokens saved")
        _ = try await manager.accessToken()
        t.eq(server.count("/token"), 1, "fresh token not refreshed again")
    } catch { t.check(false, "token refresh works: \(error)") }

    // 401 → one refresh + retry.
    let calls = Flag()
    let lock = NSLock()
    server.on("/v1.0/me/messages") { req in
        lock.withLock { calls.hit += 1 }
        return req.value(forHTTPHeaderField: "Authorization") == "Bearer newer"
            ? (200, #"{"value":[]}"#) : (401, #"{"error":{"code":"InvalidAuthenticationToken","message":"expired"}}"#)
    }
    server.on("/oauth2/v2.0/token", status: 200, #"{"access_token":"newer","expires_in":3600}"#)
    let api = APIClient(provider: .microsoft, tokens: manager, transport: server.transport)
    do {
        _ = try await api.get(MicrosoftGraphProvider.listURL(since: Date()))
        t.eq(lock.withLock { calls.hit }, 2, "401 → refresh + one retry")
        t.eq(storage.load("k")?.refreshToken, "rt-new", "refresh keeps the refresh token when none comes back")
    } catch { t.check(false, "401 retry works: \(error)") }

    // invalid_grant → unauthorized + needs sign-in.
    let dead = MemoryTokenStore()
    try? dead.save(OAuthTokens(accessToken: "x", refreshToken: "revoked", expiresAt: Date().addingTimeInterval(-10), scope: ""), for: "d")
    let badServer = FakeServer()
    badServer.on("/token", status: 400, #"{"error":"invalid_grant","error_description":"AADSTS700082: The refresh token has expired"}"#)
    let deadManager = TokenManager(key: "d", provider: .microsoft, endpoint: endpoint, storage: dead, transport: badServer.transport,
                                   onReauthRequired: { flag.hit += 1 })
    var kind = "none"
    do { _ = try await deadManager.accessToken() } catch { kind = errorKind(error) }
    t.eq(kind, "unauthorized", "invalid_grant → unauthorized")
    t.eq(flag.hit, 1, "invalid_grant → needs sign-in callback")
    let empty = TokenManager(key: "none", provider: .google, endpoint: nil, storage: MemoryTokenStore(), onReauthRequired: { flag.hit += 1 })
    kind = "none"
    do { _ = try await empty.accessToken() } catch { kind = errorKind(error) }
    t.eq(kind, "unauthorized", "no stored tokens → unauthorized")
}

@MainActor private func testLoopbackServer(_ t: Tester) async {
    let server = LoopbackServer(language: "es")
    do {
        let port = try await server.start()
        t.check(port > 0, "loopback port assigned")
        let waiter = Task { try await server.waitForCallback(timeout: .seconds(10)) }
        // Unrelated requests (favicon) don't end the wait.
        let (_, fav) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        t.eq((fav as? HTTPURLResponse)?.statusCode, 404, "favicon → 404")
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=x&state=y")!)
        let page = String(decoding: data, as: UTF8.self)
        t.eq((resp as? HTTPURLResponse)?.statusCode, 200, "callback → 200")
        t.check(page.contains("Listo, ya puedes volver a SecondBrain"), "callback page (es)")
        let params = try await waiter.value
        t.eq(params["code"], "x", "captured code")
        t.eq(params["state"], "y", "captured state")
    } catch { t.check(false, "loopback round trip: \(error)") }
    server.stop()
    t.check(LoopbackServer.page(success: true, language: "en").contains("Done, you can go back to SecondBrain"), "callback page (en)")

    // With an expected state, a forged callback (other state, or none) gets a 404 and doesn't end the wait.
    let guarded = LoopbackServer(language: "en", expectedState: "good")
    do {
        let port = try await guarded.start()
        let waiter = Task { try await guarded.waitForCallback(timeout: .seconds(10)) }
        let (_, forged) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?error=admin_policy_enforced&state=bad")!)
        t.eq((forged as? HTTPURLResponse)?.statusCode, 404, "forged error (wrong state) → 404")
        let (_, stateless) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=x")!)
        t.eq((stateless as? HTTPURLResponse)?.statusCode, 404, "callback without state → 404")
        let (_, real) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=c2&state=good")!)
        t.eq((real as? HTTPURLResponse)?.statusCode, 200, "real callback → 200")
        t.eq(try await waiter.value["code"], "c2", "only the real callback ends the wait")
    } catch { t.check(false, "loopback state guard: \(error)") }
    guarded.stop()
    t.eq(errorKind { _ = try OAuthClient.validateCallback(["error": "admin_policy_enforced", "state": "bad"], expectedState: "mine",
                                                          provider: .microsoft) },
         "failed", "error with a wrong state is not believed (no 'org blocked')")

    // localhost (Microsoft's redirect host) reaches the loopback listener too.
    let local = LoopbackServer(language: "en")
    do {
        let port = try await local.start()
        let waiter = Task { try await local.waitForCallback(timeout: .seconds(10)) }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://localhost:\(port)/?error=access_denied&state=s")!)
        t.check(String(decoding: data, as: UTF8.self).contains("Couldn't connect"), "error page via localhost")
        t.eq(try await waiter.value["error"], "access_denied", "error captured via localhost")
    } catch { t.check(false, "loopback via localhost: \(error)") }
    local.stop()

    // Timeout and cancellation.
    let slow = LoopbackServer(language: "es")
    var kind = "none"
    do {
        _ = try await slow.start()
        _ = try await slow.waitForCallback(timeout: .milliseconds(200))
    } catch { kind = errorKind(error) }
    t.eq(kind, "failed", "loopback timeout → failed")
    slow.stop()
    let cancelled = LoopbackServer(language: "es")
    do {
        _ = try await cancelled.start()
        let task = Task { try await cancelled.waitForCallback(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        kind = "none"
        do { _ = try await task.value } catch { kind = errorKind(error) }
        t.eq(kind, "cancellation", "loopback wait cancels")
    } catch { t.check(false, "loopback cancel setup: \(error)") }
    cancelled.stop()
}

@MainActor private func testAuthorizeFlow(_ t: Tester) async {
    let server = FakeServer()
    final class Seen: @unchecked Sendable { var fields: [String: String] = [:] }
    let seen = Seen()
    server.on("oauth2.googleapis.com/token") { req in
        seen.fields = formFields(req)
        return (200, #"{"access_token":"g-at","refresh_token":"g-rt","expires_in":3599,"scope":"openid email","token_type":"Bearer"}"#)
    }
    let browser = FakeBrowser()
    let endpoint = OAuthEndpoint.google(clientId: "g-id", clientSecret: "g-secret")
    do {
        let tokens = try await OAuthClient.authorize(endpoint, language: "es", timeout: .seconds(10), transport: server.transport,
                                                     openURL: browser.open)
        t.eq(tokens.accessToken, "g-at", "authorize → access token")
        t.eq(tokens.refreshToken, "g-rt", "authorize → refresh token")
        let auth = query(browser.authorizeURL!)
        t.eq(seen.fields["grant_type"], "authorization_code", "token request grant")
        t.eq(seen.fields["code"], "abc123", "token request code")
        t.eq(seen.fields["client_secret"], "g-secret", "Google token request has the secret")
        t.eq(seen.fields["redirect_uri"], auth["redirect_uri"], "token redirect_uri = authorize redirect_uri")
        t.eq(PKCE.challenge(for: seen.fields["code_verifier"] ?? ""), auth["code_challenge"], "verifier matches the challenge")
        t.check(auth["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true, "Google loopback redirect")
        try? await Task.sleep(for: .milliseconds(100))
        t.check(browser.page?.contains("Listo") == true, "browser saw the ✓ page")
    } catch { t.check(false, "authorize flow: \(error)") }

    // Wrong state from the "browser" → rejected, no token request.
    let evil = FakeBrowser()
    evil.overrideState = "forged"
    let before = server.count("oauth2.googleapis.com/token")
    var kind = "none"
    do { _ = try await OAuthClient.authorize(endpoint, language: "es", timeout: .seconds(10), transport: server.transport, openURL: evil.open) }
    catch { kind = errorKind(error) }
    t.eq(kind, "failed", "forged state → failed")
    t.eq(server.count("oauth2.googleapis.com/token"), before, "forged state → no token request")

    // Cancelling the sign-in task → cancelled.
    let task = Task { try await OAuthClient.authorize(endpoint, language: "es", timeout: .seconds(30), transport: server.transport, openURL: { _ in }) }
    try? await Task.sleep(for: .milliseconds(150))
    task.cancel()
    kind = "none"
    do { _ = try await task.value } catch { kind = errorKind(error) }
    t.eq(kind, "cancelled", "cancelled sign-in → AccountError.cancelled")
}

@MainActor private func testAccountStoreFlow(_ t: Tester, root: URL) async {
    let server = FakeServer()
    server.on("login.microsoftonline.com/common/oauth2/v2.0/token") { req in
        let f = formFields(req)
        if f["grant_type"] == "authorization_code" {
            return f["scope"] == "User.Read Mail.Read Calendars.Read offline_access" && f["client_secret"] == nil
                ? (200, #"{"access_token":"ms-at","refresh_token":"ms-rt","expires_in":3600,"scope":"User.Read Mail.Read Calendars.Read"}"#)
                : (400, #"{"error":"invalid_request"}"#)
        }
        return (400, #"{"error":"invalid_grant","error_description":"AADSTS50173: The provided grant has expired"}"#)
    }
    server.on("/v1.0/me?", status: 200, #"{"displayName":"Ana García","mail":"Ana@Contoso.com","userPrincipalName":"ana@contoso.com"}"#)
    server.on("/v1.0/me/calendarView", status: 200, graphEvents)
    let fileURL = root.appendingPathComponent("accounts.json")
    let store = AccountStore(fileURL: fileURL, demo: false)
    let storage = MemoryTokenStore()
    store.tokenStorage = storage
    store.transport = server.transport
    store.registration = { OAuthAppRegistration(microsoftClientId: "ms-id") }
    var connected: [String] = []
    store.onConnected = { connected.append($0.email) }

    var kind = "none"
    do { _ = try await store.connect(.google, registration: .empty, openURL: { _ in }) } catch { kind = errorKind(error) }
    t.eq(kind, "notConfigured", "connect without ids → notConfigured")

    let browser = FakeBrowser()
    do {
        let account = try await store.connect(.microsoft, registration: OAuthAppRegistration(microsoftClientId: "ms-id"), openURL: browser.open)
        t.eq(account.id, "microsoft:ana@contoso.com", "connected account id")
        t.eq(account.displayName, "Ana García", "connected display name")
        t.eq(store.accounts.map(\.id), ["microsoft:ana@contoso.com"], "account listed")
        t.eq(storage.load("oauth-microsoft-ana@contoso.com")?.accessToken, "ms-at", "tokens saved under oauth-<provider>-<email>")
        t.eq(connected, ["ana@contoso.com"], "onConnected hook called")
        t.check(FileManager.default.fileExists(atPath: fileURL.path), "accounts.json written")
        t.check((try? String(contentsOf: fileURL, encoding: .utf8))?.contains("ms-at") == false, "no tokens in accounts.json")
        t.check(store.mailAccounts.count == 1 && !store.hasLocalCalendar, "mail accounts")

        let provider = store.provider(for: account)
        t.check(provider is MicrosoftGraphProvider, "provider is Microsoft Graph")
        let events = try await provider.events(from: utcDate(2026, 10, 26), to: utcDate(2026, 11, 4))
        t.eq(events.count, 4, "events through the store provider")
        t.check(server.last("/calendarView")?.value(forHTTPHeaderField: "Prefer") == "outlook.timezone=\"UTC\"", "calendarView asks for UTC")

        // Revoked refresh token → needs sign-in.
        try? storage.save(OAuthTokens(accessToken: "ms-at", refreshToken: "ms-rt", expiresAt: Date().addingTimeInterval(-5), scope: ""),
                          for: "oauth-microsoft-ana@contoso.com")
        let fresh = AccountStore(fileURL: fileURL, demo: false)
        fresh.tokenStorage = storage
        fresh.transport = server.transport
        fresh.registration = { OAuthAppRegistration(microsoftClientId: "ms-id") }
        t.eq(fresh.accounts.map(\.id), ["microsoft:ana@contoso.com"], "accounts.json reloads")
        kind = "none"
        do { _ = try await fresh.provider(for: account).events(from: Date(), to: Date().addingTimeInterval(86_400)) } catch { kind = errorKind(error) }
        t.eq(kind, "unauthorized", "expired grant → unauthorized")
        try? await Task.sleep(for: .milliseconds(50))
        t.check(fresh.needsSignIn.contains(account.id), "expired grant → needs sign-in")

        try store.disconnect(account.id)
        t.check(store.accounts.isEmpty, "disconnect removes the account")
        t.eq(storage.load("oauth-microsoft-ana@contoso.com")?.accessToken, nil, "disconnect deletes the tokens")
    } catch { t.check(false, "store connect flow: \(error)") }

    // Consent block during sign-in → consentRequired, nothing stored.
    let blocked = FakeBrowser()
    blocked.code = "x&error=access_denied&error_description=AADSTS65001"
    let blockedStore = AccountStore(fileURL: root.appendingPathComponent("blocked.json"), demo: false)
    blockedStore.tokenStorage = MemoryTokenStore()
    blockedStore.transport = server.transport
    kind = "none"
    do { _ = try await blockedStore.connect(.microsoft, registration: OAuthAppRegistration(microsoftClientId: "ms-id"), openURL: blocked.open) }
    catch { kind = errorKind(error) }
    t.eq(kind, "consentRequired", "organization block during sign-in → consentRequired")
    t.check(blockedStore.accounts.isEmpty, "blocked sign-in adds nothing")
}
