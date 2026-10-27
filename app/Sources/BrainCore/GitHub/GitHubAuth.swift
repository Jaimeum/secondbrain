import Foundation
import Security

/// Where the GitHub token lives. The app uses the Keychain; tests use memory.
public protocol GitHubCredentialStorage: Sendable {
    func load() -> GitHubCredential?
    func save(_ credential: GitHubCredential) throws
    func delete()
}

/// Keychain storage (generic password, service "app.secondbrain.mac", account "github-token", JSON `GitHubCredential`).
public struct KeychainGitHubCredentialStore: GitHubCredentialStorage {
    public static let account = "github-token"
    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: KeychainTokenStore.service,
         kSecAttrAccount as String: Self.account]
    }

    public func load() -> GitHubCredential? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder.sb.decode(GitHubCredential.self, from: data)
    }

    public func save(_ credential: GitHubCredential) throws {
        let data = try JSONEncoder.sb.encode(credential)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw GitHubError.failed("Keychain error \(update)") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "SecondBrain (GitHub)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw GitHubError.failed("Keychain error \(status)") }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// In-memory storage (self-tests, demo).
public final class MemoryGitHubCredentialStore: GitHubCredentialStorage, @unchecked Sendable {
    private var value: GitHubCredential?
    private let lock = NSLock()
    public init(_ value: GitHubCredential? = nil) { self.value = value }
    public func load() -> GitHubCredential? { lock.withLock { value } }
    public func save(_ credential: GitHubCredential) throws { lock.withLock { value = credential } }
    public func delete() { lock.withLock { value = nil } }
}

/// Ways to get a GitHub token (CONTRACT §13.1): OAuth device flow of SecondBrain's GitHub OAuth App, the GitHub CLI's
/// own session (`gh auth token`), a pasted personal token, or `SB_GITHUB_TOKEN`.
public enum GitHubAuth {
    /// GitHub has no "read-only private repos" scope; the app only ever sends `GET`.
    public static let scopes = "repo read:org read:user user:email"
    public static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    public static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    public static let personalTokenHelpURL = URL(string: "https://github.com/settings/personal-access-tokens/new")!

    /// Saved token first, then `SB_GITHUB_TOKEN`.
    public static func resolveToken(storage: GitHubCredentialStorage = KeychainGitHubCredentialStore(),
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> GitHubCredential? {
        if let saved = storage.load(), !saved.token.isEmpty { return saved }
        if let env = environment["SB_GITHUB_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return GitHubCredential(token: env, method: .environment)
        }
        return nil
    }

    /// The OAuth App client id: env `SB_GITHUB_CLIENT_ID`, then Ajustes → GitHub → Avanzado, then the bundled default.
    public static func clientId(config: AppConfig, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        OAuthAppRegistration.effective(config: config, environment: environment).githubClientId.nonEmpty
    }

    // MARK: Device flow

    /// Step 1: asks GitHub for a user code to type at `verificationURI`.
    public static func requestDeviceCode(clientId: String, transport: HTTPTransport = HTTP.urlSession, now: Date = Date()) async throws -> GitHubDeviceCode {
        guard !clientId.isEmpty else { throw GitHubError.notConfigured }
        let (data, http) = try await send(HTTP.formRequest(deviceCodeURL, [("client_id", clientId), ("scope", scopes)]), transport)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = obj["error"] as? String {
            if error == "device_flow_disabled" || error == "unauthorized_client" || error == "incorrect_client_credentials" {
                throw GitHubError.notConfigured
            }
            throw GitHubError.failed([error, obj["error_description"] as? String].compactMap { $0 }.joined(separator: ": "))
        }
        guard (200..<300).contains(http.statusCode),
              let device = obj["device_code"] as? String, let user = obj["user_code"] as? String,
              let uri = (obj["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            if http.statusCode == 404 || http.statusCode == 401 { throw GitHubError.notConfigured }
            throw GitHubError.failed("GitHub device code: HTTP \(http.statusCode)")
        }
        let expires = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 900
        let interval = (obj["interval"] as? NSNumber)?.intValue ?? 5
        return GitHubDeviceCode(deviceCode: device, userCode: user, verificationURI: uri,
                                expiresAt: now.addingTimeInterval(expires), interval: max(1, interval))
    }

    /// Step 2: polls every `interval` seconds until the user approves (or denies, or the code expires). Respects
    /// `slow_down` (+5 s, or GitHub's new interval). Cancel by cancelling the calling task.
    public static func pollForToken(_ code: GitHubDeviceCode, clientId: String, transport: HTTPTransport = HTTP.urlSession,
                                    sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                                    now: @Sendable () -> Date = { Date() }) async throws -> GitHubCredential {
        var interval = TimeInterval(code.interval)
        while true {
            try Task.checkCancellation()
            if now() >= code.expiresAt { throw GitHubError.deviceFlowExpired }
            try await sleep(interval)
            let request = HTTP.formRequest(accessTokenURL, [("client_id", clientId), ("device_code", code.deviceCode),
                                                            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")])
            let (data, _) = try await send(request, transport)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let token = obj["access_token"] as? String, !token.isEmpty {
                let scopes = ((obj["scope"] as? String) ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                return GitHubCredential(token: token, method: .deviceFlow, scopes: scopes)
            }
            switch obj["error"] as? String {
            case "authorization_pending": continue
            case "slow_down":
                interval = (obj["interval"] as? NSNumber).map { TimeInterval($0.intValue) } ?? interval + 5
            case "expired_token": throw GitHubError.deviceFlowExpired
            case "access_denied": throw GitHubError.deviceFlowDenied
            case "device_flow_disabled", "incorrect_client_credentials", "unsupported_grant_type": throw GitHubError.notConfigured
            case let other?: throw GitHubError.failed([other, obj["error_description"] as? String].compactMap { $0 }.joined(separator: ": "))
            case nil: throw GitHubError.failed("GitHub returned no token")
            }
        }
    }

    private static func send(_ request: URLRequest, _ transport: HTTPTransport) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport(request) } catch let error as AccountError {
            if case .network(let msg) = error { throw GitHubError.network(msg) }
            throw GitHubError.network(error.localizedDescription)
        }
    }

    // MARK: GitHub CLI

    /// `gh` in Homebrew's folders, else whatever a login shell finds.
    public static func locateGH() -> URL? {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let out = try? run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v gh"]), out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
        return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// The token of the user's `gh` session (`gh auth token`). Throws `.notConnected` when gh is missing or logged out.
    public static func ghCLIToken() throws -> String {
        guard let gh = locateGH() else { throw GitHubError.notConnected }
        let out = try run(gh, ["auth", "token"])
        let token = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.status == 0, !token.isEmpty, !token.contains(" ") else { throw GitHubError.notConnected }
        return token
    }

    static func run(_ binary: URL, _ args: [String], timeout: TimeInterval = 15) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"] + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension GitHubError: LocalizedError {
    public var errorDescription: String? {
        let lang = Lang(AppConfig.load().uiLanguage)
        switch self {
        case .notConnected: return lang.t("GitHub no está conectado.", "GitHub isn't connected.")
        case .notConfigured:
            return lang.t("Falta configurar la app de GitHub de SecondBrain (client id).", "SecondBrain's GitHub app isn't set up yet (client id).")
        case .unauthorized: return lang.t("Vuelve a conectar GitHub.", "Connect GitHub again.")
        case .rateLimited(let reset):
            let when = reset.map { Fmt.local($0, "HH:mm") }
            return when.map { lang.t("GitHub llegó a su límite de uso. Sigo a las \($0).", "GitHub hit its rate limit. Resuming at \($0).") }
                ?? lang.t("GitHub llegó a su límite de uso. Inténtalo más tarde.", "GitHub hit its rate limit. Try again later.")
        case .orgRestricted(let org):
            let name = org.map { "«\($0)»" } ?? lang.t("tu organización", "your organization")
            return lang.t("La organización \(name) tiene que aprobar SecondBrain en GitHub.", "The \(org ?? "organization") needs to approve SecondBrain on GitHub.")
        case .notFound(let what): return lang.t("No encontré eso en GitHub (o no tienes acceso): \(what)", "Not found on GitHub (or no access): \(what)")
        case .deviceFlowExpired: return lang.t("El código expiró. Vuelve a intentarlo.", "The code expired. Try again.")
        case .deviceFlowDenied: return lang.t("Se canceló la conexión con GitHub.", "The GitHub connection was cancelled.")
        case .network(let msg): return lang.t("No pude conectarme a GitHub: \(msg)", "I couldn't reach GitHub: \(msg)")
        case .failed(let msg): return msg
        }
    }
}
