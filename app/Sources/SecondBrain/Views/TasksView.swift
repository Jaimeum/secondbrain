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
    /// Tasks toggled moments ago keep the segment they were listed in (id → their done state before the click), so
    /// a mis-click stays visible — struck through — and can be undone right there. Released after a few seconds or
    /// when the list's segment/filter changes.
    private(set) var sticky: [String: Bool] = [:]
    /// The task just marked done, for the "Hecho · Deshacer" line (nil = no line).
    private(set) var justDone: TaskItem?
    var error: String?
    @ObservationIgnored private var stickyGeneration = 0

    func isDone(_ task: TaskItem) -> Bool {
        pending[task.id] ?? tasks.first { $0.id == task.id }?.done ?? task.done
    }

    /// The done state that decides which segment lists the task (the pre-click one while it is sticky). `task` is an
    /// element of `tasks` (no lookup: this runs for every task on every body pass).
    func listedDone(_ task: TaskItem) -> Bool { sticky[task.id] ?? pending[task.id] ?? task.done }

    func load(_ fetch: () async -> [TaskItem]) async {
        let list = await fetch()
        guard !Task.isCancelled else { return }
        // The 10 s poll usually brings the same list: don't invalidate every row for nothing.
        if list != tasks { tasks = list }
        if !loaded { loaded = true }
        // A reload that already reflects the change makes the optimistic value unnecessary.
        let stillPending = pending.filter { id, done in tasks.first { $0.id == id }?.done != done }
        if stillPending != pending { pending = stillPending }
    }

    func toggle(_ task: TaskItem, state: AppState) {
        let before = isDone(task)
        let target = !before
        pending[task.id] = target
        do {
            try state.engine.setTask(task, done: target)
            if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[i].done = target
                tasks[i].doneDate = target ? Date() : nil
            }
            pending[task.id] = nil
            keepInPlace(task, wasDone: before, nowDone: target)
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

    /// Lets every just-toggled row drop to its new segment (the segment or filter changed, or time ran out).
    func releaseSticky() {
        stickyGeneration += 1
        if !sticky.isEmpty { sticky = [:] }
        if justDone != nil { justDone = nil }
    }

    private func keepInPlace(_ task: TaskItem, wasDone: Bool, nowDone: Bool) {
        let original = sticky[task.id] ?? wasDone
        sticky[task.id] = original == nowDone ? nil : original   // toggled back: nothing to keep
        justDone = nowDone ? task : (justDone?.id == task.id ? nil : justDone)
        stickyGeneration += 1
        let generation = stickyGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.stickyGeneration == generation else { return }
            withAnimation(Brand.motion.fast) { self.releaseSticky() }
        }
    }
}

/// The global Pendientes filters (Proyecto ▾, Persona ▾, Buscar; CONTRACT §16.8), kept across launches in
/// UserDefaults, plus one-shot requests from other screens ("Ver todos (n)" in Inicio, a meeting's "Mis pendientes").
@MainActor @Observable
final class TaskFilterStore {
    static let shared = TaskFilterStore()

    enum Request: Equatable {
        /// Míos with no filters, so the list shows exactly what Inicio counted.
        case mine
        /// Míos of one source (a lowercased citation key: a meeting's raw file name), with no other filter.
        case origin(String)
    }

    var filter: TaskFilter { didSet { if filter != oldValue { save() } } }
    /// Taken by the global TasksView on appear / once its tasks are loaded.
    var request: Request?

    private static let defaultsKey = "tasks.filters.brain"
    /// Snapshots neither read nor write the saved filters (deterministic PNGs, the user's choice left alone).
    private static var persists: Bool { DebugSnapshots.directory == nil }

    private init() {
        let data = Self.persists ? UserDefaults.standard.data(forKey: Self.defaultsKey) : nil
        filter = data.flatMap { try? JSONDecoder().decode(TaskFilter.self, from: $0) } ?? TaskFilter()
    }

    private func save() {
        guard Self.persists, let data = try? JSONEncoder().encode(filter) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Opens Pendientes for a request (filters are reset by the list when it takes it).
    func open(_ request: Request, state: AppState) {
        self.request = request
        state.navigate(to: .sidebar(.tasks))
    }
}

/// "Pendientes" (CONTRACT §15.2, §16.8): one view for the sidebar item (`.brain`) and the project tab (`.project`).
/// Segments Míos · De otros · Sin dueño · Hechos, an "Origen" menu and Exportar; a click on a task previews its
/// meeting or email in a sheet without leaving the list.
struct TasksView: View {
    @Environment(AppState.self) private var state
    let scope: Scope
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
    /// A citation read in a sheet: only in the global Pendientes, which has no navigation stack (§16.4).
    @ViewState private var preview: VaultPageItem?
    @ViewState private var pickedSegment = false
    /// The task the router asked for (⌘K, a ficha, a project chip): its segment is shown, the list scrolls to it and
    /// the row is outlined for a moment.
    @ViewState private var highlightedTaskId: String?
    /// The row the list scrolls to (set once the task is found in the loaded list).
    @ViewState private var scrollTarget: String?
    /// The Persona menu (`.brain`): people pages and plain-text owners with at least one task, worked out on reload.
    @ViewState private var people: [TaskPerson] = []

    private var isAll: Bool { scope == .brain }
    private var filters: TaskFilterStore { .shared }
    /// Proyecto / Persona / Buscar only exist in the global list (inside a project the place is the filter).
    private var activeFilter: TaskFilter? { isAll && filters.filter.isActive ? filters.filter : nil }

    // MARK: Filtering

    /// The one segment that lists a task.
    private func segment(of task: TaskItem) -> Segment {
        if model.listedDone(task) { return .done }
        if task.isMine { return .mine }
        return task.ownerSlug != nil ? .theirs : .unowned
    }

    /// Everything the header and the list read, computed once per body pass (one source index, one pass per segment).
    private struct Snapshot {
        var filtered: [TaskItem] = []
        var counts: [Segment: Int] = [:]
        var cited: [CitedSource] = []
    }

    private func snapshot() -> Snapshot {
        let index = SourceLabels.shared.index(state)
        let allowed = filteredTasks()
        var base = allowed
        if let sourceFilter {
            base = base.filter { task in task.sourceKeys.contains { sourceGroup($0, index) == sourceFilter } }
        }
        var snap = Snapshot()
        var bySegment: [Segment: [TaskItem]] = [:]
        for task in base { bySegment[segment(of: task), default: []].append(task) }
        for s in Segment.allCases { snap.counts[s] = bySegment[s]?.count ?? 0 }
        let list = bySegment[segment] ?? []
        // Hechos lists every done task (LazyVStack), so its count and its rows always agree.
        snap.filtered = segment == .done ? list.sorted(by: TaskSort.doneFirst) : list.sorted(by: TaskSort.byDue)
        snap.cited = citedSources(allowed, index)
        return snap
    }

    /// The tasks Proyecto / Persona / Buscar let through (all of them inside a project or with no filter).
    private func filteredTasks() -> [TaskItem] {
        guard let filter = activeFilter else { return model.tasks }
        return model.tasks.filter { filter.matches($0, projectName: state.project($0.projectSlug)?.name) }
    }

    private func sourceGroup(_ key: String, _ index: SourceIndex) -> String {
        index.source(forKey: key)?.threadKey.map { "thread:" + $0 } ?? key
    }

    private struct CitedSource: Identifiable {
        let group: String
        let key: String
        let projectSlug: String
        let date: Date
        var id: String { group }
    }

    /// Sources cited by at least one task, newest first: one per meeting/document and ONE per email thread.
    private func citedSources(_ tasks: [TaskItem], _ index: SourceIndex) -> [CitedSource] {
        var seen: [String: CitedSource] = [:]
        for task in tasks {
            for key in task.sourceKeys {
                let group = sourceGroup(key, index)
                let date = index.source(forKey: key)?.timelineDate ?? .distantPast
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
        // Strictly this calendar week: next Monday is "Más adelante", even when it's 6 days away.
        if Calendar.current.isDate(due, equalTo: Date(), toGranularity: .weekOfYear) { return .week }
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

    private func makeGroups(_ list: [TaskItem]) -> [Group] {
        guard isAll, segment != .done else { return [Group(id: -1, title: nil, warn: false, tasks: list)] }
        let byBucket = Dictionary(grouping: list, by: bucket)
        return Bucket.allCases.compactMap { b in
            guard let tasks = byBucket[b], !tasks.isEmpty else { return nil }
            return Group(id: b.rawValue, title: title(b), warn: b == .overdue, tasks: tasks)
        }
    }

    // MARK: Body

    var body: some View {
        let snap = snapshot()
        reactions(list(snap), snap)
            .sheet(item: $export) { ExportSheet(request: $0) }
            .sheet(item: $preview) { item in PageSheet(path: item.path, onOpen: onOpenPage) }
            .alert(L("common.oops"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button(L("common.ok")) { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }

    private func list(_ snap: Snapshot) -> some View {
        VStack(spacing: 0) {
            header(snap)
                .padding(.horizontal, Brand.spacing.content)
                .padding(.vertical, Brand.spacing.m)
            if isAll {
                TaskFilterBar(people: people)
                    .padding(.horizontal, Brand.spacing.content)
                    .padding(.bottom, Brand.spacing.m)
            }
            content(snap)
        }
        .background(Brand.color.surface)
        .overlay(alignment: .bottom) { undoLine }
        .animation(Brand.motion.animation(fast: true), value: model.justDone?.id)
        .modifier(AllScopeTitle(isAll: isAll))
    }

    /// Loading, label resolution, and the reactions to the router and to filter changes.
    private func reactions(_ content: some View, _ snap: Snapshot) -> some View {
        content
        .task(id: state.tasksRevision) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await reload()
            }
        }
        // Re-resolved when the vault changes too (a page written or retitled after the first lookup).
        .task(id: [String(state.vaultRevision)] + snap.cited.map(\.key)) {
            let byProject = Dictionary(grouping: snap.cited, by: \.projectSlug)
            await withTaskGroup(of: Void.self) { group in
                for (slug, items) in byProject {
                    let keys = items.map(\.key)
                    group.addTask { @MainActor in await SourceLabels.shared.resolve(keys, projectSlug: slug, state: state) }
                }
            }
        }
        .onChange(of: snap.cited.map(\.group)) { _, groups in
            if let sourceFilter, !groups.contains(sourceFilter) { self.sourceFilter = nil }
        }
        .onChange(of: segment) { model.releaseSticky() }
        .onChange(of: sourceFilter) { model.releaseSticky() }
        .onChange(of: filters.filter) { model.releaseSticky() }
        .onAppear(perform: consumePendingTask)
        .onChange(of: state.pendingTaskId) { consumePendingTask() }
        // A highlight or a request can arrive before the list is loaded: `reload` applies it once the tasks are in.
        .onChange(of: highlightedTaskId) { revealHighlight() }
        .onChange(of: filters.request) { takeRequest() }
    }

    /// `AppState.navigate(to: .task(id))` selected this list (the sidebar's, or this project's tab).
    /// A task's citation (§16.4): inside a project, the project's stack (Contenido or a pushed ficha); the global
    /// Pendientes has no stack, so it reads the page in a sheet with "Abrir".
    private func openSource(_ path: String) {
        if scope.projectSlug != nil, let onOpenPage {
            onOpenPage(path)
        } else {
            preview = VaultPageItem(path: path)
        }
    }

    private func consumePendingTask() {
        guard let id = state.pendingTaskId else { return }
        if let slug = scope.projectSlug, Scope.projectSlug(ofPath: id) != slug { return }
        state.pendingTaskId = nil
        highlightedTaskId = id
    }

    /// Shows the highlighted task wherever it is: its segment, no Origen, and (global list) no filter that hides it;
    /// then scrolls to it and drops the outline after a moment.
    private func revealHighlight() {
        guard let id = highlightedTaskId, model.loaded else { return }
        guard let task = model.tasks.first(where: { $0.id == id }) else {
            highlightedTaskId = nil   // gone (rewritten by Claude meanwhile): nothing to point at
            return
        }
        pickedSegment = true
        segment = segment(of: task)
        sourceFilter = nil
        if isAll, filters.filter.isActive,
           !filters.filter.matches(task, projectName: state.project(task.projectSlug)?.name) {
            filters.filter = TaskFilter()
        }
        scrollTarget = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if highlightedTaskId == id {
                withAnimation(Brand.motion.animation()) { highlightedTaskId = nil }
            }
        }
    }

    /// Inicio's "Ver todos (n)" and a meeting's "Mis pendientes (n)": Míos, with exactly what they counted.
    private func takeRequest() {
        guard isAll, let request = filters.request, model.loaded else { return }
        filters.request = nil
        filters.filter = TaskFilter()
        pickedSegment = true
        segment = .mine
        switch request {
        case .mine:
            sourceFilter = nil
        case .origin(let key):
            let index = SourceLabels.shared.index(state)
            let task = model.tasks.first { $0.sourceKeys.contains { $0.lowercased() == key } }
            sourceFilter = task?.sourceKeys.first { $0.lowercased() == key }.map { sourceGroup($0, index) }
        }
    }

    /// Segments left; Origen + Exportar right. Folds to icon-only buttons, then to two lines.
    private func header(_ snap: Snapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Brand.spacing.m) {
                segments(snap)
                Spacer(minLength: Brand.spacing.m)
                originMenu(snap.cited, compact: false)
                exportButton(snap.filtered, compact: false)
            }
            HStack(spacing: Brand.spacing.s) {
                segments(snap)
                Spacer(minLength: Brand.spacing.s)
                originMenu(snap.cited, compact: true)
                exportButton(snap.filtered, compact: true)
            }
            VStack(alignment: .leading, spacing: Brand.spacing.s) {
                segments(snap)
                HStack(spacing: Brand.spacing.s) {
                    originMenu(snap.cited, compact: false)
                    exportButton(snap.filtered, compact: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func segments(_ snap: Snapshot) -> some View {
        TaskSegmentControl(
            items: Segment.allCases.map { s in (s, segmentTitle(s), snap.counts[s] ?? 0) },
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

    @ViewBuilder private func originMenu(_ sources: [CitedSource], compact: Bool) -> some View {
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
            BrandMenuChip(text: compact && selected == nil ? nil : (selected.map { label($0).title } ?? L("tasks.from")),
                          symbol: compact && selected == nil ? "line.3.horizontal.decrease" : nil,
                          active: selected != nil)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: selected == nil ? nil : 180)
        .fixedSize(horizontal: selected == nil, vertical: false)
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

    private func exportButton(_ filtered: [TaskItem], compact: Bool) -> some View {
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

    @ViewBuilder private func content(_ snap: Snapshot) -> some View {
        let filtered = snap.filtered
        let groups = makeGroups(filtered)
        if !model.loaded {
            BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty, activeFilter != nil {
            EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: L("tasks.emptyFilters"), message: "",
                           actionTitle: L("tasks.filter.clear")) { filters.filter = TaskFilter() }
        } else if filtered.isEmpty {
            EmptyStateView(symbol: segment == .done ? "checkmark.circle" : "checklist", title: emptyTitle,
                           message: model.tasks.isEmpty ? L("tasks.emptyMessage") : "")
        } else {
            ScrollViewReader { proxy in
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
                                    .foregroundStyle(Brand.color.text2)
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
                                    onOpen: openSource)
                                .overlay {
                                    // The task the router pointed at, lit for a moment: a soft `accentSoft` wash with a
                                    // `focusBorder` edge, never a dark outline.
                                    RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
                                        .fill(Brand.color.accentSoft)
                                        .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
                                            .strokeBorder(Brand.color.focusBorder, lineWidth: 1))
                                        .opacity(highlightedTaskId == task.id ? 1 : 0)
                                        .allowsHitTesting(false)
                                }
                                .id(task.id)
                        }
                    }
                }
                .padding(.horizontal, Brand.spacing.content - 10)
                .padding(.vertical, Brand.spacing.m)
            }
            // Room for the "Hecho · Deshacer" line so it never covers the last row.
            .contentMargins(.bottom, model.justDone == nil ? 0 : 44, for: .scrollContent)
            .animation(Brand.motion.fast, value: filtered.map(\.id))
            .onChange(of: scrollTarget, initial: true) { _, id in
                guard let id else { return }
                // After the segment switch has laid the row out.
                Task { @MainActor in
                    withAnimation(Brand.motion.animation()) { proxy.scrollTo(id, anchor: .center) }
                    scrollTarget = nil
                }
            }
            }
        }
    }

    /// "Hecho · Deshacer" for a few seconds after a task is checked (the row also stays put, struck through).
    @ViewBuilder private var undoLine: some View {
        if let task = model.justDone {
            HStack(spacing: Brand.spacing.s) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.color.success)
                Text(L("tasks.doneToast"))
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                Text(verbatim: "·").foregroundStyle(Brand.color.text2)
                Button(L("tasks.undo")) {
                    withAnimation(Brand.motion.fast) { model.toggle(task, state: state) }
                }
                .buttonStyle(.plain)
                .font(Brand.callout)
                .foregroundStyle(Brand.color.accent)
                .fixedSize()
            }
            .padding(.horizontal, Brand.spacing.m)
            .padding(.vertical, 8)
            .background(Capsule().fill(Brand.color.card))
            .overlay(Capsule().strokeBorder(Brand.color.lineSoft))
            .shadow(color: Brand.color.shadow, radius: 12, y: 4)
            .padding(.bottom, Brand.spacing.m)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let engine = state.engine, slug = scope.projectSlug
        await model.load { await engine.tasks(projectSlug: slug) }
        if isAll {
            let directory = await engine.taskPeopleDirectory(), tasks = model.tasks
            let found = await Task.detached { TaskPeople.people(in: tasks, directory: directory) }.value
            if found != people { people = found }
        }
        // First load: open on the first segment that has something (mine, then others', then no owner).
        if !pickedSegment {
            pickedSegment = true
            let open = filteredTasks().filter { !model.isDone($0) }
            let has: [Segment: Bool] = [
                .mine: open.contains(where: \.isMine),
                .theirs: open.contains { !$0.isMine && $0.ownerSlug != nil },
                .unowned: open.contains { !$0.isMine && $0.ownerSlug == nil },
            ]
            segment = initialSegment ?? [Segment.mine, .theirs, .unowned].first { has[$0] == true } ?? .mine
        }
        revealHighlight()
        takeRequest()
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

/// Global Pendientes only (§16.8): Proyecto ▾ (several at once), Persona ▾ ("Lo que le debo a…" / "Lo que me debe…")
/// and Buscar, kept in `TaskFilterStore`. The search field takes what's left; at narrow widths the menus go icon-only.
private struct TaskFilterBar: View {
    @Environment(AppState.self) private var state
    let people: [TaskPerson]

    private var store: TaskFilterStore { .shared }

    var body: some View {
        @Bindable var store = store
        HStack(spacing: Brand.spacing.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Brand.spacing.s) {
                    projectMenu(compact: false)
                    personMenu(compact: false)
                }
                HStack(spacing: Brand.spacing.s) {
                    projectMenu(compact: true)
                    personMenu(compact: true)
                }
            }
            .layoutPriority(1)
            searchField($store.filter.text)
                .frame(minWidth: 140, maxWidth: 280)
            Spacer(minLength: 0)
            if store.filter.isActive {
                Button(L("tasks.filter.clear")) {
                    withAnimation(Brand.motion.fast) { store.filter = TaskFilter() }
                }
                .buttonStyle(.plain)
                .font(Brand.callout)
                .foregroundStyle(Brand.color.accent)
                .lineLimit(1)
            }
        }
    }

    // MARK: Proyecto ▾

    private var projectTitle: String {
        let picked = store.filter.projects
        if picked.isEmpty { return L("tasks.filter.project") }
        if picked.count == 1, let slug = picked.first, let project = state.project(slug) {
            return "\(project.emoji) \(project.name)"
        }
        return L("tasks.filter.projects", picked.count)
    }

    private func projectMenu(compact: Bool) -> some View {
        let picked = store.filter.projects
        return Menu {
            Button {
                store.filter.projects = []
            } label: {
                if picked.isEmpty { Label(L("tasks.filter.allProjects"), systemImage: "checkmark") } else { Text(L("tasks.filter.allProjects")) }
            }
            Divider()
            ForEach(state.projects, id: \.slug) { project in
                let on = picked.contains(project.slug)
                Button {
                    if on { store.filter.projects.remove(project.slug) } else { store.filter.projects.insert(project.slug) }
                } label: {
                    if on { Label("\(project.emoji) \(project.name)", systemImage: "checkmark") } else { Text("\(project.emoji) \(project.name)") }
                }
            }
        } label: {
            menuLabel(projectTitle, symbol: "folder", compact: compact && picked.isEmpty, active: !picked.isEmpty)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()   // the title is capped (`menuLabel`), so the menu hugs it instead of stretching
        .help(L("tasks.filter.projectHelp"))
    }

    // MARK: Persona ▾

    private var personTitle: String {
        guard let person = store.filter.person else { return L("tasks.filter.person") }
        switch store.filter.relation {
        case .any: return person.name
        case .iOwe: return L("tasks.filter.iOweShort", person.name)
        case .owesMe: return L("tasks.filter.owesMeShort", person.name)
        }
    }

    private func personMenu(compact: Bool) -> some View {
        let picked = store.filter.person
        // The picked person stays in the menu even when none of the loaded tasks names them any more.
        let list = picked.map { p in people.contains { $0.key == p.key } ? people : [p] + people } ?? people
        return Menu {
            Button {
                store.filter.person = nil
                store.filter.relation = .any
            } label: {
                if picked == nil { Label(L("tasks.filter.anyone"), systemImage: "checkmark") } else { Text(L("tasks.filter.anyone")) }
            }
            Divider()
            if list.isEmpty {
                Text(L("tasks.filter.noPeople"))
            }
            ForEach(list, id: \.key) { person in
                Menu {
                    relationButton(person, .any, L("tasks.filter.with", person.name))
                    relationButton(person, .iOwe, L("tasks.filter.iOwe", person.name))
                    relationButton(person, .owesMe, L("tasks.filter.owesMe", person.name))
                } label: {
                    if picked?.key == person.key { Label(person.name, systemImage: "checkmark") } else { Text(person.name) }
                }
            }
        } label: {
            menuLabel(personTitle, symbol: "person", compact: compact && picked == nil, active: picked != nil)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()   // the title is capped (`menuLabel`), so the menu hugs it instead of stretching
        .help(L("tasks.filter.personHelp"))
    }

    private func relationButton(_ person: TaskPerson, _ relation: TaskRelation, _ title: String) -> some View {
        let on = store.filter.person?.key == person.key && store.filter.relation == relation
        return Button {
            store.filter.person = person
            store.filter.relation = relation
        } label: {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    /// A filter menu's chip (`BrandMenuChip`: symbol, title cut to a few words, faint chevron; `accentSoft` while the
    /// filter is on). Compact toolbars keep the symbol alone.
    private func menuLabel(_ title: String, symbol: String, compact: Bool, active: Bool) -> some View {
        BrandMenuChip(text: compact ? nil : (title.count > 26 ? String(title.prefix(25)) + "…" : title),
                      symbol: symbol, active: active)
    }

    // MARK: Buscar

    private func searchField(_ text: Binding<String>) -> some View {
        TaskSearchField(text: text)
    }
}

/// Buscar in the filter bar: `card` with a `lineSoft` edge at rest and the brand focus halo while typing (§15.1).
private struct TaskSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text3)
            TextField(L("tasks.filter.search"), text: $text)
                .textFieldStyle(.plain)
                .font(Brand.callout)
                .lineLimit(1)
                .focused($focused)
                .focusEffectDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.color.text3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("tasks.filter.clear")))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(shape.fill(Brand.color.card))
        .overlay(shape.strokeBorder(focused ? Brand.color.focusBorder : Brand.color.lineSoft))
        .brandFocusHalo(focused)
        .animation(Brand.motion.fast, value: focused)
    }
}

/// `.all` is a top-level screen with its own title; inside a project the project's header names it.
private struct AllScopeTitle: ViewModifier {
    let isAll: Bool
    func body(content: Content) -> some View {
        if isAll { content.navigationTitle(L("tasks.title")) } else { content }
    }
}

/// Brand segmented control with counts (same type scale and track as `BrandSegmentedControl`). Each segment reserves
/// the width of its title in the heavier (selected) weight plus a two-digit count, and centers what it shows inside,
/// so neither a selection change nor a count appearing, changing or reaching zero moves anything (CONTRACT §15.3).
private struct TaskSegmentControl<Value: Hashable>: View {
    let items: [(Value, String, Int)]
    @Binding var selection: Value

    private var countFont: Font { Brand.font(11, .medium) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title, count in
                let selected = value == selection
                Button {
                    withAnimation(Brand.motion.animation(fast: true)) { selection = value }
                } label: {
                    ZStack {
                        // Width reference: heaviest title + "99", never shown.
                        HStack(spacing: 5) {
                            Text(title).font(Brand.font(12, .semibold))
                            Text(verbatim: "99").font(countFont).monospacedDigit()
                        }
                        .hidden()
                        HStack(spacing: 5) {
                            Text(title)
                                .font(Brand.font(12, selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Brand.color.text : Brand.color.text2)
                            if count > 0 {
                                Text(count, format: .number)
                                    .font(countFont)
                                    .foregroundStyle(selected ? Brand.color.text : Brand.color.text2)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background {
                        if selected {
                            // A lifted `card` capsule, as in `BrandSegmentedControl` (the project tabs).
                            Capsule(style: .continuous)
                                .fill(Brand.color.card)
                                .overlay(Capsule(style: .continuous).strokeBorder(Brand.color.lineSoft))
                                .shadow(color: Brand.color.shadow.opacity(0.35), radius: 2, x: 0, y: 1)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(count > 0 ? "\(title), \(count)" : title))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        // The same faint capsule track as `BrandSegmentedControl`: a tonal shift, no outline (§15.1 calm surfaces).
        .background(Brand.color.hover, in: Capsule(style: .continuous))
        .fixedSize()
    }
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
    /// A click on the row does this instead of opening its source (the per-source sheet: show it in Pendientes).
    var onSelect: (() -> Void)? = nil

    @ViewState private var hovering = false

    private var overdue: Bool {
        guard !done, let due = task.due else { return false }
        return Fmt.daysFromToday(due) < 0
    }

    private var labels: SourceLabels { SourceLabels.shared }

    private func label(_ key: String) -> SourceLabel {
        labels.label(for: key, projectSlug: task.projectSlug, state: state)
    }

    var body: some View {
        // Computed once per pass (hover re-renders the row): cited keys, their labels, the page a click opens.
        let keys = chipKeys(SourceLabels.shared.index(state))
        let primaryPath = keys.lazy.compactMap { label($0).path }.first
        let canOpen = onSelect != nil || (onOpen != nil && primaryPath != nil)
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
                    chips(keys)
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
        // `hover`, not `accentSoft`: hover never looks like selection (it reads on the surface and inside a card).
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(hovering && canOpen ? Brand.color.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let onSelect { onSelect() } else if let path = primaryPath { onOpen?(path) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(onSelect != nil ? L("tasks.showInList") : L("tasks.openSource"))) {
            if let onSelect { onSelect() } else if canOpen, let path = primaryPath { onOpen?(path) }
        }
        .animation(Brand.motion.fast, value: hovering)
        // Re-resolved when the vault changes too, so a page written or retitled later updates the chip.
        .task(id: [String(state.vaultRevision)] + task.sourceKeys) {
            guard showSources || onOpen != nil, !task.sourceKeys.isEmpty else { return }
            await labels.resolve(task.sourceKeys, projectSlug: task.projectSlug, state: state)
        }
        .contextMenu {
            Button(done ? L("tasks.markUndone") : L("tasks.markDone"), action: onToggle)
            if let onSelect {
                Button(L("tasks.showInList"), action: onSelect)
            } else if canOpen, let path = primaryPath {
                Button(L("tasks.openSource")) { onOpen?(path) }
            }
            Button(L("chat.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.text, forType: .string)
            }
        }
    }

    @ViewBuilder private func chips(_ keys: [String]) -> some View {
        if showOwner {
            Chip(text: task.isMine ? L("tasks.me") : (task.ownerName ?? L("tasks.noOwner")),
                 tone: task.isMine ? .accent : .neutral, symbol: "person")
        }
        if showProject, let project = state.project(task.projectSlug) {
            // §16.8: the project's Pendientes tab, with this task outlined.
            Button {
                state.navigate(to: .task(task.id))
            } label: {
                Chip(text: "\(project.emoji) \(project.name)", maxWidth: 200)
            }
            .buttonStyle(.plain)
            .help(L("tasks.openProjectTasks"))
        }
        if let due = task.due {
            Chip(text: dueText(due), tone: dueTone(due), symbol: "calendar", strikethrough: done)
        }
        if done, let doneDate = task.doneDate {
            Chip(text: L("tasks.doneOn", Fmt.dayTime(doneDate, hasTime: false)), tone: .accent, symbol: "checkmark")
        }
        if showSources {
            ForEach(keys.prefix(2), id: \.self) { key in
                sourceChip(key)
            }
        }
    }

    private func dueTone(_ due: Date) -> Chip.Tone {
        if done { return .neutral }
        return Fmt.daysFromToday(due) <= 0 ? .warning : .neutral
    }

    private func dueText(_ due: Date) -> String {
        if done { return Fmt.day(due) }
        return "\(Fmt.day(due)) · \(Fmt.relativeDay(due))"
    }

    /// Cited sources newest first, without repeating an email thread (two messages of one thread → one chip).
    private func chipKeys(_ index: SourceIndex) -> [String] {
        var out: [String] = []
        var groups: [String: Int] = [:]
        for key in task.sourceKeys {
            let src = index.source(forKey: key)
            let group = src?.threadKey.map { "thread:" + $0 } ?? key
            if let i = groups[group] {
                if let s = src, let prev = index.source(forKey: out[i]), s.timelineDate > prev.timelineDate { out[i] = key }
            } else {
                groups[group] = out.count
                out.append(key)
            }
        }
        let dates = Dictionary(out.map { ($0, index.source(forKey: $0)?.timelineDate ?? .distantPast) }) { a, _ in a }
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
            // Not found: same readable chip with a "?" symbol; the tooltip says why it can't open.
            Chip(text: label.title, symbol: missing ? "questionmark.circle" : label.symbol, maxWidth: 240)
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
            .brandScrollEdgeFade(.bottom)
            BrandSheetFooter(horizontalPadding: Brand.spacing.xxl) {
                Spacer()
                Button(L("common.close")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
            }
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
                    Text(tasks.count, format: .number).font(Brand.callout).foregroundStyle(Brand.color.text2).monospacedDigit()
                }
            }
            .padding(.bottom, 4)
            if tasks.isEmpty {
                Text(L("srctasks.none")).font(Brand.body).foregroundStyle(Brand.color.text2)
            } else {
                ForEach(tasks) { task in
                    TaskRow(task: task, done: model.isDone(task), showOwner: !task.isMine,
                            onToggle: { model.toggle(task, state: state) }, onOpen: nil, showSources: false,
                            onSelect: {
                                // The project's Pendientes, with this task outlined (§16.8).
                                dismiss()
                                state.navigate(to: .task(task.id))
                            })
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
