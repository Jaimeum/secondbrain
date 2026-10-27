import AppKit
import BrainCore
import SwiftUI

/// Inicio (CONTRACT §15.2): one centered column (max 880 pt) with, in order and only when they have content: today's
/// date and the ⌘K field · Ahora / Siguiente (+ the rest of today) · Por ordenar · Pendientes para hoy · Recientes ·
/// Conexiones. Its own NavigationStack pushes a global page, the timeline, the graph, Sin asignar or a question.
/// The whole screen accepts dropped files (→ Sin asignar).
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
    @ViewState private var ruleOffer = RuleOffer()
    @ViewState private var error: String?
    /// The latest timeline entries with a page (Recientes when few sources are learned on this Mac).
    @ViewState private var timelineRecents: [TimelineEntry] = []
    @ViewState private var timelineLoaded = false
    /// A page cited by an answer, shown over Inicio so the answer stays where it was.
    @ViewState private var citedPage: VaultPageItem?
    /// A task's meeting or email, read over Inicio (Pendientes para hoy never leaves Inicio).
    @ViewState private var taskPreview: PagePreviewItem?
    /// The task just checked in Pendientes para hoy: "Hecho · Deshacer" for `undoSeconds`.
    @ViewState private var undoTask: TaskItem?
    /// Bumped on every check, so a newer one restarts the countdown.
    @ViewState private var undoGeneration = 0

    static let undoSeconds = 6

    static let maxWidth: CGFloat = 880
    /// Below this content width the grids collapse to one column.
    static let oneColumnBelow: CGFloat = 700

    var body: some View {
        NavigationStack(path: $routes) {
            home
                .navigationDestination(for: HomeRoute.self) { destination($0) }
        }
        .onAppear(perform: consumeRoute)
        .onChange(of: state.homeRoute) { consumeRoute() }
        // "Inicio" (sidebar, ⌘1) while already here: back to the root.
        .onChange(of: state.homePopToken) { routes.removeAll() }
        .sheet(item: $citedPage) { VaultPageSheet(path: $0.path) }
    }

    // MARK: Data

    /// A new vault: nothing on this Mac and nothing in the vault's timelines (decided once they are read).
    private var isEmptyVault: Bool {
        previewEmpty || (state.engine.sources.isEmpty && timelineLoaded && timelineRecents.isEmpty)
    }
    private var oneColumn: Bool { width < Self.oneColumnBelow }

    /// Sin asignar and the failed sources without a project, newest first; one row per email thread. The same items
    /// as Sin asignar ("Ver todo"), so the counts match: a failed source of a project shows in its "Procesando".
    private var toSort: [SourceRecord] {
        InboxView.onePerThread(state.engine.sources
            .filter { $0.status == .needsProject || ($0.projectSlug == nil && $0.status == .failed) })
            .sorted { $0.updatedAt > $1.updatedAt }
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

    /// In progress first, then the last learned, then (when this Mac learned fewer than 6) the latest pages of the
    /// vault's timelines, so a vault with content never shows an empty Recientes. 6 in all.
    private var recents: [HomeRecentItem] {
        let sources = state.engine.sources.filter { $0.kind != .github }
        let busy = sources.filter { $0.status.isInProgress }.sorted { $0.updatedAt > $1.updatedAt }
        let done = sources.filter { $0.status == .done }.sorted { $0.updatedAt > $1.updatedAt }
        var items = (busy + done).prefix(6).map(HomeRecentItem.init(source:))
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
                HomeNowSection()
                if isEmptyVault {
                    emptyState
                } else {
                    if !toSort.isEmpty { toSortSection.transition(.opacity) }
                    if tasks.loaded, !myListed.isEmpty { tasksSection.transition(.opacity) }
                    if !recents.isEmpty { recentSection.transition(.opacity) }
                    connectionsSection
                }
            }
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .padding(.horizontal, Brand.spacing.contentWide)
            .padding(.vertical, Brand.spacing.contentWide)
            .frame(maxWidth: .infinity)
            .animation(Brand.motion.animation(), value: tasks.loaded)
            .animation(Brand.motion.animation(), value: toSort.count)
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
            VStack(spacing: 8) {
                if let task = undoTask { undoLine(task).transition(.opacity) }
                if ruleOffer.current != nil {
                    RuleOfferBar(offer: ruleOffer)
                        .frame(maxWidth: Self.maxWidth)
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, undoTask != nil || ruleOffer.current != nil ? 12 : 0)
        }
        .animation(Brand.motion.animation(fast: true), value: ruleOffer.current)
        .animation(Brand.motion.animation(fast: true), value: undoTask?.id)
        .sheet(item: $taskPreview) { PagePreviewSheet(path: $0.path) }
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
            if let question = lastQuestion { lastQuestionRow(question) }
        }
    }

    /// The last whole-brain question, while it is recent and its answer isn't on screen: back to it without asking again.
    private var lastQuestion: String? {
        guard let asked = state.homeChatAskedAt, MeetingsModel.shared.now.timeIntervalSince(asked) < 30 * 60,
              !routes.contains(where: { if case .ask = $0 { true } else { false } }) else { return nil }
        return state.homeChat.messages.last { $0.role == .user }?.text
    }

    private func lastQuestionRow(_ question: String) -> some View {
        Button {
            routes.append(.ask(question))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(Brand.color.accent)
                Text(L("home.lastQuestion", question))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "arrow.right")
                    .imageScale(.small)
                    .foregroundStyle(Brand.color.accent)
                Spacer(minLength: 0)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(question)
    }

    // MARK: Por ordenar

    private var toSortSection: some View {
        let items = toSort
        return VStack(alignment: .leading, spacing: 10) {
            BrandSectionHeader(title: L("home.toSort"), count: items.count) {
                HomeLink(title: L("home.seeAll")) { routes.append(.inbox) }
            }
            BrandCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { offset, source in
                        if offset > 0 { HomeDivider() }
                        // The same row as Sin asignar (suggestion · Asignar · Otro ▾, or Reintentar · Eliminar).
                        InboxRow(source: source, onError: { error = $0 }, onAssigned: { subject, slug in
                            ruleOffer.propose(subject, projectSlug: slug, state: state)
                        }, showsCard: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: Pendientes para hoy

    private var tasksSection: some View {
        let soon = dueSoon
        return VStack(alignment: .leading, spacing: 10) {
            BrandSectionHeader(title: L("home.tasksToday")) {
                HomeLink(title: L("home.seeAllTasks", myOpen.count)) { state.selection = .tasks }
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
                                    onOpen: { taskPreview = PagePreviewItem(path: $0) })
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

    // MARK: Recientes

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

    // MARK: Conexiones

    private var connectionsSection: some View {
        Button {
            routes.append(.graph)
        } label: {
            BrandCard(padding: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(Brand.color.accent)
                    Text(L("home.connections"))
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right").foregroundStyle(Brand.color.text3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty vault

    /// The big "Grabar" only when Ahora doesn't already show one (the hero's or the recording's): one "Grabar" on
    /// screen besides the sidebar's.
    private var showsRecordTile: Bool {
        !state.isRecording && HomeNowSection.heroEvent(now: MeetingsModel.shared.now) == nil
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            BrandMark(size: 56)
            Text(L("home.emptyTitle"))
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            let showsRecord = showsRecordTile
            let columns = oneColumn
                ? [GridItem(.flexible())]
                : Array(repeating: GridItem(.flexible(), spacing: 12), count: showsRecord ? 3 : 2)
            LazyVGrid(columns: columns, spacing: 12) {
                if showsRecord {
                    HomeBigAction(symbol: "record.circle", title: L("home.emptyRecord"), shortcut: nil, tint: Brand.color.record) {
                        state.recordNow(placement: .sidebar)
                    }
                }
                HomeBigAction(symbol: "envelope", title: L("home.emptyPaste"), shortcut: "⌘⇧V", tint: Brand.color.accent) {
                    state.requestEmail()
                }
                HomeBigAction(symbol: "arrow.down.doc", title: L("home.emptyDrop"), shortcut: nil, tint: Brand.color.accent,
                              dashed: true, action: chooseFiles)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
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
        case .page(let path):
            HomePageView(path: path)
        case .timeline:
            BrainTimelineView(projectSlug: nil) { path, _ in state.open(path: path) }
        case .graph:
            GraphView(scope: .global, focus: nil, onOpen: { state.open(path: $0) })
        case .inbox:
            InboxView()
        case .ask:
            // A cited page opens over the answer (a sheet), so the answer is still here after reading it.
            ChatView(model: state.homeChat, projectSlug: nil, onOpenPage: { citedPage = VaultPageItem(path: $0) })
        }
    }

    /// Pushes `state.homeRoute` (set by ⌘K, `AppState.open(path:)` or `ask`). A question is asked here, once; one
    /// still being answered is stopped first (as a project's Preguntar does), else the new one would be dropped.
    private func consumeRoute() {
        guard let route = state.homeRoute else { return }
        state.homeRoute = nil
        if case .ask(let question) = route, state.engineStarted {
            if state.homeChat.isAsking { state.homeChat.stop() }
            state.homeChat.draft = question
            state.homeChat.ask(engine: state.engine, projectSlug: nil)
            state.homeChatAskedAt = Date()
            if let existing = routes.firstIndex(where: { if case .ask = $0 { true } else { false } }) {
                routes.removeSubrange(existing...)
            }
        }
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

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("sources.addFiles")
        panel.message = L("sources.panelMessage")
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    /// Same engine calls as SourcesView's drop, with no project: everything lands in Sin asignar.
    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing += 1
        Task {
            defer { importing -= 1 }
            var failed: [String] = []
            for url in urls {
                do {
                    if url.isFileURL {
                        try await state.engine.importFileAsync(url, projectSlug: nil)
                    } else {
                        try await state.engine.importURL(url, projectSlug: nil)
                    }
                } catch let engineError as EngineError {
                    failed.append(engineError.errorDescription ?? L("sources.importFailed", url.lastPathComponent))
                } catch {
                    failed.append(url.isFileURL ? L("sources.importFailed", url.lastPathComponent) : L("sources.linkFailed"))
                }
            }
            if !failed.isEmpty { self.error = failed.joined(separator: "\n") }
        }
    }
}

/// A global page (index.md, log.md…) inside Inicio's stack. Its title is read off the main thread (the file name
/// until then).
struct HomePageView: View {
    @Environment(AppState.self) private var state
    let path: String
    @ViewState private var title: String?

    var body: some View {
        WikiWebView(vault: state.engine.vault, path: path) { next in state.open(path: next) }
            .background(Brand.color.surface)
            .navigationTitle(title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            .task(id: path) {
                let vault = state.engine.vault, path = self.path
                title = await Task.detached { vault.title(of: path) }.value
            }
    }
}
