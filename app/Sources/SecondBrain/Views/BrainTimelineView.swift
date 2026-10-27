import BrainCore
import SwiftUI

/// Everything in the order it HAPPENED (meetings, emails, documents, decisions, milestones, due dates), grouped by
/// month and day. Standalone for Inicio ("Ver todo por fecha", every project); a project's Contenido tab shows the
/// same entries as a compact list (`ProjectContentView`).
struct BrainTimelineView: View {
    @Environment(AppState.self) private var state
    /// nil = every project.
    let projectSlug: String?
    /// Opens a page; the second value is the project the page belongs to (for the global timeline).
    var onOpen: (String, String?) -> Void

    @ViewState private var entries: [TimelineEntry] = []
    @ViewState private var loaded = false
    @ViewState private var kinds: Set<TimelineKind> = []

    private var presentKinds: [TimelineKind] { TimelineGroups.presentKinds(in: entries) }
    private var months: [TimelineGroups.Month] { TimelineGroups.months(entries, kinds: kinds) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !presentKinds.isEmpty {
                    filterBar(proxy)
                    Rectangle().fill(Brand.color.line).frame(height: 1)
                }
                if !loaded {
                    BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if months.isEmpty {
                    EmptyStateView(symbol: "calendar", title: L("timeline.emptyTitle"),
                                   message: entries.isEmpty ? L("timeline.emptyMessage") : L("timeline.allHidden"))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(months) { month in
                                SwiftUI.Section {
                                    ForEach(month.days) { day in
                                        dayView(day)
                                            .timelineAnchor(day.start, headerHeight: TimelineGroups.fullHeaderHeight)
                                    }
                                } header: {
                                    monthHeader(month)
                                }
                            }
                        }
                        .padding(.bottom, Brand.spacing.xxl)
                    }
                    .onAppear { scrollToAnchor(proxy, animated: false) }
                    .onChange(of: kinds) { scrollToAnchor(proxy, animated: false) }
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

    private func filterBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .top, spacing: Brand.spacing.m) {
            TimelineKindChips(kinds: presentKinds, selected: $kinds)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("timeline.today")) { scrollToAnchor(proxy, animated: true) }
                .buttonStyle(.brandSecondary)
                .controlSize(.small)
                .help(L("timeline.todayHelp"))
        }
        .padding(.horizontal, Brand.spacing.content)
        .padding(.vertical, Brand.spacing.m)
    }

    private func monthHeader(_ month: TimelineGroups.Month) -> some View {
        Text(TimelineGroups.monthTitle(month.start))
            .font(Brand.section)
            .foregroundStyle(Brand.color.text)
            .lineLimit(1)
            .padding(.horizontal, Brand.spacing.content)
            .frame(maxWidth: .infinity, minHeight: TimelineGroups.fullHeaderHeight, alignment: .leading)
            .background(Brand.color.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.color.line).frame(height: 1) }
            .id(TimelineGroups.MonthAnchor(start: month.start))
    }

    private func scrollToAnchor(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let target = TimelineGroups.anchorTarget(in: months) else { return }
        if animated {
            withAnimation(Brand.motion.animation()) { proxy.scrollTo(target, anchor: .top) }
        } else {
            proxy.scrollTo(target, anchor: .top)
        }
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

    /// Scroll targets: a day (its anchor sits a header's height above it) or a month header.
    struct DayAnchor: Hashable { let start: Date }
    struct MonthAnchor: Hashable { let start: Date }

    static let fullHeaderHeight: CGFloat = 40

    static func presentKinds(in entries: [TimelineEntry]) -> [TimelineKind] {
        let kinds = Set(entries.map(\.kind))
        return TimelineKind.allKinds.filter { kinds.contains($0) }
    }

    /// `kinds` empty = every kind.
    static func months(_ entries: [TimelineEntry], kinds: Set<TimelineKind>) -> [Month] {
        let cal = Calendar.current
        let visible = entries.filter { kinds.isEmpty || kinds.contains($0.kind) }.sorted { $0.date < $1.date }
        let byDay = Dictionary(grouping: visible) { cal.startOfDay(for: $0.date) }
        let days = byDay.keys.sorted().map { Day(start: $0, entries: byDay[$0] ?? []) }
        let byMonth = Dictionary(grouping: days) { cal.dateInterval(of: .month, for: $0.start)?.start ?? $0.start }
        return byMonth.keys.sorted().map { Month(start: $0, days: byMonth[$0] ?? []) }
    }

    static func monthTitle(_ date: Date) -> String {
        let text = Fmt.month(date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Where a timeline opens: the first day today or later (else the last one). The first day of a month scrolls
    /// to the month header itself, so the pinned header never hides it.
    static func anchorTarget(in months: [Month]) -> AnyHashable? {
        let today = Calendar.current.startOfDay(for: Date())
        let days = months.flatMap(\.days).map(\.start)
        guard let day = days.first(where: { $0 >= today }) ?? days.last else { return nil }
        if let month = months.first(where: { $0.days.first?.start == day }) { return AnyHashable(MonthAnchor(start: month.start)) }
        return AnyHashable(DayAnchor(start: day))
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
            Image(systemName: entry.kind.symbol)
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
