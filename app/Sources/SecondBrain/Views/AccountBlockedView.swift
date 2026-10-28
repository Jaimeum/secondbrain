import AppKit
import BrainCore
import SwiftUI

/// "Bloqueo por organización = bifurcación, no error" (CONTRACT §12.7): what happened in one line and the ways
/// forward — ask IT (mail draft), see how to enable it, paste an email meanwhile, and in Reuniones the Mac Calendar.
/// Also the "aún no disponible" variant when no client id is configured: one plain sentence, the Mac Calendar and
/// pasting first, the technical way only behind a link.
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
                SheetIconTile(symbol: reason == .consent ? "building.2" : "clock",
                              tone: Brand.color.warning, background: Brand.color.warningSoft, size: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason == .consent ? L("accounts.blocked.title") : L("accounts.notRegistered.title", provider.displayName))
                        .font(Brand.section)
                        .foregroundStyle(Brand.color.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(reason == .consent ? L("accounts.blocked.message", provider.displayName)
                                            : L("accounts.notRegistered.plain", provider.displayName))
                        .foregroundStyle(Brand.color.text2)
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
                    ForkButton(symbol: "questionmark.circle", title: L("accounts.howToEnable"),
                               detail: L("accounts.blocked.howDetail")) {
                        help = OrgHelpRequest(provider: provider)
                    }
                }
                if offersMacCalendar, let onUseMacCalendar {
                    ForkButton(symbol: "calendar", title: L("accounts.useMacCalendar"), detail: L("accounts.blocked.macCalendarDetail"),
                               prominent: reason == .notRegistered, action: onUseMacCalendar)
                }
                ForkButton(symbol: "doc.on.clipboard", title: L("accounts.blocked.paste"), detail: L("accounts.blocked.pasteDetail")) {
                    pasteEmail()
                }
            }

            HStack(spacing: 8) {
                if reason == .notRegistered {
                    // The technical way (own registration) stays one click away, never in the main path.
                    Button(L("accounts.notRegistered.technical")) { help = OrgHelpRequest(provider: provider) }
                        .buttonStyle(.settingsLink)
                        .font(Brand.caption)
                }
                Spacer()
                if let onClose {
                    Button(L("common.close"), action: onClose)
                        .buttonStyle(.brandGhost)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, 18)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.color.surface)
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
        let shape = RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(Brand.font(14, .medium))
                    .foregroundStyle(prominent ? Brand.color.onAccent : Brand.color.accent)
                    .frame(width: 30, height: 30)
                    .background(prominent ? Brand.color.accent : Brand.color.accentSoft,
                                in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                // The text takes every point up to the chevron (a Spacer would split the width with it).
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Brand.callout).foregroundStyle(Brand.color.text)
                    Text(detail)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                Image(systemName: "chevron.right").font(Brand.font(11, .semibold)).foregroundStyle(Brand.color.text3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(shape)
            .background(shape.fill(hovering ? Brand.color.cardAlt : Brand.color.card))
            .overlay(shape.strokeBorder(Brand.color.lineSoft, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
    }
}
