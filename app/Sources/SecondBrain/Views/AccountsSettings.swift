import AppKit
import BrainCore
import SwiftUI

/// Ajustes → Cuentas (CONTRACT §12.3, §12.7, §15.2): connected accounts with avatar tokens, "Conectar otra cuenta ▾"
/// once one exists, the read-only promise and the help link; plus the Claude account. The OAuth client ids live in
/// Avanzado.
struct AccountsSettingsPage: View {
    @Environment(AppState.self) private var state
    @ViewState private var connector = AccountConnector()
    @ViewState private var help: OrgHelpRequest?
    @ViewState private var pendingDisconnect: ConnectedAccount?
    @ViewState private var showReconnect = false
    @ViewState private var claudeConnected: Bool?

    var body: some View {
        let store = state.engine.accounts
        SettingsPage {
            SettingsGroup(title: L("settings.group.mailCalendar")) {
                if store.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("accounts.none"))
                            .foregroundStyle(Brand.color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        ConnectAccountControls(connector: connector, help: $help, context: .settings)
                    }
                    .padding(14)
                } else {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { SettingsDivider(inset: 52) }
                        AccountRow(account: account, needsSignIn: store.needsSignIn.contains(account.id),
                                   onReconnect: { connector.start(account.provider, state: state) },
                                   onDisconnect: { pendingDisconnect = account })
                    }
                    SettingsDivider()
                    ConnectAccountControls(connector: connector, help: $help, context: .settings, compact: true)
                        .padding(14)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L("readonly.promise"), systemImage: "lock.shield")
                    Button(L("accounts.troubleConnecting")) { help = OrgHelpRequest(provider: nil) }
                        .buttonStyle(.settingsLink)
                }
            }

            SettingsGroup(title: L("settings.claude")) {
                SettingsRow(title: L("claude.reconnectTitle"), detail: claudeStatus) {
                    Button(L("chat.reconnect")) { showReconnect = true }
                        .buttonStyle(.brandSecondary)
                }
            }
        }
        .sheet(item: $help) { request in OrgAccessHelpSheet(provider: request.provider) }
        .sheet(isPresented: $showReconnect, onDismiss: refreshClaude) { ReconnectClaudeSheet() }
        .confirmationDialog(L("settings.disconnect.confirm", pendingDisconnect.map(Self.name) ?? ""),
                            isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } })) {
            Button(L("accounts.disconnect"), role: .destructive) {
                if let account = pendingDisconnect {
                    do { try state.disconnectAccount(account.id) } catch { connector.error = FriendlyError.message(error) }
                }
                pendingDisconnect = nil
            }
        } message: {
            Text(L("settings.disconnect.message"))
        }
        .task { refreshClaude() }
    }

    /// "Conectada" only when the app holds the token. Without it Claude may still work through the CLI's own login,
    /// so nothing is claimed (checking for real costs a Claude call).
    private var claudeStatus: String? {
        claudeConnected == true ? L("settings.claude.connected") : nil
    }

    private func refreshClaude() {
        claudeConnected = ClaudeSetup.loadToken() != nil
    }

    static func name(_ account: ConnectedAccount) -> String {
        account.provider == .local ? L("accounts.macCalendar") : account.email
    }
}

/// Where the connect controls live: decides whether "Usar el calendario de la Mac" is offered.
enum ConnectContext {
    case settings, mail, meetings, onboarding

    var offersMacCalendar: Bool { self != .mail }
}

/// One step of the connect sheet: trust → waiting for the browser → done, or the blocked fork / a plain failure.
enum ConnectPhase: Equatable {
    case trust
    case waiting
    case blocked(AccountBlockReason)
    case failed(String)
}

enum AccountBlockReason: Equatable {
    /// The organization has to approve SecondBrain (AADSTS65001, org_internal, …).
    case consent
    /// No client id for this provider yet (nobody registered the app).
    case notRegistered
}

struct ConnectFlow: Identifiable {
    let id = UUID()
    var provider: AccountProvider
    var phase: ConnectPhase
}

/// Drives the whole "Conectar …" flow (CONTRACT §12.7): trust sheet → browser → result → blocked fork on
/// `consentRequired` / `notConfigured`. The Mac Calendar skips the sheet: one system permission, inline.
@MainActor @Observable
final class AccountConnector {
    /// The connect sheet (nil = closed).
    var flow: ConnectFlow?
    /// Inline error (Mac Calendar permission, disconnect).
    var error: String?
    /// The Mac Calendar permission was refused: offer System Settings.
    private(set) var calendarDenied = false
    private(set) var connectingLocal = false
    /// Last account connected here ("✓ Conectado: ana@contoso.com").
    private(set) var lastConnected: ConnectedAccount?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var browserURL: URL?

    init(preview: ConnectFlow? = nil) { flow = preview }

    /// Entry point of every "Conectar …" button.
    func start(_ provider: AccountProvider, state: AppState) {
        error = nil
        calendarDenied = false
        if provider == .local { connectMacCalendar(state: state); return }
        let configured = state.engine.accounts.isDemo || OAuthAppRegistration.effective(config: state.config).isConfigured(provider)
        flow = ConnectFlow(provider: provider, phase: configured ? .trust : .blocked(.notRegistered))
    }

    /// "Continuar en el navegador".
    func continueInBrowser(state: AppState) {
        guard let provider = flow?.provider else { return }
        flow?.phase = .waiting
        task?.cancel()
        task = Task { [weak self] in
            do {
                let account = try await state.connectAccount(provider) { url in
                    Task { @MainActor in self?.browserURL = url }
                }
                guard let self, !Task.isCancelled else { return }
                lastConnected = account
                OwnerAddresses.merge(state: state)   // "Mis direcciones de correo" includes the new account
                flow = nil
            } catch {
                guard let self, !Task.isCancelled, flow != nil else { return }
                flow?.phase = Self.phase(for: error)
            }
        }
    }

    /// "¿No se abrió? Abrir de nuevo".
    func reopenBrowser() {
        if let browserURL { NSWorkspace.shared.open(browserURL) }
    }

    /// Cancelar / closing the sheet: stops the loopback wait, nothing is stored.
    func cancel() {
        task?.cancel()
        task = nil
        browserURL = nil
        flow = nil
    }

    func retry() { flow?.phase = .trust }

    static func phase(for error: Error) -> ConnectPhase {
        switch error {
        case AccountError.notConfigured: return .blocked(.notRegistered)
        case AccountError.consentRequired: return .blocked(.consent)
        case AccountError.cancelled, is CancellationError: return .failed(L("accounts.cancelled"))
        default: return .failed(FriendlyError.message(error))
        }
    }

    private func connectMacCalendar(state: AppState) {
        connectingLocal = true
        Task {
            defer { connectingLocal = false }
            do {
                lastConnected = try await state.connectAccount(.local) { _ in }
            } catch {
                self.error = FriendlyError.message(error)
                calendarDenied = !state.engine.accounts.isDemo && LocalCalendarProvider.isDenied
            }
        }
    }
}

extension AppState {
    /// `connectAccount` with the authorize URL reported back (for "Abrir de nuevo"). Opens the browser itself.
    @discardableResult
    func connectAccount(_ provider: AccountProvider, onBrowserURL: @escaping @Sendable (URL) -> Void) async throws -> ConnectedAccount {
        let registration = OAuthAppRegistration.effective(config: config)
        let account = try await engine.accounts.connect(provider, registration: registration) { url in
            onBrowserURL(url)
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        accountsRevision += 1
        return account
    }
}

/// The connect buttons and the connect sheet. The single entry point other views use (Correo, Reuniones, Ajustes,
/// onboarding): it runs trust → browser → result → blocked fork. `compact`: one "Conectar otra cuenta ▾" menu (Ajustes,
/// once an account exists).
struct ConnectAccountControls: View {
    @Environment(AppState.self) private var state
    let connector: AccountConnector
    @Binding var help: OrgHelpRequest?
    var centered = false
    var context: ConnectContext = .settings
    var compact = false

    private var includeMacCalendar: Bool { context.offersMacCalendar && !state.engine.accounts.hasLocalCalendar }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            if compact {
                Menu {
                    Button(L("accounts.connectMicrosoft")) { connector.start(.microsoft, state: state) }
                    Button(L("accounts.connectGoogle")) { connector.start(.google, state: state) }
                    if includeMacCalendar {
                        Button(L("accounts.useMacCalendar")) { connector.start(.local, state: state) }
                    }
                } label: {
                    SettingsMenuLabel(title: L("settings.addAccount"), symbol: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(connector.connectingLocal)
            } else {
                ConnectAccountButtons(includeMacCalendar: includeMacCalendar, busyLocal: connector.connectingLocal,
                                      centered: centered, macCalendarFirst: context == .meetings) { connector.start($0, state: state) }
            }
            if let account = connector.lastConnected, connector.error == nil {
                Label(L("accounts.connected", account.provider == .local ? L("accounts.macCalendar") : account.email),
                      systemImage: "checkmark.circle")
                    .foregroundStyle(Brand.color.success)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let error = connector.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.color.warning)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if connector.calendarDenied {
                    Button(L("accounts.openCalendarSettings")) { MacCalendarSettings.open() }
                        .buttonStyle(.brandSecondary)
                }
            }
        }
        .sheet(item: Bindable(connector).flow) { _ in
            TrustSheet(connector: connector, context: context)
        }
    }
}

enum MacCalendarSettings {
    static func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Empty state of Correo and Reuniones without accounts: one sentence and the connect buttons. In Reuniones (a
/// calendar symbol, or `context: .meetings`) it also offers the Mac Calendar.
struct ConnectAccountsEmptyState: View {
    var symbol: String
    var title: String
    var message: String
    /// Optional extra action under the buttons (Correo: "o pega un correo").
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var context: ConnectContext? = nil
    @ViewState private var connector = AccountConnector()
    @ViewState private var help: OrgHelpRequest?

    private var resolvedContext: ConnectContext { context ?? (symbol.hasPrefix("calendar") ? .meetings : .mail) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(Brand.font(36))
                .foregroundStyle(Brand.color.text3)
            Text(title)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .foregroundStyle(Brand.color.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            ConnectAccountControls(connector: connector, help: $help, centered: true, context: resolvedContext)
                .padding(.top, 4)
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(.settingsLink)
            }
            Label(L("readonly.promise"), systemImage: "lock.shield")
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $help) { request in OrgAccessHelpSheet(provider: request.provider) }
    }
}

struct OrgHelpRequest: Identifiable {
    let id = UUID()
    var provider: AccountProvider?
}

/// "Conectar Microsoft 365" · "Conectar Google" (· "Usar el calendario de la Mac").
struct ConnectAccountButtons: View {
    var includeMacCalendar = false
    var busyLocal = false
    var centered = false
    /// Reuniones: the Mac calendar (always available, one click) is the primary action; accounts come second.
    var macCalendarFirst = false
    var onConnect: (AccountProvider) -> Void

    var body: some View {
        if macCalendarFirst && includeMacCalendar {
            VStack(alignment: centered ? .center : .leading, spacing: 10) {
                macCalendarButton
                    .buttonStyle(.brandPrimary)
                    .controlSize(.large)
                Text(L("accounts.orConnect")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { oauthButtons }
                    VStack(alignment: centered ? .center : .leading, spacing: 8) { oauthButtons }
                }
            }
        } else {
            allButtons
        }
    }

    private var allButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { oauthButtons; macCalendarButton.buttonStyle(.brandSecondary) }
            VStack(alignment: centered ? .center : .leading, spacing: 8) {
                HStack(spacing: 10) { oauthButtons }
                macCalendarButton.buttonStyle(.brandSecondary)
            }
            VStack(alignment: centered ? .center : .leading, spacing: 8) { oauthButtons; macCalendarButton.buttonStyle(.brandSecondary) }
        }
    }

    @ViewBuilder private var oauthButtons: some View {
        ForEach([AccountProvider.microsoft, .google], id: \.self) { provider in
            Button {
                onConnect(provider)
            } label: {
                // The same "M" / "G" tokens as the account rows and the trust sheet.
                ButtonContent(text: L(provider == .microsoft ? "accounts.connectMicrosoft" : "accounts.connectGoogle")) {
                    ProviderBadge(provider: provider, size: 16)
                }
            }
            .buttonStyle(.brandSecondary)
        }
    }

    @ViewBuilder private var macCalendarButton: some View {
        if includeMacCalendar {
            Button {
                onConnect(.local)
            } label: {
                // Same anatomy as the OAuth buttons (16 pt icon box), so the three labels share one baseline.
                ButtonContent(text: L("accounts.useMacCalendar")) {
                    if busyLocal {
                        BrandLoader(size: 14)
                    } else {
                        Image(systemName: AccountProvider.local.symbol).imageScale(.medium)
                    }
                }
            }
            .disabled(busyLocal)
        }
    }

    private struct ButtonContent<Icon: View>: View {
        let text: String
        @ViewBuilder var icon: Icon

        var body: some View {
            HStack(spacing: 6) {
                icon.frame(width: 16, height: 16)
                Text(text)
            }
        }
    }
}

private struct AccountRow: View {
    let account: ConnectedAccount
    var needsSignIn = false
    var onReconnect: () -> Void
    var onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProviderBadge(provider: account.provider, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.provider == .local ? L("accounts.macCalendar") : account.email)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if needsSignIn {
                        Text(L("accounts.needsSignIn")).foregroundStyle(Brand.color.warning)
                    } else if account.provider == .local {
                        Text(L("accounts.macCalendar.detail"))
                    } else {
                        Text(account.displayName.map { "\($0) · \(account.provider.displayName)" } ?? account.provider.displayName)
                    }
                }
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if needsSignIn {
                Button(L("accounts.signInAgain"), action: onReconnect).buttonStyle(.brandPrimary)
            }
            Button(L("accounts.disconnect") + "…", action: onDisconnect).buttonStyle(.brandSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Avatar token for an account: `cardAlt` circle with the provider's initial (or a calendar glyph) in `text2`. No
/// trademarked logos, no provider colors (CONTRACT §15.1).
struct ProviderBadge: View {
    let provider: AccountProvider
    var size: CGFloat = 26

    var body: some View {
        Group {
            switch provider {
            case .local:
                Image(systemName: "calendar").font(Brand.font(size * 0.46, .medium))
            case .microsoft, .google:
                Text(verbatim: provider == .microsoft ? "M" : "G").font(Brand.font(size * 0.46, .semibold))
            }
        }
        .foregroundStyle(Brand.avatar.initials)
        .frame(width: size, height: size)
        .background(Brand.avatar.background, in: Circle())
        .accessibilityLabel(provider == .local ? L("accounts.macCalendar") : provider.displayName)
    }
}

extension AccountProvider {
    var symbol: String {
        switch self {
        case .microsoft, .google: "person.crop.circle.badge.plus"
        case .local: "calendar"
        }
    }

    /// Kept for source compatibility: every provider uses the calm avatar tone now.
    var tint: Color { Brand.color.sage }

    /// "Microsoft 365" / "Google" / "Calendario de la Mac" in the UI language.
    var localizedName: String { self == .local ? L("accounts.macCalendar") : displayName }
}

/// Ajustes → Avanzado: the user's own OAuth client ids (§12.3 "Soy técnico") for Microsoft, Google and GitHub.
struct AdvancedOAuthFields: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(L("accounts.msClientId"), text: binding(\.microsoftClientId))
            field(L("accounts.googleClientId"), text: binding(\.googleClientId))
            field(L("accounts.googleClientSecret"), text: binding(\.googleClientSecret), secure: true)
            field(L("github.clientId"), text: binding(\.githubClientId))
        }
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Brand.caption).foregroundStyle(Brand.color.text2)
            Group {
                if secure { SecureField("", text: text) } else { TextField("", text: text) }
            }
            .textFieldStyle(.roundedBorder)
            .font(Brand.mono)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<OAuthAppRegistration, String?>) -> Binding<String> {
        Binding(get: { state.config.oauth[keyPath: keyPath] ?? "" }, set: { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            state.update { $0.oauth[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed }
        })
    }
}
