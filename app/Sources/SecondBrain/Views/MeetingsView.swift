import AppKit
import BrainCore
import SwiftUI

/// Sidebar "Reuniones" (CONTRACT §12.5, §12.7): the agenda of every connected calendar with a hero "Ahora / Siguiente"
/// card, one action per meeting that changes with time, and the detail (or "Prepararme") on the right.
struct MeetingsView: View {
    @Environment(AppState.self) private var state
    @ViewState private var segment: MeetingSegment = .today
    @ViewState private var selectedId: String?
    @ViewState private var prepEventId: String?
    @ViewState private var pageSheet: VaultPageItem?

    init(initialSegment: MeetingSegment = .today) {
        _segment = ViewState(initialValue: initialSegment)
    }

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        Group {
            if state.engine.accounts.accounts.isEmpty {
                ConnectAccountsEmptyState(symbol: "calendar", title: L("meetings.empty.title"),
                                          message: L("meetings.empty.message"), context: .meetings)
            } else {
                content
            }
        }
        .navigationTitle(L("meetings.title"))
        .navigationSubtitle(L("meetings.subtitle"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.refresh(state: state) } label: {
                    Label(L("meetings.refresh"), systemImage: "arrow.clockwise")
                }
                .help(L("meetings.refresh"))
                .disabled(state.engine.accounts.accounts.isEmpty)
            }
        }
        .task(id: state.accountsRevision) {
            // Fresh on every visit; the loop keeps it fresh every 15 minutes after that.
            if model.isRunning { model.refresh(state: state) } else { model.start(state: state) }
        }
        .onChange(of: state.vaultRevision) { model.reloadPeople(state: state) }
        .sheet(item: $pageSheet) { VaultPageSheet(path: $0.path) }
    }

    private var content: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                agenda
                    .frame(width: max(380, min(580, geo.size.width * 0.55)))
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Agenda

    private var agenda: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $segment) {
                    ForEach(MeetingSegment.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            MeetingOverrunBanner()
            if !model.accountErrors.isEmpty || model.error != nil {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.accountErrors.keys.sorted(), id: \.self) { key in
                        softError(model.accountErrors[key] ?? "")
                    }
                    if let error = model.error { softError(error) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                list(now: context.date)
            }
        }
    }

    private func softError(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func list(now: Date) -> some View {
        let hero = segment == .today ? model.hero(now: now) : nil
        // The hero card already shows its meeting: the list below holds the rest.
        let days = model.days(in: segment, now: now)
            .map { (day: $0.day, events: $0.events.filter { $0.id != hero?.event.id }) }
            .filter { !$0.events.isEmpty }
        if !model.loadedOnce {
            VStack(spacing: 10) {
                ProgressView()
                Text(L("meetings.loading")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if days.isEmpty && hero == nil {
            EmptyStateView(symbol: "calendar", title: L("meetings.nothing.title"), message: L("meetings.nothing.message"))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let hero {
                        MeetingHeroCard(event: hero.event, isNow: hero.isNow, isSelected: selectedEvent(now: now)?.id == hero.event.id,
                                        onSelect: { select(hero.event) }, onPrepare: { prepare(hero.event) },
                                        onShowPage: { pageSheet = VaultPageItem(path: $0) })
                            .padding(.bottom, 10)
                    }
                    if days.isEmpty {
                        Text(L("meetings.nothingMoreToday"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(days, id: \.day) { group in
                        Text(dayTitle(group.day))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                        ForEach(group.events) { event in
                            MeetingCard(event: event, isSelected: selectedEvent(now: now)?.id == event.id,
                                        onSelect: { select(event) }, onPrepare: { prepare(event) },
                                        onShowPage: { pageSheet = VaultPageItem(path: $0) })
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let long = Fmt.weekdayLong(day)
        switch Fmt.daysFromToday(day) {
        case 0: return L("date.today").capitalized + " · " + long
        case 1: return L("date.tomorrow").capitalized + " · " + long
        default: return long.prefix(1).uppercased() + long.dropFirst()
        }
    }

    private func select(_ event: CalendarEvent) {
        if selectedId != event.id { prepEventId = nil }
        selectedId = event.id
    }

    private func prepare(_ event: CalendarEvent) {
        selectedId = event.id
        prepEventId = event.id
    }

    /// The chosen event; by default the hero (now / next), else the first one.
    private func selectedEvent(now: Date) -> CalendarEvent? {
        model.event(id: selectedId) ?? model.hero(now: now)?.event ?? model.events(in: segment, now: now).first
    }

    // MARK: Detail

    @ViewBuilder private var detailPane: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let event = selectedEvent(now: context.date) {
                if prepEventId == event.id {
                    MeetingPrepView(event: event, onClose: { prepEventId = nil },
                                    onShowPage: { pageSheet = VaultPageItem(path: $0) })
                        .id(event.id)
                } else {
                    MeetingDetail(event: event, onPrepare: { prepare(event) },
                                  onShowPage: { pageSheet = VaultPageItem(path: $0) })
                        .id(event.id)
                }
            } else if model.loadedOnce {
                EmptyStateView(symbol: "calendar.badge.clock", title: L("meetings.pick"), message: "")
            }
        }
    }
}

// MARK: - Hero

/// "Ahora / Siguiente" at the top of Hoy, with a live countdown and the meeting's one action.
struct MeetingHeroCard: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    let isNow: Bool
    var isSelected = false
    var onSelect: () -> Void
    var onPrepare: () -> Void
    var onShowPage: (String) -> Void

    private var tint: Color { isNow ? .red : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(isNow ? L("meetings.now") : L("meetings.next"))
                    .font(.caption.weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MeetingTimes.countdown(event, now: context.date))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                MeetingProjectChip(event: event)
            }
            Text(event.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 12) {
                Label(MeetingTimes.range(event), systemImage: "clock")
                if let place = event.location, !place.isEmpty {
                    Label(place, systemImage: event.joinURL != nil ? "video" : "mappin.and.ellipse").lineLimit(1)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                MeetingActionButton(event: event, large: true, onPrepare: onPrepare, onShowPage: onShowPage)
                if let join = event.joinURL, JoinLink.isSafe(join) {
                    Button { NSWorkspace.shared.open(join) } label: {
                        Label(L("meetings.join"), systemImage: "video.fill")
                    }
                    .controlSize(.large)
                }
                Spacer(minLength: 8)
                AttendeeInitials(attendees: MeetingsModel.shared.others(in: event), size: 26)
            }
        }
        .padding(16)
        .background(tint.opacity(isSelected ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.3), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onSelect)
    }
}

/// Human times for meetings.
enum MeetingTimes {
    /// "45 min", "1 h", "1 h 30 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60, minutes % 60 == 0 { return L("meetings.hours", minutes / 60) }
        return Fmt.shortDuration(seconds)
    }

    /// "10:20 – 11:20" (or "Todo el día").
    static func range(_ e: CalendarEvent) -> String {
        e.isAllDay ? L("meetings.allDay") : "\(Fmt.time(e.start)) – \(Fmt.time(e.end))"
    }

    /// "hoy 10:20 – 11:20 · 1 h 0 min" / "mañana · todo el día".
    static func when(_ e: CalendarEvent) -> String {
        if e.isAllDay { return Fmt.relativeDay(e.start).meetingCapitalized + " · " + L("meetings.allDay").lowercased() }
        return Fmt.dayTime(e.start).meetingCapitalized + " – " + Fmt.time(e.end) + " · " + duration(e.end.timeIntervalSince(e.start))
    }

    /// "empieza en 12 min" · "empezó hace 3 min · quedan 47 min" · "terminó hace 2 min" · "mañana 9:30".
    static func countdown(_ e: CalendarEvent, now: Date) -> String {
        if now < e.start {
            let wait = e.start.timeIntervalSince(now)
            if wait > 12 * 3600 { return Fmt.dayTime(e.start) }
            return L("meetings.startsIn", duration(wait))
        }
        if now <= e.end {
            return L("meetings.startedAgo", duration(now.timeIntervalSince(e.start)))
                + " · " + L("meetings.left", duration(e.end.timeIntervalSince(now)))
        }
        return L("meetings.endedAgo", duration(now.timeIntervalSince(e.end)))
    }
}

extension String {
    var meetingCapitalized: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Detail

/// Right pane: when, who (names open their people page), the invitation notes, Unirme and the meeting's action.
struct MeetingDetail: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    var onPrepare: () -> Void
    var onShowPage: (String) -> Void

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Label(MeetingTimes.when(event), systemImage: "calendar")
                        .foregroundStyle(.secondary)
                    if let place = event.location, !place.isEmpty {
                        Label(place, systemImage: event.joinURL != nil ? "video" : "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                    }
                    MeetingProjectChip(event: event).padding(.top, 2)
                }

                HStack(spacing: 10) {
                    MeetingActionButton(event: event, large: true, onPrepare: onPrepare, onShowPage: onShowPage)
                    if let join = event.joinURL, JoinLink.isSafe(join) {
                        Button { NSWorkspace.shared.open(join) } label: {
                            Label(L("meetings.join"), systemImage: "video.fill")
                        }
                        .controlSize(.large)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let phase = model.phase(of: event, state: state, now: context.date)
                        if phase == .recordable || phase == .recording {
                            Button(action: onPrepare) { Label(L("meetings.prepare"), systemImage: "sparkles") }
                                .buttonStyle(.link)
                        }
                    }
                }

                section(L("meetings.who")) {
                    let people = event.attendees
                    if people.isEmpty {
                        Text(L("meetings.noAttendees")).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(people.enumerated()), id: \.offset) { _, person in attendeeRow(person) }
                        }
                    }
                }

                if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    section(L("meetings.notes")) {
                        LinkedText(text: notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let web = JoinLink.https(event.webLink) {
                    Link(destination: web) {
                        Label(L("meetings.openInCalendar"), systemImage: "arrow.up.forward.square")
                    }
                    .font(.callout)
                }
            }
            .padding(22)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func attendeeRow(_ a: EmailAddress) -> some View {
        let path = model.personPath(for: a)
        let isMe = a.email.map { model.myEmails.contains($0.lowercased()) } ?? false
        let isOrganizer = a.email != nil && a.email?.lowercased() == event.organizer?.email?.lowercased()
        return HStack(spacing: 10) {
            InitialsCircle(address: a, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let path {
                        Button(a.name ?? a.display) { onShowPage(path) }
                            .buttonStyle(.link)
                            .help(L("meetings.openPerson"))
                    } else {
                        Text(a.name ?? a.display)
                    }
                    if isMe { Text(L("meetings.you")).font(.caption).foregroundStyle(.secondary) }
                    if isOrganizer { Text(L("meetings.organizer")).font(.caption).foregroundStyle(.secondary) }
                }
                if let email = a.email, a.name != nil {
                    Text(email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }
}
