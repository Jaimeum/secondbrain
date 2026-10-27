import AppKit
import BrainCore
import SwiftUI

/// A project's "Contenido" tab (CONTRACT §15.2): a list on the left — *Por fecha* (what happened, by month, with the
/// sources still being processed pinned on top) or *Por tema* (the wiki groups) — and the page on the right.
/// The whole tab accepts dropped files and links.
struct ProjectContentView: View {
    enum Mode: String, Hashable { case byDate = "date", byTopic = "topic" }

    @Environment(AppState.self) private var state
    let project: Project
    @Binding var selection: String?

    @ViewState private var mode: Mode
    @ViewState private var entries: [TimelineEntry] = []
    @ViewState private var entriesLoaded = false
    @ViewState private var pages: [WikiPage] = []
    @ViewState private var pagesLoaded = false
    @ViewState private var kinds: Set<TimelineKind> = []
    /// A source that has no page yet (in progress or failed): the right side shows its status instead.
    @ViewState private var selectedSourceId: String?
    /// The timeline row the user clicked (a source row resolves to its summary page).
    @ViewState private var selectedEntryId: String?
    /// Pages that source rows resolved to (a source's summary), by timeline entry id.
    @ViewState private var entryPaths: [String: String] = [:]
    @ViewState private var showAllProcessing = false
    @ViewState private var actions = SourceActionsState()

    private static let modeKey = "content.mode"

    init(project: Project, selection: Binding<String?>, initialMode: Mode? = nil) {
        self.project = project
        _selection = selection
        let saved = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:))
        _mode = ViewState(initialValue: initialMode ?? saved ?? .byDate)
    }

    private var slug: String { project.slug }

    /// Sources of this project still on their way (recording, queued, transcribing, learning) or failed.
    private var processing: [SourceRecord] {
        state.engine.sources
            .filter { $0.projectSlug == slug && ($0.status.isInProgress || $0.status == .failed) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var months: [TimelineGroups.Month] {
        let hidden = Set(processing.map(\.id))
        return TimelineGroups.months(entries.filter { $0.sourceId.map { !hidden.contains($0) } ?? true }, kinds: kinds)
    }

    private var topicGroups: [WikiGrouping.Group] {
        WikiGrouping.groups(for: pages, scope: .project(slug), projectName: project.name)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                listColumn
                    .frame(width: ContentLayout.listWidth(for: geo.size.width))
                Rectangle().fill(Brand.color.line).frame(width: 1)
                pageColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Brand.color.surface)
        .sourceDropTarget(projectSlug: slug)
        .sourceActions($actions, onOpen: { openPath($0) })
        .onChange(of: mode) { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
        .onChange(of: selection) {
            if selection != nil { selectedSourceId = nil }
        }
        .onChange(of: processing.map(\.id)) {
            // A processed source left the group: show its page when it was the one selected.
            if let id = selectedSourceId, !processing.contains(where: { $0.id == id }) {
                selectedSourceId = nil
                if let source = state.engine.source(id) { openSource(source) }
            }
        }
        .task(id: state.vaultRevision) {
            await reloadPages()
            await reloadEntries()
        }
        .task {
            // Claude edits pages and adds entries in the background: keep the lists fresh.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await reloadPages()
                await reloadEntries()
            }
        }
    }

    // MARK: List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Brand.spacing.s) {
                BrandSegmentedControl(options: [(Mode.byDate, L("tabs.byDate")), (Mode.byTopic, L("tabs.byTopic"))],
                                      selection: $mode)
            }
            .padding(.horizontal, Brand.spacing.m)
            .padding(.top, Brand.spacing.m)
            .padding(.bottom, Brand.spacing.s)

            switch mode {
            case .byDate: dateList
            case .byTopic: topicList
            }
        }
        .background(Brand.color.surface)
    }

    private var topicList: some View {
        Group {
            if pagesLoaded && topicGroups.isEmpty {
                listEmpty
            } else {
                WikiPageList(groups: topicGroups, selection: Binding(get: { selectedSourceId == nil ? selection : nil },
                                                                     set: { selectEntry(nil); selection = $0 }))
            }
        }
    }

    private var dateList: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !TimelineGroups.presentKinds(in: entries).isEmpty {
                    HStack(spacing: Brand.spacing.s) {
                        TimelineKindMenu(kinds: TimelineGroups.presentKinds(in: entries), selected: $kinds)
                        Spacer(minLength: 4)
                        Button(L("timeline.today")) { scrollToAnchor(proxy, animated: true) }
                            .buttonStyle(.borderless)
                            .font(Brand.font(11, .medium))
                            .foregroundStyle(Brand.color.accent)
                            .help(L("timeline.todayHelp"))
                    }
                    .padding(.horizontal, Brand.spacing.m)
                    .padding(.bottom, Brand.spacing.xs)
                }
                if !processing.isEmpty { processingGroup }
                Rectangle().fill(Brand.color.line).frame(height: 1)
                if !entriesLoaded {
                    BrandLoader(size: 24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if months.isEmpty {
                    if processing.isEmpty { listEmpty } else { Spacer() }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(months) { month in
                                SwiftUI.Section {
                                    ForEach(month.days) { day in
                                        VStack(alignment: .leading, spacing: 1) {
                                            ForEach(day.entries) { entry in entryRow(entry) }
                                        }
                                        .timelineAnchor(day.start, headerHeight: Self.monthHeaderHeight)
                                    }
                                } header: {
                                    ContentListHeader(title: TimelineGroups.monthTitle(month.start))
                                        .frame(height: Self.monthHeaderHeight, alignment: .bottom)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Brand.color.surface)
                                        .id(TimelineGroups.MonthAnchor(start: month.start))
                                }
                            }
                        }
                        .padding(.horizontal, Brand.spacing.s)
                        .padding(.bottom, Brand.spacing.l)
                    }
                    .onAppear { scrollToAnchor(proxy, animated: false) }
                    .onChange(of: kinds) { scrollToAnchor(proxy, animated: false) }
                    .onChange(of: entriesLoaded) { scrollToAnchor(proxy, animated: false) }
                }
            }
        }
    }

    private static let monthHeaderHeight: CGFloat = 32

    private var listEmpty: some View {
        Text(L("content.listEmpty"))
            .font(Brand.body)
            .foregroundStyle(Brand.color.text2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Brand.spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func scrollToAnchor(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let target = TimelineGroups.anchorTarget(in: months) else { return }
        if animated {
            withAnimation(Brand.motion.animation()) { proxy.scrollTo(target, anchor: .top) }
        } else {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    // MARK: Processing ("Procesando", pinned above the dates)

    private var processingGroup: some View {
        let list = processing
        let shown = showAllProcessing ? list : Array(list.prefix(3))
        return VStack(alignment: .leading, spacing: 1) {
            ContentListHeader(title: L("content.processing"), trailing: "\(list.count)")
            ForEach(shown) { source in
                ProcessingRow(source: source, isSelected: selectedSourceId == source.id,
                              onSelect: { selectProcessing(source) },
                              onRetry: { state.engine.retry(sourceId: source.id) },
                              onDelete: { actions.pendingDelete = source })
                    .contextMenu { SourceMenuItems(source: source, trimmed: true, onOpen: { openPath($0) }, actions: $actions) }
            }
            if list.count > 3 {
                Button(showAllProcessing ? L("content.showLess") : L("home.seeAllTasks", list.count)) {
                    withAnimation(Brand.motion.animation(fast: true)) { showAllProcessing.toggle() }
                }
                .buttonStyle(.borderless)
                .font(Brand.caption)
                .foregroundStyle(Brand.color.accent)
                .padding(.horizontal, Brand.spacing.s)
                .padding(.vertical, Brand.spacing.xs)
            }
        }
        .padding(.horizontal, Brand.spacing.s)
        .padding(.bottom, Brand.spacing.s)
    }

    // MARK: Date rows

    private func entryRow(_ entry: TimelineEntry) -> some View {
        let source = entry.sourceId.flatMap { state.engine.source($0) }
        let clickable = entry.pagePath != nil || source != nil
        return ContentListRow(symbol: entry.kind.symbol, title: entry.title, caption: caption(entry),
                              isSelected: isSelected(entry)) {
            if clickable { open(entry) }
        }
        .contextMenu {
            if let source {
                SourceMenuItems(source: source, trimmed: true, onOpen: { openPath($0) }, actions: $actions)
            } else if let path = entry.pagePath {
                Button(L("wiki.showInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([state.engine.vault.url(for: path)])
                }
            }
        }
    }

    private func caption(_ entry: TimelineEntry) -> String {
        let date = Fmt.dayTime(entry.date, hasTime: entry.hasTime)
        return entry.kind == .task || entry.kind == .decision || entry.kind == .milestone
            ? "\(entry.kind.label) · \(date)" : date
    }

    private func isSelected(_ entry: TimelineEntry) -> Bool {
        guard selectedSourceId == nil, let selection else { return false }
        // The clicked row wins over other rows pointing at the same page (due dates all live in one page).
        if let id = selectedEntryId, entryPaths[id] == selection { return entry.id == id }
        return (entry.pagePath ?? entryPaths[entry.id]) == selection
    }

    private func open(_ entry: TimelineEntry) {
        selectedSourceId = nil
        if let path = entry.pagePath {
            selectEntry(entry.id)
            entryPaths[entry.id] = path
            selection = path
            return
        }
        guard let id = entry.sourceId, let source = state.engine.source(id) else { return }
        guard source.status == .done else {
            selectProcessing(source)
            return
        }
        selectEntry(entry.id)
        SourceOpener.openSummary(source, state: state) { path in
            entryPaths[entry.id] = path
            selection = path
        }
    }

    private func selectEntry(_ id: String?) { selectedEntryId = id }

    private func selectProcessing(_ source: SourceRecord) {
        selectEntry(nil)
        selection = nil
        selectedSourceId = source.id
    }

    /// A done source opens its summary (else its raw text); one still in progress shows "Aprendiendo…".
    private func openSource(_ source: SourceRecord) {
        guard source.status == .done else {
            selectProcessing(source)
            return
        }
        SourceOpener.openSummary(source, state: state) { path in selection = path }
    }

    private func openPath(_ path: String) {
        selectEntry(nil)
        selection = path
    }

    // MARK: Page column

    @ViewBuilder private var pageColumn: some View {
        if let id = selectedSourceId, let source = state.engine.source(id) {
            ProcessingPanel(source: source,
                            onRetry: { state.engine.retry(sourceId: source.id) },
                            onDelete: { actions.pendingDelete = source })
        } else if selection != nil {
            WikiPagePane(selection: $selection,
                         title: WikiGrouping.title(of: selection, in: pages, projectName: project.name))
        } else if pagesLoaded {
            EmptyStateView(symbol: "book.closed", title: L("wiki.emptyTitle"), message: L("wiki.emptyMessage"))
        } else {
            BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Loading

    private func reloadPages() async {
        guard state.engineStarted else { return }
        let vault = state.engine.vault
        let all = await WikiGrouping.loadPages(scope: .project(slug), vault: vault)
        guard !Task.isCancelled, vault === state.engine.vault else { return }
        if all != pages { pages = all }
        pagesLoaded = true
        if selection == nil, selectedSourceId == nil {
            selection = WikiGrouping.defaultPage(in: all)?.path
        }
    }

    private func reloadEntries() async {
        guard state.engineStarted else { return }
        let list = await state.engine.timeline(projectSlug: slug)
        guard !Task.isCancelled else { return }
        if list != entries { entries = list }
        entriesLoaded = true
    }
}

// MARK: - Processing row and panel

/// A source on its way: kind, title, status; failed ones offer Reintentar / Eliminar.
private struct ProcessingRow: View {
    let source: SourceRecord
    let isSelected: Bool
    var onSelect: () -> Void
    var onRetry: () -> Void
    var onDelete: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: Brand.spacing.s) {
                Image(systemName: source.kind.symbol)
                    .font(Brand.font(12))
                    .foregroundStyle(Brand.color.text2)
                    .frame(width: 16)
                Text(source.title)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                statusLine(iconsOnly: false)
                statusLine(iconsOnly: true)
            }
            .padding(.leading, 24)
        }
        .padding(.horizontal, Brand.spacing.s)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(isSelected ? Brand.color.accentSoft : (hovering ? Brand.color.cardAlt.opacity(0.55) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .help(source.title)
    }

    private func statusLine(iconsOnly: Bool) -> some View {
        HStack(spacing: 6) {
            StatusPill(status: source.status, progress: source.progress)
                .fixedSize()
            Spacer(minLength: 4)
            if source.status == .failed {
                if iconsOnly {
                    smallIcon("arrow.clockwise", help: L("sources.retry"), action: onRetry)
                } else {
                    Button(L("sources.retry"), action: onRetry)
                        .buttonStyle(.borderless)
                        .font(Brand.font(11, .medium))
                        .foregroundStyle(Brand.color.accent)
                        .lineLimit(1)
                        .fixedSize()
                }
                smallIcon("trash", help: L("sources.delete"), action: onDelete)
            }
        }
    }

    private func smallIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Brand.font(11))
                .foregroundStyle(Brand.color.text2)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// The right side while a source has no page yet: "Aprendiendo…" (or what failed, with the way out).
private struct ProcessingPanel: View {
    let source: SourceRecord
    var onRetry: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(spacing: Brand.spacing.m) {
            if source.status == .failed {
                Image(systemName: "exclamationmark.circle")
                    .font(Brand.font(32))
                    .foregroundStyle(Brand.color.danger)
            } else {
                BrandLoader(size: 32)
            }
            Text(source.title)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            StatusPill(status: source.status, progress: source.progress)
                .fixedSize()
            Text(message)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            if source.status.isInProgress, source.status != .recording, let progress = source.progress {
                ProgressView(value: progress)
                    .tint(Brand.color.accent)
                    .frame(maxWidth: 240)
            }
            if source.status == .failed {
                HStack(spacing: Brand.spacing.s) {
                    Button(L("sources.delete"), action: onDelete).buttonStyle(.brandSecondary)
                    Button(L("sources.retry"), action: onRetry).buttonStyle(.brandPrimary)
                }
                .padding(.top, Brand.spacing.xs)
            }
        }
        .padding(Brand.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.color.surface)
    }

    private var message: String {
        switch source.status {
        case .failed: SourceRow.failureText(source)
        case .recording: L("content.recordingHint")
        default: L("content.learningHint")
        }
    }
}

// MARK: - Brand segmented control

/// A two-to-four option switcher in brand colors: `cardAlt` track, selected = `card` with a hairline. Never wider
/// than its container; labels truncate.
struct BrandSegmentedControl<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let selected = value == selection
                Button {
                    withAnimation(Brand.motion.animation(fast: true)) { selection = value }
                } label: {
                    Text(title)
                        .font(Brand.font(12, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Brand.color.text : Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Brand.radius.control - 2, style: .continuous)
                                    .fill(Brand.color.card)
                                    .overlay(RoundedRectangle(cornerRadius: Brand.radius.control - 2, style: .continuous)
                                        .strokeBorder(Brand.color.line))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Brand.color.cardAlt, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
    }
}
