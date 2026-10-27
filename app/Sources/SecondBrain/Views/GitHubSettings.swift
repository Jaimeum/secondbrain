import AppKit
import BrainCore
import SwiftUI

/// Ajustes → GitHub (CONTRACT §13.1, §13.6): the connected account or the ways to connect (device flow, the GitHub CLI's
/// session), how often the repos refresh, the last sync, and "Avanzado" (own client id, a pasted personal token).
/// Embedded in `SettingsView`'s Form.
struct GitHubSection: View {
    @Environment(AppState.self) private var state
    @ViewState private var connect: GitHubConnectRequest?
    @ViewState private var showOrgHelp = false
    @ViewState private var ghAvailable = false

    private var github: GitHubStore { state.engine.github }
    private var model: GitHubModel { GitHubModel.shared }

    var body: some View {
        Section {
            if let account = github.account {
                GitHubAccountRow(account: account) { github.disconnect() }
            } else if github.isConnected {
                // SB_GITHUB_TOKEN: a token without account.json (CLI / development).
                Label(L("github.envToken"), systemImage: "terminal").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("github.none")).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button {
                            connect = GitHubConnectRequest(method: .deviceFlow)
                        } label: {
                            Label(L("github.connect"), systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        .buttonStyle(.borderedProminent)
                        if ghAvailable {
                            Button(L("github.useCLI")) { connect = GitHubConnectRequest(method: .ghCLI) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Picker(L("github.interval"), selection: intervalBinding) {
                ForEach(GitHubLimits.syncIntervalChoices, id: \.self) { Text(GitHubModel.intervalTitle($0)).tag($0) }
            }

            LabeledContent(L("github.lastSync")) {
                HStack(spacing: 8) {
                    if model.isSyncing || !github.syncing.isEmpty {
                        ProgressView().controlSize(.small)
                        Text(L("repos.syncing")).foregroundStyle(.secondary)
                    } else {
                        Text(github.lastGlobalSyncAt.map(Fmt.relative) ?? L("github.lastSync.never")).foregroundStyle(.secondary)
                        Button(L("github.syncNow")) { model.syncNow(state: state) }
                            .disabled(!github.isConnected || github.repos.isEmpty)
                    }
                }
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GitHubAdvancedFields()
        } header: {
            Text(L("github.section"))
        } footer: {
            HStack {
                Label(L("github.footer"), systemImage: "lock.shield").foregroundStyle(.secondary)
                Spacer()
                Button(L("github.org.trouble")) { showOrgHelp = true }.buttonStyle(.link)
            }
        }
        .sheet(item: $connect) { request in GitHubConnectSheet(method: request.method) }
        .sheet(isPresented: $showOrgHelp) { GitHubOrgHelpSheet() }
        .task {
            if github.isDemo { ghAvailable = true; return }
            ghAvailable = await Task.detached(priority: .utility) { GitHubAuth.locateGH() != nil }.value
        }
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { state.config.githubSyncMinutes }, set: { value in state.update { $0.githubSyncMinutes = value } })
    }
}

struct GitHubConnectRequest: Identifiable {
    let id = UUID()
    var method: GitHubAuthMethod
}

private struct GitHubAccountRow: View {
    let account: GitHubAccount
    var onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GitHubAvatar(account: account, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name.map { "\($0) (@\(account.login))" } ?? "@\(account.login)")
                Text(methodText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("accounts.disconnect"), role: .destructive, action: onDisconnect)
        }
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

/// The account's avatar (from GitHub), or its initial while it loads / without network.
struct GitHubAvatar: View {
    let account: GitHubAccount
    var size: CGFloat = 26

    var body: some View {
        AsyncImage(url: account.avatarURL.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String(account.login.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: size, height: size)
                .background(Color(nsColor: .labelColor), in: Circle())
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// "Avanzado" (folded): own OAuth App client id and a pasted personal access token.
private struct GitHubAdvancedFields: View {
    @Environment(AppState.self) private var state
    @ViewState private var token = ""
    @ViewState private var saving = false
    @ViewState private var message: (text: String, ok: Bool)?

    var body: some View {
        DisclosureGroup(L("github.advanced")) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L("github.clientId"), text: clientIdBinding)
                Text(L("github.clientId.hint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField(L("github.token"), text: $token).onSubmit(saveToken)
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L("github.token.save"), action: saveToken)
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack(spacing: 4) {
                    Text(L("github.token.hint")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(L("github.token.create"), destination: GitHubAuth.personalTokenHelpURL).font(.caption)
                }
                if let message {
                    Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(message.ok ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
    }

    private var clientIdBinding: Binding<String> {
        Binding(get: { state.config.oauth.githubClientId ?? "" }, set: { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            state.update { $0.oauth.githubClientId = trimmed.isEmpty ? nil : trimmed }
        })
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
    @ViewState private var connector: GitHubConnector
    @ViewState private var copied = false
    @ViewState private var showOrgHelp = false

    init(method: GitHubAuthMethod = .deviceFlow, preview: GitHubConnectPhase? = nil) {
        self.method = method
        _connector = ViewState(initialValue: GitHubConnector(phase: preview ?? .trust))
    }

    var body: some View {
        Group {
            switch connector.phase {
            case .trust: trust
            case .code(let code): codeStep(code)
            case .working: working
            case .failed(let message, let org, let notConfigured): failed(message, org: org, notConfigured: notConfigured)
            }
        }
        .frame(width: 460)
        .animation(.easeInOut(duration: 0.2), value: connector.phase)
        .onChange(of: connector.connected) { if connector.connected != nil { dismiss() } }
        .onDisappear { connector.cancel() }
        .sheet(isPresented: $showOrgHelp) { GitHubOrgHelpSheet() }
    }

    // MARK: Trust (§13.6: 👁 · 💻 · 🔌)

    private var trust: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 38, height: 38)
                    .background(Color(nsColor: .labelColor), in: Circle())
                Text(L("github.trust.title")).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 18) {
                TrustLine(symbol: "eye", tint: .blue, title: L("github.trust.read"), detail: L("github.trust.readDetail"))
                TrustLine(symbol: "laptopcomputer", tint: .green, title: L("github.trust.local"), detail: L("github.trust.localDetail"))
                TrustLine(symbol: "powerplug", tint: .orange, title: L("github.trust.disconnect"), detail: L("github.trust.disconnectDetail"))
            }
            Text(method == .ghCLI ? L("github.trust.cliHint") : L("github.trust.browserHint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    connector.start(method, state: state)
                } label: {
                    if method == .ghCLI {
                        Label(L("github.useCLI"), systemImage: "terminal")
                    } else {
                        Label(L("common.continue"), systemImage: "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(28)
    }

    // MARK: Device code

    private func codeStep(_ code: GitHubDeviceCode) -> some View {
        VStack(spacing: 14) {
            Text(L("github.code.title")).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(L("github.code.hint")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(code.userCode)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(4)
                .textSelection(.enabled)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
            HStack(spacing: 10) {
                Button {
                    copy(code.userCode)
                } label: {
                    Label(copied ? L("github.code.copied") : L("github.code.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    copy(code.userCode)
                    NSWorkspace.shared.open(code.verificationURI)
                } label: {
                    Label(L("github.code.open"), systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("github.code.waiting")).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            Button(L("common.cancel")) { connector.cancel(); dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var working: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(method == .ghCLI ? L("github.working.cli") : L("github.working")).font(.headline)
            Button(L("common.cancel")) { connector.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private func failed(_ message: String, org: Bool, notConfigured: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: org ? "building.2" : "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            Text(L("github.failed.title")).font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if notConfigured {
                Text(L("github.failed.notConfigured"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                if org {
                    Button(L("github.org.howTo")) { showOrgHelp = true }.buttonStyle(.borderedProminent)
                } else if !notConfigured {
                    Button(L("accounts.failed.retry")) { connector.phase = .trust }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

// MARK: - Organization approval

/// "Tu organización tiene que aprobar SecondBrain en GitHub" (§13.1): what an org owner does, what to do with SAML SSO,
/// and the way around it (a personal token).
struct GitHubOrgHelpSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private var clientId: String? { GitHubAuth.clientId(config: state.config) }
    private var ssoURL: URL? {
        clientId.flatMap { URL(string: "https://github.com/settings/connections/applications/\($0)") }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("github.org.title")).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(L("github.org.subtitle")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("github.org.owner")).font(.headline)
                        NumberedSteps(steps: (1...4).map { L("github.org.owner.\($0)") })
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("github.org.sso")).font(.headline)
                        NumberedSteps(steps: (1...2).map { L("github.org.sso.\($0)") })
                        if let ssoURL {
                            Button {
                                NSWorkspace.shared.open(ssoURL)
                            } label: {
                                Label(L("github.org.sso.open"), systemImage: "safari")
                            }
                            .padding(.leading, 30)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("github.org.token")).font(.headline)
                        Text(L("github.org.token.detail")).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(destination: GitHubAuth.personalTokenHelpURL) {
                            Label(L("github.token.create"), systemImage: "key")
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
    }
}
