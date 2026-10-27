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

/// Detect → install → connect account → verify. Used by onboarding and by Ajustes ("Reconectar Claude").
struct ClaudeConnectView: View {
    @Environment(AppState.self) private var state
    @ViewState private var model = ClaudeConnectModel()
    @ViewState private var showInstallLog = false
    @ViewState private var showTrouble = false
    var autoVerify = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.install {
            case .checking:
                BrandLoader(size: 20, text: L("claude.looking"))
            case .missing, .failed, .installing:
                installCard
            case .installed:
                connectSection
            }
        }
        .onAppear { if model.install == .checking { model.locate(config: state.config, autoVerify: autoVerify) } }
    }

    private var installCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("claude.missingTitle")).font(Brand.section).foregroundStyle(Brand.color.text)
            Text(L("claude.missingMessage")).foregroundStyle(Brand.color.text2).fixedSize(horizontal: false, vertical: true)
            if model.install == .failed {
                Label(L("claude.installFailed"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    model.runInstall(state: state)
                } label: {
                    Label(model.install == .installing ? L("claude.installing") : L("claude.install"),
                          systemImage: "arrow.down.circle")
                }
                .buttonStyle(.brandPrimary)
                .controlSize(.large)
                .disabled(model.install == .installing)
                if model.install == .installing { BrandLoader(size: 18) }
                Spacer()
                Button(L("claude.checkAgain")) { model.locate(config: state.config, autoVerify: autoVerify) }
                    .buttonStyle(.settingsLink)
            }
            if !model.installLog.isEmpty {
                // The raw installer output is for whoever wants it: folded.
                Disclosure(title: L("claude.details"), isOpen: $showInstallLog) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(model.installLog)
                                .font(Brand.font(11).monospaced())
                                .foregroundStyle(Brand.color.text2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id("log")
                        }
                        .frame(height: 120)
                        .padding(8)
                        .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.line))
                        .onChange(of: model.installLog) { proxy.scrollTo("log", anchor: .bottom) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var connectSection: some View {
        switch model.auth {
        case .connected:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle")
                    .font(Brand.font(22, .medium))
                    .foregroundStyle(Brand.color.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("claude.connectedTitle")).font(Brand.section).foregroundStyle(Brand.color.text)
                    Text(L("claude.connectedMessage")).foregroundStyle(Brand.color.text2)
                }
            }
            .padding(.vertical, 6)
        case .verifying:
            HStack(spacing: 12) {
                BrandLoader(size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("claude.verifying")).font(Brand.callout).foregroundStyle(Brand.color.text)
                    Text(L("claude.verifyingHint")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                }
            }
            .padding(.vertical, 6)
        case .unknown, .failed:
            connectOptions
        }
    }

    private var connectOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("claude.found"), systemImage: "checkmark.circle").foregroundStyle(Brand.color.success)
            if model.auth == .failed {
                Label(L("claude.verifyFailed"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("claude.connectTitle")).font(Brand.section).foregroundStyle(Brand.color.text)
            Text(L("claude.connectMessage")).foregroundStyle(Brand.color.text2).fixedSize(horizontal: false, vertical: true)

            if model.showTerminal, let url = model.claudeURL {
                ClaudeTerminalView(executable: url,
                                   onToken: { model.received(token: $0, config: state.config) },
                                   onExit: { _ in })
                    .id(model.terminalRun)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.line))
                HStack {
                    Text(L("claude.terminalHint")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                    Spacer()
                    Button(L("claude.restartTerminal")) { model.terminalRun += 1 }
                        .buttonStyle(.settingsLink)
                        .font(Brand.caption)
                }
            } else {
                Button {
                    model.terminalRun += 1
                    model.showTerminal = true
                } label: {
                    Label(L("claude.connect"), systemImage: "person.badge.key")
                }
                .buttonStyle(.brandPrimary)
                .controlSize(.large)
            }

            // The other ways in (already signed in, a pasted code) folded together.
            Disclosure(title: L("claude.trouble"), isOpen: $showTrouble) {
                VStack(alignment: .leading, spacing: 10) {
                    Button(L("claude.alreadyLoggedIn")) { model.verify(config: state.config) }
                        .buttonStyle(.brandSecondary)
                    Text(L("claude.pasteTitle")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                    HStack(spacing: 8) {
                        SecureField(text: $model.pastedToken) { Text(verbatim: "sk-ant-oat…") }
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.submitPasted(config: state.config) }
                        Button(L("claude.pasteSave")) { model.submitPasted(config: state.config) }
                            .buttonStyle(.brandSecondary)
                            .disabled(model.pastedToken.isEmpty)
                    }
                    if let error = model.pasteError {
                        Text(error).font(Brand.caption).foregroundStyle(Brand.color.danger)
                    }
                }
            }
        }
    }
}

/// A folded section with a plain header (title + rotating chevron) that lines up with the text around it.
private struct Disclosure<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Brand.motion.animation(fast: true)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(Brand.font(10, .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title)
                }
                .foregroundStyle(Brand.color.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { content }
        }
    }
}

/// "Reconectar Claude" (Ajustes → Cuentas, Preguntar, Preparar): the same flow in a sheet, "Listo" bottom-right like
/// every other sheet.
struct ReconnectClaudeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("claude.reconnectTitle")).font(Brand.title).foregroundStyle(Brand.color.text)
                    ClaudeConnectView(autoVerify: false)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            HStack {
                Spacer()
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 520)
        .background(Brand.color.surface)
    }
}
