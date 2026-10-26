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

    private var sources: [SourceRecord] {
        state.engine.sources.filter { $0.projectSlug == projectSlug }
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
                        SourceRow(source: source, onOpen: onOpen, onDelete: { pendingDelete = source }, onError: { error = $0 })
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
            Button { showNote = true } label: { Label(L("sources.newNote"), systemImage: "square.and.pencil") }
            Button(action: chooseFiles) { Label(L("sources.addFiles"), systemImage: "doc.badge.plus") }
                .help(L("sources.addFilesHelp"))
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
        if panel.runModal() == .OK { importURLs(panel.urls) }
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

struct SourceRow: View {
    @Environment(AppState.self) private var state
    let source: SourceRecord
    var onOpen: (String) -> Void
    var onDelete: () -> Void
    var onError: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: source.kind.symbol)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(source.title).font(.body.weight(.medium)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
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
        .onTapGesture(count: 2) { if let raw = source.rawPath { onOpen(raw) } }
        .contextMenu { menuItems }
    }

    private var subtitle: String {
        var parts = [source.kind.label, Fmt.date(source.createdAt)]
        if let d = source.durationSeconds, d > 0 { parts.append(Fmt.shortDuration(d)) }
        return parts.joined(separator: " · ")
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
        if let raw = source.rawPath {
            Button(L("sources.openTranscript")) { onOpen(raw) }
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
        let finalTitle = trimmed.isEmpty ? L("note.defaultTitle", Fmt.date(Date())) : trimmed
        do {
            try state.engine.addNote(title: finalTitle, body: text, projectSlug: projectSlug)
            dismiss()
        } catch {
            self.error = L("note.failed")
        }
    }
}
