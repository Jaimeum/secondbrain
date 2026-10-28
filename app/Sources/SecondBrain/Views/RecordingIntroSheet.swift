import AppKit
import BrainCore
import Recorder
import SwiftUI

// MARK: v0.6 — first "Grabar" (CONTRACT §16.11)
// Onboarding no longer asks for recording permissions nor downloads the transcription model: the first time any
// "Grabar" runs (sidebar, ⌘K, menu bar, ⌥⌘R, a meeting's own button), this short sheet explains what recording
// needs, asks for the two permissions (with the same "Reparar permiso" way out as the recording error), starts the
// model download in the background and asks for the consent that used to sit on the welcome. "Grabar" then runs the
// recording that was asked for.

/// The recording waiting for the sheet: the very call that was gated (plain, or a calendar event's).
struct RecordingIntroRequest: Identifiable {
    let id = UUID()
    let start: @MainActor () async -> Void
}

extension AppState {
    /// Set once the user went through the sheet (or already had the permissions from v0.5's onboarding), keyed by the
    /// config file like the onboarding's own state.
    private static var recordingIntroKey: String { "recording.introDone|" + AppConfig.configURL.path }

    var recordingIntroDone: Bool {
        get { UserDefaults.standard.bool(forKey: Self.recordingIntroKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.recordingIntroKey) }
    }

    /// True when the recording must wait for the first-recording sheet (MainView presents it from
    /// `recordingIntro`); `start` runs on its "Grabar". Someone upgrading with both permissions already granted
    /// passes straight through (they saw the consent in v0.5's onboarding), and their model loads as before.
    func needsRecordingIntro(then start: @escaping @MainActor () async -> Void) async -> Bool {
        if recordingIntroDone { return false }
        let permissions = await Recorder.permissions()
        if permissions.screenAudio && (permissions.microphone || !config.captureMic) {
            recordingIntroDone = true
            prepareModels()
            return false
        }
        recordingIntro = RecordingIntroRequest(start: start)
        // From the menu bar or ⌥⌘R the window may be behind other apps, or closed: the sheet lives on the main window.
        showMainWindow()
        return true
    }

    /// Brings the main window forward, reopening it when the user closed it (the app lives on in the menu bar).
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else if let open = openMainWindowAction {
            open()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        }
    }
}

/// "Antes de tu primera grabación": what recording does, the two permissions, the model download and the consent.
struct RecordingIntroSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: RecordingIntroRequest?

    @ViewState private var permissions = RecorderPermissions(screenAudio: false, microphone: false)
    @ViewState private var consent = false

    private var micNeeded: Bool { state.config.captureMic }
    private var ready: Bool { consent && permissions.screenAudio && (permissions.microphone || !micNeeded) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L("record.intro.title"), systemImage: "record.circle")
                            .font(Brand.title)
                            .foregroundStyle(Brand.color.text)
                        Text(L("record.intro.message"))
                            .font(Brand.body)
                            .foregroundStyle(Brand.color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    RecordingPermissionsView(permissions: $permissions)
                    ConsentCard(consent: $consent)
                    ModelsStatusLine().padding(.horizontal, 4)
                }
                .padding(20)
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            HStack(spacing: 8) {
                if !ready {
                    Text(consent ? L("record.intro.needsPermission") : L("record.intro.needsConsent"))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(L("common.cancel")) { close() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("record.start")) { start() }
                    .buttonStyle(.brandRecord)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Brand.color.bg)
        }
        .background(Brand.color.surface)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 520)
        // The model download starts with the sheet: it runs in the background whatever the user decides.
        .onAppear { if DebugSnapshots.directory == nil { state.prepareModels() } }
    }

    private func close() {
        state.recordingIntro = nil
        dismiss()
    }

    private func start() {
        state.recordingIntroDone = true
        let start = request?.start
        close()
        if let start { Task { await start() } }
    }
}

/// The two recording permissions, live-checked while on screen: "Permitir" → (after macOS's own prompt) "Abrir
/// Ajustes", and, once Screen Recording was asked for and still isn't seen, "Reabrir secondbrain" plus the same
/// "Reparar permiso" as the recording error (a switch already on in System Settings may belong to an older build).
struct RecordingPermissionsView: View {
    @Environment(AppState.self) private var state
    @Binding var permissions: RecorderPermissions
    @ViewState private var askedScreen = RecordingPermissionsView.askedScreen
    @ViewState private var askedMic = false

    /// Whether the Screen Recording prompt was already shown (before a relaunch, too).
    private static var askedScreenKey: String { "recording.askedScreen|" + AppConfig.configURL.path }
    static var askedScreen: Bool {
        get { UserDefaults.standard.bool(forKey: askedScreenKey) }
        set { UserDefaults.standard.set(newValue, forKey: askedScreenKey) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionCard(symbol: "speaker.wave.2", title: L("onb.perm.screenTitle"), message: L("onb.perm.screenMessage"),
                           granted: permissions.screenAudio, asked: askedScreen,
                           request: {
                               askedScreen = true
                               Self.askedScreen = true
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
            if askedScreen && !permissions.screenAudio { restartNotice }
            if let error = state.recordingError, error == L("record.repairFailed") {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            // Live re-check: the user grants access in System Settings while this is open.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// macOS usually applies Screen Recording only to a fresh process.
    private var restartNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.clockwise").font(Brand.font(17)).foregroundStyle(Brand.color.accent)
                Text(L("record.intro.restartHint"))
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { restartButtons }
                VStack(alignment: .leading, spacing: 8) { restartButtons }
            }
            .padding(.leading, 29)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
    }

    @ViewBuilder private var restartButtons: some View {
        Button(L("onb.perm.reopen")) { AppState.shared.relaunch() }
            .buttonStyle(.brandPrimary)
        Button(L("record.repairPermission")) { state.repairRecordingPermission() }
            .buttonStyle(.brandSecondary)
            .help(L("record.repairPermissionHelp"))
    }

    private func refresh() async {
        let now = await Recorder.permissions()
        if now != permissions { permissions = now }
    }
}

struct PermissionCard: View {
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

/// Recording consent: the checkbox enables "Grabar" (it used to sit on the onboarding's welcome).
struct ConsentCard: View {
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

/// The background model download, as one status line: "Descargando… 42 %" · ready · error + Reintentar. Recording
/// before it finishes still works: the engine waits for the model while the job says "Preparando el modelo…".
struct ModelsStatusLine: View {
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
                    Text(L("record.intro.modelsHint"))
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
