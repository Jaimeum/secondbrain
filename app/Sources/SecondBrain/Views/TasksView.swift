import AppKit
import BrainCore
import SwiftUI

/// Shared loading + optimistic toggling for every task list (project tab, "Mis pendientes", per-source sheet).
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
            withAnimation { pending[task.id] = nil }
            if let engine = error as? EngineError, case .busy = engine {
                self.error = L("tasks.busy")
            } else {
                self.error = FriendlyError.message(error)
            }
        }
    }
}

/// Project tab "Pendientes": mine / others' / no owner / done, with a filter by source.
struct ProjectTasksView: View {
    @Environment(AppState.self) private var state
    let project: Project
    var onOpen: (String) -> Void

    enum Section: Hashable { case mine, theirs, unowned, done }

    @ViewState private var model = TaskListModel()
    @ViewState private var section: Section = .mine
    @ViewState private var sourceFilter: String?
    @ViewState private var export: ExportRequest?
    @ViewState private var pickedSection = false

    private var filtered: [TaskItem] {
        model.tasks.filter { task in
            guard sourceFilter == nil || task.sourceKeys.contains(where: { sourceGroup($0) == sourceFilter }) else { return false }
            let done = model.isDone(task)
            switch section {
            case .mine: return !done && task.isMine
            case .theirs: return !done && !task.isMine && task.ownerSlug != nil
            case .unowned: return !done && !task.isMine && task.ownerSlug == nil
            case .done: return done
            }
        }
        .sorted(by: section == .done ? TaskSort.doneFirst : TaskSort.byDue)
    }

    private func count(_ s: Section) -> Int {
        model.tasks.filter { task in
            let done = model.isDone(task)
            switch s {
            case .mine: return !done && task.isMine
            case .theirs: return !done && !task.isMine && task.ownerSlug != nil
            case .unowned: return !done && !task.isMine && task.ownerSlug == nil
            case .done: return done
            }
        }.count
    }

    /// Sources cited by at least one task, newest event first.
    /// One entry per meeting/document, and ONE per email thread (its messages share the thread's title).
    private var citedSources: [(key: String, source: SourceRecord?)] {
        var seen: [String: SourceRecord?] = [:]
        for key in model.tasks.flatMap(\.sourceKeys) {
            let group = sourceGroup(key)
            let src = state.source(forKey: key)
            if let existing = seen[group], let e = existing, let s = src, e.timelineDate >= s.timelineDate { continue }
            seen[group] = src
        }
        return seen.map { ($0.key, $0.value) }
            .sorted { ($0.source?.timelineDate ?? .distantPast) > ($1.source?.timelineDate ?? .distantPast) }
    }

    private func sourceGroup(_ key: String) -> String {
        state.source(forKey: key)?.threadKey.map { "thread:" + $0 } ?? key
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $section) {
                    Text(L("tasks.mine") + badge(count(.mine))).tag(Section.mine)
                    Text(L("tasks.theirs") + badge(count(.theirs))).tag(Section.theirs)
                    Text(L("tasks.unowned") + badge(count(.unowned))).tag(Section.unowned)
                    Text(L("tasks.done") + badge(count(.done))).tag(Section.done)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if !citedSources.isEmpty {
                    Picker(L("tasks.from"), selection: $sourceFilter) {
                        Text(L("tasks.allSources")).tag(String?.none)
                        Divider()
                        ForEach(citedSources, id: \.key) { item in
                            Text(item.source.map { "\($0.emoji) \($0.title)" } ?? item.key).tag(Optional(item.key))
                        }
                    }
                    .frame(maxWidth: 260)
                }
                Button {
                    export = ExportRequest(target: .tasks(filtered, title: exportTitle))
                } label: {
                    Label(L("export.button"), systemImage: "square.and.arrow.up")
                }
                .disabled(filtered.isEmpty)
            }
            .padding(12)
            Divider()
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                EmptyStateView(symbol: "checklist", title: emptyTitle, message: model.tasks.isEmpty ? L("tasks.emptyMessage") : "")
            } else {
                List {
                    ForEach(filtered) { task in
                        TaskRow(task: task, done: model.isDone(task), showOwner: section != .mine,
                                onToggle: { model.toggle(task, state: state) }, onOpen: onOpen)
                    }
                }
                .listStyle(.inset)
                .animation(.default, value: filtered.map(\.id))
            }
        }
        .task(id: state.tasksRevision) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await reload()
            }
        }
        .sheet(item: $export) { ExportSheet(request: $0) }
        .alert(L("common.oops"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("common.ok")) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let engine = state.engine, slug = project.slug
        await model.load { await engine.tasks(projectSlug: slug) }
        // First load: open on the first section that has something (mine, then others', then no owner).
        if !pickedSection {
            pickedSection = true
            section = [Section.mine, .theirs, .unowned].first { count($0) > 0 } ?? .mine
        }
    }

    private func badge(_ n: Int) -> String { n > 0 ? "  \(n)" : "" }

    private var emptyTitle: String {
        switch section {
        case .mine: L("tasks.emptyMine")
        case .theirs: L("tasks.emptyTheirs")
        case .unowned: L("tasks.emptyUnowned")
        case .done: L("tasks.emptyDone")
        }
    }

    private var exportTitle: String {
        let part: String
        switch section {
        case .mine: part = L("tasks.mine")
        case .theirs: part = L("tasks.theirs")
        case .unowned: part = L("tasks.unowned")
        case .done: part = L("tasks.done")
        }
        return "\(project.name) — \(part)"
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

/// One task: checkbox, text, owner chip, due date ("vie 30 oct · en 4 días", red when overdue), source chip.
struct TaskRow: View {
    @Environment(AppState.self) private var state
    let task: TaskItem
    let done: Bool
    var showOwner = true
    var showProject = false
    var onToggle: () -> Void
    var onOpen: ((String) -> Void)?

    private var overdue: Bool {
        guard !done, let due = task.due else { return false }
        return Fmt.daysFromToday(due) < 0
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(done ? Color.green : overdue ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(done ? L("tasks.markUndone") : L("tasks.markDone"))

            VStack(alignment: .leading, spacing: 5) {
                Text(task.text)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if showOwner {
                        Chip(text: task.isMine ? L("tasks.me") : (task.ownerName ?? L("tasks.noOwner")),
                             tint: task.isMine ? .accentColor : .secondary, symbol: "person.fill")
                    }
                    if showProject, let project = state.project(task.projectSlug) {
                        Chip(text: "\(project.emoji) \(project.name)")
                    }
                    if let due = task.due {
                        Chip(text: dueText(due), tint: overdue ? .red : (Fmt.daysFromToday(due) <= 1 && !done ? .orange : .secondary),
                             symbol: "calendar")
                    }
                    if done, let doneDate = task.doneDate {
                        Chip(text: L("tasks.doneOn", Fmt.day(doneDate)), tint: .green, symbol: "checkmark")
                    }
                    ForEach(chipKeys.prefix(2), id: \.self) { key in
                        sourceChip(key)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(done ? L("tasks.markUndone") : L("tasks.markDone"), action: onToggle)
            Button(L("chat.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.text, forType: .string)
            }
        }
    }

    private func dueText(_ due: Date) -> String {
        if done { return Fmt.day(due) }
        return "\(Fmt.day(due)) · \(Fmt.relativeDay(due))"
    }

    /// Cited sources without repeating an email thread (two messages of one thread → one ✉️ chip, the newest).
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
        return out
    }

    @ViewBuilder private func sourceChip(_ key: String) -> some View {
        let source = state.source(forKey: key)
        let title = source.map { "\($0.emoji) \($0.title)" } ?? key
        Button {
            open(key)
        } label: {
            Chip(text: String(title.prefix(40)))
        }
        .buttonStyle(.plain)
        .help(source.map { $0.datesLine } ?? key)
        .disabled(onOpen == nil)
    }

    private func open(_ key: String) {
        guard let onOpen else { return }
        let vault = state.engine.vault
        let base = "projects/\(task.projectSlug)/wiki/index.md"
        Task {
            if let path = await vault.resolveWikilinksAsync([key], from: base)[key] { onOpen(path) }
        }
    }
}

/// Sidebar "Mis pendientes": every task of mine across projects, grouped by when it's due.
struct MyTasksView: View {
    @Environment(AppState.self) private var state

    @ViewState private var model = TaskListModel()
    @ViewState private var showDone = false
    @ViewState private var export: ExportRequest?

    private enum Bucket: Int, CaseIterable { case overdue, today, week, later, undated, done }

    private func bucket(_ task: TaskItem) -> Bucket {
        if model.isDone(task) { return .done }
        guard let due = task.due else { return .undated }
        let days = Fmt.daysFromToday(due)
        if days < 0 { return .overdue }
        if days == 0 { return .today }
        let cal = Calendar.current
        if days <= 7 || cal.isDate(due, equalTo: Date(), toGranularity: .weekOfYear) { return .week }
        return .later
    }

    private func title(_ b: Bucket) -> String {
        switch b {
        case .overdue: L("mytasks.overdue")
        case .today: L("mytasks.today")
        case .week: L("mytasks.week")
        case .later: L("mytasks.later")
        case .undated: L("mytasks.undated")
        case .done: L("mytasks.recentlyDone")
        }
    }

    private var mine: [TaskItem] { model.tasks.filter(\.isMine) }

    private var grouped: [(Bucket, [TaskItem])] {
        let byBucket = Dictionary(grouping: mine, by: bucket)
        return Bucket.allCases.compactMap { b in
            guard b != .done || showDone, var list = byBucket[b], !list.isEmpty else { return nil }
            if b == .done {
                list = Array(list.sorted(by: TaskSort.doneFirst).prefix(30))
            } else {
                list.sort(by: TaskSort.byDue)
            }
            return (b, list)
        }
    }

    var body: some View {
        Group {
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if grouped.isEmpty {
                EmptyStateView(symbol: "checkmark.seal", title: L("mytasks.emptyTitle"), message: L("mytasks.emptyMessage"))
            } else {
                List {
                    ForEach(grouped, id: \.0) { bucket, tasks in
                        SwiftUI.Section {
                            ForEach(tasks) { task in
                                TaskRow(task: task, done: model.isDone(task), showOwner: false, showProject: true,
                                        onToggle: { model.toggle(task, state: state) },
                                        onOpen: { path in open(path, project: task.projectSlug) })
                            }
                        } header: {
                            HStack {
                                Text(title(bucket)).foregroundStyle(bucket == .overdue ? Color.red : Color.primary)
                                Text("\(tasks.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .animation(.default, value: mine.map { $0.id + "\(model.isDone($0))" })
            }
        }
        .navigationTitle(L("mytasks.title"))
        .navigationSubtitle(L("mytasks.subtitle"))
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showDone) { Label(L("mytasks.showDone"), systemImage: "checkmark.circle") }
                    .help(L("mytasks.showDone"))
                Button {
                    let open = mine.filter { !model.isDone($0) }.sorted(by: TaskSort.byDue)
                    export = ExportRequest(target: .tasks(open, title: L("mytasks.title")))
                } label: {
                    Label(L("export.button"), systemImage: "square.and.arrow.up")
                }
                .help(L("export.button"))
            }
        }
        .task(id: state.tasksRevision) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await reload()
            }
        }
        .sheet(item: $export) { ExportSheet(request: $0) }
        .alert(L("common.oops"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("common.ok")) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let engine = state.engine
        await model.load { await engine.tasks(projectSlug: nil) }
    }

    private func open(_ path: String, project: String) {
        state.pendingPage = path
        state.selection = .project(project)
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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("srctasks.title")).font(.title2.weight(.semibold))
                    Text("\(source.emoji) \(source.title)").font(.headline).lineLimit(2)
                    Text(source.datesLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    export = ExportRequest(target: .tasks(model.tasks, title: source.title))
                } label: {
                    Label(L("export.button"), systemImage: "square.and.arrow.up")
                }
                .disabled(model.tasks.isEmpty)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !model.loaded {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        group(L("srctasks.mine"), mine)
                        group(L("srctasks.theirs"), theirs)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("srctasks.agreements")).font(.headline)
                        if let agreements {
                            MarkdownText(markdown: agreements).font(.callout)
                        } else {
                            Text(source.status == .done ? L("srctasks.noAgreements") : L("srctasks.notYet"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 600, height: 560)
        .task(id: state.tasksRevision) { await reload() }
        .sheet(item: $export) { ExportSheet(request: $0) }
        .alert(L("common.oops"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("common.ok")) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder private func group(_ title: String, _ tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if tasks.isEmpty {
                Text(L("srctasks.none")).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(tasks) { task in
                    TaskRow(task: task, done: model.isDone(task), showOwner: !task.isMine,
                            onToggle: { model.toggle(task, state: state) }, onOpen: nil)
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
