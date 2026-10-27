import AppKit
import BrainCore
import Recorder
import SwiftUI

/// Six steps (CONTRACT §15.2): Bienvenida (consent + where the brain is saved) → Permisos → Claude → Tú y tu primer
/// proyecto → Cuentas (optional) → Listo. The transcription model downloads in the background from the moment the
/// welcome is accepted; its status shows on Listo (and in the sidebar footer afterwards).
enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, claude, project, accounts, done

    /// The step survives a relaunch (macOS often needs one after granting Screen Recording), keyed by the
    /// config file so an isolated `SB_CONFIG` doesn't resume someone else's setup. ("step5": the v0.5 numbering; an
    /// older saved step restarts at the welcome.)
    private static var key: String { "onboarding.step5|" + AppConfig.configURL.path }
    private static var legacyKey: String { "onboarding.step|" + AppConfig.configURL.path }

    static var saved: OnboardingStep {
        OnboardingStep(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .welcome
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: Self.key) }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var step: OnboardingStep = .saved
    // Resuming past the welcome step means consent was already given before the relaunch.
    @ViewState private var consent = OnboardingStep.saved != .welcome
    @ViewState private var form = ProjectForm()
    @ViewState private var projectError: String?
    @ViewState private var createdProject: Project?

    /// `initialStep`: development snapshots open a given step; normally the saved one (or the welcome).
    init(initialStep: OnboardingStep? = nil) {
        let step = initialStep ?? .saved
        _step = ViewState(initialValue: step)
        _consent = ViewState(initialValue: step != .welcome)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                        .frame(maxWidth: 600, alignment: .leading)
                        .transition(.opacity)
                        .id(step)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 48)
                .padding(.top, 36)
                .padding(.bottom, 24)
            }
            footer
        }
        .background(Brand.color.surface)
        .animation(Brand.motion.animation(reduceMotion: reduceMotion), value: step)
        .onAppear {
            // Resumed after a relaunch on a step that needs the engine (projects, owner name).
            if step.rawValue >= OnboardingStep.project.rawValue { state.startEngine() }
            if step != .welcome { Self.prepareModelsInBackground(state) }
        }
        .onChange(of: step) { step.save() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .claude:
            StepHeader(symbol: "sparkles", title: L("onb.claude.title"), message: L("onb.claude.message"))
            ClaudeConnectView().padding(.top, 24)
        case .project:
            StepHeader(symbol: "folder.badge.plus", title: L("onb.you.title"), message: L("onb.you.message"))
            VStack(alignment: .leading, spacing: 16) {
                OwnerNameField()
                OwnerAddressesField()
                Rectangle().fill(Brand.color.line).frame(height: 1).padding(.vertical, 4)
                ProjectFormFields(form: $form)
                if let projectError { Text(projectError).foregroundStyle(Brand.color.danger) }
            }
            .padding(.top, 24)
        case .accounts: AccountsStep()
        case .done: DoneStep()
        }
    }

    /// Pinned under the scroll view: on the welcome the consent card sits here, so it is never below the fold.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Brand.color.line).frame(height: 1)
            if step == .welcome {
                ConsentCard(consent: $consent)
                    .frame(maxWidth: 600)
                    .padding(.horizontal, 48)
                    .padding(.top, 14)
            }
            HStack(spacing: 8) {
                if step != .welcome && step != .done {
                    Button(L("common.back")) { go(-1) }
                        .buttonStyle(.brandSecondary)
                        .controlSize(.large)
                        .disabled(state.isSwitchingVault)
                }
                Spacer()
                if step == .project {
                    Button(L("onb.skip")) { go(1) }
                        .buttonStyle(.brandSecondary)
                        .controlSize(.large)
                }
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.brandPrimary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .welcome && !consent || step == .project && !form.isValid || state.isSwitchingVault)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            // Centered on the window whatever buttons are on each side (the last step has no "Atrás").
            .overlay { ProgressDots(count: OnboardingStep.allCases.count, current: step.rawValue).allowsHitTesting(false) }
        }
        .background(Brand.color.bg)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: L("onb.start")
        // Back on this step after creating it: the project exists, so the button only continues (and saves edits).
        case .project: createdProject == nil ? L("onb.project.create") : L("common.continue")
        case .done: L("onb.finish.open")
        case .accounts where !state.engine.accounts.hasAccounts: L("onb.accounts.later")
        default: L("common.continue")
        }
    }

    private func primaryAction() {
        switch step {
        case .project:
            do {
                if var project = createdProject {
                    // Atrás → Crear y continuar again must not make a second project ("…-2"): edit the first one.
                    let description = form.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    if project.name != form.trimmedName || project.emoji != form.emoji || project.description != description {
                        project.name = form.trimmedName
                        project.emoji = form.emoji
                        project.description = description
                        try state.updateProject(project)
                        createdProject = project
                    }
                } else {
                    createdProject = try state.createProject(name: form.trimmedName, description: form.description, emoji: form.emoji)
                }
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
        // Leaving the welcome: the brain's folder is settled and the model download can start (in the background).
        if step == .welcome && delta > 0 { Self.prepareModelsInBackground(state) }
        // Projects and the owner fields need a started engine.
        if next == .project { state.startEngine() }
        step = next
    }

    /// The same engine call as before (`AppState.prepareModels`, idempotent); never in development snapshots.
    static func prepareModelsInBackground(_ state: AppState) {
        guard DebugSnapshots.directory == nil else { return }
        state.prepareModels()
    }
}

struct ProgressDots: View {
    let count: Int
    let current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Brand.color.accent : (i < current ? Brand.color.sage : Brand.color.line))
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .animation(Brand.motion.animation(fast: true, reduceMotion: reduceMotion), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(current + 1) / \(count)"))
    }
}

struct StepHeader: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(Brand.font(30))
                .foregroundStyle(Brand.color.accent)
            Text(title)
                .font(Brand.font(26, .semibold))
                .foregroundStyle(Brand.color.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(Brand.font(15))
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    BrandMark(size: 44)
                    BrandWordmark(size: 24)
                }
                Text(L("onb.welcome.title"))
                    .font(Brand.font(26, .semibold))
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("onb.welcome.message"))
                    .font(Brand.font(15))
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LanguageSwitch()
            if state.menuLanguageNeedsRestart { MenuLanguageNotice() }

            VStack(alignment: .leading, spacing: 12) {
                Feature(symbol: "waveform", text: L("onb.welcome.feature1"))
                Feature(symbol: "lock.shield", text: L("onb.welcome.feature2"))
                Feature(symbol: "book", text: L("onb.welcome.feature3"))
            }

            VaultLine()
        }
    }
}

/// "Se guarda en ~/Documents/SecondBrain · Cambiar…" (the former vault step, now one line).
private struct VaultLine: View {
    @Environment(AppState.self) private var state

    private var path: String {
        state.config.vaultURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Brand.color.text2)
                Text(L("onb.saveIn", path))
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "·").foregroundStyle(Brand.color.text3)
                Button(L("onb.change")) { VaultPicker.choose(state: state) }
                    .buttonStyle(.settingsLink)
                    .disabled(state.isSwitchingVault)
            }
            .help(L("onb.vault.hint"))
            if state.isSwitchingVault { VaultSwitchingNotice() }
        }
    }
}

/// Recording consent: the checkbox enables "Empezar". Lives in the pinned footer of the welcome.
private struct ConsentCard: View {
    @Binding var consent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised")
                .font(Brand.font(15, .medium))
                .foregroundStyle(Brand.color.warning)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("onb.consent.title")).font(Brand.callout).foregroundStyle(Brand.color.text)
                Text(L("onb.consent.message"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("onb.consent.accept"), isOn: $consent)
                    .toggleStyle(.checkbox)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Brand.color.warningSoft, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
    }
}

private struct LanguageSwitch: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Picker("", selection: Binding(get: { state.config.uiLanguage }, set: { lang in state.update { $0.uiLanguage = lang } })) {
            Text(verbatim: "Español").tag("es")
            Text(verbatim: "English").tag("en")
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(Brand.font(17))
                .foregroundStyle(Brand.color.accent)
                .frame(width: 28)
            Text(text).foregroundStyle(Brand.color.text).fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(symbol: "lock.open", title: L("onb.perm.title"), message: L("onb.perm.message"))
            PermissionCard(symbol: "speaker.wave.2", title: L("onb.perm.screenTitle"), message: L("onb.perm.screenMessage"),
                           granted: permissions.screenAudio, asked: askedScreen,
                           request: {
                               askedScreen = true
                               OnboardingStep.askedScreen = true
                               Task { _ = await Recorder.requestScreenCapture(); await refresh() }
                           },
                           openSettings: { Recorder.openPrivacySettings(.screenRecording) })
            PermissionCard(symbol: "mic", title: L("onb.perm.micTitle"), message: L("onb.perm.micMessage"),
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
                    Image(systemName: "arrow.clockwise").font(Brand.font(17)).foregroundStyle(Brand.color.accent)
                    Text(L("onb.perm.restartHint"))
                        .foregroundStyle(Brand.color.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L("onb.perm.reopen")) { AppState.shared.relaunch() }
                        .buttonStyle(.brandPrimary)
                }
                .padding(14)
                .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
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
        BrandCard(padding: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(Brand.font(18, .medium))
                    .foregroundStyle(granted ? Brand.color.onAccent : Brand.color.accent)
                    .frame(width: 40, height: 40)
                    .background(granted ? Brand.color.accent : Brand.color.accentSoft,
                                in: RoundedRectangle(cornerRadius: Brand.radius.control + 2, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Brand.callout).foregroundStyle(Brand.color.text)
                    Text(message).foregroundStyle(Brand.color.text2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if granted {
                    Label(L("onb.perm.granted"), systemImage: "checkmark.circle")
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.success)
                } else if asked {
                    Button(L("onb.perm.openSettings"), action: openSettings).buttonStyle(.brandSecondary)
                } else {
                    Button(L("onb.perm.allow"), action: request).buttonStyle(.brandPrimary)
                }
            }
        }
        .animation(Brand.motion.fast, value: granted)
    }
}

private struct DoneStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    BrandMark(size: 44)
                    BrandWordmark(size: 24)
                }
                Text(L("onb.done.title"))
                    .font(Brand.font(26, .semibold))
                    .foregroundStyle(Brand.color.text)
                Text(L("onb.done.message"))
                    .font(Brand.font(15))
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BrandCard(padding: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    // Menu bar (with what happens after each meeting) · ⌥⌘R · ⌘K, the "find without thinking" way in.
                    tip(icon: AnyView(BrandMark(size: 22)), title: L("onb.done.menuTitle"), message: L("onb.done.menuAfterMessage"))
                    tip(icon: AnyView(Text(verbatim: "⌥⌘R").font(Brand.font(12, .semibold)).foregroundStyle(Brand.color.accent)),
                        title: L("onb.done.hotkeyTitle"), message: L("onb.done.hotkeyMessage"))
                    tip(icon: AnyView(Text(verbatim: "⌘K").font(Brand.font(13, .semibold)).foregroundStyle(Brand.color.accent)),
                        title: L("onb.done.searchTitle"), message: L("onb.done.searchMessage"))
                }
            }
            ModelsStatusLine()
        }
        .onAppear { OnboardingView.prepareModelsInBackground(state) }
    }

    private func tip(icon: AnyView, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon
                .frame(width: 40, height: 40)
                .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control + 2, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.callout).foregroundStyle(Brand.color.text)
                Text(message).foregroundStyle(Brand.color.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The background model download, as one status line: "Descargando… 42 %" · ready · error + Reintentar. Recording
/// before it finishes still works: the engine waits for the model while the job says "Preparando el modelo…".
private struct ModelsStatusLine: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            if state.modelsReady {
                Label(L("onb.models.ready"), systemImage: "checkmark.circle")
                    .foregroundStyle(Brand.color.success)
            } else if let error = state.modelError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.color.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("onb.models.retry")) { state.prepareModels() }.buttonStyle(.brandSecondary)
            } else {
                // The hint tells the user they don't have to wait: readable (text2) and wrapping, never cut.
                VStack(alignment: .leading, spacing: 2) {
                    BrandLoader(size: 18, text: L("onb.models.downloading", Fmt.percent(state.modelProgress?.fraction ?? 0)))
                    Text(L("onb.models.hint"))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18 + Brand.spacing.s)
                }
            }
            Spacer(minLength: 0)
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
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(symbol: "person.crop.circle.badge.plus", title: L("onb.accounts.title"), message: L("onb.accounts.message"))
            BrandCard(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(state.engine.accounts.accounts) { account in
                        HStack(spacing: 10) {
                            ProviderBadge(provider: account.provider)
                            Text(account.provider == .local ? L("accounts.macCalendar") : account.email)
                                .foregroundStyle(Brand.color.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Image(systemName: "checkmark.circle").foregroundStyle(Brand.color.success)
                        }
                    }
                    // Once an account exists, the same single "Conectar otra cuenta ▾" as Ajustes.
                    ConnectAccountControls(connector: connector, help: $help, context: .onboarding,
                                           compact: !state.engine.accounts.accounts.isEmpty)
                    Label(L("readonly.promise"), systemImage: "lock.shield")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                }
            }
        }
        .sheet(item: $help) { request in OrgAccessHelpSheet(provider: request.provider) }
    }
}
