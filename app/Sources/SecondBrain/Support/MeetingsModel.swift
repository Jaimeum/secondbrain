import BrainCore
import Foundation
import Observation

/// "Hoy · Próximas · Anteriores" (CONTRACT §15.2). Hoy = today's events; Próximas = from tomorrow to the horizon,
/// grouped by day; Anteriores = meetings the brain knows (recordings and the vault timeline), which need no calendar.
enum MeetingSegment: Hashable, CaseIterable {
    case today, upcoming, past

    /// v0.3 name of the week view, kept so older call sites compile: it is `upcoming` now.
    static let week = MeetingSegment.upcoming

    var title: String {
        switch self {
        case .today: L("meetings.today")
        case .upcoming: L("meetings.upcoming")
        case .past: L("meetings.segment.past")
        }
    }

    /// Whether a calendar event is listed in this segment (`past` lists sources, never calendar events).
    func contains(_ event: CalendarEvent, now: Date, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let limit = calendar.date(byAdding: .day, value: MeetingsModel.horizonDays + 1, to: today) else { return false }
        switch self {
        case .today: return event.start < tomorrow && event.end > today
        case .upcoming: return event.start >= tomorrow && event.start < limit
        case .past: return false
        }
    }
}

/// The agenda of every connected calendar, shared by Reuniones, the sidebar banner and the menu bar. Loads on appear
/// and every 15 minutes while the app is open; one account failing never hides the others (soft error per account).
@MainActor @Observable
final class MeetingsModel {
    static let shared = MeetingsModel()
    nonisolated static let horizonDays = 30
    static let refreshInterval: TimeInterval = 15 * 60

    /// Deduped across accounts (same title + start), sorted by start.
    private(set) var events: [CalendarEvent] = []
    /// accountId → human message ("No pude leer el calendario de ana@contoso.com").
    private(set) var accountErrors: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var loadedOnce = false
    /// `AppState.accountsRevision` of the last finished load: a newly connected account shows the loader, never a
    /// premature "Nada en la agenda".
    private(set) var loadedAccountsRevision: Int?
    /// People pages, to link attendees and suggest projects.
    private(set) var people = MeetingPeopleIndex()
    /// The owner's addresses (accounts + people/README): left out of initials and prep.
    private(set) var myEmails: Set<String> = []
    private(set) var error: String?
    /// Bumped when a project choice is saved (MeetingLinks isn't observable).
    private var linksRevision = 0

    @ObservationIgnored private var links: MeetingLinks?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var seenAccountsRevision: Int?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    /// Bumped per load: only the newest load clears `isLoading` (a cancelled one never leaves it set).
    @ObservationIgnored private var loadGeneration = 0
    /// Ticks every 20 s: the banners ("empezó hace 3 min", "Siguiente: … · 15:30") follow the clock through it.
    private(set) var now = Date()

    // MARK: Loading

    /// Starts the loop once (AppState.startEngine): reload every 15 minutes, right away when accounts change, and tick
    /// `now`. Later calls reload only when the accounts changed meanwhile.
    func start(state: AppState) {
        guard loop == nil else {
            if seenAccountsRevision != state.accountsRevision { refresh(state: state) }
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = Date()
                if self.now.timeIntervalSince(self.lastRefresh) >= Self.refreshInterval
                    || self.seenAccountsRevision != state.accountsRevision {
                    self.refresh(state: state)
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    var isRunning: Bool { loop != nil }

    /// Reloads events from every account now (cancels a load in flight) and re-reads the people pages.
    func refresh(state: AppState) {
        seenAccountsRevision = state.accountsRevision
        lastRefresh = Date()
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load(state: state) }
        reloadPeople(state: state)
    }

    private func load(state: AppState) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { isLoading = false } }
        let store = state.engine.accounts
        let accounts = store.accounts
        let revision = state.accountsRevision
        guard !accounts.isEmpty else {
            events = []
            accountErrors = [:]
            loadedOnce = true
            loadedAccountsRevision = revision
            return
        }
        isLoading = true
        let providers = accounts.map { ($0, store.provider(for: $0)) }
        let from = Calendar.current.startOfDay(for: Date())
        let to = Calendar.current.date(byAdding: .day, value: Self.horizonDays + 1, to: from) ?? from.addingTimeInterval(31 * 86_400)
        let arrived = await withTaskGroup(of: (ConnectedAccount, Result<[CalendarEvent], Error>).self) { group in
            for (account, provider) in providers {
                group.addTask {
                    do { return (account, .success(try await provider.events(from: from, to: to))) }
                    catch { return (account, .failure(error)) }
                }
            }
            var out: [(ConnectedAccount, Result<[CalendarEvent], Error>)] = []
            for await result in group { out.append(result) }
            return out
        }
        guard !Task.isCancelled else { return }
        // Account order, not arrival order: which copy of a shared meeting is kept must not depend on network timing.
        let order = Dictionary(accounts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let results = arrived.sorted { (order[$0.0.id] ?? .max, $0.0.id) < (order[$1.0.id] ?? .max, $1.0.id) }
        var all: [CalendarEvent] = []
        var errors: [String: String] = [:]
        for (account, result) in results {
            switch result {
            case .success(let list): all += list
            case .failure(let error):
                if error is CancellationError { continue }
                errors[account.id] = L("meetings.accountError", account.email, FriendlyError.message(error))
            }
        }
        let deduped = MeetingAgenda.dedupe(all)
        if deduped != events { events = deduped }
        if errors != accountErrors { accountErrors = errors }
        loadedOnce = true
        loadedAccountsRevision = revision
    }

    /// The agenda reflects the accounts connected now (false right after connecting one: show the loader).
    func isLoaded(state: AppState) -> Bool { loadedOnce && loadedAccountsRevision == state.accountsRevision }

    /// Re-reads people pages and the owner's addresses (after Claude learned something new).
    func reloadPeople(state: AppState) {
        guard state.engineStarted else { return }
        indexTask?.cancel()
        let vault = state.engine.vault
        let accountEmails = Set(state.engine.accounts.accounts.map(\.email))
        let linksURL = state.engine.paths.meetings
        if links?.fileURL != linksURL { links = MeetingLinks(fileURL: linksURL); linksRevision += 1 }
        indexTask = Task { [weak self] in
            let (people, owner) = await Task.detached(priority: .utility) {
                (MeetingPeopleIndex.load(vault: vault), Set(vault.ownerEmails()))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.people = people
            let mine = owner.union(accountEmails)
            if mine != self.myEmails { self.myEmails = mine }
        }
    }

    // MARK: Agenda

    func events(in segment: MeetingSegment, now: Date) -> [CalendarEvent] {
        events.filter { segment.contains($0, now: now) }
    }

    /// Events grouped by local day (multi-day events under the first visible day), in order.
    func days(in segment: MeetingSegment, now: Date) -> [(day: Date, events: [CalendarEvent])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        // Próximas starts tomorrow; events that began before the first listed day go under it.
        let first = segment == .upcoming ? (cal.date(byAdding: .day, value: 1, to: today) ?? today) : today
        var order: [Date] = []
        var groups: [Date: [CalendarEvent]] = [:]
        for event in events(in: segment, now: now) {
            let day = max(cal.startOfDay(for: event.start), first)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(event)
        }
        return order.sorted().map { ($0, groups[$0] ?? []) }
    }

    func event(id: String?) -> CalendarEvent? {
        guard let id else { return nil }
        return events.first { $0.matches(id) }
    }

    /// "Ahora" (in its record window) or else "Siguiente", the latter only when it is today or tomorrow (§15.2).
    func hero(now: Date) -> (event: CalendarEvent, isNow: Bool)? {
        if let live = MeetingAgenda.current(in: events, now: now) { return (live, true) }
        if let next = MeetingAgenda.next(in: events, now: now), (0...1).contains(Self.dayOffset(of: next.start, from: now)) {
            return (next, false)
        }
        return nil
    }

    /// Calendar days from `now`'s day to `date`'s day (0 = same day).
    static func dayOffset(of date: Date, from now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Recorded meetings, done or still being processed (failed ones too, to retry), newest first.
    func pastMeetings(state: AppState) -> [SourceRecord] {
        state.engine.sources
            .filter { $0.kind == .meeting && $0.status != .recording }
            .sorted { $0.timelineDate > $1.timelineDate }
    }

    // MARK: Anteriores

    /// Meeting entries of the vault timeline (all projects), read off the main actor; nil until the first read.
    private(set) var timelineMeetings: [TimelineEntry]?
    @ObservationIgnored private var pastTask: Task<Void, Never>?
    @ObservationIgnored private var pastKey: Int?

    /// Reads the timeline once per vault revision (the Anteriores segment calls it on appear and on vault changes).
    func loadPast(state: AppState) {
        guard state.engineStarted, pastKey != state.vaultRevision || timelineMeetings == nil else { return }
        pastKey = state.vaultRevision
        pastTask?.cancel()
        let engine = state.engine
        pastTask = Task { [weak self] in
            let entries = await engine.timeline(projectSlug: nil).filter { $0.kind == .meeting }
            guard let self, !Task.isCancelled else { return }
            if entries != self.timelineMeetings { self.timelineMeetings = entries }
        }
    }

    /// "Anteriores" (§15.2): the meetings the brain learned, newest first. Recordings come live from the sources (their
    /// state changes while processing; the timeline's page title is used once learned); meetings only known from the
    /// vault timeline (`wiki/timeline.md` lines, older imports) come with their page. Works without any calendar.
    func pastItems(state: AppState, now: Date = Date()) -> [PastMeetingItem] {
        let entries = timelineMeetings ?? []
        var titles: [String: String] = [:]
        for e in entries { if let id = e.sourceId { titles[id] = e.title } }
        var items = pastMeetings(state: state).map { PastMeetingItem.source($0, title: titles[$0.id]) }
        items += entries.filter { $0.sourceId == nil && $0.date <= now }.map(PastMeetingItem.page)
        return items.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// Anteriores has been read at least once (the loader shows until then, never a premature empty state).
    var pastLoaded: Bool { timelineMeetings != nil }

    /// The segment last shown in Reuniones: coming back (⌘2, after "Ver resumen") lands where the user was.
    @ObservationIgnored var lastSegment: MeetingSegment = .today

    func phase(of event: CalendarEvent, state: AppState, now: Date) -> MeetingPhase {
        MeetingAgenda.phase(of: event, now: now, recordingEventId: state.recordingEventId,
                            source: state.engine.meetingSource(for: event))
    }

    /// Attendees other than me.
    func others(in event: CalendarEvent) -> [EmailAddress] {
        event.attendees.filter { a in !(a.email.map { myEmails.contains($0.lowercased()) } ?? false) }
    }

    func personPath(for attendee: EmailAddress) -> String? { people.person(for: attendee)?.path }

    // MARK: Project per meeting

    func choice(for event: CalendarEvent) -> MeetingProjectChoice? {
        _ = linksRevision
        return links?.choice(for: event)
    }

    /// The project of an event and why (CONTRACT §14.2): the user's choice > a routing rule > the default project >
    /// the suggestion. Reads the rules (observable), so chips follow rule edits.
    func resolution(for event: CalendarEvent, state: AppState) -> MeetingProjectResolution {
        let choice = choice(for: event)
        let routing = state.engine.routing
        return MeetingProjectResolution.resolve(
            choice: choice, rule: routing.match(routingSubject(event)), defaultProject: routing.settings.defaultProjectSlug,
            projectExists: { state.project($0) != nil },
            suggestion: {
                MeetingProjectSuggester(people: people, projects: state.projects, ownerEmails: myEmails).suggestProject(for: event)
            })
    }

    func routingSubject(_ event: CalendarEvent) -> RoutingSubject {
        .meeting(event, ownerEmails: myEmails.sorted())
    }

    /// The project the recording goes to: the remembered choice, else a rule, else the default project.
    func projectSlug(for event: CalendarEvent, state: AppState) -> String? {
        resolution(for: event, state: state).recordingProject
    }

    /// "Grabar" on a meeting: the recording goes to `projectSlug(for:)`. A rule that decided it counts a hit ("n veces")
    /// only once the recording really started (no microphone permission, a recorder error… count nothing).
    func record(_ event: CalendarEvent, state: AppState) async {
        let r = resolution(for: event, state: state)
        await state.startRecording(for: event, projectSlug: r.recordingProject)
        if r.rule != nil, event.matches(state.recordingEventId) { _ = state.engine.routing.route(routingSubject(event)) }
    }

    /// The calendar event a recording is tied to: from the agenda when it is loaded, else asked of the calendars around
    /// the recording's date (the agenda starts today, and Sin asignar is mostly yesterday's meetings). nil if not found.
    func event(for source: SourceRecord, state: AppState) async -> CalendarEvent? {
        guard let id = source.calendarEventId else { return nil }
        if let cached = event(id: id) { return cached }
        let store = state.engine.accounts
        let date = source.eventDate ?? source.createdAt
        let from = date.addingTimeInterval(-86_400), to = date.addingTimeInterval(86_400)
        for account in store.calendarAccounts {
            if let list = try? await store.provider(for: account).events(from: from, to: to), let found = list.first(where: { $0.matches(id) }) {
                return found
            }
        }
        return nil
    }

    /// "¿Es de 🚀 Acme?" — only while nothing decided the event (no choice, no rule, no default project).
    func suggestion(for event: CalendarEvent, state: AppState) -> MeetingSuggestion? {
        if case .suggestion(let s) = resolution(for: event, state: state).origin { return s }
        return nil
    }

    /// `offerAt`: where the user made the choice (a chip), to offer a rule right there (§14.3); nil offers nothing.
    func setProject(_ choice: MeetingProjectChoice?, for event: CalendarEvent, state: AppState, offerAt placement: MeetingChipPlacement? = nil) {
        let previous = resolution(for: event, state: state)
        if links == nil { links = MeetingLinks(fileURL: state.engine.paths.meetings) }
        do {
            try links?.set(choice, for: event)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        linksRevision += 1
        // Recording this meeting right now: the recording follows the new choice.
        if event.matches(state.recordingEventId) { state.recordingProjectSlug = choice?.projectSlug }
        // MARK: v0.4 routing — §14.3: one quiet "always?" line after a manual choice that didn't come from a rule.
        if let placement, let slug = choice?.projectSlug,
           let rule = MeetingRuleOffers.forMeeting(event, projectSlug: slug, previous: previous, ownerEmails: myEmails.sorted(),
                                                   existing: state.engine.routing.rules, language: state.config.uiLanguage) {
            ruleOfferTarget = MeetingRuleOfferTarget(eventId: event.id, placement: placement)
            ruleOffer.show(rule, projectLabel: state.projectName(slug), kind: .meeting)
        } else if ruleOfferTarget?.eventId == event.id {
            ruleOffer.dismiss()
            ruleOfferTarget = nil
        }
    }

    // MARK: Rule offer (§14.3)

    /// «¿Las reuniones que organiza ana@acme.com a 🚀 Acme de ahora en adelante?» · Sí, siempre · Solo esta vez: the same
    /// `RuleOffer` as Correo (same words, timings and "Regla creada · Deshacer"; one offer in the app at a time).
    let ruleOffer = RuleOffer()
    /// Which chip the offer belongs under (it shows nowhere else).
    private(set) var ruleOfferTarget: MeetingRuleOfferTarget?
}

/// Where a project chip is shown: the rule offer appears under the chip the user clicked, nowhere else. Agenda rows
/// show a read-only chip, so `card` never shows an offer (kept for older call sites).
enum MeetingChipPlacement: Hashable {
    case card, hero, detail, prep
}

/// One row of "Anteriores": a recording (live state, actions) or a meeting known only from the vault timeline.
enum PastMeetingItem: Identifiable, Equatable {
    case source(SourceRecord, title: String?)
    case page(TimelineEntry)

    var id: String {
        switch self {
        case .source(let s, _): "source:\(s.id)"
        case .page(let e): e.id
        }
    }

    var date: Date {
        switch self {
        case .source(let s, _): s.timelineDate
        case .page(let e): e.date
        }
    }
}

/// Where the §14.3 offer of Reuniones shows: under the chip of this event that the user used.
struct MeetingRuleOfferTarget: Equatable {
    let eventId: String
    let placement: MeetingChipPlacement
}
