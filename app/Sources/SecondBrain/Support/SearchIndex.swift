import BrainCore
import Foundation
import Observation

// ⌘K (CONTRACT §15.2): an in-memory index of titles (meetings, notes and documents, email threads, pages, people,
// tasks, projects, actions), rebuilt when the vault, the tasks or the accounts change. Matching ignores accents and
// case: prefix > start of a word > contains, with a boost for recent things. Full-text search is a later phase.

enum SearchGroup: String, CaseIterable, Hashable {
    case today, recent, meetings, notes, mail, pages, people, tasks, projects, actions

    var title: String {
        switch self {
        case .today: L("search.group.today")
        case .recent: L("search.group.recent")
        case .meetings: L("search.group.meetings")
        case .notes: L("search.group.notes")
        case .mail: L("search.group.mail")
        case .pages: L("search.group.pages")
        case .people: L("search.group.people")
        case .tasks: L("search.group.tasks")
        case .projects: L("search.group.projects")
        case .actions: L("search.group.actions")
        }
    }

    /// Order of the groups for a query.
    static let resultOrder: [SearchGroup] = [.meetings, .notes, .mail, .pages, .people, .tasks, .projects, .actions]
}

enum SearchAction: String, CaseIterable {
    case record, pasteMail, newNote, newProject, settings, rules, formats

    var title: String {
        switch self {
        case .record: L("search.action.record")
        case .pasteMail: L("search.action.pasteMail")
        case .newNote: L("search.action.newNote")
        case .newProject: L("search.action.newProject")
        case .settings: L("search.action.settings")
        case .rules: L("search.action.rules")
        case .formats: L("search.action.formats")
        }
    }

    var symbol: String {
        switch self {
        case .record: "record.circle"
        case .pasteMail: "envelope"
        case .newNote: "square.and.pencil"
        case .newProject: "folder.badge.plus"
        case .settings: "gearshape"
        case .rules: "arrow.triangle.branch"
        case .formats: "doc.richtext"
        }
    }
}

/// Where a result goes. `encoded` round-trips through UserDefaults ("Abiertos hace poco").
enum SearchTarget: Hashable {
    case page(String)
    case source(String)
    case event(String)
    case project(String)
    case projectTasks(String)
    case action(SearchAction)

    var encoded: String {
        switch self {
        case .page(let p): "page:" + p
        case .source(let id): "source:" + id
        case .event(let id): "event:" + id
        case .project(let s): "project:" + s
        case .projectTasks(let s): "tasks:" + s
        case .action(let a): "action:" + a.rawValue
        }
    }

    init?(encoded: String) {
        guard let colon = encoded.firstIndex(of: ":") else { return nil }
        let kind = encoded[..<colon], value = String(encoded[encoded.index(after: colon)...])
        switch kind {
        case "page": self = .page(value)
        case "source": self = .source(value)
        case "event": self = .event(value)
        case "project": self = .project(value)
        case "tasks": self = .projectTasks(value)
        case "action": guard let a = SearchAction(rawValue: value) else { return nil }; self = .action(a)
        default: return nil
        }
    }
}

struct SearchItem: Identifiable, Hashable {
    var id: String { group.rawValue + "|" + target.encoded }
    let group: SearchGroup
    let title: String
    var subtitle = ""
    var symbol = "doc.text"
    /// A project's emoji (user data), shown instead of the symbol.
    var emoji: String?
    var date: Date?
    let target: SearchTarget
    /// Folded title (+ extra terms) the query is matched against.
    var key: String

    init(group: SearchGroup, title: String, subtitle: String = "", symbol: String = "doc.text", emoji: String? = nil,
         date: Date? = nil, target: SearchTarget, extra: String = "") {
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.emoji = emoji
        self.date = date
        self.target = target
        key = SearchIndex.fold(extra.isEmpty ? title : title + " " + extra)
    }
}

@MainActor @Observable
final class SearchIndex {
    static let shared = SearchIndex()

    private(set) var items: [SearchItem] = []
    @ObservationIgnored private var builtKey: String?
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    static let maxPerGroup = 4
    static let recentsKey = "search.recent"

    // MARK: Building

    private func revisionKey(_ state: AppState) -> String {
        "\(state.vaultGeneration)-\(state.vaultRevision)-\(state.tasksRevision)-\(state.accountsRevision)-\(state.projects.count)"
    }

    /// Rebuilds in the background when something changed since the last build (`debounce`: wait for a burst of
    /// changes to settle, used by MainView; the palette asks without it when it opens).
    func refresh(state: AppState, debounce: Bool = true) {
        guard state.engineStarted else { return }
        let key = revisionKey(state)
        guard key != builtKey else { return }
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .seconds(1.5)) }
            guard !Task.isCancelled else { return }
            let built = await Self.build(state: state)
            guard let self, !Task.isCancelled else { return }
            self.items = built
            self.builtKey = key
        }
    }

    /// Builds now and waits (snapshots).
    func rebuild(state: AppState) async {
        buildTask?.cancel()
        items = await Self.build(state: state)
        builtKey = revisionKey(state)
    }

    private static func build(state: AppState) async -> [SearchItem] {
        let engine = state.engine
        var out: [SearchItem] = []
        func projectLabel(_ slug: String?) -> String { state.projectName(slug) }

        // Sources: meetings, notes/documents/links, and one row per email thread (its newest message).
        var threads: [String: SourceRecord] = [:]
        for source in engine.sources {
            let when = Fmt.dayTime(source.timelineDate)
            let sub = projectLabel(source.projectSlug) + " · " + when
            switch source.kind {
            case .meeting:
                out.append(SearchItem(group: .meetings, title: source.title, subtitle: sub, symbol: "waveform",
                                      date: source.timelineDate, target: .source(source.id)))
            case .note, .document, .url:
                out.append(SearchItem(group: .notes, title: source.title, subtitle: sub, symbol: source.kind.symbol,
                                      date: source.timelineDate, target: .source(source.id)))
            case .email:
                let key = source.threadKey ?? source.id
                if let current = threads[key], current.timelineDate >= source.timelineDate { continue }
                threads[key] = source
            case .github:
                continue
            }
        }
        for source in threads.values {
            out.append(SearchItem(group: .mail, title: source.title,
                                  subtitle: projectLabel(source.projectSlug) + " · " + Fmt.dayTime(source.timelineDate),
                                  symbol: "envelope", date: source.timelineDate, target: .source(source.id)))
        }

        // Pages: global (people apart) and per project, without the pages a source row already represents.
        for page in await engine.vault.pagesAsync(projectSlug: nil) {
            if page.path.hasPrefix("people/") {
                out.append(SearchItem(group: .people, title: page.title, symbol: "person", target: .page(page.path)))
            } else {
                out.append(SearchItem(group: .pages, title: page.title, subtitle: L("brand.name"), symbol: "doc.text",
                                      target: .page(page.path)))
            }
        }
        for project in state.projects {
            guard !Task.isCancelled else { return out }
            for page in await engine.vault.pagesAsync(projectSlug: project.slug) {
                let p = page.path
                if p.contains("/wiki/meetings/") || p.contains("/wiki/emails/") || p.contains("/wiki/sources/") { continue }
                var title = page.title
                for prefix in [project.name + " — ", project.name + " - "] where title.hasPrefix(prefix) {
                    title = String(title.dropFirst(prefix.count))
                }
                out.append(SearchItem(group: .pages, title: title, subtitle: project.name, emoji: project.emoji,
                                      target: .page(p), extra: project.name))
            }
        }

        // Open tasks (mine first by recency boost of the due date).
        for task in await engine.tasks(projectSlug: nil) where !task.done {
            var sub = projectLabel(task.projectSlug)
            if let due = task.due { sub += " · " + Fmt.relativeDay(due) }
            out.append(SearchItem(group: .tasks, title: task.text, subtitle: sub, symbol: "circle", date: task.due,
                                  target: .projectTasks(task.projectSlug), extra: task.ownerName ?? ""))
        }

        for project in state.projects {
            out.append(SearchItem(group: .projects, title: project.name, subtitle: project.description,
                                  emoji: project.emoji, target: .project(project.slug)))
        }
        for action in SearchAction.allCases {
            out.append(SearchItem(group: .actions, title: action.title, symbol: action.symbol, target: .action(action)))
        }
        return out
    }

    // MARK: Matching

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// 3 prefix, 2 start of a word, 1 contains (every word of the query must appear), 0 no match.
    nonisolated static func score(_ key: String, query q: String) -> Double {
        if key.hasPrefix(q) { return 3 }
        if let range = key.range(of: q) {
            let before = key[key.index(before: range.lowerBound)]
            return before.isLetter || before.isNumber ? 1 : 2
        }
        let words = q.split(separator: " ")
        guard words.count > 1, words.allSatisfy({ key.contains($0) }) else { return 0 }
        return 1
    }

    /// Up to +0.9 for things that happened (or are due) close to now.
    static func recencyBoost(_ date: Date?, now: Date) -> Double {
        guard let date else { return 0 }
        let days = abs(date.timeIntervalSince(now)) / 86_400
        return 0.9 * exp(-days / 30)
    }

    /// Grouped results for a non-empty query (upcoming events come live from the agenda, not the index).
    func results(for query: String, now: Date = Date()) -> [(SearchGroup, [SearchItem])] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        var scored: [SearchGroup: [(Double, SearchItem)]] = [:]
        for item in items + Self.upcomingEvents(now: now) {
            let s = Self.score(item.key, query: q)
            guard s > 0 else { continue }
            scored[item.group, default: []].append((s + Self.recencyBoost(item.date, now: now), item))
        }
        return SearchGroup.resultOrder.compactMap { group in
            guard let list = scored[group], !list.isEmpty else { return nil }
            let top = list.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.title < $1.1.title }.prefix(Self.maxPerGroup).map(\.1)
            return (group, Array(top))
        }
    }

    /// Empty query: today's meetings and the last things opened from here.
    func suggestions(now: Date = Date()) -> [(SearchGroup, [SearchItem])] {
        var out: [(SearchGroup, [SearchItem])] = []
        let today = MeetingsModel.shared.events(in: .today, now: now).filter { $0.end > now }.prefix(Self.maxPerGroup)
            .map { event in
                SearchItem(group: .today, title: event.title, subtitle: Fmt.time(event.start), symbol: "calendar",
                           date: event.start, target: .event(event.id))
            }
        if !today.isEmpty { out.append((.today, Array(today))) }
        let recents = Self.recents()
        if !recents.isEmpty { out.append((.recent, recents)) }
        return out
    }

    private static func upcomingEvents(now: Date) -> [SearchItem] {
        MeetingsModel.shared.events
            .filter { $0.end > now && $0.start < now.addingTimeInterval(14 * 86_400) }
            .map { event in
                SearchItem(group: .meetings, title: event.title, subtitle: Fmt.dayTime(event.start), symbol: "calendar",
                           date: event.start, target: .event(event.id))
            }
    }

    // MARK: Recents (UserDefaults)

    private struct RecentEntry: Codable {
        var title: String
        var subtitle: String
        var symbol: String
        var emoji: String?
        var target: String
    }

    static func noteOpened(_ item: SearchItem) {
        if case .action = item.target { return }   // actions are not "opened"
        var list = storedRecents().filter { $0.target != item.target.encoded }
        list.insert(RecentEntry(title: item.title, subtitle: item.subtitle, symbol: item.symbol, emoji: item.emoji,
                                target: item.target.encoded), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(5))) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    private static func storedRecents() -> [RecentEntry] {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let list = try? JSONDecoder().decode([RecentEntry].self, from: data) else { return [] }
        return list
    }

    private static func recents() -> [SearchItem] {
        storedRecents().compactMap { entry in
            guard let target = SearchTarget(encoded: entry.target) else { return nil }
            return SearchItem(group: .recent, title: entry.title, subtitle: entry.subtitle, symbol: entry.symbol,
                              emoji: entry.emoji, target: target)
        }
    }

    // MARK: Opening

    static func perform(_ target: SearchTarget, state: AppState) {
        switch target {
        case .page(let path):
            state.open(path: path)
        case .source(let id):
            if let source = state.engine.sources.first(where: { $0.id == id }) { state.open(source: source) }
        case .event(let id):
            state.pendingEventId = id
            state.selection = .meetings
        case .project(let slug):
            state.selection = .project(slug)
        case .projectTasks(let slug):
            state.pendingProjectTab = .tasks
            state.selection = .project(slug)
        case .action(let action):
            switch action {
            case .record:
                if !state.isRecording { state.recordingProjectSlug = state.currentProjectSlug }
                state.toggleRecording()
            case .pasteMail: state.requestEmail()
            case .newNote: state.noteRequest = NoteRequest(projectSlug: state.currentProjectSlug)
            case .newProject: state.showNewProject = true
            case .settings: SettingsLink.open(tab: "general")
            case .rules: SettingsLink.open(tab: "rules")
            case .formats: SettingsLink.open(tab: "formats")
            }
        }
    }
}
