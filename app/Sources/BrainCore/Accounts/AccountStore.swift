import Foundation
import Observation

/// Connected Microsoft 365 / Google accounts and the Mac Calendar (CONTRACT §12.3, §12.7). The list lives in
/// `data/accounts.json`; OAuth tokens go to the Keychain (never to disk in plain text). The Mac Calendar ("local:calendar")
/// has no tokens: it only needs the system permission.
///
/// With `SB_DEMO_ACCOUNTS=1` the store starts with two demo accounts backed by `DemoProvider` (nothing is written to
/// disk and no browser is opened).
@MainActor @Observable public final class AccountStore {
    public private(set) var accounts: [ConnectedAccount] = []
    /// Accounts whose refresh token stopped working (revoked, password change, admin policy): the UI offers
    /// "Vuelve a iniciar sesión". Cleared by a successful `connect`.
    public private(set) var needsSignIn: Set<String> = []
    /// `SB_DEMO_ACCOUNTS=1`: fake accounts and data for snapshots and UX review.
    public let isDemo: Bool
    @ObservationIgnored public private(set) var fileURL: URL
    @ObservationIgnored private var providers: [String: MailCalendarProvider] = [:]
    /// Called after an account is added (the engine adds its address to "Tus correos").
    @ObservationIgnored public var onConnected: ((ConnectedAccount) -> Void)?
    /// Where tokens live (Keychain in the app; memory in tests).
    @ObservationIgnored public var tokenStorage: TokenStorage = KeychainTokenStore()
    /// The network (tests inject fixtures).
    @ObservationIgnored public var transport: HTTPTransport = HTTP.urlSession
    /// The app registration used to refresh tokens (env > config > compiled defaults).
    @ObservationIgnored public var registration: () -> OAuthAppRegistration = { OAuthAppRegistration.effective(config: AppConfig.load()) }

    public nonisolated static var demoRequested: Bool { ProcessInfo.processInfo.environment["SB_DEMO_ACCOUNTS"] == "1" }

    public init(fileURL: URL, demo: Bool = AccountStore.demoRequested) {
        self.fileURL = fileURL
        self.isDemo = demo
        load()
    }

    public var hasAccounts: Bool { !accounts.isEmpty }
    /// Accounts with mail (Microsoft / Google).
    public var mailAccounts: [ConnectedAccount] { accounts.filter { $0.provider.hasMail } }
    /// Every account with a calendar (all of them, including the Mac Calendar).
    public var calendarAccounts: [ConnectedAccount] { accounts }
    public var hasLocalCalendar: Bool { accounts.contains { $0.provider == .local } }

    public func account(id: String) -> ConnectedAccount? { accounts.first { $0.id == id } }

    /// Signs in with the system browser (OAuth 2.0 Authorization Code + PKCE, loopback redirect) and adds the account;
    /// `.local` asks for the Calendar permission instead. Throws `AccountError.notConfigured` without a client id,
    /// `.cancelled`, `.consentRequired` (organization policy). Cancel by cancelling the calling task.
    public func connect(_ provider: AccountProvider, registration: OAuthAppRegistration,
                        openURL: @escaping @Sendable (URL) -> Void) async throws -> ConnectedAccount {
        if isDemo {
            try await Task.sleep(for: .milliseconds(600))
            let account = DemoProvider.demoAccount(provider)
            upsert(account)
            return account
        }
        if provider == .local { return try await connectLocalCalendar() }

        let endpoint = try OAuthEndpoint.make(provider, registration: registration)
        let language = AppConfig.load().uiLanguage
        let transport = self.transport
        let tokens = try await OAuthClient.authorize(endpoint, language: language, transport: transport, openURL: openURL)
        try Task.checkCancellation()

        // Who signed in: ask the API with the fresh token (nothing is stored until we know the address).
        let pending = ConnectedAccount(provider: provider, email: "pending", scopes: provider.scopes)
        let manager = TokenManager(key: "pending", provider: provider, endpoint: endpoint, storage: MemoryTokenStore(),
                                   transport: transport, initial: tokens)
        let profile = try await Self.makeProvider(pending, tokens: manager, transport: transport).profile()
        var account = profile
        account.scopes = tokens.scope.isEmpty ? provider.scopes : tokens.scope.split(separator: " ").map(String.init)
        try tokenStorage.save(tokens, for: KeychainTokenStore.key(for: account))
        needsSignIn.remove(account.id)
        upsert(account)
        Log.info("connected \(provider.rawValue) account")
        onConnected?(account)
        return account
    }

    private func connectLocalCalendar() async throws -> ConnectedAccount {
        guard try await LocalCalendarProvider.requestAccess() else {
            throw AccountError.failed(LocalCalendarProvider.noAccessMessage)
        }
        let account = account(id: LocalCalendarProvider.accountId) ?? LocalCalendarProvider.makeAccount()
        upsert(account)
        return account
    }

    /// Forgets the account and its tokens.
    public func disconnect(_ id: String) throws {
        if let account = account(id: id), account.provider.needsOAuth, !isDemo {
            tokenStorage.delete(KeychainTokenStore.key(for: account))
        }
        accounts.removeAll { $0.id == id }
        providers[id] = nil
        needsSignIn.remove(id)
        try save()
    }

    /// Mail and calendar of `account`; the provider refreshes its tokens on its own.
    public func provider(for account: ConnectedAccount) -> MailCalendarProvider {
        if let cached = providers[account.id] { return cached }
        let provider: MailCalendarProvider
        if isDemo {
            provider = DemoProvider(account: account, language: AppConfig.load().uiLanguage)
        } else if account.provider == .local {
            provider = LocalCalendarProvider(account: account)
        } else {
            let id = account.id
            let manager = TokenManager(
                key: KeychainTokenStore.key(for: account), provider: account.provider,
                endpoint: try? OAuthEndpoint.make(account.provider, registration: registration()),
                storage: tokenStorage, transport: transport,
                onReauthRequired: { [weak self] in Task { @MainActor in self?.markNeedsSignIn(id) } })
            provider = Self.makeProvider(account, tokens: manager, transport: transport)
        }
        providers[account.id] = provider
        return provider
    }

    static func makeProvider(_ account: ConnectedAccount, tokens: TokenManager, transport: @escaping HTTPTransport) -> MailCalendarProvider {
        let api = APIClient(provider: account.provider, tokens: tokens, transport: transport)
        switch account.provider {
        case .microsoft: return MicrosoftGraphProvider(account: account, api: api)
        case .google: return GoogleProvider(account: account, api: api)
        case .local: return LocalCalendarProvider(account: account)
        }
    }

    public func markNeedsSignIn(_ id: String) {
        guard account(id: id) != nil, !needsSignIn.contains(id) else { return }
        needsSignIn.insert(id)
        providers[id] = nil
    }

    /// The data folder moved (`BrainEngine.reload`): read the list from the new place.
    public func reload(fileURL: URL) {
        self.fileURL = fileURL
        providers = [:]
        needsSignIn = []
        load()
    }

    // MARK: Persistence

    /// Adds or replaces (same id) an account and saves the list.
    public func upsert(_ account: ConnectedAccount) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        providers[account.id] = nil
        do { try save() } catch { Log.error("could not save accounts: \(error)") }
    }

    private func load() {
        if isDemo {
            accounts = [DemoProvider.demoAccount(.microsoft), DemoProvider.demoAccount(.google)]
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else { accounts = []; return }
        do {
            accounts = try JSONDecoder.sb.decode([ConnectedAccount].self, from: data)
        } catch {
            Log.error("could not read \(fileURL.lastPathComponent): \(error)")
            accounts = []
        }
    }

    private func save() throws {
        guard !isDemo else { return }   // demo accounts never touch the user's data folder
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.sb.encode(accounts).write(to: fileURL, options: .atomic)
    }
}

public extension BrainEngine {
    /// After connecting an account: its address joins "Tus correos" (people/README.md) if it wasn't there, so mail
    /// from it counts as the owner's (CONTRACT §12.3).
    func rememberOwnerEmail(of account: ConnectedAccount) {
        guard account.provider.hasMail, account.email.contains("@") else { return }
        let current = vault.ownerEmails()
        guard !current.contains(account.email.lowercased()) else { return }
        do { try vault.setOwnerEmails(current + [account.email.lowercased()]) } catch {
            Log.error("could not add the account address to the owner's emails: \(error)")
        }
    }
}
