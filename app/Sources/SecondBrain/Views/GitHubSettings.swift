import AppKit
import BrainCore
import SwiftUI

/// Ajustes → GitHub (CONTRACT §13.1, §13.6, §15.2): the connected account or one way to connect (plus the alternative as a
/// link), how often the repos refresh and the last sync (only once connected), repos of deleted projects, and a pasted
/// personal token. The OAuth App client id lives in Avanzado.
struct GitHubSettingsPage: View {
    @Environment(AppState.self) private var state
    @ViewState private var connect: GitHubConnectRequest?
    @ViewState private var showOrgHelp = false
    /// nil until the GitHub CLI lookup finishes (cached for the session): the connect button waits for it, so its
    /// label and method never switch under the pointer.
    @ViewState private var ghAvailable: Bool? = GHDetection.cached
    @ViewState private var confirmDisconnect = false
    @ViewState private var showToken = false

    private var github: GitHubStore { state.engine.github }
    private var model: GitHubModel { GitHubModel.shared }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("github.section")) {
                if let account = github.account {
                    GitHubAccountRow(account: account) { confirmDisconnect = true }
                } else if github.isConnected {
                    // A token from the environment (set up by whoever installed the app), without account.json.
                    SettingsRow(title: L("github.envToken")) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Brand.color.success)
                    }
                    .help("SB_GITHUB_TOKEN")
                } else {
                    connectChoices.padding(14)
                }

                if github.isConnected {
                    SettingsDivider()
                    SettingsRow(title: L("github.interval")) {
                        BrandMenuPicker(title: GitHubModel.intervalTitle(intervalBinding.wrappedValue), selection: intervalBinding) {
                            ForEach(GitHubLimits.syncIntervalChoices, id: \.self) { Text(GitHubModel.intervalTitle($0)).tag($0) }
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: L("github.lastSync")) {
                        if model.isSyncing || !github.syncing.isEmpty {
                            BrandLoader(size: 16, text: L("repos.syncing"))
                        } else {
                            HStack(spacing: 10) {
                                Text(github.lastGlobalSyncAt.map(Fmt.relative) ?? L("github.lastSync.never"))
                                    .foregroundStyle(Brand.color.text2)
                                    .lineLimit(1)
                                Button(L("github.syncNow")) { model.syncNow(state: state) }
                                    .buttonStyle(.brandSecondary)
                                    .disabled(github.repos.isEmpty)
                            }
                        }
                    }
                }
                if let problem = model.problem {
                    SettingsDivider()
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Brand.color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L("github.footer"), systemImage: "lock.shield")
                    Button(L("github.org.trouble")) { showOrgHelp = true }
                        .buttonStyle(.settingsLink)
                }
            }

            if !github.orphanedRepos.isEmpty {
                SettingsGroup(title: L("github.orphans.title"), footer: L("github.orphans.hint")) {
                    ForEach(Array(github.orphanedRepos.enumerated()), id: \.element.id) { index, repo in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(title: repo.fullName, detail: L("settings.github.orphanProject", projectName(repo.projectSlug))) {
                            Button(L("github.orphans.remove")) { try? github.remove(repoId: repo.id) }
                                .buttonStyle(.brandSecondary)
                        }
                    }
                }
            }

            if !github.isConnected || showToken {
                GitHubTokenGroup(expanded: $showToken)
            }
        }
        .sheet(item: $connect) { request in
            GitHubConnectSheet(method: request.method, onUseToken: { showToken = true })
        }
        .sheet(isPresented: $showOrgHelp) { GitHubOrgHelpSheet(onUseToken: { showToken = true }) }
        .confirmationDialog(L("settings.disconnect.confirm", github.account.map { "@\($0.login)" } ?? "GitHub"),
                            isPresented: $confirmDisconnect) {
            Button(L("accounts.disconnect"), role: .destructive) { github.disconnect() }
        } message: {
            Text(L("settings.disconnect.message"))
        }
        .task {
            ghAvailable = await GHDetection.check(demo: github.isDemo)
        }
    }

    private var hasClientId: Bool { GitHubAuth.clientId(config: state.config) != nil }

    /// One primary way in; the other (GitHub CLI session) as a link. Without an OAuth App client id the CLI is the way.
    private var connectChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("github.none"))
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let ghAvailable {
                let cliFirst = ghAvailable && !hasClientId
                Button {
                    connect = GitHubConnectRequest(method: cliFirst ? .ghCLI : .deviceFlow)
                } label: {
                    Label(cliFirst ? L("github.useCLI") : L("github.connect"),
                          systemImage: cliFirst ? "terminal" : "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.brandPrimary)
                if ghAvailable {
                    Button(cliFirst ? L("github.connect") : L("github.useCLI")) {
                        connect = GitHubConnectRequest(method: cliFirst ? .deviceFlow : .ghCLI)
                    }
                    .buttonStyle(.settingsLink)
                }
            } else {
                // Same height as the button: nothing below moves when the lookup ends.
                BrandLoader(size: 16).frame(height: 28)
            }
        }
    }

    /// A deleted project's name from its slug ("lanzamiento-atlas" → "Lanzamiento atlas").
    private func projectName(_ slug: String) -> String {
        if let p = state.project(slug) { return "\(p.emoji) \(p.name)" }
        let words = slug.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { state.config.githubSyncMinutes }, set: { value in state.update { $0.githubSyncMinutes = value } })
    }
}

/// Whether the GitHub CLI (`gh`) is installed, looked up once per session off the main thread.
@MainActor
enum GHDetection {
    private(set) static var cached: Bool?

    static func check(demo: Bool) async -> Bool {
        if demo { return true }
        if let cached { return cached }
        let found = await Task.detached(priority: .userInitiated) { GitHubAuth.locateGH() != nil }.value
        cached = found
        return found
    }
}

/// Deprecated name kept for the snapshot harness (`settings-github`); new code uses `SettingsView(initialTab: .github)`.
struct GitHubSection: View {
    var body: some View { GitHubSettingsPage() }
}

struct GitHubConnectRequest: Identifiable {
    let id = UUID()
    var method: GitHubAuthMethod
}

private struct GitHubAccountRow: View {
    let account: GitHubAccount
    var onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            GitHubAvatar(account: account, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name.map { "\($0) (@\(account.login))" } ?? "@\(account.login)")
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(methodText).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("accounts.disconnect") + "…", action: onDisconnect).buttonStyle(.brandSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var methodText: String {
        switch account.method {
        case .deviceFlow: L("github.method.device")
        case .ghCLI: L("github.method.cli")
        case .personalToken: L("github.method.token")
        case .environment: L("github.method.env")
        }
    }
}

/// The account's avatar (from GitHub), or its initial in the brand avatar token while it loads / without network.
struct GitHubAvatar: View {
    let account: GitHubAccount
    var size: CGFloat = 26

    var body: some View {
        AsyncImage(url: account.avatarURL.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String(account.login.prefix(1)).uppercased())
                .font(Brand.avatar.font(size))
                .foregroundStyle(Brand.avatar.initials)
                .frame(width: size, height: size)
                .background(Brand.avatar.background, in: Circle())
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// "Usar un token personal": paste a read-only token (the way around an organization that blocks OAuth Apps).
private struct GitHubTokenGroup: View {
    @Environment(AppState.self) private var state
    @Binding var expanded: Bool
    @ViewState private var token = ""
    @ViewState private var saving = false
    @ViewState private var message: (text: String, ok: Bool)?

    var body: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(Brand.motion.animation(fast: true)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(Brand.font(10, .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(Brand.color.text2)
                        Text(L("settings.github.tokenTitle")).font(Brand.callout).foregroundStyle(Brand.color.text)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    HStack(spacing: 8) {
                        SecureField(L("github.token"), text: $token)
                            .onSubmit(saveToken)
                            .brandField()
                        if saving {
                            BrandLoader(size: 16)
                        } else {
                            Button(L("github.token.save"), action: saveToken)
                                .buttonStyle(.brandPrimary)
                                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("github.token.hint"))
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(L("github.token.create"), destination: GitHubAuth.personalTokenHelpURL)
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.accent)
                    }
                    if let message {
                        Label(message.text, systemImage: message.ok ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(message.ok ? Brand.color.success : Brand.color.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
        }
    }

    private func saveToken() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !saving else { return }
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do {
                let account = try await state.engine.github.connect(token: value, method: .personalToken)
                token = ""
                message = (L("github.connectedAs", account.login), true)
            } catch {
                message = (FriendlyError.message(error), false)
            }
        }
    }
}

// MARK: - Connect sheet

/// One step of "Conectar GitHub": the trust promises → the device code to type on github.com (or the GitHub CLI's
/// session being copied) → closes when connected, or explains what went wrong.
enum GitHubConnectPhase: Equatable {
    case trust
    case code(GitHubDeviceCode)
    case working
    case failed(String, orgRestricted: Bool, notConfigured: Bool)
}

@MainActor @Observable
final class GitHubConnector {
    var phase: GitHubConnectPhase
    private(set) var connected: GitHubAccount?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(phase: GitHubConnectPhase = .trust) { self.phase = phase }

    func start(_ method: GitHubAuthMethod, state: AppState) {
        task?.cancel()
        let github = state.engine.github
        if method == .ghCLI {
            phase = .working
            task = Task { [weak self] in
                do { self?.finish(try await github.connectWithGHCLI()) } catch { self?.fail(error) }
            }
            return
        }
        let clientId = GitHubAuth.clientId(config: state.config) ?? ""
        guard !clientId.isEmpty || github.isDemo else {
            fail(GitHubError.notConfigured)
            return
        }
        phase = .working
        task = Task { [weak self] in
            do {
                let code = try await github.startDeviceFlow(clientId: clientId)
                guard !Task.isCancelled else { return }
                self?.phase = .code(code)
                let account = try await github.finishDeviceFlow(code)
                guard !Task.isCancelled else { return }
                self?.finish(account)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func finish(_ account: GitHubAccount) {
        connected = account
    }

    private func fail(_ error: Error) {
        if error is CancellationError { return }
        var org = false, notConfigured = false
        if case GitHubError.orgRestricted = error { org = true }
        if case GitHubError.notConfigured = error { notConfigured = true }
        phase = .failed(FriendlyError.message(error), orgRestricted: org, notConfigured: notConfigured)
    }
}

struct GitHubConnectSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var method: GitHubAuthMethod = .deviceFlow
    /// Ajustes → GitHub: "Pegar un token personal" closes the sheet and opens the token field there. Elsewhere (nil)
    /// the button opens Ajustes → GitHub.
    var onUseToken: (() -> Void)? = nil
    @ViewState private var connector: GitHubConnector
    @ViewState private var copied = false
    @ViewState private var showOrgHelp = false
    @ViewState private var ghAvailable = GHDetection.cached ?? false

    init(method: GitHubAuthMethod = .deviceFlow, preview: GitHubConnectPhase? = nil, onUseToken: (() -> Void)? = nil) {
        self.method = method
        self.onUseToken = onUseToken
        _connector = ViewState(initialValue: GitHubConnector(phase: preview ?? .trust))
    }

    var body: some View {
        // One stable size for every phase (CONTRACT §15.3), like the account connect sheet.
        StableSheetBody(alignment: phaseAlignment) {
            switch connector.phase {
            case .trust: trust
            case .code(let code): codeStep(code)
            case .working: working
            case .failed(let message, let org, let notConfigured): failed(message, org: org, notConfigured: notConfigured)
            }
        }
        .frame(minWidth: 440, idealWidth: 460, maxWidth: 520, minHeight: 360, idealHeight: 460, maxHeight: .infinity)
        .background(Brand.color.surface)
        .animation(Brand.motion.animation(), value: connector.phase)
        .onChange(of: connector.connected) { if connector.connected != nil { dismiss() } }
        .onDisappear { connector.cancel() }
        .sheet(isPresented: $showOrgHelp) { GitHubOrgHelpSheet() }
        .task {
            ghAvailable = await GHDetection.check(demo: state.engine.github.isDemo)
        }
    }

    private var phaseAlignment: Alignment {
        if case .trust = connector.phase { return .top }
        return .center
    }

    // MARK: Trust (§13.6: three promises)

    private var trust: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SheetIconTile(symbol: "chevron.left.forwardslash.chevron.right")
                Text(L("github.trust.title"))
                    .font(Brand.title)
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 18) {
                TrustLine(symbol: "eye", title: L("github.trust.read"), detail: L("github.trust.readDetail"))
                TrustLine(symbol: "laptopcomputer", title: L("github.trust.local"), detail: L("github.trust.localDetail"))
                TrustLine(symbol: "powerplug", title: L("github.trust.disconnect"), detail: L("github.trust.disconnectDetail"))
            }
            Text(method == .ghCLI ? L("github.trust.cliHint") : L("github.trust.browserHint"))
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
            HStack(spacing: 8) {
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    connector.start(method, state: state)
                } label: {
                    if method == .ghCLI {
                        Label(L("github.useCLI"), systemImage: "terminal")
                    } else {
                        Label(L("common.continue"), systemImage: "arrow.right")
                    }
                }
                .buttonStyle(.brandPrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(28)
    }

    // MARK: Device code

    private func codeStep(_ code: GitHubDeviceCode) -> some View {
        VStack(spacing: 14) {
            Text(L("github.code.title"))
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .multilineTextAlignment(.center)
            Text(L("github.code.hint"))
                .foregroundStyle(Brand.color.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Click the code to copy it.
            Button { copy(code.userCode) } label: {
                Text(code.userCode)
                    .font(Brand.mono(36, .semibold))
                    .tracking(4)
                    .foregroundStyle(Brand.color.text)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).strokeBorder(Brand.color.lineSoft))
            }
            .buttonStyle(.plain)
            .help(L("github.code.copy"))
            Label(L("github.code.copied"), systemImage: "checkmark")
                .font(Brand.caption)
                .foregroundStyle(Brand.color.success)
                .opacity(copied ? 1 : 0)
            Button {
                copy(code.userCode)
                NSWorkspace.shared.open(code.verificationURI)
            } label: {
                Label(L("github.code.copyOpen"), systemImage: "safari")
            }
            .buttonStyle(.brandPrimary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            BrandLoader(size: 18, text: L("github.code.waiting"))
                .padding(.top, 6)
            Button(L("common.cancel")) { connector.cancel(); dismiss() }
                .buttonStyle(.brandSecondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var working: some View {
        VStack(spacing: 14) {
            BrandLoader(size: 32)
            Text(method == .ghCLI ? L("github.working.cli") : L("github.working"))
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
            Button(L("common.cancel")) { connector.cancel(); dismiss() }
                .buttonStyle(.brandSecondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private func failed(_ message: String, org: Bool, notConfigured: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: org ? "building.2" : "exclamationmark.triangle")
                .font(Brand.font(30))
                .foregroundStyle(Brand.color.warning)
            Text(L("github.failed.title")).font(Brand.section).foregroundStyle(Brand.color.text)
            Text(message)
                .foregroundStyle(Brand.color.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if notConfigured {
                Text(L("github.failed.notConfigured"))
                    .foregroundStyle(Brand.color.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { failedActions(org: org, notConfigured: notConfigured) }
                VStack(spacing: 8) { failedActions(org: org, notConfigured: notConfigured) }
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func failedActions(org: Bool, notConfigured: Bool) -> some View {
        Button(L("common.close")) { dismiss() }
            .buttonStyle(.brandSecondary)
            .keyboardShortcut(.cancelAction)
        if notConfigured {
            // No OAuth App yet: the other ways in (a personal token, the GitHub CLI's session).
            Button(L("github.failed.useToken")) {
                dismiss()
                if let onUseToken { onUseToken() } else { SettingsTab.open(.github) }
            }
            .buttonStyle(.brandSecondary)
            if ghAvailable {
                Button {
                    connector.start(.ghCLI, state: state)
                } label: {
                    Label(L("github.useCLI"), systemImage: "terminal")
                }
                .buttonStyle(.brandPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        if org {
            Button(L("github.org.howTo")) { showOrgHelp = true }.buttonStyle(.brandPrimary)
        } else if !notConfigured {
            Button(L("accounts.failed.retry")) { connector.phase = .trust }
                .buttonStyle(.brandPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(Brand.motion.animation(fast: true)) { copied = true }
    }
}

/// The icon square at the top of a connect / blocked sheet: `accentSoft` tile, `accent` glyph.
struct SheetIconTile: View {
    let symbol: String
    var tone: Color = Brand.color.accent
    var background: Color = Brand.color.accentSoft
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(Brand.font(size * 0.45, .medium))
            .foregroundStyle(tone)
            .frame(width: size, height: size)
            .background(background, in: RoundedRectangle(cornerRadius: Brand.radius.control + 2, style: .continuous))
    }
}

// MARK: - Organization approval

/// "Tu organización tiene que aprobar secondbrain en GitHub" (§13.1): what an org owner does, what to do with SAML SSO,
/// and the way around it (a personal token).
struct GitHubOrgHelpSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// Ajustes → GitHub: "Pegar un token personal" closes the sheet and shows the token field there.
    var onUseToken: (() -> Void)? = nil

    private var clientId: String? { GitHubAuth.clientId(config: state.config) }
    private var ssoURL: URL? {
        clientId.flatMap { URL(string: "https://github.com/settings/connections/applications/\($0)") }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("github.org.title"))
                    .font(Brand.title)
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("github.org.subtitle"))
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("github.org.owner")).font(Brand.section).foregroundStyle(Brand.color.text)
                        NumberedSteps(steps: (1...4).map { L("github.org.owner.\($0)") })
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("github.org.sso")).font(Brand.section).foregroundStyle(Brand.color.text)
                        NumberedSteps(steps: (1...2).map { L("github.org.sso.\($0)") })
                        if let ssoURL {
                            Button {
                                NSWorkspace.shared.open(ssoURL)
                            } label: {
                                Label(L("github.org.sso.open"), systemImage: "safari")
                            }
                            .buttonStyle(.brandSecondary)
                            .padding(.leading, 30)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("github.org.token")).font(Brand.section).foregroundStyle(Brand.color.text)
                        Text(L("settings.github.orgTokenDetail"))
                            .foregroundStyle(Brand.color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 14) {
                            if let onUseToken {
                                Button {
                                    dismiss()
                                    onUseToken()
                                } label: {
                                    Label(L("github.failed.useToken"), systemImage: "key")
                                }
                                .buttonStyle(.brandSecondary)
                            }
                            Button(L("github.token.create")) { NSWorkspace.shared.open(GitHubAuth.personalTokenHelpURL) }
                                .buttonStyle(.settingsExternalLink)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .brandScrollEdgeFade(.top)
            .brandScrollEdgeFade(.bottom)
            BrandSheetFooter {
                Spacer()
                Button(L("common.close")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 380, idealHeight: 520)
        .background(Brand.color.surface)
    }
}
