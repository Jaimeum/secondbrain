import AppKit
import BrainCore
import SwiftUI

/// Sidebar "Reuniones" (CONTRACT §12.7, §15.2): segments Hoy · Próximas · Anteriores. Hoy has the hero "Ahora /
/// Siguiente" card; Próximas is grouped by day; Anteriores lists recorded meetings (no calendar needed). The detail
/// (or "Prepararme") sits on the right, or is pushed when the screen is narrower than `singleColumnBelow`.
struct MeetingsView: View {
    @Environment(AppState.self) private var state
    @ViewState private var segment: MeetingSegment = .today
    @ViewState private var selectedId: String?
    @ViewState private var prepEventId: String?
    @ViewState private var pageSheet: VaultPageItem?
    /// Single-column mode: the event whose detail is pushed.
    @ViewState private var pushedId: String?
    @ViewState private var isNarrow = false
    /// The header loader shows only when a refresh takes longer than a moment (no flicker on every visit).
    @ViewState private var showsLoader = false

    /// Below this width list and detail become one column with push (§15.2).
    static let singleColumnBelow: CGFloat = 700

    init(initialSegment: MeetingSegment = .today) {
        _segment = ViewState(initialValue: initialSegment)
    }

    private var model: MeetingsModel { MeetingsModel.shared }
    private var hasAccounts: Bool { !state.engine.accounts.accounts.isEmpty }

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < Self.singleColumnBelow
            Group {
                if narrow {
                    NavigationStack {
                        agenda
                            .navigationDestination(item: $pushedId) { id in pushedDetail(id) }
                    }
                } else {
                    split(width: geo.size.width)
                }
            }
            .onChange(of: narrow, initial: true) { isNarrow = narrow }
        }
        .background(Brand.color.surface)
        .navigationTitle(L("meetings.title"))
        .toolbar {
            ToolbarItem { RulesToolbarButton() }   // MARK: v0.4 rules
            ToolbarItem(placement: .primaryAction) {
                Button { model.refresh(state: state) } label: {
                    Label(L("meetings.refresh"), systemImage: "arrow.clockwise")
                }
                .help(L("meetings.refresh"))
                .disabled(!hasAccounts)
            }
        }
        .task(id: state.accountsRevision) {
            // Fresh on every visit; the loop keeps it fresh every 15 minutes after that.
            if model.isRunning { model.refresh(state: state) } else { model.start(state: state) }
        }
        .task(id: model.isLoading) {
            guard model.isLoading else { showsLoader = false; return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { showsLoader = model.isLoading }
        }
        .onChange(of: state.vaultRevision) { model.reloadPeople(state: state) }
        .onChange(of: segment) { segmentChanged() }
        .onAppear { consumePendingEvent() }
        .onChange(of: state.pendingEventId) { consumePendingEvent() }
        .onChange(of: model.loadedOnce) { consumePendingEvent() }
        .sheet(item: $pageSheet) { VaultPageSheet(path: $0.path) }
    }

    // MARK: Layout

    @ViewBuilder private func split(width: CGFloat) -> some View {
        if showsDetailColumn {
            HStack(spacing: 0) {
                agenda
                    .frame(width: min(520, max(320, (width * 0.46).rounded())))
                Rectangle().fill(Brand.color.line).frame(width: 1)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // Nothing to pick (Anteriores, no calendar, empty agenda): one full-width column, one empty state.
            agenda
        }
    }

    /// Two columns only when there is an event to show on the right.
    private var showsDetailColumn: Bool {
        guard segment != .past, hasAccounts, model.loadedOnce else { return false }
        let now = Date()
        return !visibleEvents(now: now).isEmpty
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
                .frame(maxWidth: 340)
                Spacer(minLength: 8)
                if showsLoader && segment != .past {
                    BrandLoader(size: 16)
                        .help(L("meetings.loading"))
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .animation(Brand.motion.fast, value: showsLoader)
            if segment != .past {
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
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            if segment == .past {
                pastList
            } else if !hasAccounts {
                ConnectAccountsEmptyState(symbol: "calendar", title: L("meetings.empty.title"),
                                          message: L("meetings.empty.message"), context: .meetings)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    list(now: context.date)
                }
            }
        }
        .background(Brand.color.surface)
    }

    private func softError(_ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(Brand.color.text2)
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.color.warning)
        }
        .font(Brand.caption)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func list(now: Date) -> some View {
        let hero = segment == .today ? model.hero(now: now) : nil
        // The hero card already shows its meeting: the list below holds the rest.
        let days = model.days(in: segment, now: now)
            .map { (day: $0.day, events: $0.events.filter { $0.id != hero?.event.id }) }
            .filter { !$0.events.isEmpty }
        let selected = isNarrow ? nil : selectedEvent(now: now)?.id
        if !model.loadedOnce {
            BrandLoader(size: 28, text: L("meetings.loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if days.isEmpty && hero == nil {
            emptyAgenda(now: now)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let hero {
                        MeetingHeroCard(event: hero.event, isNow: hero.isNow, isSelected: selected == hero.event.id,
                                        onSelect: { select(hero.event) }, onPrepare: { prepare(hero.event) },
                                        onShowPage: { pageSheet = VaultPageItem(path: $0) })
                            .padding(.bottom, 10)
                    }
                    if segment == .today {
                        if days.isEmpty {
                            Text(L("meetings.nothingMoreToday"))
                                .font(Brand.body)
                                .foregroundStyle(Brand.color.text2)
                                .padding(.vertical, 8)
                                .padding(.leading, 4)
                        } else if hero != nil {
                            dayHeader(L("meetings.restOfToday"))
                        }
                        ForEach(days.flatMap(\.events)) { row($0, selected: selected) }
                    } else {
                        ForEach(days, id: \.day) { group in
                            dayHeader(MeetingTimes.dayTitle(group.day))
                            ForEach(group.events) { row($0, selected: selected) }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func row(_ event: CalendarEvent, selected: String?) -> some View {
        MeetingCard(event: event, isSelected: selected == event.id,
                    onSelect: { select(event) }, onPrepare: { prepare(event) },
                    onShowPage: { pageSheet = VaultPageItem(path: $0) })
    }

    private func dayHeader(_ text: String) -> some View {
        Text(text)
            .font(Brand.font(12, .semibold))
            .foregroundStyle(Brand.color.text2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func emptyAgenda(now: Date) -> some View {
        if segment == .today, !model.events(in: .upcoming, now: now).isEmpty {
            EmptyStateView(symbol: "calendar", title: L("meetings.nothingToday"), message: "",
                           actionTitle: L("meetings.seeUpcoming"), action: { segment = .upcoming })
        } else {
            EmptyStateView(symbol: "calendar", title: L("meetings.nothing.title"), message: L("meetings.nothing.message"))
        }
    }

    // MARK: Anteriores

    @ViewBuilder private var pastList: some View {
        let items = model.pastMeetings(state: state)
        if items.isEmpty {
            EmptyStateView(symbol: "waveform", title: L("meetings.past.empty.title"), message: L("meetings.past.empty.message"))
        } else {
            let cal = Calendar.current
            let groups = Dictionary(grouping: items) { cal.startOfDay(for: $0.timelineDate) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                        dayHeader(MeetingTimes.dayTitle(day))
                        ForEach(groups[day] ?? []) { source in
                            PastMeetingRow(source: source) { openSummary(source) }
                        }
                    }
                }
                .padding(.horizontal, Brand.spacing.content)
                .padding(.vertical, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// "Ver resumen": the meeting page in its project (pendingPage + selection), else shown in place.
    private func openSummary(_ source: SourceRecord) {
        if let path = state.engine.pagePath(forSourceId: source.id), state.openProjectPage(path) { return }
        Task { if let path = await state.openMeetingSummary(source) { pageSheet = VaultPageItem(path: path) } }
    }

    // MARK: Selection

    /// The events listed in the current segment (hero included).
    private func visibleEvents(now: Date) -> [CalendarEvent] {
        guard segment != .past else { return [] }
        var list = model.events(in: segment, now: now)
        if segment == .today, let hero = model.hero(now: now)?.event, !list.contains(where: { $0.id == hero.id }) {
            list.insert(hero, at: 0)
        }
        return list
    }

    private func isVisible(_ id: String?, now: Date) -> Bool {
        guard let id else { return false }
        return visibleEvents(now: now).contains { $0.matches(id) }
    }

    private func select(_ event: CalendarEvent) {
        if selectedId != event.id { prepEventId = nil }
        selectedId = event.id
        if isNarrow { pushedId = event.id }
    }

    private func prepare(_ event: CalendarEvent) {
        selectedId = event.id
        prepEventId = event.id
        if isNarrow { pushedId = event.id }
    }

    /// The chosen event if it is listed; by default the hero (now / next), else the first one.
    private func selectedEvent(now: Date) -> CalendarEvent? {
        if isVisible(selectedId, now: now), let event = model.event(id: selectedId) { return event }
        if segment == .today, let hero = model.hero(now: now) { return hero.event }
        return model.events(in: segment, now: now).first
    }

    /// A selection that isn't in the new segment's list is cleared (§15.2).
    private func segmentChanged() {
        let now = Date()
        if !isVisible(selectedId, now: now) { selectedId = nil; prepEventId = nil }
        if !isVisible(pushedId, now: now) { pushedId = nil }
    }

    /// Inicio / ⌘K asked for an event: switch to its segment and select it (pushed when single-column).
    private func consumePendingEvent() {
        guard let id = state.pendingEventId, model.loadedOnce else { return }
        state.pendingEventId = nil
        guard let event = model.event(id: id) else { return }
        let now = Date()
        let target: MeetingSegment = MeetingSegment.today.contains(event, now: now) ? .today : .upcoming
        if segment != target { segment = target }
        selectedId = event.id
        prepEventId = nil
        if isNarrow { pushedId = event.id }
    }

    // MARK: Detail

    @ViewBuilder private var detailPane: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let event = selectedEvent(now: context.date) {
                eventDetail(event, isHero: segment == .today && model.hero(now: context.date)?.event.id == event.id)
            } else if model.loadedOnce {
                EmptyStateView(symbol: "calendar.badge.clock", title: L("meetings.pick"), message: "")
            }
        }
        .background(Brand.color.surface)
    }

    /// Single column: the pushed detail never sits next to the hero, so it keeps its actions.
    @ViewBuilder private func pushedDetail(_ id: String) -> some View {
        Group {
            if let event = model.event(id: id) {
                eventDetail(event, isHero: false)
            } else {
                EmptyStateView(symbol: "calendar.badge.clock", title: L("meetings.pick"), message: "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.color.surface)
    }

    @ViewBuilder private func eventDetail(_ event: CalendarEvent, isHero: Bool) -> some View {
        if prepEventId == event.id {
            MeetingPrepView(event: event, onClose: { prepEventId = nil },
                            onShowPage: { pageSheet = VaultPageItem(path: $0) })
                .id(event.id)
        } else {
            // The hero already holds this meeting's Grabar / Unirme: one visible record button (§15.2).
            MeetingDetail(event: event, showsActions: !isHero, onPrepare: { prepare(event) },
                          onShowPage: { pageSheet = VaultPageItem(path: $0) })
                .id(event.id)
        }
    }
}

// MARK: - Hero

/// "Ahora / Siguiente" at the top of Hoy (and on Inicio), with a live countdown and the meeting's one action.
struct MeetingHeroCard: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    let isNow: Bool
    var isSelected = false
    var onSelect: () -> Void
    var onPrepare: () -> Void
    var onShowPage: (String) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
        let recording = event.matches(state.recordingEventId)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if recording { BrandRecordingDot(size: 7) }
                Text(isNow ? L("meetings.now") : L("meetings.next"))
                    .font(Brand.font(11, .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(isNow ? Brand.color.record : Brand.color.accent)
                    .lineLimit(1)
                    .layoutPriority(2)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ViewThatFits(in: .horizontal) {
                        Text(MeetingTimes.countdown(event, now: context.date))
                        Text(MeetingTimes.countdownShort(event, now: context.date))
                    }
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .monospacedDigit()
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            Text(event.title)
                .font(Brand.font(17, .semibold))
                .foregroundStyle(Brand.color.text)
                .lineLimit(2)
            MeetingProjectChip(event: event, placement: .hero, showsOffer: false)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { timeLabel; placeLabel }
                VStack(alignment: .leading, spacing: 4) { timeLabel; placeLabel }
            }
            .font(Brand.body)
            .foregroundStyle(Brand.color.text2)
            actionRow
            MeetingRuleOfferLine(event: event, placement: .hero)   // v0.4 rules: under the actions, never above the title
        }
        .padding(16)
        .background(shape.fill(isNow ? Brand.color.recordSoft : Brand.color.card))
        .overlay(shape.strokeBorder(isSelected ? Brand.color.accent : Brand.color.line, lineWidth: isSelected ? 1.5 : 1))
        .contentShape(shape)
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(.isButton)
    }

    private var timeLabel: some View {
        Label(MeetingTimes.range(event), systemImage: "clock")
            .lineLimit(1)
            .layoutPriority(1)
    }

    @ViewBuilder private var placeLabel: some View {
        if let place = MeetingPlace.visible(event) {
            Label(place, systemImage: MeetingPlace.symbol(place))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Action + Unirme + initials; drops the initials, then stacks, then goes icon-only (§15.3).
    private var actionRow: some View {
        let others = MeetingsModel.shared.others(in: event)
        let action = MeetingActionButton(event: event, large: true, onPrepare: onPrepare, onShowPage: onShowPage).fixedSize()   // fixed only inside ViewThatFits candidates: it measures true widths
        let join = MeetingJoinButton(event: event, large: true).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                action; join
                Spacer(minLength: 8)
                AttendeeInitials(attendees: others, size: 26)
            }
            HStack(spacing: 8) { action; join; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { action; join }
            HStack(spacing: 8) { action; join; Spacer(minLength: 0) }.labelStyle(.iconOnly)
        }
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

    /// "hoy 10:20 – 11:20 · 1 h" / "mañana · todo el día".
    static func when(_ e: CalendarEvent) -> String {
        if e.isAllDay { return Fmt.relativeDay(e.start).meetingCapitalized + " · " + L("meetings.allDay").lowercased() }
        return Fmt.dayTime(e.start).meetingCapitalized + " – " + Fmt.time(e.end) + " · " + duration(e.end.timeIntervalSince(e.start))
    }

    /// "10:20 – 11:20 · 1 h" (or "Todo el día").
    static func timeAndDuration(_ e: CalendarEvent) -> String {
        e.isAllDay ? L("meetings.allDay") : range(e) + " · " + duration(e.end.timeIntervalSince(e.start))
    }

    /// "Hoy · martes, 27 de octubre", "Mañana · …", "Ayer · …", else "Jueves, 29 de octubre".
    static func dayTitle(_ day: Date) -> String {
        let long = Fmt.weekdayLong(day)
        switch Fmt.daysFromToday(day) {
        case 0: return L("date.today").meetingCapitalized + " · " + long
        case 1: return L("date.tomorrow").meetingCapitalized + " · " + long
        case -1: return L("date.yesterday").meetingCapitalized + " · " + long
        default: return long.meetingCapitalized
        }
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

    /// `countdown` without the "· quedan …" clause, for tight rows.
    static func countdownShort(_ e: CalendarEvent, now: Date) -> String {
        if now >= e.start, now <= e.end { return L("meetings.startedAgo", duration(now.timeIntervalSince(e.start))) }
        return countdown(e, now: now)
    }
}

extension String {
    var meetingCapitalized: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Detail

/// Right pane: when, who (names open their people page), the invitation notes, Unirme and the meeting's action.
/// `showsActions` is false when the hero card next to it already shows them.
struct MeetingDetail: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    var showsActions = true
    var onPrepare: () -> Void
    var onShowPage: (String) -> Void

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(Brand.title)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .padding(.bottom, 2)
                    Label(MeetingTimes.dayTitle(event.start), systemImage: "calendar")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !event.isAllDay {
                        Label(MeetingTimes.timeAndDuration(event), systemImage: "clock")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let place = MeetingPlace.visible(event) {
                        Label(place, systemImage: MeetingPlace.symbol(place))
                            .lineLimit(2)
                    }
                }
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)

                MeetingProjectChip(event: event, placement: .detail)

                actions

                VStack(alignment: .leading, spacing: 10) {
                    let people = sortedAttendees
                    BrandSectionHeader(title: L("meetings.who"), count: people.isEmpty ? nil : people.count)
                    if people.isEmpty {
                        Text(L("meetings.noAttendees")).font(Brand.body).foregroundStyle(Brand.color.text2)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(people.enumerated()), id: \.offset) { _, person in attendeeRow(person) }
                        }
                    }
                }

                if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        BrandSectionHeader(title: L("meetings.notes"))
                        LinkedText(text: notes)
                            .font(Brand.body)
                            .foregroundStyle(Brand.color.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let web = JoinLink.https(event.webLink) {
                    Link(destination: web) {
                        Label(L("meetings.openInCalendar"), systemImage: "arrow.up.forward.square")
                    }
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.accent)
                }
            }
            .padding(Brand.spacing.content)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.color.surface)
    }

    /// Grabar · Unirme · Prepararme as a row, else a column, else icons only.
    private var actions: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let phase = model.phase(of: event, state: state, now: context.date)
            let prepLink = phase == .recordable || phase == .recording
            if showsActions {
                let action = MeetingActionButton(event: event, large: true, onPrepare: onPrepare, onShowPage: onShowPage).fixedSize()   // fixed only inside ViewThatFits candidates: it measures true widths
                let join = MeetingJoinButton(event: event, large: true).fixedSize()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { action; join; if prepLink { prepareLink.fixedSize() } }
                    VStack(alignment: .leading, spacing: 8) { action; join; if prepLink { prepareLink.fixedSize() } }
                    HStack(spacing: 8) { action; join; if prepLink { prepareLink.fixedSize() } }.labelStyle(.iconOnly)
                }
            } else if prepLink {
                prepareLink
            }
        }
    }

    private var prepareLink: some View {
        Button(action: onPrepare) { Label(L("meetings.prepare"), systemImage: "sparkles") }
            .buttonStyle(.plain)
            .font(Brand.callout)
            .foregroundStyle(Brand.color.accent)
            .lineLimit(1)
            .help(L("meetings.prepare"))
    }

    /// Everyone, me last.
    private var sortedAttendees: [EmailAddress] {
        let all = event.attendees
        return all.filter { !isMe($0) } + all.filter(isMe)
    }

    private func isMe(_ a: EmailAddress) -> Bool { a.email.map { model.myEmails.contains($0.lowercased()) } ?? false }

    private func attendeeRow(_ a: EmailAddress) -> some View {
        let path = model.personPath(for: a)
        let isOrganizer = a.email != nil && a.email?.lowercased() == event.organizer?.email?.lowercased()
        let name = a.name ?? a.display
        let nameView = Group {
            if let path {
                Button(name) { onShowPage(path) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.color.accent)
                    .help(L("meetings.openPerson"))
            } else {
                Text(name).foregroundStyle(Brand.color.text)
            }
        }
        .font(Brand.font(13, .medium))
        .lineLimit(1)
        .truncationMode(.tail)
        let roles = roleChips(me: isMe(a), organizer: isOrganizer)
        return HStack(alignment: .top, spacing: 10) {
            InitialsCircle(address: a, size: 28, ring: Brand.color.surface)
            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { nameView; roles }
                    VStack(alignment: .leading, spacing: 3) {
                        nameView
                        HStack(spacing: 4) { roles }
                    }
                }
                if let email = a.email, a.name != nil {
                    Text(email)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func roleChips(me: Bool, organizer: Bool) -> some View {
        if me { BrandChip(text: L("meetings.role.you")) }
        if organizer { BrandChip(text: L("meetings.role.organizer")) }
    }
}
