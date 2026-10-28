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
    /// Bumped on every copy, so each one restarts the "Copiado" moment.
    @ViewState private var copyStamp = 0

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
                            BrandMenuPicker(title: format.label, selection: $formatRaw, maxWidth: 180) {
                                ForEach(ExportFormat.menuOrder, id: \.self) { Text($0.label).tag($0.rawValue) }
                            }
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
                        .toggleStyle(.brandCheckbox)
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
            .brandScrollEdgeFade(.bottom)

            BrandSheetFooter(horizontalPadding: Brand.spacing.xxl) {
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
                    .buttonStyle(.brandGhost)
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)
                Button(L("export.save")) { Task { await save() } }
                    .buttonStyle(.brandPrimary)
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || nothingSelected)
            }
        }
        .background(Brand.color.surface)
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 640, minHeight: 300, idealHeight: 440, maxHeight: 640)
        .onChange(of: formatRaw) { savedURL = nil; copied = false }
        .onChange(of: options) { copied = false }
        // "Copiado ✓" is a moment, not a state: back to "Copiar" so the next copy shows its own feedback.
        .task(id: copyStamp) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { withAnimation(Brand.motion.fast) { copied = false } }
        }
    }

    /// Task lists have no wikilinks or front matter to keep, so only sources and pages offer options.
    private var hasOptions: Bool {
        switch request.target {
        case .source: true
        case .page: format == .markdown
        case .tasks: false
        }
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
            return (title, TaskExport.markdown(tasks, title: title, state: state))
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
            copyStamp += 1
        } catch {
            self.error = L("export.failed", FriendlyError.message(error))
        }
    }
}

/// A task list as Markdown, in the words the screen uses: "Míos · De otros · Sin dueño" (the segment names), and
/// "· 🚀 Proyecto" on each line when the list spans more than one project (sidebar Pendientes).
enum TaskExport {
    @MainActor
    static func markdown(_ tasks: [TaskItem], title: String, state: AppState) -> String {
        let language = state.config.uiLanguage
        let manyProjects = Set(tasks.map(\.projectSlug)).count > 1
        var out = "# \(title)\n"
        let groups: [(String, [TaskItem])] = [
            (L("tasks.segment.mine"), tasks.filter(\.isMine)),
            (L("tasks.segment.theirs"), tasks.filter { !$0.isMine && ($0.ownerName != nil || $0.ownerSlug != nil) }),
            (L("tasks.segment.unowned"), tasks.filter { !$0.isMine && $0.ownerName == nil && $0.ownerSlug == nil }),
        ]
        for (heading, items) in groups where !items.isEmpty {
            out += "\n## \(heading)\n\n"
            let sorted = items.sorted { a, b in
                if a.done != b.done { return !a.done }
                return (a.due ?? .distantFuture, a.text) < (b.due ?? .distantFuture, b.text)
            }
            for task in sorted {
                var line = "- [\(task.done ? "x" : " ")] \(task.text)"
                if !task.isMine, let name = task.ownerName { line += " — \(name)" }
                if let due = task.due {
                    line += " · " + L("export.tasks.due", SBDate.human(due, hasTime: false, language: language))
                }
                if task.done, let doneDate = task.doneDate {
                    line += " · " + L("export.tasks.done", SBDate.human(doneDate, hasTime: false, language: language))
                }
                if manyProjects {
                    let project = state.project(task.projectSlug)
                    line += " · " + (project.map { "\($0.emoji) \($0.name)" } ?? task.projectSlug)
                }
                out += line + "\n"
            }
        }
        if tasks.isEmpty { out += "\n" + L("export.tasks.none") + "\n" }
        return out
    }
}
