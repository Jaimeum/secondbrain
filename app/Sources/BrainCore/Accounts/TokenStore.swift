import Foundation
import Security

/// Where OAuth tokens live. The app uses the Keychain; tests use memory.
public protocol TokenStorage: Sendable {
    func load(_ key: String) -> OAuthTokens?
    func save(_ tokens: OAuthTokens, for key: String) throws
    func delete(_ key: String)
}

/// Keychain storage (generic password, service "app.secondbrain.mac", account "oauth-<provider>-<email>", JSON value).
public struct KeychainTokenStore: TokenStorage {
    public static let service = "app.secondbrain.mac"
    public init() {}

    /// "oauth-microsoft-ana@contoso.com".
    public static func key(provider: AccountProvider, email: String) -> String { "oauth-\(provider.rawValue)-\(email.lowercased())" }
    public static func key(for account: ConnectedAccount) -> String { key(provider: account.provider, email: account.email) }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: key]
    }

    public func load(_ key: String) -> OAuthTokens? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder.sb.decode(OAuthTokens.self, from: data)
    }

    public func save(_ tokens: OAuthTokens, for key: String) throws {
        let data = try JSONEncoder.sb.encode(tokens)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AccountError.failed("Keychain error \(update)") }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "SecondBrain (\(key))"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccountError.failed("Keychain error \(status)") }
    }

    public func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

/// In-memory storage (self-tests, demo).
public final class MemoryTokenStore: TokenStorage, @unchecked Sendable {
    private var items: [String: OAuthTokens] = [:]
    private let lock = NSLock()
    public init() {}
    public func load(_ key: String) -> OAuthTokens? { lock.withLock { items[key] } }
    public func save(_ tokens: OAuthTokens, for key: String) throws { lock.withLock { items[key] = tokens } }
    public func delete(_ key: String) { _ = lock.withLock { items.removeValue(forKey: key) } }
}

/// Keeps one account's access token fresh: refreshes when it expires within 2 minutes (one refresh at a time), saves
/// the new tokens, and reports `invalid_grant` (revoked / expired refresh token) so the account shows "Vuelve a
/// iniciar sesión".
public actor TokenManager {
    /// Refresh when the access token expires within this margin.
    public static let refreshMargin: TimeInterval = 120

    public let key: String
    public let provider: AccountProvider
    private let endpoint: OAuthEndpoint?
    private let storage: TokenStorage
    private let transport: HTTPTransport
    private let onReauthRequired: @Sendable () -> Void
    private var tokens: OAuthTokens?
    private var loaded = false
    private var refreshing: Task<OAuthTokens, Error>?

    /// `endpoint` nil = the app registration is missing now: tokens still work until they expire.
    public init(key: String, provider: AccountProvider, endpoint: OAuthEndpoint?, storage: TokenStorage, transport: @escaping HTTPTransport = HTTP.urlSession,
                initial: OAuthTokens? = nil, onReauthRequired: @escaping @Sendable () -> Void = {}) {
        self.key = key
        self.provider = provider
        self.endpoint = endpoint
        self.storage = storage
        self.transport = transport
        self.onReauthRequired = onReauthRequired
        if let initial { tokens = initial; loaded = true }
    }

    /// Whether `tokens` should be refreshed before use.
    public static func shouldRefresh(_ tokens: OAuthTokens, now: Date = Date()) -> Bool {
        tokens.expiresAt.timeIntervalSince(now) < refreshMargin
    }

    /// A valid access token, refreshing first when needed.
    public func accessToken(now: Date = Date()) async throws -> String {
        let current = try currentTokens()
        guard Self.shouldRefresh(current, now: now) else { return current.accessToken }
        return try await refresh(now: now).accessToken
    }

    /// After a 401: refresh even if the clock says the token is still good.
    public func forceRefresh() async throws -> String {
        _ = try currentTokens()
        return try await refresh(now: Date()).accessToken
    }

    public func current() -> OAuthTokens? { try? currentTokens() }

    private func currentTokens() throws -> OAuthTokens {
        if !loaded { tokens = storage.load(key); loaded = true }
        guard let tokens else {
            onReauthRequired()
            throw AccountError.unauthorized
        }
        return tokens
    }

    private func refresh(now: Date) async throws -> OAuthTokens {
        if let refreshing { return try await refreshing.value }
        guard let current = tokens else { throw AccountError.unauthorized }
        guard let endpoint else {
            if current.expiresAt > now { return current }
            throw AccountError.notConfigured(provider)
        }
        let transport = self.transport
        let task = Task { try await OAuthClient.refresh(current, endpoint: endpoint, transport: transport, now: now) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            do { try storage.save(fresh, for: key) } catch { Log.error("could not save refreshed tokens: \(error)") }
            return fresh
        } catch AccountError.unauthorized {
            onReauthRequired()
            throw AccountError.unauthorized
        } catch let error as AccountError {
            if case .consentRequired = error { onReauthRequired() }
            throw error
        }
    }
}
