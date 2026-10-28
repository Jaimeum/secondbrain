import BrainCore
import SwiftUI

/// "Historial": every change Claude made to the brain, what it changed (by page title), and one way back per change.
struct ActivityView: View {
    @Environment(AppState.self) private var state
    let projectSlug: String?
    var onOpenPage: (String) -> Void

    @ViewState private var entries: [HistoryEntry] = []
    @ViewState private var summaries: [String: String] = [:]
    @ViewState private var titles: [String: String] = [:]
    @ViewState private var loaded = false
    @ViewState private var diffTarget: DiffTarget?
    @ViewState private var pendingUndo: HistoryEntry?
    @ViewState private var conflict: (entry: HistoryEntry, paths: [String])?
    @ViewState private var error: String?

    var body: some View {
        Group {
            if !loaded {
                BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: L("activity.emptyTitle"), message: L("activity.emptyMessage"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Brand.spacing.s) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry,
                                       summary: summaries[entry.id],
                                       showProject: projectSlug == nil,
                                       title: title(of:),
                                       onDiff: { diffTarget = DiffTarget(entry: entry, path: $0, title: title(of: $0)) },
                                       onOpen: onOpenPage,
                                       onUndo: { pendingUndo = entry })
                        }
                    }
                    .padding(Brand.spacing.content)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Brand.color.surface)
        .task(id: state.historyRevision) { await reload() }
        .sheet(item: $diffTarget) { target in
            DiffSheet(target: target)
        }
        .confirmationDialog(L("activity.undoConfirm"), isPresented: Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } })) {
            Button(L("activity.undo"), role: .destructive) {
                if let entry = pendingUndo { undo(entry, force: false) }
                pendingUndo = nil
            }
        } message: {
            Text(L("activity.undoMessage", pendingUndo?.changes.count ?? 0))
        }
        .alert(L("activity.conflictTitle"), isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })) {
            Button(L("activity.undoAnyway"), role: .destructive) {
                if let entry = conflict?.entry { undo(entry, force: true) }
                conflict = nil
            }
            Button(L("common.cancel"), role: .cancel) { conflict = nil }
        } message: {
            Text(L("activity.conflictMessage", conflict?.paths.map { title(of: $0) }.joined(separator: ", ") ?? ""))
        }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func title(of path: String) -> String { titles[path] ?? WikiGrouping.humanize(path) }

    /// Reads every history entry, its summary and the changed pages' titles from disk: off the main thread.
    private func reload() async {
        guard state.engineStarted else { return }
        let history = state.engine.history
        let vault = state.engine.vault
        let slug = projectSlug
        let (list, texts, names) = await Task.detached { () -> ([HistoryEntry], [String: String], [String: String]) in
            let list = history.entries()
                .filter { slug == nil || $0.projectSlug == slug }
                .sorted { $0.createdAt > $1.createdAt }
            var texts: [String: String] = [:]
            var names: [String: String] = [:]
            for entry in list {
                texts[entry.id] = history.summary(entryId: entry.id)
                for change in entry.changes where names[change.path] == nil && change.change != .deleted {
                    if FileManager.default.fileExists(atPath: vault.url(for: change.path).path) {
                        names[change.path] = vault.title(of: change.path)
                    }
                }
            }
            return (list, texts, names)
        }.value
        guard !Task.isCancelled, history === state.engine.history else { return }
        entries = list
        summaries = texts
        titles = names
        loaded = true
    }

    private func undo(_ entry: HistoryEntry, force: Bool) {
        do {
            try state.engine.undo(historyId: entry.id, force: force)
            state.bumpHistory()
        } catch HistoryError.conflict(let paths) {
            conflict = (entry, paths)
        } catch {
            self.error = (error as? EngineError)?.errorDescription ?? L("activity.undoFailed")
        }
        Task { await reload() }
    }
}

/// "Historial" as a sheet (project toolbar, Inicio): a header with "Revisar mi cerebro" and Cerrar over `ActivityView`.
struct ActivitySheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let projectSlug: String?
    var onOpenPage: (String) -> Void

    /// A review of this scope is queued or running (the engine's jobs): the button waits, its label never changes.
    private var reviewing: Bool {
        state.engine.jobs.contains { $0.kind == .lint && $0.projectSlug == projectSlug && ($0.status == .queued || $0.status == .running) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Brand.spacing.m) {
                Text(L("project.history"))
                    .font(Brand.title)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Brand.spacing.s)
                if reviewing { BrandLoader(size: 14) }
                Button {
                    state.engine.lint(projectSlug: projectSlug)
                } label: {
                    Label(L("chat.lint"), systemImage: "stethoscope")
                        .lineLimit(1)
                }
                .buttonStyle(.brandSecondary)
                .disabled(reviewing || !state.engineStarted)
                .help(reviewing ? L("chat.lintQueued") : L("chat.lintHelp"))
                Button(L("common.close")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Brand.spacing.content)
            .padding(.top, Brand.spacing.l)
            .padding(.bottom, Brand.spacing.s)
            ActivityView(projectSlug: projectSlug, onOpenPage: onOpenPage)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 520)
        .background(Brand.color.surface)
    }
}

struct DiffTarget: Identifiable {
    let entry: HistoryEntry
    let path: String
    var title: String? = nil
    var id: String { entry.id + "|" + path }
}

private struct HistoryRow: View {
    @Environment(AppState.self) private var state
    let entry: HistoryEntry
    let summary: String?
    let showProject: Bool
    var title: (String) -> String
    var onDiff: (String) -> Void
    var onOpen: (String) -> Void
    var onUndo: () -> Void

    @ViewState private var expanded = false

    var body: some View {
        BrandCard(padding: Brand.spacing.l) {
            VStack(alignment: .leading, spacing: Brand.spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: Brand.spacing.s) {
                    Image(systemName: symbol)
                        .foregroundStyle(Brand.color.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(Brand.callout)
                            .foregroundStyle(Brand.color.text)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text("\(Fmt.relative(entry.createdAt)) · \(L("activity.pagesChanged", entry.changes.count))")
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text2)
                                .lineLimit(1)
                            if showProject, let project = state.project(entry.projectSlug) {
                                BrandChip(text: "\(project.emoji) \(project.name)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.undone {
                        BrandChip(text: L("activity.undone"))
                    } else {
                        // Undo is one step away (⋯ or right-click), not a button on every card.
                        Menu {
                            Button(L("activity.undo"), role: .destructive, action: onUndo)
                        } label: {
                            BrandMoreLabel()
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help(L("project.more"))
                        .accessibilityLabel(Text(L("project.more")))
                    }
                }
                if let summary, !summary.isEmpty {
                    MarkdownText(markdown: summary)
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text2)
                        .padding(.leading, 26)
                }
                Button {
                    withAnimation(Brand.motion.animation(fast: true)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(Brand.font(10, .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(L("activity.showFiles"))
                    }
                    .font(Brand.font(12, .medium))
                    .foregroundStyle(Brand.color.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 26)
                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.changes, id: \.path) { change in
                            ChangeRow(change: change, title: title(change.path),
                                      onDiff: { onDiff(change.path) }, onOpen: { onOpen(change.path) })
                        }
                    }
                    .padding(.leading, 20)
                    .transition(.opacity)
                }
            }
        }
        .opacity(entry.undone ? 0.6 : 1)
        .contextMenu {
            if !entry.undone { Button(L("activity.undo"), role: .destructive, action: onUndo) }
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .ingest: "brain"
        case .lint: "stethoscope"
        case .saveAnswer: "bookmark"
        case .classify: "tray"
        case .transcribe: "waveform"
        case .reformat: "doc.richtext"
        case .makeTemplate: "rectangle.and.pencil.and.ellipsis"
        case .manualEdit: "checkmark.circle"
        case .fileDump: "tray.and.arrow.down"   // v0.7 (§17.3)
        }
    }
}

/// One changed page: click opens it (unless deleted); "Ver cambios" shows the diff.
private struct ChangeRow: View {
    let change: FileChange
    let title: String
    var onDiff: () -> Void
    var onOpen: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: Brand.spacing.s) {
            Image(systemName: icon)
                .font(Brand.font(12))
                .foregroundStyle(color)
                .frame(width: 16)
                .help(label)
            Text(title)
                .font(Brand.body)
                .foregroundStyle(change.change == .deleted ? Brand.color.text2 : Brand.color.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            Text(label)
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: Brand.spacing.s)
            Button(L("activity.viewChanges"), action: onDiff)
                .buttonStyle(.borderless)
                .font(Brand.font(12, .medium))
                .foregroundStyle(Brand.color.accent)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(hovering && change.change != .deleted ? Brand.color.cardAlt.opacity(0.55) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if change.change != .deleted { onOpen() } }
    }

    private var icon: String {
        switch change.change {
        case .added: "plus.circle"
        case .modified: "pencil.circle"
        case .deleted: "minus.circle"
        }
    }

    private var color: Color {
        switch change.change {
        case .added: Brand.color.success
        case .modified: Brand.color.text2
        case .deleted: Brand.color.danger
        }
    }

    private var label: String {
        switch change.change {
        case .added: L("activity.added")
        case .modified: L("activity.modified")
        case .deleted: L("activity.deleted")
        }
    }
}

struct DiffSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let target: DiffTarget

    @ViewState private var sideBySide = true
    @ViewState private var rows: [LineDiff.Row?] = []
    @ViewState private var lines: [LineDiff.Line] = []
    @ViewState private var width: CGFloat = 900

    /// Side by side needs room; below this the sheet shows one column.
    private var showsSideBySide: Bool { sideBySide && width >= 760 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Brand.spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title ?? WikiGrouping.humanize(target.path))
                        .font(Brand.section)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(target.entry.title)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if width >= 760 {
                    BrandSegmentedControl(options: [(true, L("diff.sideBySide")), (false, L("diff.unified"))],
                                          selection: $sideBySide)
                        .frame(width: 240)
                }
                Button(L("common.close")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Brand.spacing.content)
            .padding(.vertical, Brand.spacing.m)
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsSideBySide {
                        HStack(spacing: 0) {
                            Text(L("diff.before")).frame(maxWidth: .infinity, alignment: .leading)
                            Text(L("diff.after")).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(Brand.font(11, .semibold))
                        .foregroundStyle(Brand.color.text2)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            if let row {
                                HStack(alignment: .top, spacing: 1) {
                                    DiffCell(line: row.left, number: row.left?.oldNumber)
                                    DiffCell(line: row.right, number: row.right?.newNumber)
                                }
                            } else {
                                gap
                            }
                        }
                    } else {
                        ForEach(lines) { line in
                            DiffCell(line: line, number: line.newNumber ?? line.oldNumber, showSign: true)
                        }
                    }
                }
                .font(Brand.mono)
            }
            .background(Brand.color.card)
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 420, idealHeight: 520)
        .background(Brand.color.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { await load() }
    }

    private var gap: some View {
        Image(systemName: "ellipsis")
            .foregroundStyle(Brand.color.text3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(Brand.color.cardAlt.opacity(0.5))
    }

    /// Reading both versions and diffing a long page can take a while: off the main thread.
    private func load() async {
        let history = state.engine.history
        let entryId = target.entry.id, path = target.path
        let (allLines, allRows) = await Task.detached { () -> ([LineDiff.Line], [LineDiff.Row?]) in
            let (before, after) = history.diff(entryId: entryId, path: path)
            let lines = LineDiff.lines(before: before ?? "", after: after ?? "")
            return (lines, LineDiff.collapsed(LineDiff.rows(lines)))
        }.value
        lines = allLines
        rows = allRows
    }
}

private struct DiffCell: View {
    let line: LineDiff.Line?
    let number: Int?
    var showSign = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(Brand.color.text3)
                .frame(width: 36, alignment: .trailing)
            if showSign {
                Text(sign).foregroundStyle(Brand.color.text2).frame(width: 10)
            }
            Text(line?.text ?? "")
                .foregroundStyle(Brand.color.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var sign: String {
        switch line?.kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private var background: Color {
        switch line?.kind {
        case .added: Brand.color.accentSoft
        case .removed: Brand.color.recordSoft
        case .same: .clear
        case nil: Brand.color.cardAlt.opacity(0.5)
        }
    }
}
