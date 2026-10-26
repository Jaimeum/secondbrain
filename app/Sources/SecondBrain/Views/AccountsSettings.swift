import AppKit
import BrainCore
import SwiftUI

/// Ajustes → Cuentas (CONTRACT §12.3, §12.7): connected accounts, connect buttons (Microsoft · Google · Mac Calendar),
/// help for organizations, and the advanced client-id fields. Embedded in `SettingsView`'s Form.
struct AccountsSection: View {
    @Environment(AppState.self) private var state
    @ViewState private var connector = AccountConnector()
    @ViewState private var help: OrgHelpRequest?

    var body: some View {
        Section {
            let store = state.engine.accounts
            if store.accounts.isEmpty {
                Text(L("accounts.none")).foregroundStyle(.secondary)
            }
            ForEach(store.accounts) { account in
                AccountRow(account: account, needsSignIn: store.needsSignIn.contains(account.id),
                           onReconnect: { connector.start(account.provider, state: state) }) {
                    do { try state.disconnectAccount(account.id) } catch { connector.error = FriendlyError.message(error) }
                }
            }
            ConnectAccountControls(connector: connector, help: $help, context: .settings)
            AdvancedOAuthFields()
        } header: {
            Text(L("accounts.section"))
        } footer: {
            HStack {
                Label(L("accounts.footer"), systemImage: "lock.shield").foregroundStyle(.secondary)
                Spacer()
                Button(L("accounts.howToEnable")) { help = OrgHelpRequest(provider: nil) }
                    .buttonStyle(.link)
            }
        }
        .sheet(item: $help) { request in OrgAccessHelpSheet(provider: request.provider) }
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
/// onboarding): it runs trust → browser → result → blocked fork.
struct ConnectAccountControls: View {
    @Environment(AppState.self) private var state
    let connector: AccountConnector
    @Binding var help: OrgHelpRequest?
    var centered = false
    var context: ConnectContext = .settings

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            ConnectAccountButtons(includeMacCalendar: context.offersMacCalendar && !state.engine.accounts.hasLocalCalendar,
                                  busyLocal: connector.connectingLocal, centered: centered) { connector.start($0, state: state) }
            if let account = connector.lastConnected, connector.error == nil {
                Label(L("accounts.connected", account.provider == .local ? L("accounts.macCalendar") : account.email),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let error = connector.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if connector.calendarDenied {
                    Button(L("accounts.openCalendarSettings")) { MacCalendarSettings.open() }
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
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            ConnectAccountControls(connector: connector, help: $help, centered: true, context: resolvedContext)
                .padding(.top, 4)
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction).buttonStyle(.link)
            }
            Label(L("accounts.footer"), systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    var onConnect: (AccountProvider) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { oauthButtons; macCalendarButton }
            VStack(alignment: centered ? .center : .leading, spacing: 8) {
                HStack(spacing: 10) { oauthButtons }
                macCalendarButton
            }
            VStack(alignment: centered ? .center : .leading, spacing: 8) { oauthButtons; macCalendarButton }
        }
    }

    @ViewBuilder private var oauthButtons: some View {
        ForEach([AccountProvider.microsoft, .google], id: \.self) { provider in
            Button {
                onConnect(provider)
            } label: {
                Label(L(provider == .microsoft ? "accounts.connectMicrosoft" : "accounts.connectGoogle"), systemImage: provider.symbol)
            }
        }
    }

    @ViewBuilder private var macCalendarButton: some View {
        if includeMacCalendar {
            Button {
                onConnect(.local)
            } label: {
                if busyLocal {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("accounts.useMacCalendar")) }
                } else {
                    Label(L("accounts.useMacCalendar"), systemImage: AccountProvider.local.symbol)
                }
            }
            .disabled(busyLocal)
        }
    }
}

private struct AccountRow: View {
    let account: ConnectedAccount
    var needsSignIn = false
    var onReconnect: () -> Void
    var onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: account.provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.provider == .local ? L("accounts.macCalendar") : account.email)
                Group {
                    if needsSignIn {
                        Text(L("accounts.needsSignIn")).foregroundStyle(.orange)
                    } else if account.provider == .local {
                        Text(L("accounts.macCalendar.detail"))
                    } else {
                        Text(account.displayName.map { "\($0) · \(account.provider.displayName)" } ?? account.provider.displayName)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if needsSignIn {
                Button(L("accounts.signInAgain"), action: onReconnect).buttonStyle(.borderedProminent)
            }
            Button(L("accounts.disconnect"), role: .destructive, action: onDisconnect)
        }
    }
}

/// Round initial (or calendar glyph) with the provider's color (no trademarked logos bundled).
struct ProviderBadge: View {
    let provider: AccountProvider
    var size: CGFloat = 26

    var body: some View {
        Group {
            switch provider {
            case .local:
                Image(systemName: "calendar").font(.system(size: size * 0.48, weight: .semibold))
            case .microsoft, .google:
                Text(provider == .microsoft ? "M" : "G").font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(provider.tint, in: Circle())
        .accessibilityLabel(provider == .local ? L("accounts.macCalendar") : provider.displayName)
    }
}

extension AccountProvider {
    var symbol: String {
        switch self {
        case .microsoft: "envelope.badge"
        case .google: "envelope.circle"
        case .local: "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .microsoft: Color(red: 0.0, green: 0.47, blue: 0.84)
        case .google: Color(red: 0.92, green: 0.26, blue: 0.21)
        case .local: Color(red: 0.98, green: 0.45, blue: 0.16)
        }
    }

    /// "Microsoft 365" / "Google" / "Calendario de la Mac" in the UI language.
    var localizedName: String { self == .local ? L("accounts.macCalendar") : displayName }
}

/// "Avanzado" (folded): the user's own OAuth client ids (§12.3 "Soy técnico").
private struct AdvancedOAuthFields: View {
    @Environment(AppState.self) private var state

    var body: some View {
        DisclosureGroup(L("accounts.advanced")) {
            Text(L("accounts.advanced.hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(L("accounts.msClientId"), text: field(\.microsoftClientId))
            TextField(L("accounts.googleClientId"), text: field(\.googleClientId))
            SecureField(L("accounts.googleClientSecret"), text: field(\.googleClientSecret))
        }
    }

    private func field(_ keyPath: WritableKeyPath<OAuthAppRegistration, String?>) -> Binding<String> {
        Binding(get: { state.config.oauth[keyPath: keyPath] ?? "" }, set: { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            state.update { $0.oauth[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed }
        })
    }
}
