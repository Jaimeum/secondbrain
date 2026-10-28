import AppKit
import BrainCore
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

// v0.6 "Captura del día a día" (CONTRACT §16.10): one field for anything that happens during the day. ⌥⌘N (or the
// shortcut recorded in Ajustes › General) opens
// it in a floating panel over whatever app is in front (SecondBrain is not brought forward); the menu bar shows the
// same field first. What was typed is detected by `CaptureDetector` (a link, a pasted email or a note), files can be
// dropped on it, and it is saved through the same engine paths as "+ Agregar" into the project the rules suggest.

// MARK: - Model

@MainActor @Observable
final class QuickCaptureModel {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            // Typing the next thing during "Guardado en …" brings the footer (and Guardar) back.
            if !text.isEmpty { savedMessage = nil }
            scheduleSuggestion()
        }
    }
    var files: [URL] = []
    /// v0.7 (§17.3): the text is an in-person meeting — saved through "Agregar al proyecto" (needs a project).
    var inPerson = false
    /// Where it goes; nil = Sin asignar.
    var projectSlug: String?
    /// The user chose the destination: the suggestion no longer moves it.
    var projectPicked = false
    /// The thread a pasted email joins (a strong match, ≥ 0.8, as in "Agregar correo").
    private(set) var thread: EmailThread?
    private(set) var saving = false
    var error: String?
    /// "Guardado en 🚀 Kickoff" after saving.
    private(set) var savedMessage: String?
    /// Bumped by each successful save (a confirmation's timer only ends its own confirmation).
    private(set) var saveCount = 0

    @ObservationIgnored private let state: AppState
    @ObservationIgnored private var suggestion: Task<Void, Never>?
    @ObservationIgnored private var routedByRule = false

    init(state: AppState, text: String = "", files: [URL] = []) {
        self.state = state
        self.text = text
        self.files = files
        scheduleSuggestion(delay: false)
    }

    var kind: CaptureKind { CaptureDetector.detect(text) }
    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSave: Bool { !saving && (hasText || !files.isEmpty) && state.engineStarted && !(inPersonActive && projectSlug == nil) }
    /// "Reunión presencial" applies: chosen, and the text is a note (not a link or a pasted email).
    var inPersonActive: Bool {
        guard inPerson, hasText, case .note = kind else { return false }
        return true
    }

    func pickProject(_ slug: String?) {
        projectPicked = true
        projectSlug = slug
    }

    func add(files new: [URL]) {
        let fresh = new.filter { url in url.isFileURL && !files.contains(url) }
        guard !fresh.isEmpty else { return }
        files += fresh
        error = nil
        savedMessage = nil
    }

    func remove(file: URL) { files.removeAll { $0 == file } }

    /// After a save shown in the menu bar: an empty field, ready for the next thing.
    func reset() {
        text = ""
        files = []
        inPerson = false
        projectPicked = false
        error = nil
        savedMessage = nil
        scheduleSuggestion(delay: false)
    }

    /// The confirmation's end (menu bar): only the label goes; whatever was typed or dropped since stays.
    func dismissSavedMessage() { savedMessage = nil }

    /// The rules' destination again (the menu bar keeps one model: the default project may have changed in Ajustes ›
    /// Reglas, or the engine started after it was made). A destination the user picked is kept.
    func refreshDestination() {
        guard !projectPicked else { return }
        scheduleSuggestion(delay: false)
    }

    // MARK: Destination

    /// §16.10: the rules decide the default. A pasted email: its thread's project when it joins one, else the
    /// first rule that matches (or the default project). Anything else: the default project of Ajustes › Reglas, or
    /// Sin asignar. Debounced while typing; the parse and the thread search run off the main thread.
    private func scheduleSuggestion(delay: Bool = true) {
        suggestion?.cancel()
        guard !projectPicked else { return }
        let pasted = text
        let engine = state.engine
        suggestion = Task { [weak self] in
            if delay { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let self else { return }
            guard case .email = CaptureDetector.detect(pasted), self.state.engineStarted else {
                self.applySuggestion(thread: nil, slug: self.defaultProject, routed: false)
                return
            }
            let owners = engine.vault.ownerEmails(), ownerName = engine.vault.ownerName()
            let email = await Task.detached(priority: .userInitiated) {
                EmailParser.parse(pasted, ownerEmails: owners, ownerName: ownerName)
            }.value
            let strong = await engine.matchThreadsAsync(for: email).max { $0.score < $1.score }.flatMap { $0.score >= 0.8 ? $0 : nil }
            guard !Task.isCancelled else { return }
            if let strong {
                self.applySuggestion(thread: strong.thread, slug: strong.thread.projectSlug, routed: false)
            } else {
                let preview = engine.routingPreview(.mail(email, ownerEmails: owners))
                self.applySuggestion(thread: nil, slug: preview.projectSlug, routed: preview.decision != nil)
            }
        }
    }

    private func applySuggestion(thread: EmailThread?, slug: String?, routed: Bool) {
        self.thread = thread
        routedByRule = routed
        guard !projectPicked else { return }
        projectSlug = state.project(slug) != nil ? slug : nil
    }

    private var defaultProject: String? {
        guard state.engineStarted else { return nil }
        let slug = state.engine.routing.settings.defaultProjectSlug
        return state.project(slug) != nil ? slug : nil
    }

    // MARK: Save

    /// Files first (like a drop), then the text as what it is. Returns true when everything was saved.
    /// What was saved leaves the field at once (a second ⌘↩ during the confirmation finds nothing to save again); on
    /// a partial failure only what failed stays, so Guardar again retries just that.
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        saving = true
        error = nil
        savedMessage = nil
        defer { saving = false }
        // The rules' destination as of now (a files-only capture never re-asked; the default may have changed), and a
        // just-pasted email's thread and project, are known before saving.
        if !projectPicked { scheduleSuggestion(delay: false) }
        await suggestion?.value
        let slug = projectSlug
        let engine = state.engine
        let savingFiles = files
        let savingText = text
        // v0.7 (§17.3): an in-person meeting goes, with the files, through "Agregar al proyecto" (/file-dump).
        if inPersonActive, let slug {
            do {
                _ = try await engine.addToProject(slug, files: savingFiles, text: savingText, inPerson: true)
            } catch {
                self.error = FriendlyError.message(error)
                return false
            }
            state.bumpVault()
            files.removeAll { savingFiles.contains($0) }
            if text == savingText { text = "" }
            inPerson = false
            savedMessage = L("capture.saved", state.projectName(slug))
            saveCount += 1
            projectPicked = false
            scheduleSuggestion(delay: false)
            return true
        }
        var failures: [String] = []
        var failedFiles: [URL] = []
        for url in savingFiles {
            let failed = await SourceImport.importURLs([url], projectSlug: slug, state: state, origin: "capture")   // Archivos › Captura
            if !failed.isEmpty {
                failures += failed
                failedFiles.append(url)
            }
        }
        var textSaved = true
        let trimmed = savingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            switch CaptureDetector.detect(trimmed) {
            case .link(let url):
                do { try await engine.importURL(url, projectSlug: slug) } catch { failures.append(L("sources.linkFailed")); textSaved = false }
            case .email:
                do { try saveEmail(trimmed, projectSlug: slug) } catch { failures.append(FriendlyError.message(error)); textSaved = false }
            case .note:
                let title = CaptureDetector.noteTitle(trimmed) ?? L("note.defaultTitle", Fmt.date(Date()))
                do { try engine.addNote(title: title, body: trimmed, projectSlug: slug) } catch { failures.append(L("note.failed")); textSaved = false }
            }
        }
        state.bumpVault()
        // Drop what was saved (anything added while saving stays).
        files.removeAll { savingFiles.contains($0) && !failedFiles.contains($0) }
        if textSaved, text == savingText { text = "" }
        guard failures.isEmpty else {
            error = failures.joined(separator: "\n")
            return false
        }
        // A joined thread keeps its own project: say where it really went.
        let destination = thread.flatMap { t in projectPicked && t.projectSlug != slug ? nil : t.projectSlug } ?? slug
        savedMessage = L("capture.saved", state.projectName(destination))
        saveCount += 1
        // The next capture starts from the rules' destination again.
        thread = nil
        projectPicked = false
        scheduleSuggestion(delay: false)
        return true
    }

    /// As "Agregar correo" saves it: the whole pasted conversation, into the strongly matching thread (unless the user
    /// sent it elsewhere) or a new thread in the chosen project. The deciding rule counts a hit.
    private func saveEmail(_ pasted: String, projectSlug slug: String?) throws {
        let engine = state.engine
        let owners = engine.vault.ownerEmails(), ownerName = engine.vault.ownerName()
        var email = EmailParser.parse(pasted, ownerEmails: owners, ownerName: ownerName)
        if email.date == nil { email.date = Date() }
        let all = EmailParser.parseAll(pasted, ownerEmails: owners, ownerName: ownerName)
        let joined = thread.flatMap { t in projectPicked && t.projectSlug != slug ? nil : t }
        let project = joined == nil ? slug : nil
        if all.count > 1 {
            var list = all
            list[list.count - 1] = email
            let added = try engine.addEmails(list, threadKey: joined?.key, projectSlug: project, routeIfUnassigned: joined != nil)
            if added.isEmpty { throw EngineError.duplicateEmail(email.subject ?? "") }
        } else {
            try engine.addEmail(email, threadKey: joined?.key, projectSlug: project, routeIfUnassigned: joined != nil)
        }
        if joined == nil, routedByRule, !projectPicked { _ = engine.routing.route(.mail(email, ownerEmails: owners)) }
    }
}

// MARK: - The field (panel and menu bar)

/// The capture field and its footer. `embedded` = inside the menu bar panel (no title, a bit shorter); `onClose` is
/// called by esc and, in the floating panel, after the confirmation.
struct QuickCaptureView: View {
    @Environment(AppState.self) private var state
    @Bindable var model: QuickCaptureModel
    var embedded = false
    var onClose: () -> Void = {}

    @ViewState private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: embedded ? 8 : 10) {
            if !embedded {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Brand.color.accent)
                    Text(L("capture.title"))
                        .font(Brand.section)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    kindChips
                }
            }
            editor
            if !model.files.isEmpty { fileList }
            if case .email = model.kind, let thread = model.thread {
                Label(L("capture.thread", thread.subject), systemImage: "arrow.turn.down.right")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if embedded, case .note = model.kind, model.hasText, model.savedMessage == nil {   // v0.7 (§17.3)
                inPersonToggle
            }
            if model.inPersonActive, model.projectSlug == nil {   // v0.7 (§17.3)
                Label(L("capture.inPersonNeedsProject"), systemImage: "info.circle")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(2)
            }
            if let error = model.error {
                Text(error)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.danger)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saved = model.savedMessage {
                Label(saved, systemImage: "checkmark.circle.fill")
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.success)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                footer
            }
        }
        .padding(embedded ? 0 : Brand.spacing.l)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.add(files: files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .animation(Brand.motion.animation(fast: true), value: model.savedMessage)
    }

    // MARK: Pieces

    private var editor: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
        return CaptureTextView(text: $model.text, onFiles: { model.add(files: $0) },
                               onSubmit: submit, onCancel: embedded ? nil : onClose)
            .frame(height: embedded ? 84 : 104)
            .background(Brand.color.card, in: shape)
            .overlay(shape.strokeBorder(dropTargeted ? Brand.color.accent : Brand.color.line, lineWidth: dropTargeted ? 2 : 1))
            .overlay(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text(L("capture.placeholder"))
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text3)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            }
    }

    /// What it will be saved as: Nota / Enlace / Correo, and the dropped files.
    @ViewBuilder private var kindChips: some View {
        HStack(spacing: 4) {
            if !model.files.isEmpty {
                chip(L("capture.kind.files", model.files.count), symbol: "doc")
            }
            if model.inPersonActive {
                chip(L("kind.inPerson"), symbol: SourceKind.inPerson.symbol)
            } else if model.hasText || model.files.isEmpty {
                switch model.kind {
                case .note: chip(L("capture.kind.note"), symbol: "square.and.pencil")
                case .link: chip(L("capture.kind.link"), symbol: "link")
                case .email: chip(L("capture.kind.email"), symbol: "envelope")
                }
            }
        }
        .help(L("capture.kindHelp"))
    }

    private func chip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(Brand.caption)
            .foregroundStyle(Brand.color.text2)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Brand.color.cardAlt, in: Capsule())
    }

    private var fileList: some View {
        let shown = model.files.prefix(3)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown), id: \.self) { url in
                HStack(spacing: 6) {
                    Image(systemName: AudioPrep.isMedia(url) ? "waveform" : "doc")
                        .foregroundStyle(Brand.color.text2)
                        .frame(width: 14)
                    Text(url.lastPathComponent)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { model.remove(file: url) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.color.text3)
                    }
                    .buttonStyle(.plain)
                    .help(L("capture.removeFile"))
                }
            }
            if model.files.count > shown.count {
                Text(L("capture.moreFiles", model.files.count - shown.count))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
            }
        }
    }

    private var footer: some View {
        // Picker and button on one line when they fit; else the button goes below (§15.3).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                footerLeading
                Spacer(minLength: 8)
                saveButton
            }
            VStack(alignment: .leading, spacing: 8) {
                footerLeading
                HStack {
                    Spacer(minLength: 0)
                    saveButton
                }
            }
        }
    }

    private var footerLeading: some View {
        HStack(spacing: 8) {
            // The menu bar is narrow: the chip takes the label's place (the picker's help still says what it is).
            if embedded {
                kindChips
            } else {
                Text(L("capture.destination"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
            Picker(L("capture.destination"), selection: Binding(get: { model.projectSlug },
                                                                 set: { model.pickProject($0) })) {
                Text(L("inbox.title")).tag(String?.none)
                Divider()
                ForEach(state.projects) { project in
                    Text("\(project.emoji) \(project.name)").tag(Optional(project.slug))
                }
            }
            .labelsHidden()
            .frame(minWidth: 120, maxWidth: embedded ? 150 : 220)
            .help(L("capture.destinationHelp"))
            if !embedded, case .note = model.kind {   // v0.7 (§17.3)
                inPersonToggle
            }
        }
    }

    /// "Reunión presencial" (v0.7, §17.3): in the panel's footer; in the narrow menu bar, on its own line.
    private var inPersonToggle: some View {
        Toggle(L("capture.inPerson"), isOn: $model.inPerson)
            .toggleStyle(.checkbox)
            .font(Brand.caption)
            .foregroundStyle(Brand.color.text2)
            .lineLimit(1)
            .fixedSize()
            .disabled(!model.hasText)
            .help(model.projectSlug == nil ? L("capture.inPersonNeedsProject") : L("capture.inPersonHelp"))
    }

    private var saveButton: some View {
        HStack(spacing: 8) {
            if model.saving { BrandLoader(size: 14) }
            if !embedded {
                Text(L("capture.hint"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button(L("capture.save"), action: submit)
                .buttonStyle(.brandPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSave)
        }
    }

    /// ⌘↩ / Guardar. The saved content has already left the field, so pressing again during the confirmation saves
    /// nothing twice. The panel closes after the confirmation (unless something new was typed meanwhile); the menu bar
    /// only drops the label, keeping whatever was typed or dropped since.
    private func submit() {
        guard model.canSave else { return }
        Task {
            guard await model.save() else { return }
            let count = model.saveCount
            try? await Task.sleep(for: .seconds(embedded ? 2.5 : 1.1))
            guard model.saveCount == count, model.savedMessage != nil else { return }
            if embedded || model.hasText || !model.files.isEmpty {
                model.dismissSavedMessage()
            } else {
                onClose()
            }
        }
    }
}

// MARK: - Text view (drops and paste of files, ⌘↩, esc)

/// A plain multiline text view. Unlike `TextEditor`, files dropped or pasted on it become attachments instead of their
/// path as text, ⌘↩ saves, esc closes, and it takes the focus whenever its window becomes key.
struct CaptureTextView: NSViewRepresentable {
    @Binding var text: String
    var onFiles: ([URL]) -> Void
    var onSubmit: () -> Void
    var onCancel: (() -> Void)?
    /// Takes the focus whenever its window becomes key (the capture panel); false in the main window (v0.7 drop box).
    var autoFocus = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CaptureNSTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // Pasted emails and links stay exactly as they were.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = NSFont(name: BrandFonts.family, size: 13) ?? .systemFont(ofSize: 13)
        textView.textColor = NSColor(Brand.color.text)
        textView.insertionPointColor = NSColor(Brand.color.accent)
        textView.textContainerInset = NSSize(width: 4, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        update(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CaptureNSTextView else { return }
        context.coordinator.text = $text
        if textView.string != text { textView.string = text }
        update(textView)
    }

    private func update(_ textView: CaptureNSTextView) {
        textView.onFiles = onFiles
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.autoFocus = autoFocus
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

final class CaptureNSTextView: NSTextView {
    var onFiles: (([URL]) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var autoFocus = true
    private var keyObserver: NSObjectProtocol?

    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onFiles?(urls)
        return true
    }

    override func paste(_ sender: Any?) {
        let urls = Self.fileURLs(.general)
        guard !urls.isEmpty else { return super.paste(sender) }
        onFiles?(urls)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { nextResponder?.cancelOperation(sender) }
    }

    /// The field is what the panel (or the menu bar) opens for: focus it each time its window comes forward.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window, autoFocus else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                if !(window.firstResponder is NSText) { window.makeFirstResponder(self) }
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow else { return }
            window.makeFirstResponder(self)
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }
}

// MARK: - Floating panel

/// A panel that takes the keyboard without bringing SecondBrain's main window forward. ⌘W and esc go through the
/// controller (`onCancel`), so it always knows the panel is gone.
final class QuickCaptureNSPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performClose(_ sender: Any?) { onCancel?() }
}

/// Owns the capture hot key (⌥⌘N by default, `AppConfig.captureHotkey`) and the floating "Captura rápida" panel (one
/// at a time; the hot key toggles it).
@MainActor
final class QuickCapturePanel {
    static let shared = QuickCapturePanel()

    static let width: CGFloat = 520

    private var panel: QuickCaptureNSPanel?
    private var hotKey: GlobalHotKey?
    /// Bumped whenever a panel opens or closes: a confirmation timer of an older panel never closes a newer one.
    private var generation = 0

    /// Registers or drops the shortcut after `config.captureHotkeyEnabled` / `captureHotkey` (launch and Ajustes ›
    /// General). Returns false when it is on but could not be registered (another app holds the combination).
    @discardableResult
    func applyHotKey(state: AppState) -> Bool {
        hotKey?.unregister()
        hotKey = nil
        guard state.config.captureHotkeyEnabled else { return true }
        let combo = state.config.captureHotkey
        let key = GlobalHotKey(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
            self?.toggle(state: state)
        }
        hotKey = key
        return key.isRegistered
    }

    /// While Ajustes records a new shortcut: the current one must not fire (it would open the panel).
    func suspendHotKey() {
        hotKey?.unregister()
        hotKey = nil
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(state: AppState) {
        if isVisible { close() } else { show(state: state) }
    }

    func show(state: AppState) {
        // Before the onboarding there is no brain to save into: open SecondBrain instead.
        guard state.config.onboardingComplete, state.engineStarted else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        generation += 1
        let mine = generation
        let model = QuickCaptureModel(state: state)
        let root = QuickCaptureView(model: model, onClose: { [weak self] in
            guard let self, self.generation == mine else { return }
            self.close()
        })
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Brand.color.surface)
            .environment(state)
            .brandEnvironment()
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        let panel = QuickCaptureNSPanel(contentRect: CGRect(origin: .zero, size: CGSize(width: Self.width, height: max(size.height, 200))),
                                        styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
                                        backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = NSColor(Brand.color.surface)
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = host
        // Centered, in the upper third of the screen with the pointer (where Spotlight opens).
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let frame = panel.frame
            panel.setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2,
                                         y: visible.minY + visible.height * 0.68 - frame.height / 2))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        generation += 1
        self.panel = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }
}
