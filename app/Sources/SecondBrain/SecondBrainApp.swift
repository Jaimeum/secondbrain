import AppKit
import BrainCore
import SwiftUI

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
            CommandGroup(replacing: .newItem) {}
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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Snapshot mode (development) must not take focus or show windows on the user's screen.
        let snapshot = MainActor.assumeIsolated { DebugSnapshots.directory != nil }
        NSApp.setActivationPolicy(snapshot ? .prohibited : .regular)
        // Before any window shows, so a forced light/dark theme never flashes the system one.
        MainActor.assumeIsolated { AppState.applyAppearance(AppState.shared.config.appearance) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let snapshot = MainActor.assumeIsolated { DebugSnapshots.directory != nil }
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
