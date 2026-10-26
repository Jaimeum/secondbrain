import AppKit
import BrainCore
import SwiftUI

/// Ajustes → Cuentas (CONTRACT §12.3): connected accounts, connect buttons, help for organizations, and the
/// advanced client-id fields. Embedded in `SettingsView`'s Form.
///
/// SKELETON (v0.3): works end to end with `SB_DEMO_ACCOUNTS=1`; the accounts engineer owns the real sign-in and polish.
struct AccountsSection: View {
    @Environment(AppState.self) private var state
    @ViewState private var connector = AccountConnector()
    @ViewState private var help: OrgHelpRequest?

    var body: some View {
        Section {
            let accounts = state.engine.accounts.accounts
            if accounts.isEmpty {
                Text(L("accounts.none")).foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                AccountRow(account: account) {
                    do { try state.disconnectAccount(account.id) } catch { connector.error = FriendlyError.message(error) }
                }
            }
            ConnectAccountControls(connector: connector, help: $help)
            AdvancedOAuthFields()
        } header: {
            Text(L("accounts.section"))
        } footer: {
            HStack {
                Text(L("accounts.footer")).foregroundStyle(.secondary)
                Spacer()
                Button(L("accounts.howToEnable")) { help = OrgHelpRequest(provider: nil) }
                    .buttonStyle(.link)
            }
        }
        .sheet(item: $help) { request in OrgAccessHelpSheet(provider: request.provider) }
    }
}

/// Runs one "Conectar …" sign-in at a time: waiting state with Cancelar, friendly errors, and whether to offer
/// "¿Cómo lo habilito?".
@MainActor @Observable
final class AccountConnector {
    private(set) var connecting: AccountProvider?
    var error: String?
    /// The provider whose sign-in failed for lack of configuration or organization approval.
    private(set) var helpProvider: AccountProvider?
    @ObservationIgnored private var task: Task<Void, Never>?

    func connect(_ provider: AccountProvider, state: AppState) {
        task?.cancel()
        error = nil
        helpProvider = nil
        connecting = provider
        task = Task {
            defer { if !Task.isCancelled { connecting = nil }; task = nil }
            do {
                try await state.connectAccount(provider)
            } catch is CancellationError {
            } catch AccountError.cancelled {
            } catch AccountError.notConfigured {
                error = L("accounts.notConfigured")
                helpProvider = provider
            } catch AccountError.consentRequired {
                error = L("accounts.consentRequired")
                helpProvider = provider
            } catch {
                self.error = FriendlyError.message(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        connecting = nil
    }
}

/// The connect buttons, or "Esperando a que inicies sesión en el navegador… (Cancelar)", plus any error.
struct ConnectAccountControls: View {
    @Environment(AppState.self) private var state
    let connector: AccountConnector
    @Binding var help: OrgHelpRequest?
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            if let provider = connector.connecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("accounts.waiting", provider.displayName)).foregroundStyle(.secondary)
                    Button(L("common.cancel")) { connector.cancel() }
                }
            } else {
                ConnectAccountButtons { connector.connect($0, state: state) }
            }
            if let error = connector.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let provider = connector.helpProvider {
                    Button(L("accounts.howToEnable")) { help = OrgHelpRequest(provider: provider) }
                }
            }
        }
    }
}

/// Empty state of Correo and Reuniones without accounts: one sentence and the two connect buttons.
struct ConnectAccountsEmptyState: View {
    var symbol: String
    var title: String
    var message: String
    /// Optional extra action under the buttons (Correo: "o pega un correo").
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    @ViewState private var connector = AccountConnector()
    @ViewState private var help: OrgHelpRequest?

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
            ConnectAccountControls(connector: connector, help: $help, centered: true)
                .padding(.top, 4)
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction).buttonStyle(.link)
            }
            Button(L("accounts.howToEnable")) { help = OrgHelpRequest(provider: nil) }
                .buttonStyle(.link)
                .font(.callout)
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

/// "Conectar Microsoft 365" · "Conectar Google": used in Ajustes and in the empty states of Correo and Reuniones.
struct ConnectAccountButtons: View {
    var onConnect: (AccountProvider) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccountProvider.allCases, id: \.self) { provider in
                Button {
                    onConnect(provider)
                } label: {
                    Label(L(provider == .microsoft ? "accounts.connectMicrosoft" : "accounts.connectGoogle"),
                          systemImage: provider.symbol)
                }
            }
        }
    }
}

private struct AccountRow: View {
    let account: ConnectedAccount
    var onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: account.provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.email)
                Text(account.displayName.map { "\($0) · \(account.provider.displayName)" } ?? account.provider.displayName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("accounts.disconnect"), role: .destructive, action: onDisconnect)
        }
    }
}

/// Round initial with the provider's color (no trademarked logos bundled).
struct ProviderBadge: View {
    let provider: AccountProvider
    var size: CGFloat = 26

    var body: some View {
        Text(provider == .microsoft ? "M" : "G")
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(provider.tint, in: Circle())
            .accessibilityLabel(provider.displayName)
    }
}

extension AccountProvider {
    var symbol: String { self == .microsoft ? "envelope.badge" : "envelope.circle" }
    var tint: Color { self == .microsoft ? Color(red: 0.0, green: 0.47, blue: 0.84) : Color(red: 0.92, green: 0.26, blue: 0.21) }
}

/// "Avanzado" (folded): the user's own OAuth client ids (§12.3 "Soy técnico").
private struct AdvancedOAuthFields: View {
    @Environment(AppState.self) private var state

    var body: some View {
        DisclosureGroup(L("accounts.advanced")) {
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

/// "¿Cómo lo habilito?" (§12.3): what to send the admin, the admin's exact steps, and how to use your own app
/// registration. `provider == nil` opens on Microsoft.
///
/// SKELETON (v0.3): the accounts engineer fills in the tabs and texts.
struct OrgAccessHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    let provider: AccountProvider?

    var body: some View {
        VStack(spacing: 0) {
            EmptyStateView(symbol: "building.2", title: L("orghelp.title"), message: L("orghelp.subtitle"))
            Divider()
            HStack {
                Spacer()
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 520)
    }
}
