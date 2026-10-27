import AppKit
import BrainCore
import SwiftUI

/// "¿Cómo lo habilito?" (CONTRACT §12.3, §12.7): tabs Microsoft / Google with (A) a message ready to send the admin
/// (Copiar · Pedírselo a TI), (B) the admin's exact steps and (C) folded "Soy técnico: usar mi propio registro".
/// Without a client id, (A) says the app isn't registered yet, (B) is skipped and the technical section takes its letter
/// and opens by default. `provider == nil` opens on
/// Microsoft.
struct OrgAccessHelpSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let provider: AccountProvider?
    @ViewState private var tab: AccountProvider
    @ViewState private var copied: String?
    @ViewState private var technicalOpen: Bool?

    init(provider: AccountProvider?) {
        self.provider = provider
        _tab = ViewState(initialValue: provider == .google ? .google : .microsoft)
    }

    private var clientId: String? { OAuthAppRegistration.effective(config: state.config).clientId(for: tab) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("orghelp.title")).font(.title2.weight(.semibold))
                Text(L("orghelp.subtitle")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $tab) {
                    Text(AccountProvider.microsoft.displayName).tag(AccountProvider.microsoft)
                    Text(AccountProvider.google.displayName).tag(AccountProvider.google)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    forYou
                    if let clientId { forAdmin(clientId) }
                    technical
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let copied {
                    Label(copied, systemImage: "checkmark").foregroundStyle(.green).font(.callout)
                }
                Spacer()
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 520)
        .onChange(of: tab) { copied = nil }
    }

    // MARK: (A) For you

    @ViewBuilder private var forYou: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(letter: "A", title: L("orghelp.forYou"))
            if let clientId {
                Text(L(tab == .microsoft ? "orghelp.ms.forYou.hint" : "orghelp.g.forYou.hint")).foregroundStyle(.secondary)
                Text(OrgHelpText.message(provider: tab, clientId: clientId))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                HStack(spacing: 10) {
                    Button {
                        copy(OrgHelpText.message(provider: tab, clientId: clientId))
                    } label: {
                        Label(L("orghelp.copy"), systemImage: "doc.on.doc")
                    }
                    Button {
                        OrgHelpText.openMailDraft(provider: tab, clientId: clientId)
                    } label: {
                        Label(L("accounts.blocked.askIT"), systemImage: "envelope")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Label {
                    Text(L("orghelp.notRegistered", tab.displayName)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "key.horizontal").foregroundStyle(.orange)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: (B) For your admin

    private func forAdmin(_ clientId: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(letter: "B", title: L("orghelp.forAdmin"))
            NumberedSteps(steps: OrgHelpText.adminSteps(provider: tab, clientId: clientId))
            if tab == .microsoft {
                Button {
                    copy(OrgHelpText.consentURL(clientId: clientId))
                } label: {
                    Label(L("orghelp.copyConsentLink"), systemImage: "link")
                }
                .padding(.leading, 30)
            }
        }
    }

    // MARK: (C) Technical

    private var technical: some View {
        DisclosureGroup(isExpanded: Binding(get: { technicalOpen ?? (clientId == nil) }, set: { technicalOpen = $0 })) {
            VStack(alignment: .leading, spacing: 10) {
                NumberedSteps(steps: OrgHelpText.ownSteps(provider: tab))
                Text(L("orghelp.own.paste")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
        } label: {
            SectionTitle(letter: clientId == nil ? "B" : "C", title: L("orghelp.technical"))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = L("orghelp.copied")
    }
}

private struct SectionTitle: View {
    let letter: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(letter)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(title).font(.headline)
        }
    }
}

private struct NumberedSteps: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    Text(step)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
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
