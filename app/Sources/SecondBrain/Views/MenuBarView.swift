import AppKit
import BrainCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "brain").foregroundStyle(Color.accentColor)
                Text("SecondBrain").font(.headline)
                Spacer()
                if state.config.hotkeyEnabled {
                    Text("⌥⌘R").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }

            if state.config.onboardingComplete {
                RecordButton()

                if state.isRecording {
                    VStack(spacing: 6) {
                        LevelMeter(label: L("menu.computer"), symbol: "speaker.wave.2", level: state.recorder.systemLevel)
                        if state.config.captureMic {
                            LevelMeter(label: L("menu.microphone"), symbol: "mic", level: state.recorder.micLevel)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker(L("menu.project"), selection: $state.recordingProjectSlug) {
                        Text(L("inbox.title")).tag(String?.none)
                        Divider()
                        ForEach(state.projects) { project in
                            Text("\(project.emoji) \(project.name)").tag(Optional(project.slug))
                        }
                    }
                    TemplatePicker(scope: .meeting, selection: $state.recordingTemplateId,
                                   projectSlug: state.recordingProjectSlug, label: L("tpl.pickerShort"))
                    TextField(L("menu.titlePlaceholder"), text: $state.recordingTitle)
                        .textFieldStyle(.roundedBorder)
                }

                if let warning = state.recorderWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let error = state.recordingError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }

                QueueStatusLine()
            } else {
                Text(L("menu.finishSetup")).font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            if state.config.onboardingComplete {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    state.requestEmail(projectSlug: state.recordingProjectSlug)
                } label: {
                    Label(L("email.pasteMenu"), systemImage: "envelope.badge")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Button(L("menu.open")) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button(L("menu.quit")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 310)
    }
}

struct LevelMeter: View {
    let label: String
    let symbol: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .green, .yellow], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(level, 0), 1))))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}
