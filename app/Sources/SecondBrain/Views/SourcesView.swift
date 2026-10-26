import AppKit
import BrainCore
import SwiftUI
import UniformTypeIdentifiers

/// "Reuniones y fuentes": everything the project learned from, with status, and ways to add more.
struct SourcesView: View {
    @Environment(AppState.self) private var state
    let projectSlug: String
    var onOpen: (String) -> Void

    @ViewState private var linkText = ""
    @ViewState private var isAddingLink = false
    @ViewState private var showNote = false
    @ViewState private var dropTargeted = false
    @ViewState private var error: String?
    @ViewState private var pendingDelete: SourceRecord?
    @ViewState private var importing = 0
    @ViewState private var sheet: SourceSheet?
    @ViewState private var filesToImport: ImportBatch?
    @AppStorage("sources.sortByAdded") private var sortByAdded = false

    private var sources: [SourceRecord] {
        state.engine.sources.filter { $0.projectSlug == projectSlug }
            .sorted { sortByAdded ? $0.createdAt > $1.createdAt : $0.timelineDate > $1.timelineDate }
    }

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            if sources.isEmpty {
                EmptyStateView(symbol: "tray.and.arrow.down", title: L("sources.emptyTitle"), message: L("sources.emptyMessage"))
            } else {
                List {
                    ForEach(sources) { source in
                        SourceRow(source: source, sortByAdded: sortByAdded, onOpen: onOpen, onDelete: { pendingDelete = source },
                                  onError: { error = $0 }, onSheet: { sheet = $0 })
                    }
                }
                .listStyle(.inset)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        VStack(spacing: 6) {
                            Label(L("sources.dropHere"), systemImage: "arrow.down.doc").font(.title3.weight(.semibold))
                            Text(L("sources.dropHint")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importURLs(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .sheet(isPresented: $showNote) {
            NoteSheet(projectSlug: projectSlug)
        }
        .sheet(item: $sheet) { $0.view(onOpen: onOpen) }
        .sheet(item: $filesToImport) { batch in
            ImportFilesSheet(urls: batch.urls, projectSlug: projectSlug)
        }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog(L("sources.deleteConfirm", pendingDelete?.title ?? ""),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(L("sources.delete"), role: .destructive) {
                if let source = pendingDelete {
                    do { try state.engine.delete(sourceId: source.id) } catch { self.error = L("sources.deleteFailed") }
                }
                pendingDelete = nil
            }
        } message: {
            Text(L("sources.deleteMessage"))
        }
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField(L("sources.linkPlaceholder"), text: $linkText)
                    .textFieldStyle(.plain)
                    .onSubmit(addLink)
                if isAddingLink {
                    ProgressView().controlSize(.small)
                } else if !linkText.isEmpty {
                    Button(L("sources.addLink"), action: addLink).buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            if importing > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("sources.importing")).font(.callout).foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            Button { state.requestEmail(projectSlug: projectSlug) } label: {
                Label(L("email.add"), systemImage: "envelope.badge")
            }
            .help(L("email.addHelp"))
            Button { showNote = true } label: { Label(L("sources.newNote"), systemImage: "square.and.pencil") }
            Button(action: chooseFiles) { Label(L("sources.addFiles"), systemImage: "doc.badge.plus") }
                .help(L("sources.addFilesHelp"))
            Menu {
                Picker("", selection: $sortByAdded) {
                    Text(L("sources.sortEvent")).tag(false)
                    Text(L("sources.sortAdded")).tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("sources.sortHelp"))
        }
        .padding(12)
    }

    private func addLink() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let normalized = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: normalized), url.host != nil else {
            error = L("sources.badLink")
            return
        }
        isAddingLink = true
        Task {
            do {
                try await state.engine.importURL(url, projectSlug: projectSlug)
                linkText = ""
            } catch {
                self.error = L("sources.linkFailed")
            }
            isAddingLink = false
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("sources.addFiles")
        panel.message = L("sources.panelMessage")
        if panel.runModal() == .OK, !panel.urls.isEmpty { filesToImport = ImportBatch(urls: panel.urls) }
    }

    /// Files (documents, audio, video) and links. Extraction and copying run off the main thread; audio and
    /// video become meetings that show up below and get transcribed by the queue.
    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing += 1
        Task {
            defer { importing -= 1 }
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
            if !failed.isEmpty { self.error = failed.joined(separator: "\n") }
        }
    }
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

struct ImportBatch: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct SourceRow: View {
    @Environment(AppState.self) private var state
    let source: SourceRecord
    var sortByAdded = false
    var onOpen: (String) -> Void
    var onDelete: () -> Void
    var onError: (String) -> Void
    var onSheet: (SourceSheet) -> Void = { _ in }

    private var isEmail: Bool { source.kind == .email }
    private var canHaveTasks: Bool { source.kind == .meeting || source.kind == .email }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: source.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(isEmail ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .background((isEmail ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)),
                            in: RoundedRectangle(cornerRadius: 7))
                .help(source.kind.label)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.title).font(.body.weight(.medium)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if source.addedLater {
                    Label(L("sources.addedLater"), systemImage: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if source.status == .failed {
                    HStack(spacing: 8) {
                        Text(failureText).font(.caption).foregroundStyle(.red)
                        Button(L("sources.retry")) { state.engine.retry(sourceId: source.id) }
                            .controlSize(.small)
                    }
                }
                if source.status.isInProgress, let progress = source.progress {
                    ProgressView(value: progress).controlSize(.small).frame(maxWidth: 260)
                }
            }
            Spacer(minLength: 8)
            StatusPill(status: source.status, progress: source.progress)
            actionsMenu
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: openSummary)
        .contextMenu { menuItems }
    }

    /// "Reunión: 26 oct, 15:30 · Agregada: hoy 10:02 · 45 min".
    private var subtitle: String {
        var parts = [source.datesLine]
        if let d = source.durationSeconds, d > 0 { parts.append(Fmt.shortDuration(d)) }
        if let template = state.template(source.templateId), source.templateId != TemplateInfo.standardId {
            parts.append(L("sources.withFormat", template.name))
        }
        return parts.joined(separator: " · ")
    }

    /// The summary page when Claude already wrote it, else the raw transcript/text.
    private func openSummary() {
        let vault = state.engine.vault, src = source
        Task {
            let page = await Task.detached { SourcePages.summaryPage(for: src, vault: vault) }.value
            if let path = page ?? src.rawPath { onOpen(path) }
        }
    }

    private var failureText: String {
        source.kind == .meeting && source.rawPath == nil ? L("sources.failedTranscribe") : L("sources.failedLearn")
    }

    private var actionsMenu: some View {
        Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    @ViewBuilder private var menuItems: some View {
        if source.status == .done {
            Button(L("sources.openSummary"), action: openSummary)
        }
        if isEmail, let thread = source.threadKey {
            Button(L("thread.view")) { onSheet(.thread(thread)) }
        }
        if canHaveTasks, source.status == .done {
            Button(L("srctasks.title")) { onSheet(.tasks(source)) }
        }
        if source.status != .recording {
            Button(L("export.buttonEllipsis")) { onSheet(.export(source)) }
                .disabled(source.rawPath == nil)
        }
        Divider()
        if source.status != .recording {
            Button(L("dates.change")) { onSheet(.date(source)) }
        }
        if canHaveTasks, source.status == .done, source.projectSlug != nil {
            Button(L("reformat.menu")) { onSheet(.reformat(source)) }
        }
        Divider()
        if let raw = source.rawPath {
            Button(isEmail ? L("sources.openEmail") : (source.kind == .meeting ? L("sources.openTranscript") : L("sources.openOriginal"))) {
                onOpen(raw)
            }
            Button(L("wiki.showInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting([state.engine.vault.url(for: raw)])
            }
        }
        if source.status == .failed {
            Button(L("sources.retry")) { state.engine.retry(sourceId: source.id) }
        }
        if source.status == .done, source.historyId == nil, source.error == nil, source.rawPath != nil {
            Button(L("sources.relearn")) { state.engine.retry(sourceId: source.id) }
        }
        if source.status != .recording {
            Menu(L("sources.moveTo")) {
                ForEach(state.projects.filter { $0.slug != source.projectSlug }) { project in
                    Button("\(project.emoji) \(project.name)") {
                        do { try state.engine.assign(sourceId: source.id, to: project.slug) } catch {
                            onError((error as? EngineError)?.errorDescription ?? L("sources.moveFailed"))
                        }
                    }
                }
            }
            Divider()
            Button(L("sources.delete"), role: .destructive, action: onDelete)
        }
    }
}

struct StatusPill: View {
    let status: SourceStatus
    var progress: Double?

    var body: some View {
        HStack(spacing: 4) {
            if status == .recording {
                Circle().fill(.red).frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12), in: Capsule())
        .fixedSize()
    }

    private var text: String {
        if status.isInProgress, status != .queued, let progress { return "\(status.label) \(Fmt.percent(progress))" }
        return status.label
    }
}

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
        VStack(alignment: .leading, spacing: 14) {
            Text(L("note.title")).font(.title2.weight(.semibold))
            Text(L("note.hint")).foregroundStyle(.secondary)
            TextField(L("note.titlePlaceholder"), text: $title)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 220)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            WhenField(date: $when, hint: L("when.noteHint"))
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("note.save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
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
        VStack(alignment: .leading, spacing: 16) {
            Text(urls.count == 1 ? L("import.titleOne") : L("import.titleMany", urls.count)).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(urls.prefix(6), id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(systemName: media.contains(url) ? "waveform" : "doc.text").foregroundStyle(.secondary).frame(width: 18)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let d = fileDates[url] { Text(Fmt.dayTime(d)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if urls.count > 6 { Text(L("import.andMore", urls.count - 6)).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("when.title")).font(.headline)
                Picker("", selection: $useFileDate) {
                    Text(L("import.fileDate")).tag(true)
                    Text(L("import.otherDate")).tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if !useFileDate {
                    DatePicker("", selection: $when, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().fixedSize().padding(.leading, 20)
                }
                Text(L("import.dateHint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !media.isEmpty {
                TemplatePicker(scope: .meeting, selection: $templateId, projectSlug: projectSlug)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("import.go"), action: run)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await inspect() }
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
            if failed.isEmpty { dismiss() } else { error = failed.joined(separator: "\n") }
        }
    }
}
