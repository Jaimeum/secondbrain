import CryptoKit
import Foundation
import Network
import Security

// OAuth 2.0 Authorization Code + PKCE (S256) with a loopback redirect (CONTRACT §12.3). The browser does the
// sign-in; SecondBrain only ever sees the one-time code on http://127.0.0.1:<random port> and swaps it for tokens.

/// PKCE pair (RFC 7636): a random verifier and its SHA-256 challenge, both base64url without padding.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// 32 random bytes → a 43-character verifier.
    public static func generate() -> PKCE { PKCE(verifier: OAuthClient.randomToken(bytes: 32)) }

    public static func challenge(for verifier: String) -> String {
        HTTP.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// Where and how one provider signs in.
public struct OAuthEndpoint: Sendable, Equatable {
    public var provider: AccountProvider
    public var authorizeURL: String
    public var tokenURL: String
    public var clientId: String
    /// Google desktop apps need it (it is not a real secret); Microsoft public clients have none.
    public var clientSecret: String?
    public var scopes: [String]
    /// Provider-specific authorize parameters (Google: offline access + consent so a refresh token comes back).
    public var extraParameters: [(String, String)]

    public static func == (a: OAuthEndpoint, b: OAuthEndpoint) -> Bool {
        a.provider == b.provider && a.authorizeURL == b.authorizeURL && a.tokenURL == b.tokenURL && a.clientId == b.clientId
            && a.clientSecret == b.clientSecret && a.scopes == b.scopes
            && a.extraParameters.map { "\($0.0)=\($0.1)" } == b.extraParameters.map { "\($0.0)=\($0.1)" }
    }

    public static let microsoftAuthority = "https://login.microsoftonline.com/common/oauth2/v2.0"

    public static func microsoft(clientId: String) -> OAuthEndpoint {
        OAuthEndpoint(provider: .microsoft, authorizeURL: microsoftAuthority + "/authorize", tokenURL: microsoftAuthority + "/token",
                      clientId: clientId, clientSecret: nil, scopes: AccountProvider.microsoft.scopes,
                      extraParameters: [("response_mode", "query"), ("prompt", "select_account")])
    }

    public static func google(clientId: String, clientSecret: String?, authURI: String? = nil, tokenURI: String? = nil) -> OAuthEndpoint {
        // Google's downloaded client file carries its own auth_uri/token_uri; use them when present (https only).
        func https(_ s: String?) -> String? { guard let s, s.hasPrefix("https://") else { return nil }; return s }
        return OAuthEndpoint(provider: .google, authorizeURL: https(authURI) ?? "https://accounts.google.com/o/oauth2/v2/auth",
                      tokenURL: https(tokenURI) ?? "https://oauth2.googleapis.com/token", clientId: clientId, clientSecret: clientSecret,
                      scopes: AccountProvider.google.scopes,
                      extraParameters: [("access_type", "offline"), ("prompt", "consent"), ("include_granted_scopes", "true")])
    }

    /// The endpoint for `provider` with the registered ids, or `AccountError.notConfigured`.
    public static func make(_ provider: AccountProvider, registration: OAuthAppRegistration) throws -> OAuthEndpoint {
        guard registration.isConfigured(provider), let id = registration.clientId(for: provider) else {
            throw AccountError.notConfigured(provider)
        }
        switch provider {
        case .microsoft: return .microsoft(clientId: id)
        case .google: return .google(clientId: id, clientSecret: registration.googleClientSecret.nonEmpty,
                                     authURI: registration.googleAuthURI, tokenURI: registration.googleTokenURI)
        case .local: throw AccountError.notConfigured(provider)
        }
    }

    /// Loopback redirect for `port`. Microsoft matches the registered `http://localhost` on any port; Google desktop
    /// apps accept any loopback IP port.
    public func redirectURI(port: UInt16) -> String {
        provider == .microsoft ? "http://localhost:\(port)" : "http://127.0.0.1:\(port)"
    }
}

public enum OAuthClient {
    /// The browser has 5 minutes to come back.
    public static let defaultTimeout: Duration = .seconds(300)

    /// Signs in through the system browser and returns fresh tokens. Throws `AccountError` (`.cancelled` when the task
    /// is cancelled or the user declines, `.consentRequired` for organization blocks, `.failed` on timeout / bad state).
    public static func authorize(_ endpoint: OAuthEndpoint, language: String, loginHint: String? = nil,
                                 timeout: Duration = defaultTimeout, transport: @escaping HTTPTransport = HTTP.urlSession,
                                 openURL: @escaping @Sendable (URL) -> Void) async throws -> OAuthTokens {
        let state = randomToken(bytes: 24)
        // Only the redirect carrying this sign-in's `state` ends the wait: stray or hostile requests get a 404.
        let server = LoopbackServer(language: language, expectedState: state)
        defer { server.stop() }
        let port = try await server.start()
        let redirect = endpoint.redirectURI(port: port)
        let pkce = PKCE.generate()
        let url = authorizationURL(endpoint, redirectURI: redirect, state: state, pkce: pkce, loginHint: loginHint)
        openURL(url)
        let params: [String: String]
        do {
            params = try await server.waitForCallback(timeout: timeout)
        } catch is CancellationError {
            throw AccountError.cancelled
        }
        let code = try validateCallback(params, expectedState: state, provider: endpoint.provider)
        try Task.checkCancellation()
        return try await exchange(code: code, endpoint: endpoint, redirectURI: redirect, verifier: pkce.verifier, transport: transport)
    }

    /// The browser URL for the authorize step.
    public static func authorizationURL(_ endpoint: OAuthEndpoint, redirectURI: String, state: String, pkce: PKCE,
                                        loginHint: String? = nil) -> URL {
        var query: [(String, String)] = [
            ("client_id", endpoint.clientId),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", endpoint.scopes.joined(separator: " ")),
            ("state", state),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
        ]
        query += endpoint.extraParameters
        if let loginHint, !loginHint.isEmpty { query.append(("login_hint", loginHint)) }
        return HTTP.url(endpoint.authorizeURL, query: query)
    }

    /// The code from the redirect, after checking `state` (CSRF) and turning `error=` into an `AccountError`. `state`
    /// is checked first: an `error=` that doesn't belong to this sign-in is not believed.
    public static func validateCallback(_ params: [String: String], expectedState: String,
                                        provider: AccountProvider) throws -> String {
        guard let state = params["state"], constantTimeEquals(state, expectedState) else {
            throw AccountError.failed(lang.t("La respuesta del navegador no coincide con este inicio de sesión. Inténtalo de nuevo.",
                                             "The browser's answer doesn't match this sign-in. Please try again."))
        }
        if let error = params["error"] {
            throw AccountErrorMapper.map(provider: provider, error: error, description: params["error_description"])
        }
        guard let code = params["code"], !code.isEmpty else {
            throw AccountError.failed(lang.t("El navegador no devolvió un código de acceso.", "The browser didn't return an access code."))
        }
        return code
    }

    /// Code → tokens (token endpoint, `authorization_code` grant with the PKCE verifier).
    public static func exchange(code: String, endpoint: OAuthEndpoint, redirectURI: String, verifier: String,
                                transport: HTTPTransport, now: Date = Date()) async throws -> OAuthTokens {
        var fields: [(String, String)] = [
            ("client_id", endpoint.clientId),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", verifier),
        ]
        if endpoint.provider == .microsoft { fields.append(("scope", endpoint.scopes.joined(separator: " "))) }
        if let secret = endpoint.clientSecret { fields.append(("client_secret", secret)) }
        let (data, response) = try await transport(HTTP.formRequest(URL(string: endpoint.tokenURL)!, fields))
        return try parseTokenResponse(data, status: response.statusCode, provider: endpoint.provider, now: now)
    }

    /// Refresh token → new tokens. Keeps the old refresh token when the provider doesn't rotate it (Google).
    public static func refresh(_ tokens: OAuthTokens, endpoint: OAuthEndpoint, transport: HTTPTransport,
                               now: Date = Date()) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else { throw AccountError.unauthorized }
        var fields: [(String, String)] = [
            ("client_id", endpoint.clientId),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]
        if endpoint.provider == .microsoft { fields.append(("scope", endpoint.scopes.joined(separator: " "))) }
        if let secret = endpoint.clientSecret { fields.append(("client_secret", secret)) }
        let (data, response) = try await transport(HTTP.formRequest(URL(string: endpoint.tokenURL)!, fields))
        return try parseTokenResponse(data, status: response.statusCode, provider: endpoint.provider, now: now,
                                      previousRefreshToken: refreshToken)
    }

    /// `{"access_token","expires_in","refresh_token"?,"scope"?}` → `OAuthTokens`; an `{"error":…}` body → `AccountError`
    /// (`invalid_grant` → `.unauthorized`, organization codes → `.consentRequired`).
    public static func parseTokenResponse(_ data: Data, status: Int = 200, provider: AccountProvider, now: Date = Date(),
                                          previousRefreshToken: String? = nil) throws -> OAuthTokens {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let obj, obj["error"] != nil || !(200..<300).contains(status) {
            if let code = obj["error"] as? String {
                throw AccountErrorMapper.map(provider: provider, error: code, description: obj["error_description"] as? String)
            }
            throw AccountErrorMapper.map(provider: provider, status: status, body: data)
        }
        guard let obj, let access = obj["access_token"] as? String, !access.isEmpty else {
            if !(200..<300).contains(status) { throw AccountErrorMapper.map(provider: provider, status: status, body: data) }
            throw AccountError.failed(lang.t("Respuesta inesperada al iniciar sesión.", "Unexpected sign-in response."))
        }
        let expiresIn: Double = (obj["expires_in"] as? Double) ?? (obj["expires_in"] as? Int).map(Double.init)
            ?? (obj["expires_in"] as? String).flatMap(Double.init) ?? 3600
        let refresh = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previousRefreshToken
        return OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(expiresIn),
                           scope: (obj["scope"] as? String) ?? "")
    }

    // MARK: Helpers

    /// `bytes` random bytes from the system CSPRNG, base64url.
    public static func randomToken(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in buffer.indices { buffer[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        return HTTP.base64url(Data(buffer))
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static var lang: Lang { Lang(AppConfig.load().uiLanguage) }
}

// MARK: - Loopback redirect server

/// One-shot HTTP server on the loopback interface (random port) that waits for the OAuth redirect, answers with a tiny
/// "✓ Listo, ya puedes volver a SecondBrain" page and hands the query parameters back. Never reachable from the network.
public final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.secondbrain.oauth-loopback")
    private let lock = NSLock()
    private let language: String
    private var listener: NWListener?
    private var result: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?

    /// When set, only a callback whose `state` equals it is accepted; anything else gets a 404 and the wait goes on.
    private let expectedState: String?

    public init(language: String, expectedState: String? = nil) {
        self.language = language
        self.expectedState = expectedState
    }

    /// Starts listening and returns the port.
    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: params, on: .any) } catch {
            throw AccountError.network(error.localizedDescription)
        }
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !once.done else { return }
                    once.done = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    if !once.done {
                        once.done = true
                        cont.resume(throwing: AccountError.network(error.localizedDescription))
                    } else {
                        self?.finish(.failure(AccountError.network(error.localizedDescription)))
                    }
                case .cancelled:
                    if !once.done { once.done = true; cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the first request that carries `code` or `error`. Cancelling the task or the timeout ends the wait.
    public func waitForCallback(timeout: Duration) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await self.callback() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AccountError.failed(OAuthClient.lang.t(
                    "Pasaron 5 minutos sin respuesta del navegador. Vuelve a intentarlo cuando quieras.",
                    "Five minutes went by without an answer from the browser. Try again whenever you like."))
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    public func stop() {
        let l = lock.withLock { () -> NWListener? in defer { listener = nil }; return listener }
        l?.cancel()
        finish(.failure(CancellationError()))
    }

    private func callback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                let ready: Result<[String: String], Error>? = lock.withLock {
                    if let result { return result }
                    waiter = cont
                    return nil
                }
                if let ready { cont.resume(with: ready) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    /// First result wins; later ones are ignored.
    private func finish(_ value: Result<[String: String], Error>) {
        let cont: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { waiter = nil }
            return waiter
        }
        cont?.resume(with: value)
    }

    // MARK: HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || error != nil || buffer.count > 65_536 {
                self.respond(connection, request: buffer)
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        let head = String(decoding: request.prefix(8192), as: UTF8.self)
        let firstLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"
        var params: [String: String] = [:]
        if let comps = URLComponents(string: "http://127.0.0.1" + target) {
            for item in comps.queryItems ?? [] where params[item.name] == nil { params[item.name] = item.value ?? "" }
        }
        let stateMatches = expectedState.map { expected in params["state"].map { OAuthClient.constantTimeEquals($0, expected) } ?? false } ?? true
        let isCallback = parts.first == "GET" && (params["code"] != nil || params["error"] != nil) && stateMatches
        let status: String
        let body: String
        if isCallback {
            status = "200 OK"
            body = Self.page(success: params["error"] == nil, language: language)
            finish(.success(params))
        } else {
            status = "404 Not Found"
            body = "Not found"
        }
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(isCallback ? "text/html" : "text/plain"); charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The page the browser shows after the redirect (es/en, follows the system's light/dark mode).
    public static func page(success: Bool, language: String) -> String {
        let l = Lang(language)
        let title = success ? l.t("✓ Listo, ya puedes volver a SecondBrain", "✓ Done, you can go back to SecondBrain")
            : l.t("No se pudo conectar", "Couldn't connect")
        let message = success ? l.t("Puedes cerrar esta pestaña.", "You can close this tab.")
            : l.t("Vuelve a SecondBrain para ver qué pasó y cómo seguir.", "Go back to SecondBrain to see what happened and what to do next.")
        return """
        <!doctype html><html lang="\(l.en ? "en" : "es")"><head><meta charset="utf-8"><title>SecondBrain</title>
        <meta name="viewport" content="width=device-width,initial-scale=1"><style>
        :root{color-scheme:light dark}body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
        font:16px -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;background:Canvas;color:CanvasText}
        main{text-align:center;padding:32px}h1{font-size:24px;font-weight:600;margin:0 0 8px}p{opacity:.65;margin:0}
        </style></head><body><main><h1>\(title)</h1><p>\(message)</p></main></body></html>
        """
    }
}
