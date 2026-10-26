import BrainCore
import SwiftUI

/// "Actividad": every change Claude made to the wiki, what it changed, and a way back.
struct ActivityView: View {
    @Environment(AppState.self) private var state
    let projectSlug: String?
    var onOpenPage: (String) -> Void

    @ViewState private var entries: [HistoryEntry] = []
    @ViewState private var summaries: [String: String] = [:]
    @ViewState private var diffTarget: DiffTarget?
    @ViewState private var pendingUndo: HistoryEntry?
    @ViewState private var conflict: (entry: HistoryEntry, paths: [String])?
    @ViewState private var error: String?

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: L("activity.emptyTitle"), message: L("activity.emptyMessage"))
            } else {
                List {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry,
                                   summary: summaries[entry.id],
                                   onDiff: { diffTarget = DiffTarget(entry: entry, path: $0) },
                                   onOpen: onOpenPage,
                                   onUndo: { pendingUndo = entry })
                    }
                }
                .listStyle(.inset)
            }
        }
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
            Text(L("activity.conflictMessage", conflict?.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") ?? ""))
        }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Reads every history entry and its summary from disk: off the main thread.
    private func reload() async {
        guard state.engineStarted else { return }
        let history = state.engine.history
        let slug = projectSlug
        let (loaded, texts) = await Task.detached { () -> ([HistoryEntry], [String: String]) in
            let list = history.entries()
                .filter { slug == nil || $0.projectSlug == slug }
                .sorted { $0.createdAt > $1.createdAt }
            var texts: [String: String] = [:]
            for entry in list { texts[entry.id] = history.summary(entryId: entry.id) }
            return (list, texts)
        }.value
        guard !Task.isCancelled, history === state.engine.history else { return }
        entries = loaded
        summaries = texts
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

struct DiffTarget: Identifiable {
    let entry: HistoryEntry
    let path: String
    var id: String { entry.id + "|" + path }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let summary: String?
    var onDiff: (String) -> Void
    var onOpen: (String) -> Void
    var onUndo: () -> Void

    @ViewState private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.body.weight(.semibold))
                    Text("\(Fmt.relative(entry.createdAt)) · \(L("activity.pagesChanged", entry.changes.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.undone {
                    Text(L("activity.undone"))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                } else {
                    Button(L("activity.undo"), action: onUndo).controlSize(.small)
                }
            }
            if let summary, !summary.isEmpty {
                MarkdownText(markdown: summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.changes, id: \.path) { change in
                        ChangeRow(change: change, onDiff: { onDiff(change.path) }, onOpen: { onOpen(change.path) })
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(L("activity.showFiles")).font(.callout)
            }
        }
        .padding(.vertical, 8)
        .opacity(entry.undone ? 0.6 : 1)
    }

    private var symbol: String {
        switch entry.kind {
        case .ingest: "brain"
        case .lint: "stethoscope"
        case .saveAnswer: "bookmark"
        case .classify: "tray"
        case .transcribe: "waveform"
        }
    }
}

private struct ChangeRow: View {
    let change: FileChange
    var onDiff: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(((change.path as NSString).lastPathComponent as NSString).deletingPathExtension)
                .lineLimit(1)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L("activity.viewChanges"), action: onDiff).buttonStyle(.borderless).controlSize(.small)
            if change.change != .deleted {
                Button(L("activity.open"), action: onOpen).buttonStyle(.borderless).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch change.change {
        case .added: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        }
    }

    private var color: Color {
        switch change.change {
        case .added: .green
        case .modified: .blue
        case .deleted: .red
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(((target.path as NSString).lastPathComponent as NSString).deletingPathExtension).font(.headline)
                    Text(target.entry.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $sideBySide) {
                    Text(L("diff.sideBySide")).tag(true)
                    Text(L("diff.unified")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sideBySide {
                        HStack(spacing: 0) {
                            Text(L("diff.before")).frame(maxWidth: .infinity, alignment: .leading)
                            Text(L("diff.after")).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 560, idealHeight: 720)
        .task { await load() }
    }

    private var gap: some View {
        Text("⋯").foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 3)
            .background(Color.primary.opacity(0.03))
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
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
            if showSign {
                Text(sign).foregroundStyle(.secondary).frame(width: 10)
            }
            Text(line?.text ?? "")
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
        case .added: .green.opacity(0.14)
        case .removed: .red.opacity(0.13)
        case .same: .clear
        case nil: .primary.opacity(0.03)
        }
    }
}
