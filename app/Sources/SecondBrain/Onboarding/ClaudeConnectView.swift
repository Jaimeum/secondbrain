import AppKit
import BrainCore
import Observation
import SwiftUI

@MainActor @Observable
final class ClaudeConnectModel {
    enum Install: Equatable { case checking, missing, installing, installed(URL), failed }
    enum Auth: Equatable { case unknown, verifying, connected, failed }

    var install: Install = .checking
    var auth: Auth = .unknown
    var installLog = ""
    var showTerminal = false
    var terminalRun = 0
    var pastedToken = ""
    var pasteError: String?

    var claudeURL: URL? {
        if case .installed(let url) = install { return url }
        return nil
    }

    func locate(config: AppConfig, autoVerify: Bool) {
        install = .checking
        Task {
            let url = await Task.detached { ClaudeSetup.locate(config: config) }.value
            if let url {
                install = .installed(url)
                if autoVerify, ClaudeSetup.loadToken() != nil { verify(config: config) }
            } else {
                install = .missing
            }
        }
    }

    func runInstall(state: AppState) {
        install = .installing
        installLog = ""
        Task {
            do {
                let url = try await ClaudeSetup.install { line in
                    Task { @MainActor in
                        self.installLog += line.hasSuffix("\n") ? line : line + "\n"
                    }
                }
                state.update { $0.claudePath = url.path }
                install = .installed(url)
            } catch {
                install = .failed
            }
        }
    }

    func received(token: String, config: AppConfig) {
        do {
            try ClaudeSetup.saveToken(token)
            showTerminal = false
            verify(config: config)
        } catch {
            auth = .failed
        }
    }

    func submitPasted(config: AppConfig) {
        let text = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = ClaudeSetup.extractToken(from: text) else {
            pasteError = L("claude.pasteInvalid")
            return
        }
        pasteError = nil
        pastedToken = ""
        received(token: token, config: config)
    }

    func verify(config: AppConfig) {
        auth = .verifying
        Task {
            auth = await ClaudeSetup.checkAuth(config: config) ? .connected : .failed
        }
    }
}

/// Detect → install → connect account → verify. Used by onboarding and by Settings ("Reconectar Claude").
struct ClaudeConnectView: View {
    @Environment(AppState.self) private var state
    @ViewState private var model = ClaudeConnectModel()
    var autoVerify = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.install {
            case .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L("claude.looking"))
                }
            case .missing, .failed:
                installCard
            case .installing:
                installCard
            case .installed:
                connectSection
            }
        }
        .onAppear { if model.install == .checking { model.locate(config: state.config, autoVerify: autoVerify) } }
    }

    private var installCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("claude.missingTitle")).font(.title3.weight(.semibold))
            Text(L("claude.missingMessage")).foregroundStyle(.secondary)
            if model.install == .failed {
                Label(L("claude.installFailed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button {
                    model.runInstall(state: state)
                } label: {
                    Label(model.install == .installing ? L("claude.installing") : L("claude.install"),
                          systemImage: "arrow.down.circle")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.install == .installing)
                if model.install == .installing { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("claude.checkAgain")) { model.locate(config: state.config, autoVerify: autoVerify) }
                    .buttonStyle(.link)
            }
            if !model.installLog.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.installLog)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("log")
                    }
                    .frame(height: 120)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: model.installLog) { proxy.scrollTo("log", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder private var connectSection: some View {
        switch model.auth {
        case .connected:
            HStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: model.auth)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("claude.connectedTitle")).font(.title2.weight(.semibold))
                    Text(L("claude.connectedMessage")).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
        case .verifying:
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("claude.verifying")).font(.headline)
                    Text(L("claude.verifyingHint")).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
        case .unknown, .failed:
            connectOptions
        }
    }

    private var connectOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("claude.found"), systemImage: "checkmark.circle").foregroundStyle(.green)
            if model.auth == .failed {
                Label(L("claude.verifyFailed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(L("claude.connectTitle")).font(.title3.weight(.semibold))
            Text(L("claude.connectMessage")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if model.showTerminal, let url = model.claudeURL {
                ClaudeTerminalView(executable: url,
                                   onToken: { model.received(token: $0, config: state.config) },
                                   onExit: { _ in })
                    .id(model.terminalRun)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                HStack {
                    Text(L("claude.terminalHint")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("claude.restartTerminal")) { model.terminalRun += 1 }.buttonStyle(.link)
                }
            } else {
                Button {
                    model.terminalRun += 1
                    model.showTerminal = true
                } label: {
                    Label(L("claude.connect"), systemImage: "person.badge.key")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 12) {
                Button(L("claude.alreadyLoggedIn")) { model.verify(config: state.config) }
                Spacer()
            }

            DisclosureGroup(L("claude.pasteTitle")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SecureField("sk-ant-oat…", text: $model.pastedToken)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.submitPasted(config: state.config) }
                        Button(L("claude.pasteSave")) { model.submitPasted(config: state.config) }
                            .disabled(model.pastedToken.isEmpty)
                    }
                    if let error = model.pasteError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }
}

struct ReconnectClaudeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("claude.reconnectTitle")).font(.title2.weight(.semibold))
                Spacer()
                Button(L("common.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ClaudeConnectView(autoVerify: false)
        }
        .padding(24)
        .frame(width: 640)
        .frame(minHeight: 360)
    }
}
