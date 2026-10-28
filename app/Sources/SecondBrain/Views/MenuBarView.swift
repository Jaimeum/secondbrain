import AppKit
import BrainCore
import SwiftUI

/// The menu bar panel (CONTRACT §16.10): brand header, the capture field first (the same one the capture shortcut opens), then
/// recording as one more option (the sidebar's `RecordControl`), "Detalles ▸" (project, format, title; opened by
/// itself while recording), Abrir · Salir.
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @ViewState private var detailsOpen = false
    @ViewState private var capture = QuickCaptureModel(state: AppState.shared)

    var body: some View {
        @Bindable var state = state
        // No rules between the parts (§15.1 calm surfaces): spacing groups them.
        VStack(alignment: .leading, spacing: 16) {
            BrandLogo(size: 18)
                .help(state.config.hotkeyEnabled ? L("record.hotkeyHint") : "")

            if state.config.onboardingComplete {
                QuickCaptureView(model: capture, embedded: true)
                    // One model for the app's life: the rules' destination is asked again whenever the panel shows,
                    // the engine starts or the projects change (Ajustes › Reglas may name another default).
                    .onAppear { capture.refreshDestination() }
                    .onChange(of: state.engineStarted) { capture.refreshDestination() }
                    .onChange(of: state.projects.map(\.slug)) { capture.refreshDestination() }

                RecordControl(placement: .menuBar)

                if state.isRecording {
                    VStack(spacing: 6) {
                        LevelMeter(label: L("menu.computer"), symbol: "speaker.wave.2", level: state.recorder.systemLevel)
                        if state.config.captureMic {
                            LevelMeter(label: L("menu.microphone"), symbol: "mic", level: state.recorder.micLevel)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $detailsOpen) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            fieldLabel(L("menu.project"))
                            BrandPicker(selection: $state.recordingProjectSlug,
                                        options: [(String?.none, L("inbox.title"))]
                                            + state.projects.map { (Optional($0.slug), "\($0.emoji) \($0.name)") })
                                .accessibilityLabel(L("menu.project"))
                        }
                        GridRow {
                            fieldLabel(L("tpl.pickerShort"))
                            TemplatePicker(scope: .meeting, selection: $state.recordingTemplateId,
                                           projectSlug: state.recordingProjectSlug, label: L("tpl.pickerShort"))
                                .labelsHidden()
                        }
                        GridRow {
                            fieldLabel(L("menu.titleLabel"))
                            TextField(L("menu.titlePlaceholder"), text: $state.recordingTitle)
                                .brandField()
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Text(L("menu.details"))
                            .font(Brand.callout)
                            .foregroundStyle(Brand.color.text)
                            .lineLimit(1)
                        // Folded, it still says where the next recording goes (no hidden destination).
                        if !detailsOpen, let destination {
                            Text(verbatim: "→ " + destination)
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Brand.motion.fast) { detailsOpen.toggle() } }
                }

                QueueStatusLine()
            } else {
                Text(L("menu.finishSetup"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(L("menu.open"), action: openMain)
                Spacer()
                Button(L("menu.quit")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.color.accent)
        }
        .font(Brand.body)
        .padding(16)
        .frame(width: 360)
        .background(Brand.color.bg)
        .onAppear { if state.isRecording { detailsOpen = true } }
        .onChange(of: state.isRecording) { _, recording in
            if recording { detailsOpen = true }
        }
    }

    /// "🚀 Atlas" (and the format, when one is chosen) for the folded "Detalles".
    private var destination: String? {
        var parts: [String] = []
        if let slug = state.recordingProjectSlug, state.project(slug) != nil { parts.append(state.projectName(slug)) }
        if let template = state.template(state.recordingTemplateId) { parts.append(template.name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Brand.font(12, .medium))
            .foregroundStyle(Brand.color.text2)
            .lineLimit(1)
            .gridColumnAlignment(.trailing)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct LevelMeter: View {
    let label: String
    let symbol: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .frame(width: 16)
            Text(label)
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(1)
                .frame(width: 82, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.color.cardAlt)
                    Capsule()
                        .fill(Brand.color.sage)
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(level, 0), 1))))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}
