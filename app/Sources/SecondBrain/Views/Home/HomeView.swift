import AppKit
import BrainCore
import SwiftUI

/// Inicio (CONTRACT §16.9, layout §15.2): one centered column (max 880 pt) with, in order and only when they have
/// content: today's date and the ⌘K field · Lo último que aprendí (any kind of source, GitHub folded per repo) ·
/// Pendientes para hoy · Agenda (compact, only with a calendar) · "n por ordenar → Sin asignar". A new vault shows five
/// equal ways in (Nota · Archivo · Enlace · Correo · Grabar): the brain is fed by the whole day, not only meetings.
/// Its own NavigationStack pushes a global ficha or the timeline. The whole screen accepts dropped files (→ Sin asignar).
struct HomeView: View {
    @Environment(AppState.self) private var state
    /// Snapshot "home-empty": the new-vault state, whatever the vault holds.
    var previewEmpty = false

    @ViewState private var routes: [HomeRoute] = []
    @ViewState private var showHistory = false
    @ViewState private var width: CGFloat = 880
    @ViewState private var tasks = TaskListModel()
    @ViewState private var dropTargeted = false
    @ViewState private var importing = 0
    @ViewState private var error: String?
    /// The latest timeline entries with a page (Lo último que aprendí when few sources are learned on this Mac).
    @ViewState private var timelineRecents: [TimelineEntry] = []
    @ViewState private var timelineLoaded = false
    /// A task's meeting or email, read over Inicio (Pendientes para hoy never leaves Inicio).
    @ViewState private var taskPreview: VaultPageItem?
    /// The task just checked in Pendientes para hoy: "Hecho · Deshacer" for `undoSeconds`.
    @ViewState private var undoTask: TaskItem?
    /// Bumped on every check, so a newer one restarts the countdown.
    @ViewState private var undoGeneration = 0

    static let undoSeconds = 6

    static let maxWidth: CGFloat = 880
    /// Below this content width the grids collapse to one column. `width` is the column inside the padding, so a
    /// 700 pt detail (the minimum window, §15.3) still gets two columns and Pendientes/Agenda stay near the top.
    static let oneColumnBelow: CGFloat = 520

    var body: some View {
        NavigationStack(path: $routes) {
            home
                .navigationDestination(for: HomeRoute.self) { destination($0) }
        }
        .onAppear(perform: consumeRoute)
        .onChange(of: state.homeRoute) { consumeRoute() }
        // "Inicio" (sidebar, ⌘1) while already here: back to the root.
        .onChange(of: state.homePopToken) { routes.removeAll() }
    }

    // MARK: Data

    /// A new vault: nothing on this Mac and nothing in the vault's timelines (decided once they are read).
    private var isEmptyVault: Bool {
        previewEmpty || (state.engine.sources.isEmpty && timelineLoaded && timelineRecents.isEmpty)
    }
    private var oneColumn: Bool { width < Self.oneColumnBelow }

    /// Sin asignar and the failed sources without a project, one per email thread: the same items as Sin asignar, so
    /// "n por ordenar" matches its list (a failed source of a project shows in its "Procesando").
    private var toSortCount: Int {
        InboxView.onePerThread(state.engine.sources
            .filter { $0.status == .needsProject || ($0.projectSlug == nil && $0.status == .failed) })
            .count
    }

    /// My open tasks (the count of "Ver todos").
    private var myOpen: [TaskItem] { tasks.tasks.filter { $0.isMine && !$0.done } }

    /// My tasks as listed: a box just ticked stays in place, struck through, for a few seconds (TaskListModel's
    /// sticky state), so a mis-click is seen and can be undone right there.
    private var myListed: [TaskItem] { tasks.tasks.filter { $0.isMine && !tasks.listedDone($0) } }

    /// Overdue, today or tomorrow.
    private var dueSoon: [TaskItem] {
        myListed.filter { task in task.due.map { Fmt.daysFromToday($0) <= 1 } ?? false }
            .sorted(by: TaskSort.byDue)
    }

    /// In progress first, then the last learned of any kind, each followed GitHub repo as one card (its newest sync),
    /// then (when this Mac learned fewer than 6) the latest pages of the vault's timelines, so a vault with content
    /// never shows an empty "Lo último que aprendí". 6 in all.
    private var recents: [HomeRecentItem] {
        let all = state.engine.sources.filter { $0.status.isInProgress || $0.status == .done }
        let busy = all.filter { $0.kind != .github && $0.status.isInProgress }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(HomeRecentItem.init(source:))
        let done = all.filter { $0.kind != .github && $0.status == .done }.map(HomeRecentItem.init(source:))
        let repos = Dictionary(grouping: all.filter { $0.kind == .github }, by: HomeRecentItem.repoName(of:))
            .map { repo, syncs in HomeRecentItem(repo: repo, syncs: syncs.sorted { $0.timelineDate > $1.timelineDate }) }
        let learned = (done + repos).sorted { $0.sortDate > $1.sortDate }
        var items = Array((busy + learned).prefix(6))
        guard items.count < 6 else { return items }
        var seen = Set(items.compactMap(\.sourceId))
        var seenPaths = Set<String>()
        for entry in timelineRecents where items.count < 6 {
            guard let path = entry.pagePath else { continue }
            if let id = entry.sourceId, seen.contains(id) { continue }
            guard seenPaths.insert(path).inserted else { continue }
            if let id = entry.sourceId { seen.insert(id) }
            items.append(HomeRecentItem(entry: entry))
        }
        return items
    }

    /// Meetings, emails, documents, notes, links and decisions that already happened, newest first, with a page to open
    /// (not the project's timeline/tasks pages a milestone or a due date points at).
    private static func recentEntries(_ all: [TimelineEntry], now: Date) -> [TimelineEntry] {
        let kinds: Set<TimelineKind> = [.meeting, .email, .document, .note, .url, .decision]
        return all.filter { entry in
            guard kinds.contains(entry.kind), entry.date <= now, let path = entry.pagePath else { return false }
            return !path.hasSuffix("/wiki/timeline.md") && !path.hasSuffix("/wiki/tasks.md") && path.hasSuffix(".md")
        }
        .sorted { $0.date > $1.date }
        .prefix(12)
        .map { $0 }
    }

    // MARK: Screen

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if isEmptyVault {
                    emptyState
                    HomeAgendaSection()
                } else {
                    if !recents.isEmpty { recentSection.transition(.opacity) }
                    if tasks.loaded, !myListed.isEmpty { tasksSection.transition(.opacity) }
                    HomeAgendaSection()
                    if toSortCount > 0 { toSortLine.transition(.opacity) }
                }
            }
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .padding(.horizontal, Brand.spacing.contentWide)
            .padding(.vertical, Brand.spacing.contentWide)
            .frame(maxWidth: .infinity)
            .animation(Brand.motion.animation(), value: tasks.loaded)
            .animation(Brand.motion.animation(), value: toSortCount)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Brand.spacing.contentWide } action: { width = $0 }
        .scrollContentBackground(.hidden)
        .background(Brand.color.surface)
        .navigationTitle(L("home.title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showHistory = true
                } label: {
                    Label(L("home.history"), systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .help(L("home.history"))
            }
        }
        .sheet(isPresented: $showHistory) { historySheet }
        .dropDestination(for: URL.self) { urls, _ in
            importURLs(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropOverlay } }
        .safeAreaInset(edge: .bottom) {
            if let task = undoTask { undoLine(task).transition(.opacity).padding(.bottom, 12) }
        }
        .animation(Brand.motion.animation(fast: true), value: undoTask?.id)
        .sheet(item: $taskPreview) { PageSheet(path: $0.path) }
        .task(id: undoGeneration) {
            guard undoTask != nil else { return }
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled else { return }
            undoTask = nil
        }
        .task {
            if !MeetingsModel.shared.isRunning, state.engineStarted { MeetingsModel.shared.start(state: state) }
        }
        .task(id: state.tasksRevision) { await loadTasks() }
        .task(id: "\(state.vaultRevision)-\(state.vaultGeneration)") { await loadTimeline() }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Fmt.weekdayLong(MeetingsModel.shared.now))
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(1)
            Button {
                state.searchPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Brand.color.text3)
                    Text(L("home.search"))
                        .foregroundStyle(Brand.color.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(verbatim: "⌘K")
                        .font(Brand.font(12, .medium))
                        .foregroundStyle(Brand.color.text3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Brand.color.cardAlt, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .font(Brand.font(15))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
                    .strokeBorder(Brand.color.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Por ordenar

    /// One line, "3 por ordenar → Sin asignar": sorting happens in Sin asignar, not on Inicio.
    private var toSortLine: some View {
        Button {
            state.navigate(to: .sidebar(.unassigned))
        } label: {
            BrandCard(padding: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "tray").foregroundStyle(Brand.color.text2)
                    Text(L("home.toSortLine", toSortCount))
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text(L("inbox.title")).lineLimit(1)
                        Image(systemName: "arrow.right").imageScale(.small)
                    }
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("home.toSortHelp"))
    }

    // MARK: Pendientes para hoy

    private var tasksSection: some View {
        let soon = dueSoon
        return VStack(alignment: .leading, spacing: 10) {
            BrandSectionHeader(title: L("home.tasksToday")) {
                HomeLink(title: L("home.seeAllTasks", myOpen.count)) { state.navigate(to: .sidebar(.tasks)) }
            }
            BrandCard(padding: soon.isEmpty ? 14 : 0) {
                if soon.isEmpty {
                    Label(L("home.nothingDue"), systemImage: "checkmark.circle")
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(soon.prefix(5).enumerated()), id: \.element.id) { offset, task in
                            if offset > 0 { HomeDivider() }
                            TaskRow(task: task, done: tasks.isDone(task), showOwner: false, showProject: true,
                                    onToggle: { toggle(task) },
                                    onOpen: { taskPreview = VaultPageItem(path: $0) })
                                .frame(minHeight: 36)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    /// "Hecho · Deshacer" (the same line as Pendientes), over the bottom of Inicio.
    private func undoLine(_ task: TaskItem) -> some View {
        HStack(spacing: Brand.spacing.s) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.color.success)
            Text(L("tasks.doneToast"))
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
            Text(verbatim: "·").foregroundStyle(Brand.color.text2)
            Button(L("tasks.undo")) { undo(task) }
                .buttonStyle(.plain)
                .font(Brand.callout)
                .foregroundStyle(Brand.color.accent)
                .fixedSize()
        }
        .padding(.horizontal, Brand.spacing.m)
        .padding(.vertical, 8)
        .background(Capsule().fill(Brand.color.card))
        .overlay(Capsule().strokeBorder(Brand.color.line))
        .shadow(color: Brand.color.shadow, radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Lo último que aprendí

    private var recentSection: some View {
        let columns = oneColumn
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return VStack(alignment: .leading, spacing: 10) {
            BrandSectionHeader(title: L("home.recent")) {
                HomeLink(title: L("home.seeByDate")) { routes.append(.timeline) }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(recents) { item in
                    HomeRecentCard(item: item)
                }
            }
        }
    }

    // MARK: Empty vault

    /// A new vault: the five ways to feed the brain, with the same weight (none of them first because it records).
    private var emptyState: some View {
        VStack(spacing: 16) {
            BrandMark(size: 56)
            VStack(spacing: 6) {
                Text(L("home.emptyTitle"))
                    .font(Brand.title)
                    .foregroundStyle(Brand.color.text)
                Text(L("home.empty.message"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .frame(maxWidth: 520)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // 5 across, else 3 + 2, else one column: the tiles never squeeze their titles.
            let count = width >= 600 ? 5 : (width >= 360 ? 3 : 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: count), spacing: 12) {
                HomeBigAction(symbol: "square.and.pencil", title: L("home.empty.note"), shortcut: nil, tint: Brand.color.accent) {
                    state.noteRequest = NoteRequest(projectSlug: nil)
                }
                HomeBigAction(symbol: "doc.badge.plus", title: L("home.empty.file"), shortcut: nil, tint: Brand.color.accent,
                              action: chooseFiles)
                HomeBigAction(symbol: "link", title: L("home.empty.link"), shortcut: nil, tint: Brand.color.accent) {
                    state.linkRequest = LinkRequest(projectSlug: nil)
                }
                HomeBigAction(symbol: "envelope", title: L("home.empty.mail"), shortcut: "⌘⇧V", tint: Brand.color.accent) {
                    state.requestEmail()
                }
                HomeBigAction(symbol: "record.circle", title: state.isRecording ? L("add.stopRecording") : L("home.empty.record"),
                              shortcut: nil, tint: Brand.color.accent) {
                    state.recordNow(placement: .sidebar)
                }
                .disabled(state.isRecorderBusy)
            }
            Text(L("home.empty.dropHint"))
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
            .strokeBorder(Brand.color.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
            .overlay {
                Label(L("home.dropToUnassigned"), systemImage: "arrow.down.doc")
                    .font(Brand.section)
                    .foregroundStyle(Brand.color.accent)
            }
            .padding(10)
            .allowsHitTesting(false)
    }

    private var historySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("home.history")).font(Brand.section).foregroundStyle(Brand.color.text)
                Spacer()
                Button(L("common.close")) { showHistory = false }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            ActivityView(projectSlug: nil) { path in
                showHistory = false
                state.open(path: path)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 520)
    }

    // MARK: Navigation

    @ViewBuilder private func destination(_ route: HomeRoute) -> some View {
        switch route {
        case .entity(let path):
            EntityView(path: path, scope: .brain)
        case .timeline:
            BrainTimelineView(projectSlug: nil) { path, _ in state.open(path: path) }
        }
    }

    /// Pushes `state.homeRoute` (left by `AppState.navigate(to:)`): a global ficha opened from a link pushes on top
    /// of the one showing, so Atrás goes back to it.
    private func consumeRoute() {
        guard state.selection == .home || state.selection == nil, let route = state.homeRoute else { return }
        state.homeRoute = nil
        if routes.last != route { routes.append(route) }
    }

    // MARK: Actions

    /// A checkbox in Pendientes para hoy: checking shows "Hecho · Deshacer" for 6 s; unchecking hides it.
    private func toggle(_ task: TaskItem) {
        let wasDone = tasks.isDone(task)
        withAnimation(Brand.motion.fast) { tasks.toggle(task, state: state) }
        if let failure = tasks.error {
            tasks.error = nil
            error = failure
            return
        }
        if !wasDone {
            undoTask = task
            undoGeneration += 1
        } else if undoTask?.id == task.id {
            undoTask = nil
        }
    }

    /// "Deshacer": the same toggle, back to open.
    private func undo(_ task: TaskItem) {
        undoTask = nil
        guard tasks.isDone(task) else { return }
        withAnimation(Brand.motion.fast) { tasks.toggle(task, state: state) }
        if let failure = tasks.error {
            tasks.error = nil
            error = failure
        }
    }

    private func loadTimeline() async {
        guard state.engineStarted else { return }
        let all = await state.engine.timeline(projectSlug: nil)
        guard !Task.isCancelled else { return }
        let recent = Self.recentEntries(all, now: Date())
        if recent != timelineRecents { timelineRecents = recent }
        timelineLoaded = true
    }

    private func loadTasks() async {
        guard state.engineStarted else { return }
        let engine = state.engine
        await tasks.load { await engine.tasks(projectSlug: nil) }
    }

    /// "Archivo": the same panel and import as "+ Agregar", with no project (→ Sin asignar).
    private func chooseFiles() {
        guard let batch = SourceImport.chooseFiles() else { return }
        importURLs(batch.urls)
    }

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing += 1
        Task {
            defer { importing -= 1 }
            let failed = await SourceImport.importURLs(urls, projectSlug: nil, state: state)
            if !failed.isEmpty { self.error = failed.joined(separator: "\n") }
        }
    }
}
