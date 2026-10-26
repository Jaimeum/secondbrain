import BrainCore
import SwiftUI

/// "Línea de tiempo": everything in the order it HAPPENED (meetings, emails, documents, decisions, milestones,
/// due dates), grouped by month and day. Shows when something was added much later than it happened.
struct BrainTimelineView: View {
    @Environment(AppState.self) private var state
    /// nil = every project ("Todo el cerebro").
    let projectSlug: String?
    /// Opens a page; the second value is the project the page belongs to (for the global timeline).
    var onOpen: (String, String?) -> Void

    @ViewState private var entries: [TimelineEntry] = []
    @ViewState private var loaded = false
    @ViewState private var hidden: Set<TimelineKind> = []

    private struct Day: Identifiable {
        let start: Date
        let entries: [TimelineEntry]
        var id: Date { start }
    }

    private struct Month: Identifiable {
        let start: Date
        let days: [Day]
        var id: Date { start }
    }

    private var presentKinds: [TimelineKind] {
        let kinds = Set(entries.map(\.kind))
        return TimelineKind.allKinds.filter { kinds.contains($0) }
    }

    private var months: [Month] {
        let cal = Calendar.current
        let visible = entries.filter { !hidden.contains($0.kind) }.sorted { $0.date < $1.date }
        let byDay = Dictionary(grouping: visible) { cal.startOfDay(for: $0.date) }
        let days = byDay.keys.sorted().map { Day(start: $0, entries: byDay[$0] ?? []) }
        let byMonth = Dictionary(grouping: days) { cal.dateInterval(of: .month, for: $0.start)?.start ?? $0.start }
        return byMonth.keys.sorted().map { Month(start: $0, days: byMonth[$0] ?? []) }
    }

    /// The first day today or later: where the list opens.
    private var anchorDay: Date? {
        let today = Calendar.current.startOfDay(for: Date())
        let days = months.flatMap(\.days).map(\.start)
        return days.first { $0 >= today } ?? days.last
    }

    var body: some View {
        VStack(spacing: 0) {
            if !presentKinds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presentKinds, id: \.self) { kind in
                            FilterChip(title: "\(kind.emoji) \(kind.label)", isOn: !hidden.contains(kind)) {
                                if hidden.contains(kind) { hidden.remove(kind) } else { hidden.insert(kind) }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                Divider()
            }
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if months.isEmpty {
                EmptyStateView(symbol: "calendar", title: L("timeline.emptyTitle"),
                               message: entries.isEmpty ? L("timeline.emptyMessage") : L("timeline.allHidden"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(months) { month in
                                SwiftUI.Section {
                                    ForEach(month.days) { day in
                                        dayView(day).id(day.start)
                                    }
                                } header: {
                                    Text(Fmt.month(month.start).prefix(1).uppercased() + Fmt.month(month.start).dropFirst())
                                        .font(.title3.weight(.semibold))
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.bar)
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .onAppear {
                        if let anchorDay { proxy.scrollTo(anchorDay, anchor: .top) }
                    }
                }
            }
        }
        .task(id: state.vaultRevision) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                await reload()
            }
        }
    }

    @ViewBuilder private func dayView(_ day: Day) -> some View {
        let isToday = Calendar.current.isDateInToday(day.start)
        let isFuture = day.start > Date()
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(day.start.formatted(.dateTime.day().locale(Localizer.locale)))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isToday ? Color.accentColor : .primary)
                Text(day.start.formatted(.dateTime.weekday(.abbreviated).locale(Localizer.locale)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isToday {
                    Text(L("date.today")).font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 52, alignment: .trailing)

            // The vertical line with one dot per entry.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(day.entries) { entry in
                    EntryRow(entry: entry, showProject: projectSlug == nil, isFuture: isFuture) {
                        open(entry)
                    }
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func open(_ entry: TimelineEntry) {
        if let path = entry.pagePath {
            onOpen(path, entry.projectSlug)
            return
        }
        guard let id = entry.sourceId, let source = state.engine.source(id) else { return }
        let vault = state.engine.vault
        Task {
            let page = await Task.detached { SourcePages.summaryPage(for: source, vault: vault) }.value
            if let path = page ?? source.rawPath { onOpen(path, source.projectSlug) }
        }
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let list = await state.engine.timeline(projectSlug: projectSlug)
        guard !Task.isCancelled else { return }
        if list != entries { entries = list }
        loaded = true
    }
}

private struct EntryRow: View {
    @Environment(AppState.self) private var state
    let entry: TimelineEntry
    let showProject: Bool
    let isFuture: Bool
    var onTap: () -> Void

    @ViewState private var hovering = false

    private var addedLater: Bool {
        guard let added = entry.addedAt else { return false }
        return added.timeIntervalSince(entry.date) > 36 * 3600
    }

    private var clickable: Bool { entry.pagePath != nil || entry.sourceId != nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.kind.emoji)
                .font(.system(size: 14))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                .offset(x: -28)
                .padding(.trailing, -28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if entry.hasTime {
                        Text(Fmt.time(entry.date)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    // v0.3: 📅 = recorded from a calendar event
                    Text(entry.title + (entry.sourceId.flatMap { state.engine.source($0)?.calendarEventId } != nil ? " 📅" : ""))
                        .font(.body.weight(entry.kind == .meeting || entry.kind == .email || entry.kind == .milestone ? .medium : .regular))
                        .foregroundStyle(entry.kind == .task && isFuture ? Color.orange : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(entry.kind.label).font(.caption).foregroundStyle(.secondary)
                    if showProject, let project = state.project(entry.projectSlug) {
                        Chip(text: "\(project.emoji) \(project.name)")
                    }
                    if addedLater, let added = entry.addedAt {
                        Chip(text: L("timeline.addedLater", Fmt.dayTime(added, hasTime: false)), tint: .orange,
                             symbol: "clock.arrow.circlepath")
                            .help(L("timeline.addedLaterHelp"))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering && clickable ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if clickable { onTap() } }
        .help(clickable ? L("timeline.open") : "")
    }
}

struct FilterChip: View {
    let title: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
                .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.5) : .clear))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
