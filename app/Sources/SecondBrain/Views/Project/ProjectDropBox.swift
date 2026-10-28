import AppKit
import BrainCore
import SwiftUI

/// "Agregar al proyecto" (CONTRACT §17.3): the box at the top of Resumen — drop files (several) and/or write or paste
/// free text, Agregar ⌘↩ imports them and runs `/file-dump`, and the latest drops show how they were filed ("Lo archivé
/// así: …") with Deshacer. The same form lives in a sheet ("+ Agregar ▸ Agregar al proyecto…").
struct ProjectDropBox: View {
    @Environment(AppState.self) private var state
    let project: Project
    /// The most the box may take (Resumen passes 45 % of its height): past drops scroll inside it, so the brief and
    /// the side column below keep their room at the minimum window size (§15.3).
    var maxHeight: CGFloat = .infinity

    @ViewState private var model = DropBoxModel()
    @ViewState private var drops: [DumpRecord] = []
    @ViewState private var showAll = false
    @ViewState private var formHeight: CGFloat = 0
    @ViewState private var listHeight: CGFloat = 0

    /// Room left for the drops under the form (at least two lines of one).
    private var listCap: CGFloat {
        guard maxHeight.isFinite else { return showAll ? 320 : 240 }
        return max(64, maxHeight - formHeight - Brand.spacing.m * 2 - Brand.spacing.s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            DropBoxForm(model: model, projectSlug: project.slug, compact: true, accessory: {
                if !earlier.isEmpty {
                    Button {
                        withAnimation(Brand.motion.animation(fast: true)) { showAll.toggle() }
                    } label: {
                        Label(showAll ? L("dump.hideEarlier") : L("dump.showEarlier", earlier.count),
                              systemImage: showAll ? "chevron.up" : "chevron.down")
                            .font(Brand.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize()
                }
            })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
            if !recent.isEmpty || (showAll && !earlier.isEmpty) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Brand.spacing.s) {
                        ForEach(recent) { DumpRow(record: $0, summaryLines: 3) }
                        if showAll {
                            ForEach(earlier) { DumpRow(record: $0, summaryLines: 3) }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), listCap))
            }
        }
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, Brand.spacing.m)
        .background(Brand.color.surface)
        .task(id: reloadKey) { reload() }
    }

    /// On view: the newest drop while it is in progress, failed, or less than a day old; the rest are "Envíos
    /// anteriores".
    private var recent: [DumpRecord] {
        guard let latest = drops.first else { return [] }
        let fresh = latest.status == .queued || latest.status == .failed || Date().timeIntervalSince(latest.createdAt) < 86_400
        return fresh ? [latest] : []
    }

    private var earlier: [DumpRecord] { Array(drops.dropFirst(recent.count)) }

    /// Jobs (a drop queued, running, done), Historial (undone elsewhere) and the vault.
    private var reloadKey: String {
        let dumpJobs = state.engine.jobs.filter { $0.kind == .fileDump }.map { "\($0.id)\($0.status.rawValue)\($0.attempts)" }
        return "\(project.slug)-\(state.vaultRevision)-\(state.historyRevision)-\(model.submitCount)-\(dumpJobs.joined())"
    }

    private func reload() {
        drops = state.engine.dumps(projectSlug: project.slug)
    }
}

// MARK: - Form

@MainActor @Observable
final class DropBoxModel {
    var text = ""
    var files: [URL] = []
    var inPerson = false
    private(set) var saving = false
    var error: String?
    private(set) var submitCount = 0

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSubmit: Bool { !saving && (hasText || !files.isEmpty) }

    /// Files, and the files inside a dropped folder (subfolders included, hidden files and packages' insides left out,
    /// at most `folderLimit` per folder). A folder with nothing to add says so.
    func add(_ urls: [URL]) {
        var expanded: [URL] = []
        var emptyFolders: [String] = []
        for url in urls where url.isFileURL {
            if Self.isFolder(url) {
                let inside = Self.files(in: url)
                if inside.isEmpty { emptyFolders.append(url.lastPathComponent) }
                expanded += inside
            } else {
                expanded.append(url)
            }
        }
        let fresh = expanded.filter { !files.contains($0) }
        files += fresh
        if !emptyFolders.isEmpty {
            error = L("dump.folderEmpty", emptyFolders.joined(separator: ", "))
        } else if !fresh.isEmpty {
            error = nil
        }
    }

    static let folderLimit = 50

    private static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    private static func files(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
            guard values?.isRegularFile == true || values?.isPackage == true else { continue }
            out.append(url)
            if out.count >= folderLimit { break }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Imports and queues `/file-dump`; what was added leaves the form. Returns true on success.
    @discardableResult
    func submit(state: AppState, projectSlug: String) async -> Bool {
        guard canSubmit, state.engineStarted else { return false }
        saving = true
        error = nil
        defer { saving = false }
        let sending = (files, text, inPerson && hasText)
        do {
            let record = try await state.engine.addToProject(projectSlug, files: sending.0, text: sending.1, inPerson: sending.2)
            files.removeAll { sending.0.contains($0) }
            if text == sending.1 { text = "" }
            inPerson = false
            error = record.error.map { L("dump.someFailed", $0) }
            submitCount += 1
            state.bumpVault()
            return true
        } catch {
            self.error = FriendlyError.message(error)
            return false
        }
    }
}

/// The text field (files can be dropped or pasted on it), the dropped files, "Es una reunión presencial" and Agregar.
struct DropBoxForm: View {
    @Environment(AppState.self) private var state
    @Bindable var model: DropBoxModel
    let projectSlug: String?
    /// Resumen: shorter field that grows while there is something in it.
    var compact = false
    var onAdded: () -> Void = {}
    /// Right side of the compact header ("Envíos anteriores").
    var headerAccessory: AnyView? = nil

    init(model: DropBoxModel, projectSlug: String?, compact: Bool = false, onAdded: @escaping () -> Void = {}) {
        self.model = model; self.projectSlug = projectSlug; self.compact = compact; self.onAdded = onAdded
    }

    init<A: View>(model: DropBoxModel, projectSlug: String?, compact: Bool, @ViewBuilder accessory: () -> A) {
        self.model = model; self.projectSlug = projectSlug; self.compact = compact
        self.headerAccessory = AnyView(accessory())
    }

    @ViewState private var dropTargeted = false
    @ViewState private var chipsHeight: CGFloat = 0

    private var fieldHeight: CGFloat {
        if !compact { return 150 }
        return model.hasText || !model.files.isEmpty ? 96 : 44
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            if compact {
                HStack(spacing: Brand.spacing.s) {
                    Text(L("dump.title"))
                        .font(Brand.font(11, .semibold))
                        .foregroundStyle(Brand.color.text2)
                        .textCase(.uppercase)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    headerAccessory
                }
            }
            field
            if !model.files.isEmpty { fileChips }
            if let error = model.error {
                Text(error)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.danger)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.add(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .animation(Brand.motion.animation(fast: true), value: fieldHeight)
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
        // A file over the box: a soft `accentSoft` wash and a `focusBorder` edge, not a hard 2 pt accent frame.
        return CaptureTextView(text: $model.text, onFiles: { model.add($0) }, onSubmit: submit, onCancel: nil,
                               autoFocus: !compact)
            .frame(height: fieldHeight)
            .background(Brand.color.card, in: shape)
            .overlay { if dropTargeted { shape.fill(Brand.color.accentSoft).allowsHitTesting(false) } }
            .overlay(shape.strokeBorder(dropTargeted ? Brand.color.focusBorder : Brand.color.lineSoft,
                                        lineWidth: dropTargeted ? 1.5 : 1))
            .brandFocusHalo(dropTargeted)
            .overlay(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text(L("dump.placeholder"))
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text3)
                        .lineLimit(compact ? 2 : 4)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(L("dump.title"))
    }

    /// Many files wrap onto many lines: past a few lines they scroll, so the form (and its sheet) keeps its size.
    private var fileChips: some View {
        ScrollView {
            FlowChips(items: model.files.map { url in
                (id: url.path, title: url.lastPathComponent, symbol: Self.symbol(for: url))
            }) { id in model.files.removeAll { $0.path == id } }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipsHeight = $0 }
        }
        .frame(height: min(max(chipsHeight, 1), compact ? 52 : 84))
    }

    static func symbol(for url: URL) -> String {
        if AudioPrep.isMedia(url) { return "waveform" }
        return FileDumpNames.kind(of: url) == .image ? "photo" : "doc"
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Brand.spacing.s) {
                footerLeading
                Spacer(minLength: Brand.spacing.s)
                addButton
            }
            VStack(alignment: .leading, spacing: Brand.spacing.s) {
                footerLeading
                HStack { Spacer(minLength: 0); addButton }
            }
        }
    }

    private var footerLeading: some View {
        HStack(spacing: Brand.spacing.m) {
            Button {
                if let batch = SourceImport.chooseFiles() { model.add(batch.urls) }
            } label: {
                Label(L("dump.chooseFiles"), systemImage: "paperclip").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.brandSecondary)
            .help(L("dump.chooseFilesHelp"))
            Toggle(L("dump.inPerson"), isOn: $model.inPerson)
                .toggleStyle(.brandCheckbox)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .disabled(!model.hasText)
                .help(L("dump.inPersonHelp"))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var addButton: some View {
        HStack(spacing: Brand.spacing.s) {
            if model.saving { BrandLoader(size: 14) }
            Text("⌘↩")
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text3)
                .lineLimit(1)
                .fixedSize()
            Button(L("dump.add"), action: submit)
                .buttonStyle(.brandPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSubmit || projectSlug == nil || !state.engineStarted)
                .help(L("dump.addHelp"))
        }
    }

    private func submit() {
        guard let projectSlug, model.canSubmit else { return }
        Task {
            if await model.submit(state: state, projectSlug: projectSlug) { onAdded() }
        }
    }
}

/// Removable chips that wrap onto several lines.
private struct FlowChips: View {
    let items: [(id: String, title: String, symbol: String)]
    let onRemove: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.id) { item in
                HStack(spacing: 4) {
                    Image(systemName: item.symbol).foregroundStyle(Brand.color.text2)
                    Text(item.title)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Button { onRemove(item.id) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.color.text3)
                    }
                    .buttonStyle(.plain)
                    .help(L("capture.removeFile"))
                }
                .font(Brand.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Brand.color.cardAlt, in: Capsule())
            }
        }
    }
}

// MARK: - A drop

/// One past "Agregar": what was added, how it was filed ("Lo archivé así: …" + the pages, clickable), Deshacer.
struct DumpRow: View {
    @Environment(AppState.self) private var state
    let record: DumpRecord
    var summaryLines = 6

    @ViewState private var error: String?
    @ViewState private var busy = false

    private var job: Job? { record.jobId.flatMap { id in state.engine.jobs.first { $0.id == id } } }
    private var running: Bool { job?.status == .running }

    var body: some View {
        HStack(alignment: .top, spacing: Brand.spacing.s) {
            statusIcon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: Brand.spacing.s) {
                    Text(headline)
                        .font(Brand.callout)
                        .foregroundStyle(record.status == .undone ? Brand.color.text3 : Brand.color.text)
                        .strikethrough(record.status == .undone)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Brand.spacing.s)
                    Text(Fmt.relative(record.createdAt))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text3)
                        .lineLimit(1)
                        .fixedSize()
                    actions
                }
                detail
                if let error {
                    Text(error).font(Brand.caption).foregroundStyle(Brand.color.danger)
                }
            }
        }
        .padding(Brand.spacing.s)
        .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).strokeBorder(Brand.color.lineSoft))
    }

    /// The text's first line, else the files' names.
    private var headline: String {
        if let text = record.textPreview, let title = CaptureDetector.noteTitle(text) {
            return record.files.isEmpty ? title : L("dump.textAndFiles", title, record.files.count + record.recordings.count)
        }
        let names = (record.files + record.recordings).map(\.name)
        return names.count == 1 ? names[0] : L("dump.files", names.count)
    }

    @ViewBuilder private var statusIcon: some View {
        switch record.status {
        case .queued:
            if running { BrandLoader(size: 14) } else { Image(systemName: "clock").foregroundStyle(Brand.color.text2) }
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.color.success)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.color.warning)
        case .undone: Image(systemName: "arrow.uturn.backward").foregroundStyle(Brand.color.text3)
        }
    }

    @ViewBuilder private var detail: some View {
        switch record.status {
        case .queued:
            Text(running ? L("dump.filing") : (job?.notBefore.map { $0 > Date() } == true ? L("dump.waitingClaude") : L("dump.queued")))
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
        case .failed:
            Text(record.error ?? L("dump.failed"))
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(3)
        case .undone:
            Text(L("dump.undone")).font(Brand.caption).foregroundStyle(Brand.color.text3)
        case .done:
            if let summary = record.summary, !summary.isEmpty {
                Text(Self.plain(summary))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(summaryLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(Self.plain(summary))
            }
            let pages = record.items.filter { $0.page != nil }
            if !pages.isEmpty {
                WrapLayout(spacing: 6) {
                    ForEach(pages, id: \.self) { item in
                        Button { open(item.page!) } label: {
                            Label(item.title, systemImage: Self.symbol(item.kind))
                                .font(Brand.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Brand.color.accentSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.color.accent)
                        .help(L("dump.openPage"))
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch record.status {
        case .queued where !running, .done:
            Button(L("dump.undo")) { undo() }
                .buttonStyle(.plain)
                .font(Brand.caption)
                .foregroundStyle(Brand.color.accent)
                .disabled(busy)
                .help(L("dump.undoHelp"))
        case .failed:
            Button(L("dump.retry")) { state.engine.retryDump(id: record.id); state.bumpVault() }
                .buttonStyle(.plain)
                .font(Brand.caption)
                .foregroundStyle(Brand.color.accent)
            Button(L("dump.undo")) { undo() }
                .buttonStyle(.plain)
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
        default:
            EmptyView()
        }
    }

    private func undo() {
        busy = true
        defer { busy = false }
        do {
            try state.engine.undoDump(id: record.id)
            error = nil
            state.bumpVault()
            state.bumpHistory()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    private func open(_ path: String) {
        state.navigate(to: .entity(path, Scope(projectSlug: record.projectSlug)))
    }

    /// `[[target|Label]]` → `Label`, `[[target]]` → `target`; the pages are the chips below.
    static func plain(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: #"\[\[(?:[^\]\|\n]*\|)?([^\]\n]*)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "• ", options: .regularExpression)
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "in-person": SourceKind.inPerson.symbol
        case "note": SourceKind.note.symbol
        case "document": SourceKind.document.symbol
        case "image": SourceKind.image.symbol
        case "decision": "checkmark.seal"
        case "tasks": "checklist"
        case "person": "person"
        case "org": "building.2"
        default: "doc.text"
        }
    }
}

// MARK: - Sheet

/// "+ Agregar ▸ Agregar al proyecto…" (sidebar, project toolbar, ⌘K): MainView presents `ProjectDropSheet`.
struct DumpRequest: Identifiable, Equatable {
    let id = UUID()
    var projectSlug: String?
}

struct ProjectDropSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: DumpRequest

    @ViewState private var model = DropBoxModel()
    @ViewState private var slug: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.m) {
            Text(L("dump.sheetTitle"))
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
            Text(L("dump.sheetHint"))
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Brand.spacing.s) {
                Text(L("dump.project"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize()
                BrandProjectMenu(selection: $slug, includeInbox: false, placeholder: L("dump.pickProject"), maxWidth: 240)
                    .accessibilityLabel(L("dump.project"))
            }
            DropBoxForm(model: model, projectSlug: slug, compact: false, onAdded: {
                dismiss()
                if let slug { state.navigate(to: .sidebar(.project(slug))) }
            })
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 380, idealHeight: 460)
        .background(Brand.color.surface)
        .onAppear {
            if slug == nil { slug = request.projectSlug.flatMap { state.project($0)?.slug } }
        }
    }
}

// MARK: - In-person meetings in lists

extension TimelineEntry {
    /// The row's icon: an in-person meeting (§17.3) is a meeting with its own symbol.
    @MainActor func symbol(engine: BrainEngine) -> String {
        if kind == .meeting, let id = sourceId, engine.source(id)?.kind == .inPerson { return SourceKind.inPerson.symbol }
        return kind.symbol
    }
}

// MARK: - Snapshots

/// `SB_SNAPSHOT_DIR` (isolated config only): two past drops in the first project's box, and the sheet.
enum DumpSnapshots {
    static let darkNames: Set<String> = ["dump-sheet"]

    @MainActor static func seed(state: AppState) {
        guard let project = state.projects.first, state.engine.dumps(projectSlug: project.slug).isEmpty else { return }
        let slug = project.slug
        let wiki = "projects/\(slug)/wiki"
        let fm = FileManager.default
        let pages = ["meetings", "sources"].flatMap { sub in
            ((try? fm.contentsOfDirectory(atPath: state.engine.vault.url(for: "\(wiki)/\(sub)").path)) ?? [])
                .filter { $0.hasSuffix(".md") }.sorted().map { "\(wiki)/\(sub)/\($0)" }
        }
        let meeting = pages.first { $0.contains("/meetings/") }
        let source = pages.first { $0.contains("/sources/") }
        func title(_ path: String?) -> String { path.map { state.engine.vault.title(of: $0) } ?? "" }
        var older = DumpRecord(projectSlug: slug, createdAt: Date().addingTimeInterval(-26 * 3600))
        older.files = [DumpFile(name: "Propuesta v2.pdf", sourceId: "demo-a", kind: .document)]
        older.status = .done
        older.summary = "Lo archivé así:\n- La propuesta v2 como documento del proyecto."
        older.items = source.map { [DumpFiled(kind: "document", title: title($0), page: $0, raw: nil)] } ?? []
        var latest = DumpRecord(projectSlug: slug, createdAt: Date().addingTimeInterval(-40 * 60))
        latest.textPreview = "Visita a la planta con Luis\n\nRevisamos la línea 2; Luis manda el layout el viernes."
        latest.files = [DumpFile(name: "Linea 2.jpg", sourceId: "demo-b", kind: .image)]
        latest.status = .done
        latest.summary = """
        Lo archivé así:
        - La visita a la planta como reunión presencial: [[x|Visita a la planta]].
        - La foto de la línea 2 quedó junto a la reunión; Luis manda el layout el viernes (en tus pendientes).
        """
        latest.items = [meeting.map { DumpFiled(kind: "in-person", title: title($0), page: $0, raw: nil) },
                        DumpFiled(kind: "tasks", title: L("tasks.title"), page: "projects/\(slug)/wiki/tasks.md", raw: nil)]
            .compactMap { $0 }
        let store = DumpStore(dataRoot: state.engine.paths.root, vaultRoot: state.engine.vault.root)
        store.save(older)
        store.save(latest)
    }

    @MainActor static func shots(state: AppState) -> [(String, CGSize, AnyView)] {
        [("dump-sheet", CGSize(width: 600, height: 460),
          AnyView(ProjectDropSheet(request: DumpRequest(projectSlug: state.projects.first?.slug))))]
    }
}
