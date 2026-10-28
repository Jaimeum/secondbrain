import BrainCore
import SwiftUI

/// Everything in the order it HAPPENED (meetings, emails, documents, decisions, milestones, due dates): newest first,
/// grouped by month and day, with what is still ahead (due dates, milestones) in a short "Próximo" group on top. Opens
/// on the most recent content. Standalone for Inicio ("Ver todo por fecha", every project); a project's Contenido tab
/// shows the same feed as a compact list (`ProjectContentView`).
struct BrainTimelineView: View {
    @Environment(AppState.self) private var state
    /// nil = every project.
    let projectSlug: String?
    /// Opens a page; the second value is the project the page belongs to (for the global timeline).
    var onOpen: (String, String?) -> Void

    @ViewState private var entries: [TimelineEntry] = []
    @ViewState private var loaded = false
    @ViewState private var kinds: Set<TimelineKind> = []
    @ViewState private var showAllUpcoming = false

    var body: some View {
        let presentKinds = TimelineGroups.presentKinds(in: entries)
        let feed = TimelineGroups.feed(entries, kinds: kinds)
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !presentKinds.isEmpty {
                    filterBar(presentKinds, proxy)
                    Rectangle().fill(Brand.color.line).frame(height: 1)
                }
                if !loaded {
                    BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if feed.isEmpty {
                    EmptyStateView(symbol: "calendar", title: L("timeline.emptyTitle"),
                                   message: entries.isEmpty ? L("timeline.emptyMessage") : L("timeline.allHidden"))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Color.clear.frame(height: 0).id(TimelineGroups.topAnchor)
                            if !feed.upcoming.isEmpty {
                                let shown = showAllUpcoming ? feed.upcoming : TimelineGroups.prefix(feed.upcoming, entries: 3)
                                SwiftUI.Section {
                                    ForEach(shown) { day in dayView(day) }
                                    let total = feed.upcomingCount
                                    if total > 3 {
                                        Button(showAllUpcoming ? L("content.showLess") : L("home.seeAllTasks", total)) {
                                            withAnimation(Brand.motion.animation(fast: true)) { showAllUpcoming.toggle() }
                                        }
                                        .buttonStyle(.borderless)
                                        .font(Brand.caption)
                                        .foregroundStyle(Brand.color.accent)
                                        .padding(.horizontal, Brand.spacing.content + 80)
                                        .padding(.bottom, Brand.spacing.s)
                                    }
                                } header: {
                                    sectionHeader(L("timeline.upcoming"))
                                }
                            }
                            ForEach(feed.months) { month in
                                SwiftUI.Section {
                                    ForEach(month.days) { day in
                                        dayView(day)
                                            .timelineAnchor(day.start, headerHeight: TimelineGroups.fullHeaderHeight)
                                    }
                                } header: {
                                    sectionHeader(TimelineGroups.monthTitle(month.start))
                                        .id(TimelineGroups.MonthAnchor(start: month.start))
                                }
                            }
                        }
                        .padding(.bottom, Brand.spacing.xxl)
                    }
                    .onChange(of: kinds) { proxy.scrollTo(TimelineGroups.topAnchor, anchor: .top) }
                }
            }
        }
        .background(Brand.color.surface)
        .task(id: state.vaultRevision) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                await reload()
            }
        }
    }

    /// Kind chips, and "Hoy" as a chip of the same set (back to the top: the newest content).
    private func filterBar(_ presentKinds: [TimelineKind], _ proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .top, spacing: Brand.spacing.m) {
            TimelineKindChips(kinds: presentKinds, selected: $kinds)
                .frame(maxWidth: .infinity, alignment: .leading)
            FilterChip(title: L("timeline.today"), symbol: "calendar", isOn: false) {
                withAnimation(Brand.motion.animation()) { proxy.scrollTo(TimelineGroups.topAnchor, anchor: .top) }
            }
            .fixedSize()
            .help(L("timeline.todayHelp"))
        }
        .padding(.horizontal, Brand.spacing.content)
        .padding(.vertical, Brand.spacing.m)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Brand.section)
            .foregroundStyle(Brand.color.text)
            .lineLimit(1)
            .padding(.horizontal, Brand.spacing.content)
            .frame(maxWidth: .infinity, minHeight: TimelineGroups.fullHeaderHeight, alignment: .leading)
            .background(Brand.color.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.color.line).frame(height: 1) }
    }

    @ViewBuilder private func dayView(_ day: TimelineGroups.Day) -> some View {
        let isToday = Calendar.current.isDateInToday(day.start)
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(day.start.formatted(.dateTime.day().locale(Localizer.locale)))
                    .font(Brand.font(20, .semibold).monospacedDigit())
                    .foregroundStyle(isToday ? Brand.color.accent : Brand.color.text)
                Text(day.start.formatted(.dateTime.weekday(.abbreviated).locale(Localizer.locale)))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                if isToday {
                    Text(L("date.today"))
                        .font(Brand.font(10, .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.color.accent)
                }
            }
            .frame(width: 52, alignment: .trailing)

            // The vertical line with one dot per entry.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(day.entries) { entry in
                    EntryRow(entry: entry, showProject: projectSlug == nil) { open(entry) }
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Rectangle().fill(Brand.color.line).frame(width: 2)
            }
        }
        .padding(.horizontal, Brand.spacing.content)
        .padding(.vertical, Brand.spacing.s)
    }

    private func open(_ entry: TimelineEntry) {
        if let path = entry.pagePath {
            onOpen(path, entry.projectSlug)
            return
        }
        guard let id = entry.sourceId, let source = state.engine.source(id) else { return }
        SourceOpener.openSummary(source, state: state) { onOpen($0, source.projectSlug) }
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let list = await state.engine.timeline(projectSlug: projectSlug)
        guard !Task.isCancelled else { return }
        if list != entries { entries = list }
        loaded = true
    }
}

// MARK: - Grouping shared with Contenido

enum TimelineGroups {
    struct Day: Identifiable {
        let start: Date
        let entries: [TimelineEntry]
        var id: Date { start }
    }

    struct Month: Identifiable {
        let start: Date
        let days: [Day]
        var id: Date { start }
    }

    /// What a date list shows: `upcoming` = days after today, soonest first ("Próximo"); `months` = today and before,
    /// newest month, day and entry first (the list opens on the most recent content).
    struct Feed {
        let upcoming: [Day]
        let months: [Month]
        var isEmpty: Bool { upcoming.isEmpty && months.isEmpty }
        var upcomingCount: Int { upcoming.reduce(0) { $0 + $1.entries.count } }
    }

    /// Scroll targets: a day (its anchor sits a header's height above it), a month header, the top of the list.
    struct DayAnchor: Hashable { let start: Date }
    struct MonthAnchor: Hashable { let start: Date }
    static let topAnchor = "timeline.top"

    static let fullHeaderHeight: CGFloat = 40

    static func presentKinds(in entries: [TimelineEntry]) -> [TimelineKind] {
        let kinds = Set(entries.map(\.kind))
        return TimelineKind.allKinds.filter { kinds.contains($0) }
    }

    /// `kinds` empty = every kind.
    static func feed(_ entries: [TimelineEntry], kinds: Set<TimelineKind>, now: Date = Date()) -> Feed {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let visible = entries.filter { kinds.isEmpty || kinds.contains($0.kind) }
        let byDay = Dictionary(grouping: visible) { cal.startOfDay(for: $0.date) }
        let upcoming = byDay.keys.filter { $0 >= tomorrow }.sorted()
            .map { Day(start: $0, entries: (byDay[$0] ?? []).sorted { $0.date < $1.date }) }
        let past = byDay.keys.filter { $0 < tomorrow }.sorted(by: >)
            .map { Day(start: $0, entries: (byDay[$0] ?? []).sorted { $0.date > $1.date }) }
        let byMonth = Dictionary(grouping: past) { cal.dateInterval(of: .month, for: $0.start)?.start ?? $0.start }
        let months = byMonth.keys.sorted(by: >).map { Month(start: $0, days: (byMonth[$0] ?? []).sorted { $0.start > $1.start }) }
        return Feed(upcoming: upcoming, months: months)
    }

    /// The first days holding at most `entries` entries (always at least one day).
    static func prefix(_ days: [Day], entries limit: Int) -> [Day] {
        var left = limit
        var out: [Day] = []
        for day in days where left > 0 {
            let taken = Array(day.entries.prefix(left))
            out.append(Day(start: day.start, entries: taken))
            left -= taken.count
        }
        return out
    }

    static func monthTitle(_ date: Date) -> String {
        let text = Fmt.month(date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension View {
    /// An invisible scroll target `headerHeight` above the view (placed by an alignment guide, so it moves in layout,
    /// not just visually): scrolling it to the top leaves the view just below a pinned header.
    func timelineAnchor(_ day: Date, headerHeight: CGFloat) -> some View {
        overlay(alignment: .top) {
            Color.clear
                .frame(height: 1)
                .alignmentGuide(.top) { _ in headerHeight }
                .id(TimelineGroups.DayAnchor(start: day))
                .accessibilityHidden(true)
        }
    }
}

/// Neutral kind chips that wrap; tapping one shows only that kind (active = `accentSoft`); none active = all.
struct TimelineKindChips: View {
    let kinds: [TimelineKind]
    @Binding var selected: Set<TimelineKind>

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(kinds, id: \.self) { kind in
                FilterChip(title: kind.label, symbol: kind.symbol, isOn: selected.contains(kind)) {
                    if selected.contains(kind) { selected.remove(kind) } else { selected.insert(kind) }
                }
            }
        }
    }
}

/// The same filter as a menu (narrow lists).
struct TimelineKindMenu: View {
    let kinds: [TimelineKind]
    @Binding var selected: Set<TimelineKind>

    var body: some View {
        Menu {
            Button {
                selected = []
            } label: {
                if selected.isEmpty { Label(L("timeline.allKinds"), systemImage: "checkmark") } else { Text(L("timeline.allKinds")) }
            }
            Divider()
            ForEach(kinds, id: \.self) { kind in
                Button {
                    if selected.contains(kind) { selected.remove(kind) } else { selected.insert(kind) }
                } label: {
                    if selected.contains(kind) { Label(kind.label, systemImage: "checkmark") } else { Text(kind.label) }
                }
            }
        } label: {
            BrandChip(text: label, symbol: "line.3.horizontal.decrease", active: !selected.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("timeline.filterHelp"))
    }

    private var label: String {
        if selected.isEmpty { return L("timeline.allKinds") }
        if selected.count == 1, let kind = selected.first { return kind.label }
        return L("timeline.someKinds", selected.count)
    }
}

private struct EntryRow: View {
    @Environment(AppState.self) private var state
    let entry: TimelineEntry
    let showProject: Bool
    var onTap: () -> Void

    @ViewState private var hovering = false

    private var addedLater: Bool {
        guard let added = entry.addedAt else { return false }
        return added.timeIntervalSince(entry.date) > 36 * 3600
    }

    private var clickable: Bool { entry.pagePath != nil || entry.sourceId != nil }
    private var fromCalendar: Bool { entry.sourceId.flatMap { state.engine.source($0)?.calendarEventId } != nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.symbol(engine: state.engine))
                .font(Brand.font(12, .medium))
                .foregroundStyle(Brand.color.text2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Brand.color.card))
                .overlay(Circle().strokeBorder(Brand.color.line))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }   // an image has no text baseline
                .offset(x: -28)
                .padding(.trailing, -28)
                .help(entry.kind.label)
                .accessibilityLabel(Text(entry.kind.label))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if entry.hasTime {
                        Text(Fmt.time(entry.date))
                            .font(Brand.body.monospacedDigit())
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                    }
                    Text(entry.title)
                        .font(entry.kind == .meeting || entry.kind == .email || entry.kind == .milestone ? Brand.callout : Brand.body)
                        .foregroundStyle(Brand.color.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if fromCalendar {
                        Image(systemName: "calendar")
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text3)
                            .help(L("content.fromCalendar"))
                    }
                }
                if (showProject && state.project(entry.projectSlug) != nil) || addedLater {
                    HStack(spacing: 6) {
                        if showProject, let project = state.project(entry.projectSlug) {
                            BrandChip(text: "\(project.emoji) \(project.name)")
                        }
                        if addedLater, let added = entry.addedAt {
                            BrandChip(text: L("timeline.addedLater", Fmt.dayTime(added, hasTime: false)), symbol: "clock.arrow.circlepath")
                                .help(L("timeline.addedLaterHelp"))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if clickable {
                Image(systemName: "chevron.right")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text3)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(hovering && clickable ? Brand.color.cardAlt.opacity(0.55) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if clickable { onTap() } }
        .help(clickable ? L("timeline.open") : "")
    }
}

/// A neutral filter chip (`BrandChip`; on = `accentSoft`).
struct FilterChip: View {
    let title: String
    var symbol: String? = nil
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            BrandChip(text: title, symbol: symbol, active: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
