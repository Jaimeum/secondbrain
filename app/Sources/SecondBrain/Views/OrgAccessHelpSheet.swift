import AppKit
import BrainCore
import SwiftUI

/// "¿Cómo lo habilito?" (CONTRACT §12.3, §12.7): tabs Microsoft / Google with "Para ti" (a message ready to send the
/// admin: Copiar · Pedírselo a TI), "Para tu administrador" (the exact steps) and, folded by default, "Usar mi propio
/// registro" (technical). Without a client id, "Para ti" says in plain words that it isn't available in this version
/// yet and the admin steps are skipped. `provider == nil` opens on Microsoft.
struct OrgAccessHelpSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let provider: AccountProvider?
    @ViewState private var tab: AccountProvider
    @ViewState private var copied: String?
    @ViewState private var technicalOpen = false

    init(provider: AccountProvider?) {
        self.provider = provider
        _tab = ViewState(initialValue: provider == .google ? .google : .microsoft)
    }

    private var clientId: String? { OAuthAppRegistration.effective(config: state.config).clientId(for: tab) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("orghelp.title")).font(Brand.title).foregroundStyle(Brand.color.text)
                Text(L("orghelp.subtitle"))
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                BrandSegmentedControl(options: [(AccountProvider.microsoft, AccountProvider.microsoft.displayName),
                                                (AccountProvider.google, AccountProvider.google.displayName)],
                                      selection: $tab, minSegmentWidth: 96, height: 26)
                    .fixedSize()
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    forYou
                    if let clientId { forAdmin(clientId) }
                    technical
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .brandScrollEdgeFade(.top)
            .brandScrollEdgeFade(.bottom)
            BrandSheetFooter {
                if let copied {
                    Label(copied, systemImage: "checkmark").foregroundStyle(Brand.color.success).font(Brand.caption)
                }
                Spacer()
                Button(L("common.close")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 400, idealHeight: 520)
        .background(Brand.color.surface)
        .onChange(of: tab) { copied = nil }
    }

    // MARK: For you

    @ViewBuilder private var forYou: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: L("orghelp.forYou"))
            if let clientId {
                Text(L(tab == .microsoft ? "orghelp.ms.forYou.hint" : "orghelp.g.forYou.hint"))
                    .foregroundStyle(Brand.color.text2)
                BrandCard {
                    Text(OrgHelpText.message(provider: tab, clientId: clientId))
                        .foregroundStyle(Brand.color.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        copy(OrgHelpText.message(provider: tab, clientId: clientId))
                    } label: {
                        Label(L("orghelp.copy"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.brandSecondary)
                    Button {
                        OrgHelpText.openMailDraft(provider: tab, clientId: clientId)
                    } label: {
                        Label(L("accounts.blocked.askIT"), systemImage: "envelope")
                    }
                    .buttonStyle(.brandPrimary)
                }
            } else {
                // Plain language: what it means for the user and what to do meanwhile (no credentials talk).
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock").foregroundStyle(Brand.color.warning)
                    Text(L("orghelp.notRegistered.plain", tab.displayName))
                        .foregroundStyle(Brand.color.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.color.warningSoft, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
            }
        }
    }

    // MARK: For your admin

    private func forAdmin(_ clientId: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: L("orghelp.forAdmin"))
            NumberedSteps(steps: OrgHelpText.adminSteps(provider: tab, clientId: clientId))
            if tab == .microsoft {
                Button {
                    copy(OrgHelpText.consentURL(clientId: clientId))
                } label: {
                    Label(L("orghelp.copyConsentLink"), systemImage: "link")
                }
                .buttonStyle(.brandSecondary)
                .padding(.leading, NumberedSteps.indent)
            }
        }
    }

    // MARK: Technical (folded)

    private var technical: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A plain button header (not a DisclosureGroup) so the title lines up with the other sections.
            Button {
                withAnimation(Brand.motion.animation(fast: true)) { technicalOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    SectionTitle(title: L("orghelp.technical"))
                    Image(systemName: "chevron.right")
                        .font(Brand.font(10, .semibold))
                        .foregroundStyle(Brand.color.text2)
                        .rotationEffect(.degrees(technicalOpen ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if technicalOpen {
                NumberedSteps(steps: OrgHelpText.ownSteps(provider: tab))
                Text(L("orghelp.own.paste"))
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = L("orghelp.copied")
    }
}

private struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Brand.section)
            .foregroundStyle(Brand.color.text)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: v0.4 github — also GitHubOrgHelpSheet
struct NumberedSteps: View {
    let steps: [String]
    /// Leading space of the step text (the number column), for buttons that belong to the steps.
    static let indent: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(Brand.color.text3)
                        .frame(width: 22, alignment: .trailing)
                    Text(step)
                        .foregroundStyle(Brand.color.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The texts of docs/org-access-help.md, from Localizable.strings (es/en), with the real client id filled in.
enum OrgHelpText {
    private static let adminCount: [AccountProvider: Int] = [.microsoft: 7, .google: 10]
    private static let ownCount: [AccountProvider: Int] = [.microsoft: 10, .google: 10]

    private static func prefix(_ provider: AccountProvider) -> String { provider == .google ? "orghelp.g" : "orghelp.ms" }

    static func consentURL(clientId: String) -> String {
        "https://login.microsoftonline.com/common/adminconsent?client_id=\(clientId)"
    }

    /// (A) "Hola, quiero conectar la app SecondBrain…" with the client id (and, for Microsoft, the consent link).
    static func message(provider: AccountProvider, clientId: String) -> String {
        L("\(prefix(provider)).message", clientId)
    }

    static func adminSteps(provider: AccountProvider, clientId: String) -> [String] {
        (1...(adminCount[provider] ?? 0)).map { L("\(prefix(provider)).admin.\($0)", clientId) }
    }

    static func ownSteps(provider: AccountProvider) -> [String] {
        (1...(ownCount[provider] ?? 0)).map { L("\(prefix(provider)).own.\($0)") }
    }

    static func mailtoURL(provider: AccountProvider, clientId: String?) -> URL? {
        let body = clientId.map { message(provider: provider, clientId: $0) } ?? L("orghelp.notRegistered", provider.displayName)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return URL(string: "mailto:?subject=\(enc(L("\(prefix(provider)).mail.subject")))&body=\(enc(body))")
    }

    /// "Pedírselo a TI": a draft in the default mail app, subject and body filled in.
    static func openMailDraft(provider: AccountProvider, clientId: String?) {
        if let url = mailtoURL(provider: provider, clientId: clientId) { NSWorkspace.shared.open(url) }
    }
}
