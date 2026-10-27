import AppKit
import BrainCore
import SwiftUI

/// Shared loading + optimistic toggling for every task list (Pendientes, the project tab, the per-source sheet).
@MainActor @Observable
final class TaskListModel {
    private(set) var tasks: [TaskItem] = []
    private(set) var loaded = false
    /// Checkbox state shown before the engine confirms (id → done).
    private(set) var pending: [String: Bool] = [:]
    var error: String?

    func isDone(_ task: TaskItem) -> Bool {
        pending[task.id] ?? tasks.first { $0.id == task.id }?.done ?? task.done
    }

    func load(_ fetch: () async -> [TaskItem]) async {
        let list = await fetch()
        guard !Task.isCancelled else { return }
        tasks = list
        loaded = true
        // A reload that already reflects the change makes the optimistic value unnecessary.
        pending = pending.filter { id, done in tasks.first { $0.id == id }?.done != done }
    }

    func toggle(_ task: TaskItem, state: AppState) {
        let target = !isDone(task)
        pending[task.id] = target
        do {
            try state.engine.setTask(task, done: target)
            if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[i].done = target
                tasks[i].doneDate = target ? Date() : nil
            }
            pending[task.id] = nil
            state.refreshTasks()
        } catch {
            // Back to how it was, with a human explanation.
            withAnimation(Brand.motion.fast) { pending[task.id] = nil }
            if let engine = error as? EngineError, case .busy = engine {
                self.error = L("tasks.busy")
            } else {
                self.error = FriendlyError.message(error)
            }
        }
    }
}

/// Which tasks a `TasksView` lists: every project (sidebar "Pendientes") or one project (its tab).
enum TaskScope: Hashable {
    case all
    case project(String)

    var projectSlug: String? {
        if case .project(let slug) = self { return slug }
        return nil
    }
}

/// "Pendientes" (CONTRACT §15.2): one view for the sidebar item (`.all`) and the project tab (`.project`).
/// Segments Míos · De otros · Sin dueño · Hechos, an "Origen" menu and Exportar; a click on a task previews its
/// meeting or email in a sheet without leaving the list.
struct TasksView: View {
    @Environment(AppState.self) private var state
    let scope: TaskScope
    /// "Abrir en el proyecto" from the preview (nil = `AppState.openProjectPage`).
    var onOpenPage: ((String) -> Void)? = nil
    /// Opens on this segment (nil = the first one with something: mine, then others', then no owner).
    var initialSegment: Segment? = nil

    enum Segment: Hashable, CaseIterable { case mine, theirs, unowned, done }

    @ViewState private var model = TaskListModel()
    @ViewState private var segment: Segment = .mine
    /// A source group ("thread:<key>" for an email thread, else the citation key).
    @ViewState private var sourceFilter: String?
    @ViewState private var export: ExportRequest?
    @ViewState private var preview: PagePreviewItem?
    @ViewState private var pickedSegment = false

    private var isAll: Bool { scope == .all }

    // MARK: Filtering

    private func matches(_ task: TaskItem, _ s: Segment) -> Bool {
        let done = model.isDone(task)
        switch s {
        case .mine: return !done && task.isMine
        case .theirs: return !done && !task.isMine && task.ownerSlug != nil
        case .unowned: return !done && !task.isMine && task.ownerSlug == nil
        case .done: return done
        }
    }

    private var sourceFiltered: [TaskItem] {
        guard let sourceFilter else { return model.tasks }
        return model.tasks.filter { task in task.sourceKeys.contains { sourceGroup($0) == sourceFilter } }
    }

    private var filtered: [TaskItem] {
        let list = sourceFiltered.filter { matches($0, segment) }
        if segment == .done {
            let sorted = list.sorted(by: TaskSort.doneFirst)
            return isAll ? Array(sorted.prefix(50)) : sorted
        }
        return list.sorted(by: TaskSort.byDue)
    }

    private func count(_ s: Segment) -> Int { sourceFiltered.filter { matches($0, s) }.count }

    private func sourceGroup(_ key: String) -> String {
        state.source(forKey: key)?.threadKey.map { "thread:" + $0 } ?? key
    }

    private struct CitedSource: Identifiable {
        let group: String
        let key: String
        let projectSlug: String
        let date: Date
        var id: String { group }
    }

    /// Sources cited by at least one task, newest first: one per meeting/document and ONE per email thread.
    private var citedSources: [CitedSource] {
        var seen: [String: CitedSource] = [:]
        for task in model.tasks {
            for key in task.sourceKeys {
                let group = sourceGroup(key)
                let date = state.source(forKey: key)?.timelineDate ?? .distantPast
                if let existing = seen[group], existing.date >= date { continue }
                seen[group] = CitedSource(group: group, key: key, projectSlug: task.projectSlug, date: date)
            }
        }
        return seen.values.sorted { $0.date == $1.date ? $0.group < $1.group : $0.date > $1.date }
    }

    // MARK: Grouping (.all: by when it's due)

    private enum Bucket: Int, CaseIterable { case overdue, today, week, later, undated }

    private func bucket(_ task: TaskItem) -> Bucket {
        guard let due = task.due else { return .undated }
        let days = Fmt.daysFromToday(due)
        if days < 0 { return .overdue }
        if days == 0 { return .today }
        if days <= 7 || Calendar.current.isDate(due, equalTo: Date(), toGranularity: .weekOfYear) { return .week }
        return .later
    }

    private func title(_ b: Bucket) -> String {
        switch b {
        case .overdue: L("mytasks.overdue")
        case .today: L("mytasks.today")
        case .week: L("mytasks.week")
        case .later: L("mytasks.later")
        case .undated: L("mytasks.undated")
        }
    }

    private struct Group: Identifiable {
        let id: Int
        let title: String?
        let warn: Bool
        let tasks: [TaskItem]
    }

    private var groups: [Group] {
        let list = filtered
        guard isAll, segment != .done else { return [Group(id: -1, title: nil, warn: false, tasks: list)] }
        let byBucket = Dictionary(grouping: list, by: bucket)
        return Bucket.allCases.compactMap { b in
            guard let tasks = byBucket[b], !tasks.isEmpty else { return nil }
            return Group(id: b.rawValue, title: title(b), warn: b == .overdue, tasks: tasks)
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Brand.spacing.content)
                .padding(.vertical, Brand.spacing.m)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            content
        }
        .background(Brand.color.surface)
        .modifier(AllScopeTitle(isAll: isAll))
        .task(id: state.tasksRevision) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await reload()
            }
        }
        .task(id: citedSources.map(\.key)) {
            let byProject = Dictionary(grouping: citedSources, by: \.projectSlug)
            await withTaskGroup(of: Void.self) { group in
                for (slug, items) in byProject {
                    let keys = items.map(\.key)
                    group.addTask { @MainActor in await SourceLabels.shared.resolve(keys, projectSlug: slug, state: state) }
                }
            }
        }
        .onChange(of: citedSources.map(\.group)) { _, groups in
            if let sourceFilter, !groups.contains(sourceFilter) { self.sourceFilter = nil }
        }
        .sheet(item: $export) { ExportSheet(request: $0) }
        .sheet(item: $preview) { item in PagePreviewSheet(path: item.path, onOpenInProject: onOpenPage) }
        .alert(L("common.oops"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("common.ok")) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    /// Segments left; Origen + Exportar right. Folds to icon-only buttons, then to two lines.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Brand.spacing.m) {
                segments
                Spacer(minLength: Brand.spacing.m)
                originMenu(compact: false)
                exportButton(compact: false)
            }
            HStack(spacing: Brand.spacing.s) {
                segments
                Spacer(minLength: Brand.spacing.s)
                originMenu(compact: true)
                exportButton(compact: true)
            }
            VStack(alignment: .leading, spacing: Brand.spacing.s) {
                segments
                HStack(spacing: Brand.spacing.s) {
                    originMenu(compact: false)
                    exportButton(compact: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var segments: some View {
        TaskSegmentControl(
            items: Segment.allCases.map { s in (s, segmentTitle(s), count(s)) },
            selection: $segment)
    }

    private func segmentTitle(_ s: Segment) -> String {
        switch s {
        case .mine: L("tasks.segment.mine")
        case .theirs: L("tasks.segment.theirs")
        case .unowned: L("tasks.segment.unowned")
        case .done: L("tasks.segment.done")
        }
    }

    private func label(_ item: CitedSource) -> SourceLabel {
        SourceLabels.shared.label(for: item.key, projectSlug: item.projectSlug, state: state)
    }

    @ViewBuilder private func originMenu(compact: Bool) -> some View {
        let sources = citedSources
        let selected = sources.first { $0.group == sourceFilter }
        Menu {
            Button {
                sourceFilter = nil
            } label: {
                if sourceFilter == nil { Label(L("tasks.allSources"), systemImage: "checkmark") } else { Text(L("tasks.allSources")) }
            }
            if !sources.isEmpty { Divider() }
            ForEach(sources) { item in
                let label = label(item)
                Button {
                    sourceFilter = item.group
                } label: {
                    Label(menuTitle(label, item), systemImage: item.group == sourceFilter ? "checkmark" : label.symbol)
                }
            }
        } label: {
            if compact && selected == nil {
                Image(systemName: "line.3.horizontal.decrease.circle")
            } else {
                Text(selected.map { label($0).title } ?? L("tasks.from"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact && selected == nil ? .hidden : .visible)
        .frame(maxWidth: selected == nil ? nil : 180)
        .fixedSize(horizontal: selected == nil, vertical: false)
        .foregroundStyle(selected == nil ? Brand.color.text2 : Brand.color.accent)
        .disabled(sources.isEmpty)
        .help(L("tasks.fromHelp"))
    }

    /// "Comité de la alianza · 26 oct" in the menu (a project emoji in front with `.all`).
    private func menuTitle(_ label: SourceLabel, _ item: CitedSource) -> String {
        var text = label.title
        if isAll, let project = state.project(item.projectSlug) { text = "\(project.emoji) \(text)" }
        if item.date != .distantPast { text += " · " + Fmt.dayTime(item.date, hasTime: false) }
        return text
    }

    private func exportButton(compact: Bool) -> some View {
        Button {
            export = ExportRequest(target: .tasks(filtered, title: exportTitle))
        } label: {
            if compact {
                Image(systemName: "square.and.arrow.up")
            } else {
                Label(L("export.button"), systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(.brandSecondary)
        .fixedSize()
        .disabled(filtered.isEmpty)
        .help(L("export.button"))
    }

    @ViewBuilder private var content: some View {
        if !model.loaded {
            BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            EmptyStateView(symbol: segment == .done ? "checkmark.circle" : "checklist", title: emptyTitle,
                           message: model.tasks.isEmpty ? L("tasks.emptyMessage") : "")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        if let title = group.title {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(title)
                                    .font(Brand.callout)
                                    .foregroundStyle(group.warn ? Brand.color.warning : Brand.color.text)
                                Text(group.tasks.count, format: .number)
                                    .font(Brand.caption)
                                    .foregroundStyle(Brand.color.text3)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, group.id == groups.first?.id ? 4 : Brand.spacing.l)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.tasks) { task in
                            TaskRow(task: task, done: model.isDone(task), showOwner: segment != .mine,
                                    showProject: isAll,
                                    onToggle: { model.toggle(task, state: state) },
                                    onOpen: { preview = PagePreviewItem(path: $0) })
                        }
                    }
                }
                .padding(.horizontal, Brand.spacing.content - 10)
                .padding(.vertical, Brand.spacing.m)
            }
            .animation(Brand.motion.fast, value: filtered.map(\.id))
        }
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let engine = state.engine, slug = scope.projectSlug
        await model.load { await engine.tasks(projectSlug: slug) }
        // First load: open on the first segment that has something (mine, then others', then no owner).
        if !pickedSegment {
            pickedSegment = true
            segment = initialSegment ?? [Segment.mine, .theirs, .unowned].first { count($0) > 0 } ?? .mine
        }
    }

    private var emptyTitle: String {
        if sourceFilter != nil, !model.tasks.isEmpty { return L("tasks.emptyFiltered") }
        switch segment {
        case .mine: return isAll ? L("mytasks.emptyTitle") : L("tasks.emptyMine")
        case .theirs: return L("tasks.emptyTheirs")
        case .unowned: return L("tasks.emptyUnowned")
        case .done: return L("tasks.emptyDone")
        }
    }

    private var exportTitle: String {
        let prefix = scope.projectSlug.flatMap { state.project($0)?.name } ?? L("tasks.title")
        return "\(prefix) — \(segmentTitle(segment))"
    }
}

/// `.all` is a top-level screen with its own title; inside a project the project's header names it.
private struct AllScopeTitle: ViewModifier {
    let isAll: Bool
    func body(content: Content) -> some View {
        if isAll { content.navigationTitle(L("tasks.title")) } else { content }
    }
}

/// Brand segmented control whose counts sit in a fixed-width slot, so a count appearing, growing or disappearing never
/// changes the control's width (CONTRACT §15.3).
private struct TaskSegmentControl<Value: Hashable>: View {
    let items: [(Value, String, Int)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title, count in
                let selected = value == selection
                Button {
                    withAnimation(Brand.motion.fast) { selection = value }
                } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(selected ? Brand.callout : Brand.body)
                            .foregroundStyle(selected ? Brand.color.text : Brand.color.text2)
                            .lineLimit(1)
                        Text(count > 0 ? "\(min(count, 999))" : "")
                            .font(Brand.font(11, .medium))
                            .foregroundStyle(selected ? Brand.color.text2 : Brand.color.text3)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: 20, alignment: .leading)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(height: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Brand.radius.control - 2, style: .continuous)
                                .fill(Brand.color.card)
                                .overlay(RoundedRectangle(cornerRadius: Brand.radius.control - 2, style: .continuous)
                                    .strokeBorder(Brand.color.line, lineWidth: 1))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(count > 0 ? "\(title), \(count)" : title))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).fill(Brand.color.cardAlt))
        .fixedSize()
    }
}

/// Sidebar "Pendientes" (kept for callers of the v0.2 name).
struct MyTasksView: View {
    var body: some View { TasksView(scope: .all) }
}

/// Project tab "Pendientes" (kept for callers of the v0.2 name).
struct ProjectTasksView: View {
    let project: Project
    var onOpen: (String) -> Void

    var body: some View { TasksView(scope: .project(project.slug), onOpenPage: onOpen) }
}

enum TaskSort {
    /// Overdue and soonest first; no date at the end.
    static func byDue(_ a: TaskItem, _ b: TaskItem) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?): return x == y ? a.text < b.text : x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.text.localizedCaseInsensitiveCompare(b.text) == .orderedAscending
        }
    }

    static func doneFirst(_ a: TaskItem, _ b: TaskItem) -> Bool {
        (a.doneDate ?? .distantPast) > (b.doneDate ?? .distantPast)
    }
}

/// One task: checkbox, text, and wrapping chips (owner, project, due date, sources by title). A click on the row
/// opens its newest source through `onOpen` (a vault path); the chips open that source.
struct TaskRow: View {
    @Environment(AppState.self) private var state
    let task: TaskItem
    let done: Bool
    var showOwner = true
    var showProject = false
    var onToggle: () -> Void
    var onOpen: ((String) -> Void)?
    /// Source chips (off in the per-source sheet, where they'd repeat the sheet's own source).
    var showSources = true

    @ViewState private var hovering = false

    private var overdue: Bool {
        guard !done, let due = task.due else { return false }
        return Fmt.daysFromToday(due) < 0
    }

    private var labels: SourceLabels { SourceLabels.shared }

    private func label(_ key: String) -> SourceLabel {
        labels.label(for: key, projectSlug: task.projectSlug, state: state)
    }

    /// Path of the newest cited source, when it has a page.
    private var primaryPath: String? {
        chipKeys.lazy.compactMap { label($0).path }.first
    }

    private var canOpen: Bool { onOpen != nil && primaryPath != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(Brand.font(16))
                    .foregroundStyle(done ? Brand.color.success : overdue ? Brand.color.warning : Brand.color.text3)
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(.plain)
            .help(done ? L("tasks.markUndone") : L("tasks.markDone"))

            VStack(alignment: .leading, spacing: 6) {
                Text(task.text)
                    .font(Brand.body)
                    .foregroundStyle(done ? Brand.color.text3 : Brand.color.text)
                    .strikethrough(done, color: Brand.color.text3)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                WrapLayout(spacing: 6, lineSpacing: 6) {
                    chips
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text3)
                .opacity(hovering && canOpen ? 1 : 0)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(hovering && canOpen ? Brand.color.card : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if let path = primaryPath { onOpen?(path) } }
        .animation(Brand.motion.fast, value: hovering)
        .task(id: task.sourceKeys) {
            guard showSources || onOpen != nil, !task.sourceKeys.isEmpty else { return }
            await labels.resolve(task.sourceKeys, projectSlug: task.projectSlug, state: state)
        }
        .contextMenu {
            Button(done ? L("tasks.markUndone") : L("tasks.markDone"), action: onToggle)
            if canOpen, let path = primaryPath {
                Button(L("tasks.openSource")) { onOpen?(path) }
            }
            Button(L("chat.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.text, forType: .string)
            }
        }
    }

    @ViewBuilder private var chips: some View {
        if showOwner {
            Chip(text: task.isMine ? L("tasks.me") : (task.ownerName ?? L("tasks.noOwner")),
                 tint: task.isMine ? Brand.color.accent : nil, symbol: "person")
        }
        if showProject, let project = state.project(task.projectSlug) {
            Chip(text: "\(project.emoji) \(project.name)", maxWidth: 200)
        }
        if let due = task.due {
            Chip(text: dueText(due), tint: dueTint(due), symbol: "calendar", strikethrough: done)
        }
        if done, let doneDate = task.doneDate {
            Chip(text: L("tasks.doneOn", Fmt.dayTime(doneDate, hasTime: false)), tint: Brand.color.success, symbol: "checkmark")
        }
        if showSources {
            ForEach(chipKeys.prefix(2), id: \.self) { key in
                sourceChip(key)
            }
        }
    }

    private func dueTint(_ due: Date) -> Color? {
        if done { return Brand.color.text3 }
        return Fmt.daysFromToday(due) <= 0 ? Brand.color.warning : nil
    }

    private func dueText(_ due: Date) -> String {
        if done { return Fmt.day(due) }
        return "\(Fmt.day(due)) · \(Fmt.relativeDay(due))"
    }

    /// Cited sources newest first, without repeating an email thread (two messages of one thread → one chip).
    private var chipKeys: [String] {
        var out: [String] = []
        var groups: [String: Int] = [:]
        for key in task.sourceKeys {
            let src = state.source(forKey: key)
            let group = src?.threadKey.map { "thread:" + $0 } ?? key
            if let i = groups[group] {
                if let s = src, let prev = state.source(forKey: out[i]), s.timelineDate > prev.timelineDate { out[i] = key }
            } else {
                groups[group] = out.count
                out.append(key)
            }
        }
        let dates = Dictionary(out.map { ($0, state.source(forKey: $0)?.timelineDate ?? .distantPast) }) { a, _ in a }
        return out.enumerated().sorted { a, b in
            let da = dates[a.element] ?? .distantPast, db = dates[b.element] ?? .distantPast
            return da == db ? a.offset < b.offset : da > db
        }.map(\.element)
    }

    @ViewBuilder private func sourceChip(_ key: String) -> some View {
        let label = label(key)
        let missing = label.resolved && label.path == nil
        Button {
            if let path = label.path { onOpen?(path) }
        } label: {
            Chip(text: label.title, tint: missing ? Brand.color.text3 : nil, symbol: label.symbol, maxWidth: 240)
        }
        .buttonStyle(.plain)
        .help(missing ? L("tasks.sourceMissing") : label.help)
        .disabled(onOpen == nil || label.path == nil)
    }
}

/// "Pendientes y acuerdos" of one meeting or email: its tasks (mine / others') and the page's `## Acuerdos`.
struct SourceTasksSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let source: SourceRecord

    @ViewState private var model = TaskListModel()
    @ViewState private var agreements: String?
    @ViewState private var export: ExportRequest?

    private var mine: [TaskItem] { model.tasks.filter(\.isMine).sorted(by: TaskSort.byDue) }
    private var theirs: [TaskItem] { model.tasks.filter { !$0.isMine }.sorted(by: TaskSort.byDue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Brand.spacing.m) {
                SheetTitleBlock(title: L("srctasks.title"), subtitle: "\(source.title) · \(source.datesLine)", symbol: source.symbol)
                    .help(source.datesHelp)
                Button {
                    export = ExportRequest(target: .tasks(model.tasks, title: source.title))
                } label: {
                    Label(L("export.button"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.brandSecondary)
                .fixedSize()
                .disabled(model.tasks.isEmpty)
            }
            .padding(Brand.spacing.xxl)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.spacing.xl) {
                    if !model.loaded {
                        BrandLoader(size: 24).frame(maxWidth: .infinity)
                    } else {
                        group(L("srctasks.mine"), mine)
                        group(L("srctasks.theirs"), theirs)
                    }
                    VStack(alignment: .leading, spacing: Brand.spacing.s) {
                        Text(L("srctasks.agreements")).font(Brand.section).foregroundStyle(Brand.color.text)
                        if let agreements {
                            MarkdownText(markdown: agreements).font(Brand.body).foregroundStyle(Brand.color.text)
                        } else {
                            Text(source.status == .done ? L("srctasks.noAgreements") : L("srctasks.notYet"))
                                .font(Brand.body).foregroundStyle(Brand.color.text2)
                        }
                    }
                }
                .padding(Brand.spacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            HStack {
                Spacer()
                Button(L("common.close")) { dismiss() }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Brand.spacing.xxl)
            .padding(.vertical, Brand.spacing.m)
        }
        .background(Brand.color.surface)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 400, idealHeight: 520)
        .task(id: state.tasksRevision) { await reload() }
        .sheet(item: $export) { ExportSheet(request: $0) }
        .alert(L("common.oops"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("common.ok")) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder private func group(_ title: String, _ tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(Brand.section).foregroundStyle(Brand.color.text)
                if !tasks.isEmpty {
                    Text(tasks.count, format: .number).font(Brand.callout).foregroundStyle(Brand.color.text3).monospacedDigit()
                }
            }
            .padding(.bottom, 4)
            if tasks.isEmpty {
                Text(L("srctasks.none")).font(Brand.body).foregroundStyle(Brand.color.text2)
            } else {
                ForEach(tasks) { task in
                    TaskRow(task: task, done: model.isDone(task), showOwner: !task.isMine,
                            onToggle: { model.toggle(task, state: state) }, onOpen: nil, showSources: false)
                        .padding(.horizontal, -10)
                }
            }
        }
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let engine = state.engine, id = source.id
        await model.load { await engine.tasks(forSourceId: id) }
        let vault = engine.vault, src = source
        agreements = await Task.detached {
            guard let page = SourcePages.summaryPage(for: src, vault: vault),
                  let text = try? vault.read(page) else { return nil as String? }
            return SourcePages.agreementsSection(of: text)
        }.value
    }
}
