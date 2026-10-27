import AppKit
import BrainCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything a project learned from, with status (v0.5: the add bar moved to the project's "+ Agregar" menu, and
/// the Contenido tab lists sources by date; this list stays as a component and for snapshots).
struct SourcesView: View {
    @Environment(AppState.self) private var state
    let projectSlug: String
    var onOpen: (String) -> Void

    @ViewState private var actions = SourceActionsState()

    private var sources: [SourceRecord] {
        state.engine.sources.filter { $0.projectSlug == projectSlug }.sorted { $0.timelineDate > $1.timelineDate }
    }

    var body: some View {
        Group {
            if sources.isEmpty {
                EmptyStateView(symbol: "tray.and.arrow.down", title: L("sources.emptyTitle"), message: L("sources.emptyMessage"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sources) { source in
                            SourceRow(source: source, onOpen: onOpen, actions: $actions)
                        }
                    }
                    .padding(Brand.spacing.m)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.color.surface)
        .sourceDropTarget(projectSlug: projectSlug)
        .sourceActions($actions, onOpen: onOpen)
    }
}

// MARK: - Shared source actions (sheets, delete, errors)

/// What a list of sources is presenting: one sheet, one delete confirmation, one error.
struct SourceActionsState {
    var sheet: SourceSheet?
    var pendingDelete: SourceRecord?
    var error: String?
}

/// The sheets a source row can open (one presenter for the whole list).
enum SourceSheet: Identifiable {
    case tasks(SourceRecord), date(SourceRecord), reformat(SourceRecord), export(SourceRecord), thread(String)

    var id: String {
        switch self {
        case .tasks(let s): "tasks-" + s.id
        case .date(let s): "date-" + s.id
        case .reformat(let s): "reformat-" + s.id
        case .export(let s): "export-" + s.id
        case .thread(let key): "thread-" + key
        }
    }

    @MainActor @ViewBuilder func view(onOpen: @escaping (String) -> Void) -> some View {
        switch self {
        case .tasks(let s): SourceTasksSheet(source: s)
        case .date(let s): ChangeDateSheet(source: s)
        case .reformat(let s): ReformatSheet(source: s)
        case .export(let s): ExportSheet(request: ExportRequest(target: .source(s)))
        case .thread(let key): ThreadSheet(threadKey: key, onOpenPage: onOpen)
        }
    }
}

private struct SourceActionsModifier: ViewModifier {
    @Environment(AppState.self) private var state
    @Binding var actions: SourceActionsState
    var onOpen: (String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.sheet) { $0.view(onOpen: onOpen) }
            .alert(L("common.oops"), isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
                Button(L("common.ok")) { actions.error = nil }
            } message: {
                Text(actions.error ?? "")
            }
            .confirmationDialog(L("sources.deleteConfirm", actions.pendingDelete?.title ?? ""),
                                isPresented: Binding(get: { actions.pendingDelete != nil },
                                                     set: { if !$0 { actions.pendingDelete = nil } })) {
                Button(L("sources.delete"), role: .destructive) {
                    if let source = actions.pendingDelete {
                        do { try state.engine.delete(sourceId: source.id) } catch { actions.error = L("sources.deleteFailed") }
                    }
                    actions.pendingDelete = nil
                }
            } message: {
                Text(L("sources.deleteMessage"))
            }
    }
}

extension View {
    /// Presents the sheets, delete confirmation and errors that `SourceMenuItems` / `SourceRow` request.
    func sourceActions(_ actions: Binding<SourceActionsState>, onOpen: @escaping (String) -> Void) -> some View {
        modifier(SourceActionsModifier(actions: actions, onOpen: onOpen))
    }

    /// The whole view accepts dropped files and links for a project (nil = Sin asignar), with a calm overlay.
    func sourceDropTarget(projectSlug: String?) -> some View {
        modifier(SourceDropModifier(projectSlug: projectSlug))
    }
}

/// A source's actions. `trimmed` = the Contenido row menu (CONTRACT §15.2): pendientes y acuerdos · exportar ·
/// cambiar fecha · reaprender · mover · Finder · eliminar (reintentar only when it failed).
struct SourceMenuItems: View {
    @Environment(AppState.self) private var state
    let source: SourceRecord
    var trimmed = false
    var onOpen: (String) -> Void
    @Binding var actions: SourceActionsState

    private var canHaveTasks: Bool { source.kind == .meeting || source.kind == .email }

    var body: some View {
        if !trimmed, source.status == .done {
            Button(L("sources.openSummary")) { SourceOpener.openSummary(source, state: state, onOpen: onOpen) }
        }
        if !trimmed, source.kind == .email, let thread = source.threadKey {
            Button(L("thread.view")) { actions.sheet = .thread(thread) }
        }
        if source.status == .failed {
            Button(L("sources.retry")) { state.engine.retry(sourceId: source.id) }
        }
        if canHaveTasks, source.status == .done {
            Button(L("srctasks.title")) { actions.sheet = .tasks(source) }
        }
        if source.status != .recording {
            Button(L("export.buttonEllipsis")) { actions.sheet = .export(source) }
                .disabled(source.rawPath == nil)
            Button(L("dates.change")) { actions.sheet = .date(source) }
        }
        if !trimmed, canHaveTasks, source.status == .done, source.projectSlug != nil {
            Button(L("reformat.menu")) { actions.sheet = .reformat(source) }
        }
        if source.status == .done, source.historyId == nil, source.error == nil, source.rawPath != nil {
            Button(L("sources.relearn")) { state.engine.retry(sourceId: source.id) }
        }
        if source.status != .recording {
            Menu(L("sources.moveTo")) {
                ForEach(state.projects.filter { $0.slug != source.projectSlug }) { project in
                    Button("\(project.emoji) \(project.name)") {
                        do { try state.engine.assign(sourceId: source.id, to: project.slug) } catch {
                            actions.error = (error as? EngineError)?.errorDescription ?? L("sources.moveFailed")
                        }
                    }
                }
            }
        }
        if let raw = source.rawPath {
            Divider()
            if !trimmed {
                Button(source.kind == .email ? L("sources.openEmail")
                       : (source.kind == .meeting ? L("sources.openTranscript") : L("sources.openOriginal"))) {
                    onOpen(raw)
                }
            }
            Button(L("wiki.showInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting([state.engine.vault.url(for: raw)])
            }
        }
        if source.status != .recording {
            Divider()
            Button(L("sources.delete"), role: .destructive) { actions.pendingDelete = source }
        }
    }
}

@MainActor
enum SourceOpener {
    /// The summary page when Claude already wrote it, else the raw transcript/text.
    static func openSummary(_ source: SourceRecord, state: AppState, onOpen: @escaping (String) -> Void) {
        let vault = state.engine.vault
        Task {
            let page = await Task.detached { SourcePages.summaryPage(for: source, vault: vault) }.value
            if let path = page ?? source.rawPath { onOpen(path) }
        }
    }
}

struct ImportBatch: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - Importing (drop, files, links)

@MainActor
enum SourceImport {
    /// "Agregar archivos…": the open panel. Returns nil when cancelled.
    static func chooseFiles() -> ImportBatch? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("sources.addFiles")
        panel.message = L("sources.panelMessage")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return ImportBatch(urls: panel.urls)
    }

    /// Files (documents, audio, video) and links. Extraction and copying run off the main thread; audio and
    /// video become meetings that get transcribed by the queue. Returns the failures, one line each.
    static func importURLs(_ urls: [URL], projectSlug: String?, state: AppState) async -> [String] {
        var failed: [String] = []
        for url in urls {
            do {
                if url.isFileURL {
                    try await state.engine.importFileAsync(url, projectSlug: projectSlug)
                } else {
                    try await state.engine.importURL(url, projectSlug: projectSlug)
                }
            } catch let engineError as EngineError {
                failed.append(engineError.errorDescription ?? L("sources.importFailed", url.lastPathComponent))
            } catch {
                failed.append(url.isFileURL ? L("sources.importFailed", url.lastPathComponent) : L("sources.linkFailed"))
            }
        }
        return failed
    }
}

private struct SourceDropModifier: ViewModifier {
    @Environment(AppState.self) private var state
    let projectSlug: String?

    @ViewState private var targeted = false
    @ViewState private var importing = 0
    @ViewState private var error: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    let shape = RoundedRectangle(cornerRadius: Brand.radius.sheet, style: .continuous)
                    shape
                        .strokeBorder(Brand.color.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(Brand.color.accentSoft, in: shape)
                        .overlay {
                            VStack(spacing: 6) {
                                Label(L("sources.dropHere"), systemImage: "arrow.down.doc")
                                    .font(Brand.section)
                                    .foregroundStyle(Brand.color.text)
                                Text(L("sources.dropHint"))
                                    .font(Brand.body)
                                    .foregroundStyle(Brand.color.text2)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(Brand.spacing.xl)
                        }
                        .padding(Brand.spacing.s)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if importing > 0 {
                    BrandLoader(size: 16, text: L("sources.importing"))
                        .padding(.horizontal, Brand.spacing.m)
                        .padding(.vertical, Brand.spacing.s)
                        .background(Capsule().fill(Brand.color.card))
                        .overlay(Capsule().strokeBorder(Brand.color.line))
                        .brandOverlayShadow()
                        .padding(Brand.spacing.l)
                        .transition(.opacity)
                }
            }
            .animation(Brand.motion.fast, value: targeted)
            .animation(Brand.motion.fast, value: importing)
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                importing += 1
                Task {
                    let failed = await SourceImport.importURLs(urls, projectSlug: projectSlug, state: state)
                    importing -= 1
                    if !failed.isEmpty { error = failed.joined(separator: "\n") }
                }
                return true
            } isTargeted: { targeted = $0 }
            .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L("common.ok")) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }
}

// MARK: - Rows

struct SourceRow: View {
    @Environment(AppState.self) private var state
    let source: SourceRecord
    var onOpen: (String) -> Void
    @Binding var actions: SourceActionsState

    @ViewState private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Brand.spacing.m) {
            SourceKindIcon(kind: source.kind)
                .help(source.kind.label)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(source.title)
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(2)
                    if source.calendarEventId != nil {
                        Image(systemName: "calendar")
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text3)
                            .help(L("content.fromCalendar"))
                    }
                }
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(source.datesLine)
                    if source.addedLater {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text3)
                            .help(L("sources.addedLater") + " · " + source.datesLine)
                    }
                }
                if source.status == .failed {
                    HStack(spacing: 8) {
                        Text(SourceRow.failureText(source))
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.danger)
                            .lineLimit(2)
                        Button(L("sources.retry")) { state.engine.retry(sourceId: source.id) }
                            .buttonStyle(.borderless)
                            .font(Brand.font(11, .medium))
                            .foregroundStyle(Brand.color.accent)
                            .lineLimit(1)
                    }
                }
                if source.status.isInProgress, let progress = source.progress {
                    ProgressView(value: progress).controlSize(.small).frame(maxWidth: 260).tint(Brand.color.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if source.status != .done {
                StatusPill(status: source.status, progress: source.progress)
            }
            Menu {
                SourceMenuItems(source: source, onOpen: onOpen, actions: $actions)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Brand.color.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("project.more"))
        }
        .padding(.horizontal, Brand.spacing.m)
        .padding(.vertical, Brand.spacing.s)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(hovering ? Brand.color.cardAlt.opacity(0.6) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { SourceOpener.openSummary(source, state: state, onOpen: onOpen) }
        .contextMenu { SourceMenuItems(source: source, onOpen: onOpen, actions: $actions) }
    }

    /// "26 oct, 15:30 · 45 min · formato Entrevista" (the "added" date lives in the tooltip).
    private var subtitle: String {
        var parts = [Fmt.dayTime(source.timelineDate)]
        if let d = source.durationSeconds, d > 0 { parts.append(Fmt.shortDuration(d)) }
        if let template = state.template(source.templateId), source.templateId != TemplateInfo.standardId {
            parts.append(L("sources.withFormat", template.name))
        }
        return parts.joined(separator: " · ")
    }

    static func failureText(_ source: SourceRecord) -> String {
        source.kind == .meeting && source.rawPath == nil ? L("sources.failedTranscribe") : L("sources.failedLearn")
    }
}

/// The kind of a source in a soft tile (`cardAlt`, `text2`).
struct SourceKindIcon: View {
    let kind: SourceKind
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: kind.symbol)
            .font(Brand.font(size * 0.46))
            .foregroundStyle(Brand.color.text2)
            .frame(width: size, height: size)
            .background(Brand.color.cardAlt, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
    }
}

struct StatusPill: View {
    let status: SourceStatus
    var progress: Double?

    var body: some View {
        HStack(spacing: 4) {
            if status == .recording {
                BrandRecordingDot(size: 6)
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
        }
        .font(Brand.font(11, .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
        .layoutPriority(1)
    }

    private var text: String {
        if status.isInProgress, status != .queued, let progress { return "\(status.label) \(Fmt.percent(progress))" }
        return status.label
    }

    private var foreground: Color {
        switch status {
        case .recording: Brand.color.record
        case .queued: Brand.color.text2
        case .transcribing, .ingesting, .done: Brand.color.accent
        case .needsProject: Brand.color.warning
        case .failed: Brand.color.danger
        }
    }

    private var background: Color {
        switch status {
        case .recording: Brand.color.recordSoft
        case .needsProject: Brand.color.warningSoft
        case .transcribing, .ingesting, .done: Brand.color.accentSoft
        case .queued, .failed: Brand.color.cardAlt
        }
    }
}

// MARK: - Sheets

struct NoteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let projectSlug: String?

    @ViewState private var title = ""
    @ViewState private var text = ""
    @ViewState private var error: String?
    @ViewState private var when = Date()
    @ViewState private var opened = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.m) {
            Text(L("note.title"))
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
            Text(projectSlug == nil ? L("note.hintInbox") : L("note.hint"))
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
            TextField(L("note.titlePlaceholder"), text: $title)
                .brandTextField()
            TextEditor(text: $text)
                .font(Brand.body)
                .scrollContentBackground(.hidden)
                .padding(Brand.spacing.s)
                .frame(minHeight: 140, maxHeight: .infinity)
                .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.line))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L("content.notePlaceholder"))
                            .font(Brand.body)
                            .foregroundStyle(Brand.color.text3)
                            .padding(.horizontal, 13)
                            .padding(.vertical, Brand.spacing.s)
                            .allowsHitTesting(false)
                    }
                }
            WhenField(date: $when, hint: L("when.noteHint"))
            if let error {
                Text(error).font(Brand.body).foregroundStyle(Brand.color.danger)
            }
            HStack(spacing: Brand.spacing.s) {
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("note.save"), action: save)
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Brand.spacing.xxl)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 500)
        .background(Brand.color.surface)
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? L("note.defaultTitle", Fmt.date(when)) : trimmed
        do {
            // "¿Cuándo pasó?" changed from "now": the note is created with that date (before Claude learns from it).
            let eventDate: Date? = abs(when.timeIntervalSince(opened)) > 5 * 60 ? when : nil
            try state.engine.addNote(title: finalTitle, body: text, projectSlug: projectSlug, eventDate: eventDate)
            dismiss()
        } catch {
            self.error = L("note.failed")
        }
    }
}

/// "Pegar enlace…": a web page for the project to read (the link field that used to live in Fuentes).
struct PasteLinkSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let projectSlug: String?

    @ViewState private var linkText = ""
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.m) {
            Text(L("content.linkTitle"))
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
            Text(L("content.linkHint"))
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
            TextField(L("sources.linkPlaceholder"), text: $linkText)
                .brandTextField()
                .onSubmit(add)
            if let error {
                Text(error)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Brand.spacing.s) {
                if busy { BrandLoader(size: 16) }
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("sources.addLink"), action: add)
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Brand.spacing.xxl)
        .frame(minWidth: 420, idealWidth: 480, maxHeight: 520)
        .background(Brand.color.surface)
    }

    private func add() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        let normalized = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: normalized), url.host != nil else {
            error = L("sources.badLink")
            return
        }
        busy = true
        error = nil
        Task {
            do {
                try await state.engine.importURL(url, projectSlug: projectSlug)
                dismiss()
            } catch {
                self.error = L("sources.linkFailed")
            }
            busy = false
        }
    }
}

/// "Agregar archivos": when did these happen (the file's own date by default, or one the user picks) and,
/// for recordings, which format to use. Drag & drop skips this and uses the file dates.
struct ImportFilesSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]
    let projectSlug: String?

    @ViewState private var useFileDate = true
    @ViewState private var when = Date()
    @ViewState private var templateId: String?
    @ViewState private var fileDates: [URL: Date] = [:]
    @ViewState private var media: Set<URL> = []
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                form
                    .padding(Brand.spacing.xxl)
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            buttons
                .padding(.horizontal, Brand.spacing.xxl)
                .padding(.vertical, Brand.spacing.l)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 320, idealHeight: 460)
        .background(Brand.color.surface)
        .task { await inspect() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.l) {
            Text(urls.count == 1 ? L("import.titleOne") : L("import.titleMany", urls.count))
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(urls.prefix(6), id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(systemName: media.contains(url) ? "waveform" : "doc.text")
                            .foregroundStyle(Brand.color.text2)
                            .frame(width: 18)
                        Text(url.lastPathComponent)
                            .foregroundStyle(Brand.color.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let d = fileDates[url] {
                            Text(Fmt.dayTime(d)).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
                        }
                    }
                }
                if urls.count > 6 {
                    Text(L("import.andMore", urls.count - 6)).font(Brand.caption).foregroundStyle(Brand.color.text2)
                }
            }
            .padding(Brand.spacing.m)
            .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.line))

            VStack(alignment: .leading, spacing: Brand.spacing.s) {
                Text(L("when.title")).font(Brand.section).foregroundStyle(Brand.color.text)
                Picker("", selection: $useFileDate) {
                    Text(L("import.fileDate")).tag(true)
                    Text(L("import.otherDate")).tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if !useFileDate {
                    DatePicker("", selection: $when, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .padding(.leading, 20)
                }
                Text(L("import.dateHint"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !media.isEmpty {
                TemplatePicker(scope: .meeting, selection: $templateId, projectSlug: projectSlug)
            }
            if let error {
                Text(error)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.danger)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        HStack(spacing: Brand.spacing.s) {
            if busy { BrandLoader(size: 16) }
            Spacer()
            Button(L("common.cancel")) { dismiss() }
                .buttonStyle(.brandSecondary)
                .keyboardShortcut(.cancelAction)
            Button(L("import.go"), action: run)
                .buttonStyle(.brandPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
        }
    }

    private func inspect() async {
        let list = urls
        let (dates, isMedia) = await Task.detached { () -> ([URL: Date], Set<URL>) in
            var dates: [URL: Date] = [:]
            var media = Set<URL>()
            for url in list {
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                if let d = values?.creationDate ?? values?.contentModificationDate { dates[url] = min(d, Date()) }
                if AudioPrep.isMedia(url) { media.insert(url) }
            }
            return (dates, media)
        }.value
        fileDates = dates
        media = isMedia
        if let first = dates.values.min() { when = first }
    }

    private func run() {
        busy = true
        error = nil
        Task {
            var failed: [String] = []
            for url in urls {
                do {
                    // Date and format go in with the import itself, so the first ingest already uses them.
                    try await state.engine.importFileAsync(url, projectSlug: projectSlug,
                                                           eventDate: useFileDate ? nil : when,
                                                           templateId: media.contains(url) ? templateId : nil)
                } catch let engineError as EngineError {
                    failed.append(engineError.errorDescription ?? L("sources.importFailed", url.lastPathComponent))
                } catch {
                    failed.append(L("sources.importFailed", url.lastPathComponent))
                }
            }
            busy = false
            if failed.isEmpty {
                dismiss()
            } else {
                // At most three reasons, then "y N más" (the sheet never grows past the window).
                var lines = Array(failed.prefix(3))
                if failed.count > 3 { lines.append(L("import.andMore", failed.count - 3)) }
                error = lines.joined(separator: "\n")
            }
        }
    }
}

private extension View {
    /// A one-line field in the brand style (card fill, hairline, control radius), like the chat input: never the
    /// AppKit bezel next to a brand-styled editor.
    func brandTextField() -> some View {
        textFieldStyle(.plain)
            .font(Brand.body)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.line))
    }
}
