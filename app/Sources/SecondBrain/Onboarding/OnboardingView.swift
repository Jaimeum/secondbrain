import AppKit
import BrainCore
import Recorder
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, vault, permissions, claude, models, project, accounts, done   // v0.3: accounts (optional)

    /// The step survives a relaunch (macOS often needs one after granting Screen Recording), keyed by the
    /// config file so an isolated `SB_CONFIG` doesn't resume someone else's setup.
    private static var key: String { "onboarding.step|" + AppConfig.configURL.path }

    static var saved: OnboardingStep {
        OnboardingStep(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .welcome
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: Self.key) }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: askedScreenKey)
    }

    /// Whether the Screen Recording prompt was already shown (before a relaunch, too).
    private static var askedScreenKey: String { "onboarding.askedScreen|" + AppConfig.configURL.path }
    static var askedScreen: Bool {
        get { UserDefaults.standard.bool(forKey: askedScreenKey) }
        set { UserDefaults.standard.set(newValue, forKey: askedScreenKey) }
    }
}

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @ViewState private var step: OnboardingStep = .saved
    // Resuming past the welcome step means consent was already given before the relaunch.
    @ViewState private var consent = OnboardingStep.saved != .welcome
    @ViewState private var form = ProjectForm()
    @ViewState private var projectError: String?
    @ViewState private var createdProject: Project?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                        .frame(maxWidth: 600, alignment: .leading)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity))
                        .id(step)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 48)
                .padding(.top, 56)
                .padding(.bottom, 24)
            }
            footer
        }
        .background(.background)
        .animation(.easeInOut(duration: 0.25), value: step)
        .onAppear {
            // Resumed after a relaunch on a step that needs the engine (projects, owner name).
            if step.rawValue >= OnboardingStep.project.rawValue { state.startEngine() }
        }
        .onChange(of: step) { step.save() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep(consent: $consent)
        case .vault: VaultStep()
        case .permissions: PermissionsStep()
        case .claude:
            StepHeader(symbol: "sparkles", title: L("onb.claude.title"), message: L("onb.claude.message"))
            ClaudeConnectView().padding(.top, 24)
        case .models: ModelsStep()
        case .project:
            StepHeader(symbol: "folder.badge.plus", title: L("onb.project.title"), message: L("onb.project.message"))
            OwnerNameField().padding(.top, 24)
            OwnerEmailsField().padding(.top, 8)
            ProjectFormFields(form: $form).padding(.top, 16)
            if let projectError { Text(projectError).foregroundStyle(.red).padding(.top, 8) }
        case .accounts: AccountsStep()
        case .done: DoneStep()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button(L("common.back")) { go(-1) }
                    .controlSize(.large)
                    .disabled(state.isSwitchingVault)
            }
            Spacer()
            ProgressDots(count: OnboardingStep.allCases.count, current: step.rawValue)
            Spacer()
            if step == .project {
                Button(L("onb.skip")) { go(1) }.controlSize(.large)
            }
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(step == .welcome && !consent || step == .project && !form.isValid || state.isSwitchingVault)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: L("onb.start")
        case .project: L("onb.project.create")
        case .done: L("onb.finish")
        case .models where !state.modelsReady: L("onb.models.continueBackground")
        case .accounts where !state.engine.accounts.hasAccounts: L("onb.accounts.later")
        default: L("common.continue")
        }
    }

    private func primaryAction() {
        switch step {
        case .project:
            do {
                createdProject = try state.createProject(name: form.trimmedName, description: form.description, emoji: form.emoji)
                projectError = nil
                go(1)
            } catch {
                projectError = L("newProject.error")
            }
        case .done:
            OnboardingStep.clearSaved()
            state.completeOnboarding()
            if let createdProject {
                state.selection = .project(createdProject.slug)
                state.recordingProjectSlug = createdProject.slug
            }
        default:
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        // The vault location is settled once we leave that step; projects need a started engine.
        if next == .project { state.startEngine() }
        step = next
    }
}

struct ProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.primary.opacity(i < current ? 0.35 : 0.12))
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .animation(.spring(duration: 0.3), value: current)
    }
}

struct StepHeader: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    @Environment(AppState.self) private var state
    @Binding var consent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                StepHeader(symbol: "brain.head.profile", title: L("onb.welcome.title"), message: L("onb.welcome.message"))
                Spacer()
            }
            LanguageSwitch()
            if state.menuLanguageNeedsRestart { MenuLanguageNotice() }

            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "waveform", text: L("onb.welcome.feature1"))
                Feature(symbol: "lock.shield", text: L("onb.welcome.feature2"))
                Feature(symbol: "book", text: L("onb.welcome.feature3"))
            }

            VStack(alignment: .leading, spacing: 10) {
                Label(L("onb.consent.title"), systemImage: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(L("onb.consent.message"))
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("onb.consent.accept"), isOn: $consent)
                    .toggleStyle(.checkbox)
                    .padding(.top, 4)
            }
            .padding(16)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct LanguageSwitch: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Picker("", selection: Binding(get: { state.config.uiLanguage }, set: { lang in state.update { $0.uiLanguage = lang } })) {
            Text("Español").tag("es")
            Text("English").tag("en")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

private struct Feature: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VaultStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(symbol: "externaldrive", title: L("onb.vault.title"), message: L("onb.vault.message"))
            HStack(spacing: 14) {
                Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.config.vaultURL.lastPathComponent).font(.headline)
                    Text(state.config.vaultURL.deletingLastPathComponent().path
                        .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("onb.vault.change")) { VaultPicker.choose(state: state) }
                    .controlSize(.large)
                    .disabled(state.isSwitchingVault)
            }
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            if state.isSwitchingVault { VaultSwitchingNotice() }
            Text(L("onb.vault.hint")).font(.callout).foregroundStyle(.secondary)
        }
    }
}

enum VaultPicker {
    @MainActor static func choose(state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("onb.vault.choose")
        panel.message = L("onb.vault.panelMessage")
        panel.directoryURL = state.config.vaultURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // Picking a folder that already holds other things (e.g. Documents) must not turn all of it into the
        // wiki: Claude would be able to edit it and every change would snapshot it. Use a subfolder instead.
        let fm = FileManager.default
        let visible = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "Icon\r" }
        if !visible.isEmpty, !fm.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) {
            url = url.appendingPathComponent("SecondBrain", isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        state.update { $0.vaultPath = path }
    }
}

private struct PermissionsStep: View {
    @ViewState private var permissions = RecorderPermissions(screenAudio: false, microphone: false)
    @ViewState private var askedScreen = OnboardingStep.askedScreen
    @ViewState private var askedMic = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(symbol: "lock.open", title: L("onb.perm.title"), message: L("onb.perm.message"))
            PermissionCard(symbol: "speaker.wave.2.fill", title: L("onb.perm.screenTitle"), message: L("onb.perm.screenMessage"),
                           granted: permissions.screenAudio, asked: askedScreen,
                           request: {
                               askedScreen = true
                               OnboardingStep.askedScreen = true
                               Task { _ = await Recorder.requestScreenCapture(); await refresh() }
                           },
                           openSettings: { Recorder.openPrivacySettings(.screenRecording) })
            PermissionCard(symbol: "mic.fill", title: L("onb.perm.micTitle"), message: L("onb.perm.micMessage"),
                           granted: permissions.microphone, asked: askedMic,
                           request: {
                               askedMic = true
                               Task { _ = await Recorder.requestMicrophone(); await refresh() }
                           },
                           openSettings: { Recorder.openPrivacySettings(.microphone) })
            if askedScreen && !permissions.screenAudio {
                // macOS usually applies Screen Recording only to a fresh process. The step is saved, so the
                // relaunched app comes back right here.
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                    Text(L("onb.perm.restartHint")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L("onb.perm.reopen")) { AppState.shared.relaunch() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task {
            // Live re-check: the user grants access in System Settings while this screen is open.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func refresh() async {
        let now = await Recorder.permissions()
        if now != permissions { permissions = now }
    }
}

private struct PermissionCard: View {
    let symbol: String
    let title: String
    let message: String
    let granted: Bool
    let asked: Bool
    var request: () -> Void
    var openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(granted ? Color.green : Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label(L("onb.perm.granted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else if asked {
                Button(L("onb.perm.openSettings"), action: openSettings).controlSize(.large)
            } else {
                Button(L("onb.perm.allow"), action: request)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .animation(.default, value: granted)
    }
}

private struct ModelsStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(symbol: "cpu", title: L("onb.models.title"), message: L("onb.models.message"))
            VStack(alignment: .leading, spacing: 10) {
                if state.modelsReady {
                    Label(L("onb.models.ready"), systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                } else if let error = state.modelError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button(L("onb.models.retry")) { state.prepareModels() }
                } else {
                    ProgressView(value: state.modelProgress?.fraction ?? 0)
                        .controlSize(.large)
                    HStack {
                        Text(state.modelProgress?.message ?? L("onb.models.starting"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(Fmt.percent(state.modelProgress?.fraction ?? 0))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            Text(L("onb.models.hint")).font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { state.prepareModels() }
    }
}

private struct DoneStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(symbol: "checkmark.seal.fill", title: L("onb.done.title"), message: L("onb.done.message"))
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "brain")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("onb.done.menuTitle")).font(.headline)
                        Text(L("onb.done.menuMessage")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Text("⌥⌘R")
                        .font(.system(.headline, design: .rounded))
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("onb.done.hotkeyTitle")).font(.headline)
                        Text(L("onb.done.hotkeyMessage")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("onb.done.afterTitle")).font(.headline)
                        Text(L("onb.done.afterMessage")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: v0.3 accounts

/// Optional: connect mail and calendar now (one card), or "Más tarde" (CONTRACT §12.3).
private struct AccountsStep: View {
    @Environment(AppState.self) private var state
    @ViewState private var connector = AccountConnector()
    @ViewState private var help: OrgHelpRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(symbol: "envelope.badge", title: L("onb.accounts.title"), message: L("onb.accounts.message"))
            VStack(alignment: .leading, spacing: 14) {
                ForEach(state.engine.accounts.accounts) { account in
                    HStack(spacing: 10) {
                        ProviderBadge(provider: account.provider)
                        Text(account.provider == .local ? L("accounts.macCalendar") : account.email)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                ConnectAccountControls(connector: connector, help: $help, context: .onboarding)
                Label(L("accounts.footer"), systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
        .sheet(item: $help) { request in OrgAccessHelpSheet(provider: request.provider) }
    }
}
