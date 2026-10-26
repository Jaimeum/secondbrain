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
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(state)
                .id(state.config.uiLanguage)
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
        }

        MenuBarExtra {
            MenuBarView()
                .environment(state)
                .id(state.config.uiLanguage)
        } label: {
            MenuBarLabel(isRecording: state.isRecording)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(state)
                .id(state.config.uiLanguage)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Snapshot mode (development) must not take focus or show windows on the user's screen.
        let snapshot = MainActor.assumeIsolated { DebugSnapshots.directory != nil }
        NSApp.setActivationPolicy(snapshot ? .prohibited : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let snapshot = MainActor.assumeIsolated { DebugSnapshots.directory != nil }
        MainActor.assumeIsolated {
            AppState.shared.launch()
            if snapshot {
                NSApp.windows.forEach { $0.orderOut(nil) }
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
        .frame(minWidth: 860, minHeight: 600)
    }
}

/// Brain in the menu bar; a red record dot while recording.
struct MenuBarLabel: View {
    let isRecording: Bool

    var body: some View {
        if isRecording {
            Image(nsImage: Self.recordingImage)
        } else {
            Image(systemName: "brain")
        }
    }

    private static let recordingImage: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [.white, .systemRed]))
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: L("status.recording"))?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}
