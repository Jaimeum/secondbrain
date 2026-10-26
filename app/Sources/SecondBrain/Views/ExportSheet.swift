import AppKit
import BrainCore
import SwiftUI
import UniformTypeIdentifiers

/// "Exportar…": choose a format (Word, PDF, Markdown…) and what to include, then save or copy.
struct ExportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: ExportRequest

    @AppStorage("export.format") private var formatRaw = ExportFormat.docx.rawValue
    @ViewState private var options = ExportOptions()
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var savedURL: URL?
    @ViewState private var copied = false

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .docx }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("export.title")).font(.title2.weight(.semibold))
                Text(displayTitle).foregroundStyle(.secondary).lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("export.format")).font(.headline)
                Picker("", selection: $formatRaw) {
                    ForEach(ExportFormat.menuOrder, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(formatHint).font(.caption).foregroundStyle(.secondary)
            }

            if hasOptions {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("export.include")).font(.headline)
                    if case .source(let source) = request.target {
                        Toggle(L("export.opt.summary"), isOn: $options.includeSummary)
                        Toggle(L("export.opt.tasks"), isOn: $options.includeTasks)
                        Toggle(source.kind == .email ? L("export.opt.emails") : L("export.opt.transcript"),
                               isOn: $options.includeTranscript)
                        if source.kind == .meeting {
                            Group {
                                Toggle(L("export.opt.timestamps"), isOn: $options.includeTimestamps)
                                Toggle(L("export.opt.names"), isOn: $options.resolveSpeakerNames)
                            }
                            .padding(.leading, 20)
                            .disabled(!options.includeTranscript)
                        }
                    }
                    if format == .markdown {
                        Toggle(L("export.opt.wikilinks"), isOn: $options.keepWikilinks)
                        Toggle(L("export.opt.frontmatter"), isOn: $options.keepFrontmatter)
                    }
                }
                .toggleStyle(.checkbox)
            }

            if let savedURL {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("export.saved", savedURL.lastPathComponent)).lineLimit(2)
                    Spacer()
                    Button(L("wiki.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                    Button(L("export.open")) { NSWorkspace.shared.open(savedURL) }
                }
                .font(.callout)
                .padding(10)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }

            HStack {
                Button {
                    Task { await copy() }
                } label: {
                    Label(copied ? L("export.copied") : L("export.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(busy)
                .help(L("export.copyHelp"))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(savedURL == nil ? L("common.cancel") : L("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("export.save")) { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || nothingSelected)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onChange(of: formatRaw) { savedURL = nil; copied = false }
    }

    private var hasOptions: Bool {
        if case .source = request.target { return true }
        return format == .markdown
    }

    private var nothingSelected: Bool {
        guard case .source = request.target else { return false }
        return !options.includeSummary && !options.includeTasks && !options.includeTranscript
    }

    private var formatHint: String {
        switch format {
        case .docx: L("export.hint.docx")
        case .pdf: L("export.hint.pdf")
        case .markdown: L("export.hint.markdown")
        case .text: L("export.hint.text")
        case .html: L("export.hint.html")
        case .rtf: L("export.hint.rtf")
        }
    }

    private var displayTitle: String {
        switch request.target {
        case .source(let source): "\(source.emoji) \(source.title)"
        case .page(_, let title): title
        case .tasks(let tasks, let title): "\(title) · \(L("tasks.count", tasks.count))"
        }
    }

    /// "2026-10-26 Kickoff con Acme.docx" — the date is when it happened.
    private func suggestedName(title: String) -> String {
        var date = Date()
        if case .source(let source) = request.target { date = source.timelineDate }
        let clean = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(Fmt.fileDay(date)) \(clean.prefix(80)).\(format.fileExtension)"
    }

    private func document() async throws -> (title: String, markdown: String) {
        switch request.target {
        case .source(let source):
            return try await state.engine.exportDocument(sourceId: source.id, options: options)
        case .page(let path, _):
            return try await state.engine.exportDocument(pagePath: path, options: options)
        case .tasks(let tasks, let title):
            return (title, state.engine.exportTasks(tasks, title: title))
        }
    }

    private func save() async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            let doc = try await document()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName(title: doc.title)
            if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
            panel.canCreateDirectories = true
            panel.message = L("export.panelMessage")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try Exporter.export(markdown: doc.markdown, title: doc.title, format: format, options: options, to: url)
            savedURL = url
        } catch {
            self.error = L("export.failed", FriendlyError.message(error))
        }
    }

    private func copy() async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            let doc = try await document()
            Exporter.copyToPasteboard(markdown: doc.markdown, options: options)
            copied = true
        } catch {
            self.error = L("export.failed", FriendlyError.message(error))
        }
    }
}
