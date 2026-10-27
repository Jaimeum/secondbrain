import AppKit
import BrainCore
import SwiftUI
import UserNotifications

@main
struct SecondBrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var state = AppState.shared

    init() {
        // System menus (Edit, View, Window…) are localized by AppKit from AppleLanguages when the app finishes
        // launching, so the preference has to be in place before that.
        AppState.applyMenuLanguage(AppState.shared.config.uiLanguage)
        // Inter must be registered before the first view asks for `Brand.font`.
        BrandFonts.register()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ZStack {
                RootView()
                    .environment(state)
                    .id(state.config.uiLanguage)
                // Outside RootView's identity: plays once per launch, never on a vault or language switch.
                LaunchOverlay()
            }
            .brandEnvironment()
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("sidebar.newProject")) { state.showNewProject = true }
                    .keyboardShortcut("n")
                    .disabled(!state.config.onboardingComplete || !state.engineStarted)
            }
            // MARK: v0.5 navigation (CONTRACT §15.2): ⌘1–5 and ⌘K.
            CommandMenu(L("menu.go")) {
                Button(L("home.title")) { go(.home) }.keyboardShortcut("1")
                Button(L("sidebar.meetings")) { go(.meetings) }.keyboardShortcut("2")
                Button(L("sidebar.mail")) { go(.mail) }.keyboardShortcut("3")
                Button(L("tasks.title")) { go(.tasks) }.keyboardShortcut("4")
                Button(L("sidebar.people")) { go(.people) }.keyboardShortcut("5")
                Divider()
                // Not over a sheet: the palette would open under it, out of reach.
                Button(L("menu.search")) { state.searchPresented.toggle() }
                    .keyboardShortcut("k")
                    .disabled(!state.config.onboardingComplete || state.showNewProject || state.emailRequest != nil
                              || state.noteRequest != nil)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(L("email.pasteMenu")) { state.requestEmail() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(!state.config.onboardingComplete || !state.engineStarted)
            }
            CommandGroup(after: .toolbar) {
                Picker(L("theme.title"), selection: Binding(get: { state.config.appearance },
                                                            set: { mode in state.update { $0.appearance = mode } })) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode.rawValue)
                    }
                }
                Divider()
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(state)
                .id(state.config.uiLanguage)
                .brandEnvironment()
        } label: {
            MenuBarLabel(isRecording: state.isRecording)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(state)
                .id(state.config.uiLanguage)
                .brandEnvironment()
        }
    }

    private func go(_ item: SidebarItem) {
        state.searchPresented = false
        // ⌘1 on Inicio goes back to its root (from a page, the timeline, the graph, Sin asignar…).
        if item == .home, state.selection?.normalized == .home { state.homePopToken += 1 }
        state.selection = item
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter traps outside a real .app bundle (the bare `swift build` binary), as in Notifier.
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Snapshot mode (development) must not take focus or show windows on the user's screen.
        let snapshot = MainActor.assumeIsolated { DebugSnapshots.directory != nil }
        NSApp.setActivationPolicy(snapshot ? .prohibited : .regular)
        // Before any window shows, so a forced light/dark theme never flashes the system one.
        MainActor.assumeIsolated { AppState.applyAppearance(AppState.shared.config.appearance) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let snapshot = MainActor.assumeIsolated { DebugSnapshots.directory != nil }
        if !snapshot, notificationsAvailable { UNUserNotificationCenter.current().delegate = self }
        MainActor.assumeIsolated {
            AppState.shared.launch()
            if snapshot {
                NSApp.windows.forEach { $0.orderOut(nil) }
                BrandGallery.renderIfRequested()   // SB_SNAPSHOT_ONLY=brand
                DebugSnapshots.runIfRequested(state: AppState.shared)
            }
        }
        if !snapshot { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = MainActor.assumeIsolated { AppState.shared }
        guard MainActor.assumeIsolated({ state.isRecording }) else { return .terminateNow }
        // Close the recording cleanly so the meeting still gets transcribed.
        Task { @MainActor in
            await state.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A Claude run cut short is recorded (and undoable) on the next launch; don't let it keep editing.
        ClaudeRunner.terminateAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    // MARK: Notifications (CONTRACT §15.2: "Por ordenar" and failures select Inicio; "Listo" opens what was learned)

    /// Shown even while SecondBrain is in front (a recording finishing is news wherever you are).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Notification ids are `AppState.notifyOnce` keys: `inbox-<source>`, `failed-<source>-…`, `done-<source>-…`, `job-…`,
    /// `rate-…`, `hist-…`.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        Task { @MainActor in
            Self.route(notificationId: id)
            completionHandler()
        }
    }

    @MainActor private static func route(notificationId id: String) {
        let state = AppState.shared
        NSApp.activate(ignoringOtherApps: true)
        // The main window (WindowGroup "main": SwiftUI names its windows "main-AppWindow-n") to the front.
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        state.searchPresented = false
        if id.hasPrefix("done-") {
            let rest = id.dropFirst("done-".count)
            if let source = state.engine.sources.first(where: { rest.hasPrefix($0.id + "-") || rest == $0.id }) {
                state.open(source: source)
                return
            }
        }
        if id.hasPrefix("inbox-") || id.hasPrefix("failed-") || id.hasPrefix("done-") {
            state.selection = .home
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.config.onboardingComplete {
                // A vault switch rebuilds the window content so no page, chat or list from the old vault lingers.
                MainView().id(state.vaultGeneration)
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 920, minHeight: 620)   // CONTRACT §15.3
    }
}

/// The brand symbol in the menu bar (an 18 pt template image); while recording, the same symbol plus a `record` dot.
struct MenuBarLabel: View {
    let isRecording: Bool

    var body: some View {
        Image(nsImage: isRecording ? BrandMenuBarIcon.recording : BrandMenuBarIcon.idle)
    }
}
