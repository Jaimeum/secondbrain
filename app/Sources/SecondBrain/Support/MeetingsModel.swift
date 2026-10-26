import BrainCore
import Foundation
import Observation

/// "Hoy · Esta semana · Próximas" (CONTRACT §12.5).
enum MeetingSegment: Hashable, CaseIterable {
    case today, week, upcoming

    var title: String {
        switch self {
        case .today: L("meetings.today")
        case .week: L("meetings.week")
        case .upcoming: L("meetings.upcoming")
        }
    }

    func contains(_ event: CalendarEvent, now: Date, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        let days = switch self {
        case .today: 1
        case .week: 7
        case .upcoming: MeetingsModel.horizonDays + 1
        }
        guard let limit = calendar.date(byAdding: .day, value: days, to: today) else { return false }
        return event.start < limit && event.end > today
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
        let store = state.engine.accounts
        let accounts = store.accounts
        guard !accounts.isEmpty else {
            events = []
            accountErrors = [:]
            loadedOnce = true
            return
        }
        isLoading = true
        let providers = accounts.map { ($0, store.provider(for: $0)) }
        let from = Calendar.current.startOfDay(for: Date())
        let to = Calendar.current.date(byAdding: .day, value: Self.horizonDays + 1, to: from) ?? from.addingTimeInterval(31 * 86_400)
        let results = await withTaskGroup(of: (ConnectedAccount, Result<[CalendarEvent], Error>).self) { group in
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
        isLoading = false
        loadedOnce = true
    }

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
        var order: [Date] = []
        var groups: [Date: [CalendarEvent]] = [:]
        for event in events(in: segment, now: now) {
            let day = max(cal.startOfDay(for: event.start), today)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(event)
        }
        return order.sorted().map { ($0, groups[$0] ?? []) }
    }

    func event(id: String?) -> CalendarEvent? {
        guard let id else { return nil }
        return events.first { $0.id == id }
    }

    /// "Ahora" (in its record window) or else "Siguiente".
    func hero(now: Date) -> (event: CalendarEvent, isNow: Bool)? {
        if let live = MeetingAgenda.current(in: events, now: now) { return (live, true) }
        if let next = MeetingAgenda.next(in: events, now: now) { return (next, false) }
        return nil
    }

    func phase(of event: CalendarEvent, state: AppState, now: Date) -> MeetingPhase {
        MeetingAgenda.phase(of: event, now: now, recordingEventId: state.recordingEventId,
                            source: state.engine.meetingSource(forEvent: event.id))
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

    /// The project the recording goes to: the remembered choice when that project still exists.
    func projectSlug(for event: CalendarEvent, state: AppState) -> String? {
        guard let slug = choice(for: event)?.projectSlug, state.project(slug) != nil else { return nil }
        return slug
    }

    /// "¿Es de 🚀 Acme?" — only while nothing was chosen for the event (or its series).
    func suggestion(for event: CalendarEvent, state: AppState) -> MeetingSuggestion? {
        switch choice(for: event) {
        case .noProject: return nil
        case .project(let slug) where state.project(slug) != nil: return nil
        default: break   // nothing chosen, or the chosen project is gone
        }
        let suggester = MeetingProjectSuggester(people: people, projects: state.projects, ownerEmails: myEmails)
        return suggester.suggestProject(for: event)
    }

    func setProject(_ choice: MeetingProjectChoice?, for event: CalendarEvent, state: AppState) {
        if links == nil { links = MeetingLinks(fileURL: state.engine.paths.meetings) }
        do {
            try links?.set(choice, for: event)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        linksRevision += 1
        // Recording this meeting right now: the recording follows the new choice.
        if state.recordingEventId == event.id { state.recordingProjectSlug = choice?.projectSlug }
    }
}
