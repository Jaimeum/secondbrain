import AppKit
import BrainCore
import SwiftUI
import UniformTypeIdentifiers

/// "Exportar…": a format (menu + one-line hint) and what to include, then save or copy. Sized per CONTRACT §15.3.
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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.spacing.xl) {
                    SheetTitleBlock(title: L("export.title"), subtitle: displayTitle, symbol: displaySymbol)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: Brand.spacing.m) {
                            Text(L("export.format"))
                                .font(Brand.callout)
                                .foregroundStyle(Brand.color.text)
                                .lineLimit(1)
                            Picker("", selection: $formatRaw) {
                                ForEach(ExportFormat.menuOrder, id: \.self) { Text($0.label).tag($0.rawValue) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 200, alignment: .leading)
                        }
                        Text(formatHint)
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(formatHint)
                    }

                    if hasOptions {
                        VStack(alignment: .leading, spacing: Brand.spacing.s) {
                            Text(L("export.include"))
                                .font(Brand.callout)
                                .foregroundStyle(Brand.color.text)
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
                                    .padding(.leading, Brand.spacing.xl)
                                    .disabled(!options.includeTranscript)
                                }
                            }
                            if format == .markdown {
                                Toggle(L("export.opt.wikilinks"), isOn: $options.keepWikilinks)
                                Toggle(L("export.opt.frontmatter"), isOn: $options.keepFrontmatter)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text)
                    }

                    if let savedURL {
                        VStack(alignment: .leading, spacing: Brand.spacing.s) {
                            HStack(alignment: .firstTextBaseline, spacing: Brand.spacing.s) {
                                Image(systemName: "checkmark.circle").foregroundStyle(Brand.color.success)
                                Text(L("export.saved", savedURL.lastPathComponent))
                                    .foregroundStyle(Brand.color.text)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: Brand.spacing.s) {
                                Button(L("export.open")) { NSWorkspace.shared.open(savedURL) }
                                    .buttonStyle(.brandSecondary)
                                Button(L("wiki.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                                    .buttonStyle(.brandSecondary)
                            }
                        }
                        .font(Brand.body)
                        .padding(Brand.spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
                            .fill(Brand.color.accentSoft))
                    }
                    if let error {
                        Text(error)
                            .font(Brand.body)
                            .foregroundStyle(Brand.color.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Brand.spacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(Brand.color.line).frame(height: 1)
            HStack(spacing: Brand.spacing.s) {
                Button {
                    Task { await copy() }
                } label: {
                    Label(copied ? L("export.copied") : L("export.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.brandSecondary)
                .fixedSize()
                .disabled(busy)
                .help(L("export.copyHelp"))
                Spacer(minLength: Brand.spacing.s)
                if busy { BrandLoader(size: 16) }
                Button(savedURL == nil ? L("common.cancel") : L("common.close")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)
                Button(L("export.save")) { Task { await save() } }
                    .buttonStyle(.brandPrimary)
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || nothingSelected)
            }
            .padding(.horizontal, Brand.spacing.xxl)
            .padding(.vertical, Brand.spacing.m)
        }
        .background(Brand.color.surface)
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 640, minHeight: 300, idealHeight: 440, maxHeight: 640)
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

    private var displaySymbol: String? {
        switch request.target {
        case .source(let source): source.symbol
        case .page(let path, _): SourceLabels.symbol(forPath: path)
        case .tasks: "checklist"
        }
    }

    private var displayTitle: String {
        switch request.target {
        case .source(let source): source.title
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
