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
        // One stable size for every phase (CONTRACT §15.3): the window never jumps while the content cross-fades.
        // Forms (trust, blocked fork) sit at the top; the status phases (waiting, failed) are centered.
        StableSheetBody(alignment: phaseAlignment) {
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
        .frame(minWidth: 440, idealWidth: 460, maxWidth: 520, minHeight: 360, idealHeight: 460, maxHeight: .infinity)
        .background(Brand.color.surface)
        .animation(Brand.motion.animation(), value: connector.flow?.phase)
        // Closed some other way (Esc, window closing): stop waiting for the browser.
        .onDisappear { if connector.flow == nil { connector.cancel() } }
    }

    private var phaseAlignment: Alignment {
        switch connector.flow?.phase {
        case .waiting, .failed: .center
        default: .top
        }
    }

    // MARK: Trust

    private func trust(_ provider: AccountProvider) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProviderBadge(provider: provider, size: 40)
                Text(L("accounts.trust.title", provider.displayName))
                    .font(Brand.title)
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 18) {
                TrustLine(symbol: "eye", title: L("accounts.trust.read"), detail: L("accounts.trust.readDetail"))
                TrustLine(symbol: "laptopcomputer", title: L("accounts.trust.local"), detail: L("accounts.trust.localDetail"))
                TrustLine(symbol: "powerplug", title: L("accounts.trust.disconnect"), detail: L("accounts.trust.disconnectDetail"))
            }
            Text(L("accounts.trust.browserHint", provider.displayName))
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
            HStack(spacing: 8) {
                Spacer()
                Button(L("common.cancel")) { connector.cancel() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    connector.continueInBrowser(state: state)
                } label: {
                    Label(L("accounts.trust.continue"), systemImage: "safari")
                }
                .buttonStyle(.brandPrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(28)
    }

    // MARK: Waiting

    private func waiting(_ provider: AccountProvider) -> some View {
        VStack(spacing: 14) {
            BrandLoader(size: 32)
            Text(L("accounts.waiting", provider.displayName))
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("accounts.waiting.detail"))
                .foregroundStyle(Brand.color.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("accounts.waiting.reopen")) { connector.reopenBrowser() }
                .buttonStyle(.settingsExternalLink)
            Button(L("common.cancel")) { connector.cancel() }
                .buttonStyle(.brandSecondary)
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
                .font(Brand.font(30))
                .foregroundStyle(Brand.color.warning)
            Text(L("accounts.failed.title", provider.displayName))
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(Brand.color.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button(L("common.close")) { connector.cancel() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("accounts.failed.retry")) { connector.retry() }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// The body of a connect sheet with a fixed ideal size: scrolls when a phase is taller than the sheet (the blocked
/// fork at the minimum height), otherwise fills it and places the phase at `alignment`.
struct StableSheetBody<Content: View>: View {
    var alignment: Alignment = .top
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: alignment)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: v0.4 github — also the GitHub connect sheet's three promises
/// One promise: a calm `accentSoft` tile with the symbol, a title and one line of detail.
struct TrustLine: View {
    let symbol: String
    /// Kept for source compatibility; the brand uses one tile tone for every promise.
    var tint: Color = Brand.color.accent
    let title: String
    let detail: String

    init(symbol: String, tint: Color = Brand.color.accent, title: String, detail: String) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(Brand.font(15, .medium))
                .foregroundStyle(Brand.color.accent)
                .frame(width: 32, height: 32)
                .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Brand.callout).foregroundStyle(Brand.color.text)
                Text(detail)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
