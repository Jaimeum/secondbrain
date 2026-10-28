import BrainCore
import SwiftUI

/// A project's "Resumen" tab (CONTRACT §16.2), its default: the project's ficha (§16.4). On the left "En breve"
/// (`overview.md`, rendered, editable); on the right, in one scrolling column: recent decisions (5), upcoming dates
/// (future milestones and deadlines of the timeline), people (avatars → their ficha filtered to the project), recent
/// activity (5 sources) and my open tasks (3, "Ver todos →" Pendientes). Every element is clickable.
struct ProjectSummaryView: View {
    @Environment(AppState.self) private var state
    let project: Project
    /// A page of the project or anything else (ProjectView's single click rule).
    var onOpen: (String) -> Void = { _ in }

    @ViewState private var snapshot: EntityIndex.Snapshot = .empty
    @ViewState private var entries: [TimelineEntry] = []
    @ViewState private var loaded = false
    @ViewState private var paneHeight: CGFloat = 0

    private var slug: String { project.slug }
    private var overview: String? { snapshot.overviewPath(ofProject: slug) }

    var body: some View {
        VStack(spacing: 0) {
            // v0.7 (§17.3): "Agregar al proyecto", at the top — at most 45 % of the tab, so the brief keeps its room.
            ProjectDropBox(project: project, maxHeight: paneHeight > 0 ? (paneHeight * 0.45).rounded() : .infinity)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    brief.frame(maxWidth: .infinity, maxHeight: .infinity)
                    BrandColumnDivider()
                    sideColumn.frame(width: Self.sideWidth(for: geo.size.width))
                }
            }
        }
        .background(Brand.color.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        .task(id: "\(state.vaultRevision)-\(state.tasksRevision)-\(state.projects.hashValue)") { await reload() }
    }

    static func sideWidth(for total: CGFloat) -> CGFloat { min(340, max(290, (total * 0.36).rounded())) }

    // MARK: En breve

    @ViewBuilder private var brief: some View {
        VStack(spacing: 0) {
            HStack(spacing: Brand.spacing.s) {
                Text(L("summary.brief"))
                    .font(Brand.font(11, .semibold))
                    .foregroundStyle(Brand.color.text2)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Spacer(minLength: Brand.spacing.s)
                if let overview {
                    Button { state.editPage(overview) } label: {
                        Label(L("entity.edit"), systemImage: "pencil").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.brandGhost)
                    .help(L("entity.editHelp"))
                }
            }
            .padding(.horizontal, Brand.spacing.l)
            .frame(height: 44)
            if let overview {
                WikiWebView(vault: state.engine.vault, path: overview, hideType: true, showsChrome: false) { onOpen($0) }
            } else if loaded {
                EmptyStateView(symbol: "sparkles", title: L("summary.noBriefTitle"), message: L("summary.noBriefMessage"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Side column

    private var decisions: [Entity] { Array(snapshot.decisions(ofProject: slug).prefix(5)) }

    private var upcoming: [TimelineEntry] {
        let today = Calendar.current.startOfDay(for: Date())
        return Array(entries.filter { $0.date >= today && $0.kind != .task }.sorted { $0.date < $1.date }.prefix(5))
    }

    private var activity: [TimelineEntry] {
        let kinds: Set<TimelineKind> = [.meeting, .email, .document, .note, .url]
        let now = Date()
        return Array(entries.filter { kinds.contains($0.kind) && $0.date <= now && $0.pagePath != nil }
            .sorted { $0.date > $1.date }.prefix(5))
    }

    private var people: [ProjectPerson] { snapshot.people(ofProject: slug) }

    private var myTasks: [TaskItem] {
        snapshot.tasks.filter { $0.projectSlug == slug && $0.isMine && !$0.done }
            .sorted { ($0.due ?? .distantFuture, $0.text) < ($1.due ?? .distantFuture, $1.text) }
    }

    private var sideColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.spacing.l) {
                if !project.description.isEmpty {
                    Text(project.description)
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !decisions.isEmpty {
                    section(L("summary.decisions")) {
                        ForEach(decisions) { d in
                            ContentListRow(symbol: "checkmark.seal", title: d.title, caption: date(d.eventDate)) { onOpen(d.path) }
                        }
                    }
                }
                if !upcoming.isEmpty {
                    section(L("summary.upcoming")) {
                        ForEach(upcoming) { e in
                            ContentListRow(symbol: TimelineStyle.symbol(e.kind), title: e.title,
                                           caption: SBDate.human(e.date, hasTime: e.hasTime, language: state.config.uiLanguage)) {
                                if let p = e.pagePath { onOpen(p) }
                            }
                        }
                    }
                }
                if !people.isEmpty {
                    section(L("sidebar.people"), more: L("summary.seeAll")) {
                        state.navigate(to: .projectTab(slug, .people))
                    } content: {
                        WrapLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(people.prefix(12)) { person in
                                Button { onOpen(person.path) } label: {
                                    InitialsCircle(address: EmailAddress(name: person.title, email: nil), size: 30, ring: .clear)
                                }
                                .buttonStyle(.plain)
                                .help([person.title, person.role].compactMap { $0 }.joined(separator: " · "))
                                .accessibilityLabel(Text(person.title))
                            }
                        }
                    }
                }
                if !activity.isEmpty {
                    section(L("summary.activity"), more: L("summary.seeAll")) {
                        state.navigate(to: .projectTab(slug, .content))
                    } content: {
                        ForEach(activity) { e in
                            ContentListRow(symbol: TimelineStyle.symbol(e.kind), title: e.title,
                                           caption: SBDate.human(e.date, hasTime: false, language: state.config.uiLanguage)) {
                                if let p = e.pagePath { onOpen(p) }
                            }
                        }
                    }
                }
                if !myTasks.isEmpty {
                    section(L("summary.myTasks"), more: L("summary.seeAll")) {
                        state.navigate(to: .projectTab(slug, .tasks))
                    } content: {
                        ForEach(myTasks.prefix(3)) { t in
                            ContentListRow(symbol: "circle", title: t.text,
                                           caption: t.due.map { SBDate.human($0, hasTime: false, language: state.config.uiLanguage) }) {
                                state.navigate(to: .task(t.id))
                            }
                        }
                    }
                }
                if loaded && decisions.isEmpty && upcoming.isEmpty && people.isEmpty && activity.isEmpty && myTasks.isEmpty {
                    Text(L("summary.nothingYet"))
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Brand.spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, more: String? = nil, onMore: (() -> Void)? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Brand.spacing.xs) {
            HStack(spacing: Brand.spacing.s) {
                Text(title)
                    .font(Brand.font(11, .semibold))
                    .foregroundStyle(Brand.color.text2)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Brand.spacing.s)
                if let more, let onMore { HomeLink(title: more, action: onMore) }
            }
            .padding(.horizontal, Brand.spacing.s)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func date(_ d: Date?) -> String? {
        d.map { SBDate.human($0, hasTime: false, language: state.config.uiLanguage) }
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let root = state.engine.vault.root
        async let snap = EntityIndex.snapshot(vaultRoot: root)
        let list = await state.engine.timeline(projectSlug: slug)
        let loadedSnap = await snap
        guard !Task.isCancelled else { return }
        snapshot = loadedSnap
        entries = list
        loaded = true
    }
}

/// Symbols of timeline kinds (Resumen's dates and activity).
enum TimelineStyle {
    static func symbol(_ kind: TimelineKind) -> String {
        switch kind {
        case .meeting: "waveform"
        case .email: "envelope"
        case .document: "doc.text"
        case .note: "note.text"
        case .url: "link"
        case .decision: "checkmark.seal"
        case .milestone: "flag"
        case .task: "checklist"
        }
    }
}
