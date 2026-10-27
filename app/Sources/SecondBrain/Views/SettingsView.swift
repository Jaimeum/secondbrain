import AppKit
import BrainCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @ViewState private var showReconnect = false

    private let claudeModels: [(id: String, key: String)] = [
        ("sonnet", "settings.model.sonnet"), ("opus", "settings.model.opus"), ("haiku", "settings.model.haiku"),
    ]

    var body: some View {
        Form {
            if state.restartNeeded {
                Section {
                    HStack {
                        Text(L("restart.message"))
                        Spacer()
                        Button(L("restart.now")) { state.relaunch() }.disabled(state.isRecording)
                    }
                }
            }

            Section(L("settings.general")) {
                Picker(L("settings.language"), selection: binding(\.uiLanguage)) {
                    Text("Español").tag("es")
                    Text("English").tag("en")
                }
                if state.menuLanguageNeedsRestart { MenuLanguageNotice() }
                Picker(L("theme.title"), selection: binding(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).labelStyle(.titleAndIcon).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                if state.engineStarted {
                    // Distinct ids: two Form rows with the same explicit id collapse into one view (it showed
                    // "Tu nombre" twice and no "Tus correos").
                    OwnerNameField().id("owner.name.\(state.vaultGeneration)")
                    OwnerEmailsField().id("owner.emails.\(state.vaultGeneration)")
                }
                Toggle(L("settings.captureMic"), isOn: binding(\.captureMic))
                Toggle(L("settings.hotkey"), isOn: binding(\.hotkeyEnabled))
            }

            AccountsSection()
            RulesSection()   // MARK: v0.4 rules

            Section(L("settings.storage")) {
                LabeledContent(L("settings.vault")) {
                    HStack {
                        Text(state.config.vaultPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(L("onb.vault.change")) { VaultPicker.choose(state: state) }
                            .disabled(state.isSwitchingVault)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([state.config.vaultURL])
                        } label: { Image(systemName: "folder") }
                            .help(L("wiki.showInFinder"))
                    }
                }
                if state.isSwitchingVault { VaultSwitchingNotice() }
                LabeledContent(L("settings.dataFolder")) {
                    Button(L("settings.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([state.config.dataURL])
                    }
                }
            }

            Section {
                Picker(L("settings.whisper"), selection: binding(\.whisperModel)) {
                    Text(L("settings.whisper.precise")).tag("large-v3")
                    Text(L("settings.whisper.fast")).tag("large-v3-v20240930_turbo")
                }
                LabeledContent(L("settings.whisper.status")) {
                    if state.modelsReady {
                        Label(L("onb.models.ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if state.isPreparingModels {
                        HStack {
                            ProgressView(value: state.modelProgress?.fraction ?? 0).frame(width: 120)
                            Text(Fmt.percent(state.modelProgress?.fraction ?? 0)).monospacedDigit()
                        }
                    } else {
                        Button(L("settings.whisper.download")) { state.prepareModels() }
                    }
                }
            } header: {
                Text(L("settings.transcription"))
            } footer: {
                Text(L("settings.whisper.footer")).foregroundStyle(.secondary)
            }

            Section(L("settings.claude")) {
                Picker(L("settings.ingestModel"), selection: binding(\.ingestModel)) {
                    ForEach(claudeModels, id: \.id) { Text(L($0.key)).tag($0.id) }
                }
                Picker(L("settings.queryModel"), selection: binding(\.queryModel)) {
                    ForEach(claudeModels, id: \.id) { Text(L($0.key)).tag($0.id) }
                }
                LabeledContent(L("settings.account")) {
                    Button(L("chat.reconnect")) { showReconnect = true }
                }
            }

            Section {
                Toggle(L("settings.git"), isOn: binding(\.gitEnabled))
            } header: {
                Text(L("settings.advanced"))
            } footer: {
                Text(L("settings.gitFooter")).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 560)
        .sheet(isPresented: $showReconnect) { ReconnectClaudeSheet() }
    }

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(get: { state.config[keyPath: keyPath] }, set: { value in state.update { $0[keyPath: keyPath] = value } })
    }
}
