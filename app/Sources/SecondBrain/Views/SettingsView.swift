import AppKit
import Carbon.HIToolbox
import BrainCore
import SwiftUI

/// Ajustes (CONTRACT §15.2): General · Cuentas · GitHub · Reglas · Formatos · Avanzado.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, accounts, github, rules, formats, advanced

    var id: String { rawValue }

    /// Deep link: whoever opens Ajustes on a tab writes its raw value here; `SettingsView` selects it and clears it.
    static let requestKey = "settings.selectedTab"

    var title: String { L("settings.tab.\(rawValue)") }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .rules: "arrow.triangle.branch"
        case .formats: "doc.richtext"
        case .advanced: "slider.horizontal.3"
        }
    }

    /// Opens the Settings window on `tab` (same mechanism as the shell's `SettingsLink.open(tab:)`).
    @MainActor static func open(_ tab: SettingsTab) { SettingsLinkOpener.open(tab: tab.rawValue) }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @ViewState private var tab: SettingsTab
    /// Observed so a deep link also works while the window is already open.
    @AppStorage(SettingsTab.requestKey) private var requested = ""

    init(initialTab: SettingsTab = .general) {
        _tab = ViewState(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { t in
                page(t)
                    .tabItem { Label(t.title, systemImage: t.symbol) }
                    .tag(t)
            }
        }
        .frame(minWidth: 760, idealWidth: 820, maxWidth: .infinity, minHeight: 520, idealHeight: 600, maxHeight: .infinity)
        .background(Brand.color.surface)
        .onAppear(perform: applyRequest)
        .onChange(of: requested) { applyRequest() }
    }

    @ViewBuilder private func page(_ t: SettingsTab) -> some View {
        switch t {
        case .general: GeneralSettings()
        case .accounts: AccountsSettingsPage()
        case .github: GitHubSettingsPage()
        case .rules: RulesSettingsPage()
        case .formats: TemplatesView().background(Brand.color.surface)
        case .advanced: AdvancedSettings()
        }
    }

    private func applyRequest() {
        guard !requested.isEmpty else { return }
        if let t = SettingsTab(rawValue: requested) { tab = t }
        requested = ""
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        SettingsPage {
            RestartNotice()
            SettingsGroup(title: L("settings.group.look")) {
                SettingsRow(title: L("settings.language")) {
                    Picker("", selection: settingsBinding(state, \.uiLanguage)) {
                        Text(verbatim: "Español").tag("es")
                        Text(verbatim: "English").tag("en")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if state.menuLanguageNeedsRestart {
                    MenuLanguageNotice().padding(.horizontal, 14).padding(.bottom, 10)
                }
                SettingsDivider()
                SettingsRow(title: L("theme.title")) {
                    Picker("", selection: settingsBinding(state, \.appearance)) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).labelStyle(.titleAndIcon).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if state.engineStarted {
                SettingsGroup(title: L("settings.group.you")) {
                    // Distinct ids: the fields reload after a vault switch.
                    OwnerNameField().id("owner.name.\(state.vaultGeneration)").padding(14)
                    SettingsDivider()
                    OwnerAddressesField().id("owner.emails.\(state.vaultGeneration)").padding(14)
                }
            }
            SettingsGroup(title: L("settings.group.recording")) {
                SettingsRow(title: L("settings.captureMic")) {
                    Toggle("", isOn: settingsBinding(state, \.captureMic)).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: L("settings.hotkey")) {
                    Toggle("", isOn: settingsBinding(state, \.hotkeyEnabled)).toggleStyle(.switch).labelsHidden()
                }
                // MARK: v0.6 capture — the capture shortcut next to ⌥⌘R, recordable (§16.10).
                SettingsDivider()
                CaptureHotKeyRow()
            }
        }
    }
}

// MARK: - Capture shortcut (§16.10)

/// "Captura rápida": on/off, the current combination and "Cambiar…", which records a new one (⌘ or ⌃ plus another
/// modifier and a key; esc cancels) and registers it at once. A combination macOS or another app already uses is
/// refused with the reason; the current one is checked against macOS's own shortcuts when the row shows.
private struct CaptureHotKeyRow: View {
    @Environment(AppState.self) private var state
    @ViewState private var recording = false
    @ViewState private var problem: String?
    @ViewState private var monitor: Any?

    var body: some View {
        SettingsRow(title: L("settings.captureHotkey"), detail: problem ?? L("settings.captureHotkeyDetail")) {
            HStack(spacing: Brand.spacing.s) {
                Text(recording ? L("settings.captureHotkey.press") : state.config.captureHotkey.symbols)
                    .font(Brand.font(12, .semibold))
                    .foregroundStyle(recording ? Brand.color.accent : Brand.color.text)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Brand.color.cardAlt, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Button(recording ? L("common.cancel") : L("settings.captureHotkey.change")) {
                    recording ? stop(restore: true) : start()
                }
                .buttonStyle(.brandSecondary)
                .disabled(!state.config.captureHotkeyEnabled)
                Toggle("", isOn: settingsBinding(state, \.captureHotkeyEnabled)).toggleStyle(.switch).labelsHidden()
            }
        }
        .onAppear(perform: checkCurrent)
        .onChange(of: state.config.captureHotkeyEnabled) { checkCurrent() }
        .onDisappear { if recording { stop(restore: true) } }
    }

    private func checkCurrent() {
        let combo = state.config.captureHotkey
        problem = state.config.captureHotkeyEnabled && SystemHotKeys.isTaken(keyCode: combo.keyCode, modifiers: combo.modifiers)
            ? L("settings.captureHotkey.system", combo.symbols) : nil
    }

    private func start() {
        problem = nil
        recording = true
        QuickCapturePanel.shared.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func stop(restore: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        if restore { QuickCapturePanel.shared.applyHotKey(state: state) }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop(restore: true)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0
        if flags.contains(.command) { mods |= CaptureHotKey.command }
        if flags.contains(.shift) { mods |= CaptureHotKey.shift }
        if flags.contains(.option) { mods |= CaptureHotKey.option }
        if flags.contains(.control) { mods |= CaptureHotKey.control }
        let combo = CaptureHotKey(keyCode: Int(event.keyCode), modifiers: mods, key: Self.label(event))
        guard combo.isValid else {
            problem = L("settings.captureHotkey.needsModifiers")
            return
        }
        if combo.keyCode == kVK_ANSI_R, combo.modifiers == CaptureHotKey.option | CaptureHotKey.command {
            problem = L("settings.captureHotkey.recordTaken")
            return
        }
        if SystemHotKeys.isTaken(keyCode: combo.keyCode, modifiers: combo.modifiers) {
            problem = L("settings.captureHotkey.system", combo.symbols)
            return
        }
        stop(restore: false)
        let previous = state.config.captureHotkey
        state.update { $0.captureHotkey = combo }
        if !QuickCapturePanel.shared.applyHotKey(state: state) {
            state.update { $0.captureHotkey = previous }
            problem = L("settings.captureHotkey.otherApp", combo.symbols)
        }
    }

    private static let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]

    /// The key as printed on the keyboard ("N", "Espacio", "F5").
    private static func label(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return L("settings.key.space")
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case let code where fKeys.contains(code):
            return "F\((fKeys.firstIndex(of: code) ?? 0) + 1)"
        default:
            let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
            return chars.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }
}

// MARK: - Avanzado

private struct AdvancedSettings: View {
    @Environment(AppState.self) private var state

    private let claudeModels: [(id: String, key: String)] = [
        ("sonnet", "settings.model.sonnet"), ("opus", "settings.model.opus"), ("haiku", "settings.model.haiku"),
    ]

    var body: some View {
        SettingsPage {
            RestartNotice()
            SettingsGroup(title: L("settings.storage")) {
                SettingsRow(title: L("settings.vault")) {
                    HStack(spacing: 8) {
                        Text(state.config.vaultPath)
                            .font(Brand.mono)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 240, alignment: .trailing)
                        Button(L("onb.vault.change")) { VaultPicker.choose(state: state) }
                            .buttonStyle(.brandSecondary)
                            .disabled(state.isSwitchingVault)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([state.config.vaultURL])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.brandSecondary)
                        .help(L("wiki.showInFinder"))
                    }
                }
                if state.isSwitchingVault { VaultSwitchingNotice().padding(.horizontal, 14).padding(.bottom, 10) }
                SettingsDivider()
                SettingsRow(title: L("settings.dataFolder")) {
                    Button(L("settings.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([state.config.dataURL])
                    }
                    .buttonStyle(.brandSecondary)
                }
            }

            SettingsGroup(title: L("settings.transcription"), footer: L("settings.whisper.footer")) {
                SettingsRow(title: L("settings.whisper")) {
                    Picker("", selection: settingsBinding(state, \.whisperModel)) {
                        Text(L("settings.whisper.precise")).tag("large-v3")
                        Text(L("settings.whisper.fast")).tag("large-v3-v20240930_turbo")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsDivider()
                SettingsRow(title: L("settings.whisper.status")) {
                    ModelStatusControl()
                }
            }

            SettingsGroup(title: L("settings.group.models")) {
                SettingsRow(title: L("settings.ingestModel")) {
                    Picker("", selection: settingsBinding(state, \.ingestModel)) {
                        ForEach(claudeModels, id: \.id) { Text(L($0.key)).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsDivider()
                SettingsRow(title: L("settings.queryModel")) {
                    Picker("", selection: settingsBinding(state, \.queryModel)) {
                        ForEach(claudeModels, id: \.id) { Text(L($0.key)).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup(title: L("settings.group.git"), footer: L("settings.gitFooter")) {
                SettingsRow(title: L("settings.git")) {
                    Toggle("", isOn: settingsBinding(state, \.gitEnabled)).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsGroup(title: L("settings.group.oauth"), footer: L("accounts.advanced.hint")) {
                AdvancedOAuthFields().padding(14)
            }
        }
    }
}

/// "Listo para transcribir" · linear progress with the real percentage · "Sin descargar · Descargar ahora" · the error
/// with "Reintentar" (the same states as the onboarding's ModelsStatusLine).
private struct ModelStatusControl: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.modelsReady {
            Label(L("onb.models.ready"), systemImage: "checkmark.circle")
                .foregroundStyle(Brand.color.success)
        } else if state.isPreparingModels {
            HStack(spacing: 8) {
                ProgressView(value: state.modelProgress?.fraction ?? 0).frame(width: 120)
                Text(Fmt.percent(state.modelProgress?.fraction ?? 0))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .monospacedDigit()
            }
        } else if let error = state.modelError {
            HStack(spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.warning)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .help(error)
                Button(L("onb.models.retry")) { state.prepareModels() }
                    .buttonStyle(.brandSecondary)
            }
        } else {
            HStack(spacing: 10) {
                Text(L("settings.whisper.notDownloaded"))
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                Button(L("settings.whisper.download")) { state.prepareModels() }
                    .buttonStyle(.brandSecondary)
            }
        }
    }
}

/// "Este cambio se aplica al reiniciar" (data folder moved, or a vault switch that couldn't be applied live).
private struct RestartNotice: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.restartNeeded {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise").foregroundStyle(Brand.color.warning)
                Text(L("restart.message"))
                    .foregroundStyle(Brand.color.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("restart.now")) { state.relaunch() }
                    .buttonStyle(.brandPrimary)
                    .disabled(state.isRecording)
            }
            .padding(12)
            .background(Brand.color.warningSoft, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
        }
    }
}

@MainActor
func settingsBinding<T: Equatable>(_ state: AppState, _ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
    Binding(get: { state.config[keyPath: keyPath] }, set: { value in state.update { $0[keyPath: keyPath] = value } })
}

// MARK: - Building blocks (brand cards instead of the grouped Form, which paints system greys)

/// One tab: a scrolling column of groups on `surface`.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.spacing.xxl) { content }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(Brand.spacing.contentWide)
                .frame(maxWidth: .infinity)
        }
        .background(Brand.color.surface)
    }
}

/// A titled card of rows, with an optional one-line footer (leading aligned).
struct SettingsGroup<Content: View, Footer: View>: View {
    var title: String?
    var content: Content
    var footer: Footer

    init(title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            if let title {
                Text(title)
                    .font(Brand.section)
                    .foregroundStyle(Brand.color.text)
                    .accessibilityAddTraits(.isHeader)
            }
            BrandCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) { content }
            }
            footer
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}

extension SettingsGroup where Footer == EmptyView {
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content) { EmptyView() }
    }
}

extension SettingsGroup where Footer == Text {
    init(title: String? = nil, footer: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content) { Text(footer) }
    }
}

/// Title (+ optional detail) on the left, a short control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Brand.spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// 1 px `line` between rows of a group.
struct SettingsDivider: View {
    var inset: CGFloat = 14

    var body: some View {
        Rectangle().fill(Brand.color.line).frame(height: 1).padding(.leading, inset)
    }
}

/// A text link (the system `.link` style ignores the brand tint and inherits the footer's grey): link color, medium
/// weight and a faint underline that strengthens on hover/press, so it never reads as body text. In dark mode `accent` equals `text2`, so links
/// use a lighter sage there. `external`: a trailing ↗ for links that leave the app.
struct SettingsLinkButtonStyle: ButtonStyle {
    var external = false

    /// Light: the brand olive (`accent`). Dark: #C9D0BE, distinct from `text2` (#AEB5A4) on every surface.
    static let linkColor = Brand.dynamic(light: 0x475243, dark: 0xC9D0BE)

    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration, external: external)
    }

    private struct LinkLabel: View {
        let configuration: Configuration
        let external: Bool
        @ViewState private var hovering = false

        var body: some View {
            HStack(spacing: 3) {
                // A faint underline always (it's a link, not body text); full strength on hover/press.
                configuration.label
                    .underline(true, color: SettingsLinkButtonStyle.linkColor
                        .opacity(hovering || configuration.isPressed ? 1 : 0.35))
                if external {
                    Image(systemName: "arrow.up.right").imageScale(.small)
                }
            }
            .fontWeight(.medium)
            .foregroundStyle(SettingsLinkButtonStyle.linkColor)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(.link)
        }
    }
}

extension ButtonStyle where Self == SettingsLinkButtonStyle {
    static var settingsLink: SettingsLinkButtonStyle { SettingsLinkButtonStyle() }
    /// A link that opens something outside the app (browser, mail, System Settings): adds ↗.
    static var settingsExternalLink: SettingsLinkButtonStyle { SettingsLinkButtonStyle(external: true) }
}

/// The label of a brand-styled pull-down ("Usar por defecto ▾", "Conectar otra cuenta ▾"): use inside
/// `Menu { … } label: { SettingsMenuLabel(…) }.menuStyle(.button).buttonStyle(.plain).fixedSize()`.
struct SettingsMenuLabel: View {
    let title: String
    var symbol: String? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(Brand.font(9, .semibold)).foregroundStyle(Brand.color.text2)
        }
        .font(Brand.callout)
        .foregroundStyle(Brand.color.text)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(shape.fill(Brand.color.cardAlt))
        .overlay(shape.strokeBorder(Brand.color.line, lineWidth: 1))
        .contentShape(shape)
    }
}
