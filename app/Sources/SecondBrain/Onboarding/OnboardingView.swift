import AppKit
import BrainCore
import SwiftUI

/// Five steps (CONTRACT §16.11): Bienvenida (what a second brain of the whole day is + where it is saved) → Claude →
/// Tú y tu primer proyecto → Cuentas (optional) → Listo. Recording permissions, the consent and the transcription
/// model are not asked here: they wait for the first "Grabar" (`RecordingIntroSheet`).
enum OnboardingStep: Int, CaseIterable {
    case welcome, claude, project, accounts, done

    /// The step survives a relaunch, keyed by the config file so an isolated `SB_CONFIG` doesn't resume someone
    /// else's setup. ("step6": the v0.6 numbering; a step saved by an older version restarts at the welcome.)
    private static var key: String { "onboarding.step6|" + AppConfig.configURL.path }
    private static let legacyKeys = ["onboarding.step|", "onboarding.step5|"]

    static var saved: OnboardingStep {
        OnboardingStep(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .welcome
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: Self.key) }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: key)
        for legacy in legacyKeys { UserDefaults.standard.removeObject(forKey: legacy + AppConfig.configURL.path) }
        UserDefaults.standard.removeObject(forKey: "onboarding.askedScreen|" + AppConfig.configURL.path)
    }
}

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var step: OnboardingStep = .saved
    @ViewState private var form = ProjectForm()
    @ViewState private var projectError: String?
    @ViewState private var createdProject: Project?

    /// `initialStep`: development snapshots open a given step; normally the saved one (or the welcome).
    init(initialStep: OnboardingStep? = nil) {
        _step = ViewState(initialValue: initialStep ?? .saved)
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
        }
        .onChange(of: step) { step.save() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .claude:
            StepHeader(symbol: "sparkles", title: L("onb.claude.title"), message: L("onb.claude.message"))
            ClaudeConnectView().padding(.top, 24)
        case .project:
            StepHeader(symbol: "folder.badge.plus", title: L("onb.you.title"), message: L("onb.you.message"))
            VStack(alignment: .leading, spacing: 16) {
                OwnerNameField()
                OwnerAddressesField()
                Color.clear.frame(height: 8)   // space, not a hairline, between "you" and the first project (§15.1)
                ProjectFormFields(form: $form)
                if let projectError { Text(projectError).foregroundStyle(Brand.color.danger) }
            }
            .padding(.top, 24)
        case .accounts: AccountsStep()
        case .done: DoneStep()
        }
    }

    /// Pinned under the scroll view, so the primary button is never below the fold.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Brand.color.line).frame(height: 1)
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
                    .disabled(step == .project && !form.isValid || state.isSwitchingVault)
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
                state.navigate(to: .sidebar(.project(createdProject.slug)))
                state.recordingProjectSlug = createdProject.slug
            }
        default:
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        // Projects and the owner fields need a started engine.
        if next == .project { state.startEngine() }
        step = next
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
                Feature(symbol: "tray.full", text: L("onb.welcome.feature1"))
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
                    // Menu bar (capture first, recording as one more option) · the quick capture shortcut · ⌘K, the
                    // "find without thinking" way in (§16.10).
                    tip(icon: AnyView(BrandMark(size: 22)), title: L("onb.done.menuTitle"), message: L("onb.done.menuCaptureMessage"))
                    tip(icon: AnyView(Text(verbatim: state.config.captureHotkey.symbols).font(Brand.font(12, .semibold))
                                        .foregroundStyle(Brand.color.accent).lineLimit(1).minimumScaleFactor(0.7)),
                        title: L("onb.done.captureTitle"), message: L("onb.done.captureMessage", state.config.captureHotkey.symbols))
                    tip(icon: AnyView(Text(verbatim: "⌘K").font(Brand.font(13, .semibold)).foregroundStyle(Brand.color.accent)),
                        title: L("onb.done.searchTitle"), message: L("onb.done.searchMessage"))
                }
            }
        }
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
