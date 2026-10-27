import BrainCore
import SwiftUI

/// The connect sheet (CONTRACT §12.7 "Confianza antes del navegador"): three short promises and "Continuar en el
/// navegador"; then "Esperando a que inicies sesión… · Cancelar"; then either closes (connected) or turns into the
/// blocked fork (`AccountBlockedView`) or a plain error with "Intentar de nuevo".
struct TrustSheet: View {
    @Environment(AppState.self) private var state
    let connector: AccountConnector
    var context: ConnectContext = .settings

    var body: some View {
        Group {
            if let flow = connector.flow {
                switch flow.phase {
                case .trust: trust(flow.provider)
                case .waiting: waiting(flow.provider)
                case .blocked(let reason):
                    AccountBlockedView(provider: flow.provider, reason: reason, context: context,
                                       onUseMacCalendar: { connector.cancel(); connector.start(.local, state: state) },
                                       onClose: { connector.cancel() })
                case .failed(let message): failed(flow.provider, message)
                }
            }
        }
        .frame(width: 460)
        .animation(.easeInOut(duration: 0.2), value: connector.flow?.phase)
        // Closed some other way (Esc, window closing): stop waiting for the browser.
        .onDisappear { if connector.flow == nil { connector.cancel() } }
    }

    // MARK: Trust

    private func trust(_ provider: AccountProvider) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProviderBadge(provider: provider, size: 38)
                Text(L("accounts.trust.title", provider.displayName))
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 18) {
                TrustLine(symbol: "eye", tint: .blue, title: L("accounts.trust.read"), detail: L("accounts.trust.readDetail"))
                TrustLine(symbol: "laptopcomputer", tint: .green, title: L("accounts.trust.local"), detail: L("accounts.trust.localDetail"))
                TrustLine(symbol: "powerplug", tint: .orange, title: L("accounts.trust.disconnect"),
                          detail: L("accounts.trust.disconnectDetail"))
            }
            Text(L("accounts.trust.browserHint", provider.displayName))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
            HStack {
                Spacer()
                Button(L("common.cancel")) { connector.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    connector.continueInBrowser(state: state)
                } label: {
                    Label(L("accounts.trust.continue"), systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(28)
    }

    // MARK: Waiting

    private func waiting(_ provider: AccountProvider) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(L("accounts.waiting", provider.displayName))
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("accounts.waiting.detail"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("accounts.waiting.reopen")) { connector.reopenBrowser() }
                .buttonStyle(.link)
            Button(L("common.cancel")) { connector.cancel() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    // MARK: Failed

    private func failed(_ provider: AccountProvider, _ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            Text(L("accounts.failed.title", provider.displayName)).font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Button(L("common.close")) { connector.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("accounts.failed.retry")) { connector.retry() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: v0.4 github — also the GitHub connect sheet's three promises
struct TrustLine: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
