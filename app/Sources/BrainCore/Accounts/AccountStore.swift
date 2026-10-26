import Foundation
import Observation

/// Connected Microsoft 365 / Google accounts (CONTRACT §12.3). The list lives in `data/accounts.json`; tokens go to
/// the Keychain (never to disk in plain text).
///
/// SKELETON (v0.3): `connect` and the real providers are stubs for the accounts engineer. With `SB_DEMO_ACCOUNTS=1`
/// the store starts with two demo accounts backed by `DemoProvider` (nothing is written to disk).
@MainActor @Observable public final class AccountStore {
    public private(set) var accounts: [ConnectedAccount] = []
    /// `SB_DEMO_ACCOUNTS=1`: fake accounts and data for snapshots and UX review.
    public let isDemo: Bool
    @ObservationIgnored public private(set) var fileURL: URL
    @ObservationIgnored private var providers: [String: MailCalendarProvider] = [:]

    public nonisolated static var demoRequested: Bool { ProcessInfo.processInfo.environment["SB_DEMO_ACCOUNTS"] == "1" }

    public init(fileURL: URL, demo: Bool = AccountStore.demoRequested) {
        self.fileURL = fileURL
        self.isDemo = demo
        load()
    }

    public var hasAccounts: Bool { !accounts.isEmpty }

    public func account(id: String) -> ConnectedAccount? { accounts.first { $0.id == id } }

    /// Signs in with the system browser (OAuth 2.0 Authorization Code + PKCE, loopback redirect) and adds the account.
    /// Throws `AccountError.notConfigured` without a client id, `.cancelled`, `.consentRequired` (organization policy).
    public func connect(_ provider: AccountProvider, registration: OAuthAppRegistration,
                        openURL: @escaping @Sendable (URL) -> Void) async throws -> ConnectedAccount {
        if isDemo {
            try await Task.sleep(for: .milliseconds(600))
            let account = DemoProvider.demoAccount(provider)
            upsert(account)
            return account
        }
        // TODO(accounts engineer): OAuthFlow (PKCE + loopback), token exchange, Keychain, profile(), upsert.
        throw AccountError.notConfigured(provider)
    }

    /// Forgets the account and its tokens.
    public func disconnect(_ id: String) throws {
        accounts.removeAll { $0.id == id }
        providers[id] = nil
        // TODO(accounts engineer): delete the Keychain tokens of `id`.
        try save()
    }

    /// Mail and calendar of `account`; the provider refreshes its tokens on its own.
    public func provider(for account: ConnectedAccount) -> MailCalendarProvider {
        if let cached = providers[account.id] { return cached }
        let provider: MailCalendarProvider = isDemo
            ? DemoProvider(account: account, language: AppConfig.load().uiLanguage)
            : UnavailableProvider(account: account)   // TODO(accounts engineer): GraphProvider / GoogleProvider
        providers[account.id] = provider
        return provider
    }

    /// The data folder moved (`BrainEngine.reload`): read the list from the new place.
    public func reload(fileURL: URL) {
        self.fileURL = fileURL
        providers = [:]
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

/// Placeholder until the real Microsoft Graph / Google providers exist: every call says the account must be reconnected.
final class UnavailableProvider: MailCalendarProvider {
    let account: ConnectedAccount
    init(account: ConnectedAccount) { self.account = account }
    func profile() async throws -> ConnectedAccount { throw AccountError.notConfigured(account.provider) }
    func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        throw AccountError.notConfigured(account.provider)
    }
    func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        throw AccountError.notConfigured(account.provider)
    }
    func fetchMessage(id: String) async throws -> MailMessageFull { throw AccountError.notConfigured(account.provider) }
    func fetchThread(id: String) async throws -> [MailMessageFull] { throw AccountError.notConfigured(account.provider) }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { throw AccountError.notConfigured(account.provider) }
}
