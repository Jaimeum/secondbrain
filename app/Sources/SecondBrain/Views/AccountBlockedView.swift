import AppKit
import BrainCore
import SwiftUI

/// "Bloqueo por organización = bifurcación, no error" (CONTRACT §12.7): what happened in one line and the ways
/// forward — ask IT (mail draft), see how to enable it, paste an email meanwhile, and in Reuniones the Mac Calendar.
/// Also the "SecondBrain aún no está registrada" variant when no client id is configured.
struct AccountBlockedView: View {
    @Environment(AppState.self) private var state
    let provider: AccountProvider
    var reason: AccountBlockReason = .consent
    var context: ConnectContext = .settings
    /// "Usar el calendario de la Mac" (shown in Reuniones, and whenever the app isn't registered yet).
    var onUseMacCalendar: (() -> Void)? = nil
    /// Close the surrounding sheet; nil when embedded in a page.
    var onClose: (() -> Void)? = nil
    @ViewState private var help: OrgHelpRequest?

    private var clientId: String? { OAuthAppRegistration.effective(config: state.config).clientId(for: provider) }
    private var offersMacCalendar: Bool {
        onUseMacCalendar != nil && !state.engine.accounts.hasLocalCalendar && (context == .meetings || reason == .notRegistered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: reason == .consent ? "building.2" : "key.horizontal")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)
                    .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason == .consent ? L("accounts.blocked.title") : L("accounts.notRegistered.title", provider.displayName))
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(reason == .consent ? L("accounts.blocked.message", provider.displayName) : L("accounts.notRegistered.message"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 20)

            VStack(spacing: 8) {
                if reason == .consent {
                    ForkButton(symbol: "envelope", title: L("accounts.blocked.askIT"), detail: L("accounts.blocked.askITDetail"),
                               prominent: true) {
                        OrgHelpText.openMailDraft(provider: provider, clientId: clientId)
                    }
                }
                ForkButton(symbol: "questionmark.circle", title: L("accounts.howToEnable"),
                           detail: reason == .consent ? L("accounts.blocked.howDetail") : L("accounts.notRegistered.howDetail")) {
                    help = OrgHelpRequest(provider: provider)
                }
                if offersMacCalendar, let onUseMacCalendar {
                    ForkButton(symbol: "calendar", title: L("accounts.useMacCalendar"), detail: L("accounts.blocked.macCalendarDetail"),
                               prominent: reason == .notRegistered, action: onUseMacCalendar)
                }
                ForkButton(symbol: "doc.on.clipboard", title: L("accounts.blocked.paste"), detail: L("accounts.blocked.pasteDetail")) {
                    pasteEmail()
                }
            }

            if let onClose {
                HStack {
                    Spacer()
                    Button(L("common.close"), action: onClose).keyboardShortcut(.cancelAction)
                }
                .padding(.top, 18)
            }
        }
        .padding(28)
        .sheet(item: $help) { request in OrgAccessHelpSheet(provider: request.provider) }
    }

    /// Closes the sheet first: the "Agregar correo" sheet opens from the main window right after.
    private func pasteEmail() {
        if let onClose {
            onClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { state.requestEmail() }
        } else {
            state.requestEmail()
        }
    }
}

/// A full-width choice: icon, verb title and one line of detail.
private struct ForkButton: View {
    let symbol: String
    let title: String
    let detail: String
    var prominent = false
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(prominent ? Color.white : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(prominent ? Color.accentColor : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(hovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
