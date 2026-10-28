import AppKit
import BrainCore
import Foundation
import Observation

// ⌘K (CONTRACT §16.7): always global. Two indexes, rebuilt when the vault, the tasks or the accounts change:
// - rows (`items`): every wiki page, meeting, email thread, note, task, project and action, matched by title (folded:
//   no accents or case; prefix > start of a word > contains, with a boost for recent things);
// - `fullText` (BrainCore): the text of every wiki page, refreshed per changed file, so a page whose title doesn't
//   hold the query is still found by its body and shown with a snippet. A title match always ranks over a body match.

enum SearchGroup: String, CaseIterable, Hashable {
    case today, recent, people, orgs, topics, decisions, meetings, mail, notes, questions, repos, tasks, projects, actions
    case files   // v0.7 (§17.2): Archivos

    var title: String {
        switch self {
        case .today: L("search.group.today")
        case .recent: L("search.group.recent")
        case .people: L("search.group.people")
        case .orgs: L("search.group.orgs")
        case .topics: L("search.group.topics")
        case .decisions: L("search.group.decisions")
        case .meetings: L("search.group.meetings")
        case .mail: L("search.group.mail")
        case .notes: L("search.group.notes")
        case .questions: L("search.group.questions")
        case .repos: L("search.group.repos")
        case .tasks: L("search.group.tasks")
        case .projects: L("search.group.projects")
        case .actions: L("search.group.actions")
        case .files: L("search.group.files")
        }
    }

    /// Order of the groups for a query (§16.7).
    static let resultOrder: [SearchGroup] = [.people, .orgs, .topics, .decisions, .meetings, .mail, .notes, .files,
                                             .questions, .repos, .tasks, .projects, .actions]

    /// Where a wiki page goes, and its icon.
    static func of(_ kind: SearchPageKind) -> (group: SearchGroup, symbol: String) {
        switch kind {
        case .person: (.people, "person")
        case .org: (.orgs, "building.2")
        case .topic: (.topics, "tag")
        case .decision: (.decisions, "checkmark.seal")
        case .meeting: (.meetings, "waveform")
        case .emailThread: (.mail, "envelope")
        case .note: (.notes, "doc.text")
        case .question: (.questions, "questionmark.bubble")
        case .repo: (.repos, "chevron.left.forwardslash.chevron.right")
        case .project: (.projects, "doc.text")
        }
    }
}

/// §16.7's list, in this order: Grabar is one more, not the first.
enum SearchAction: String, CaseIterable {
    case newNote, addFile, pasteLink, pasteMail, record, newProject, settings, rules, formats, facts

    var title: String {
        switch self {
        case .newNote: L("search.action.newNote")
        case .addFile: L("search.action.addFile")
        case .pasteLink: L("search.action.pasteLink")
        case .pasteMail: L("search.action.pasteMail")
        case .record: L("search.action.record")
        case .newProject: L("search.action.newProject")
        case .settings: L("search.action.settings")
        case .rules: L("search.action.rules")
        case .formats: L("search.action.formats")
        case .facts: L("search.action.facts")
        }
    }

    var symbol: String {
        switch self {
        case .newNote: "square.and.pencil"
        case .addFile: "doc.badge.plus"
        case .pasteLink: "link"
        case .pasteMail: "envelope"
        case .record: "record.circle"
        case .newProject: "folder.badge.plus"
        case .settings: "gearshape"
        case .rules: "arrow.triangle.branch"
        case .formats: "doc.richtext"
        case .facts: "checkmark.shield"
        }
    }

    /// The vault page "Hechos confirmados" opens (§16.6).
    static let factsPath = "facts.md"
}

/// Where a result goes. `encoded` round-trips through UserDefaults ("Abiertos hace poco").
enum SearchTarget: Hashable {
    case page(String)
    case source(String)
    case event(String)
    case project(String)
    /// Recents saved by v0.5: a project's Pendientes tab (a task now opens with `.task`).
    case projectTasks(String)
    case task(String)
    case action(SearchAction)
    /// v0.7 (§17.2): a file of Archivos (vault-relative path), opened there with its panel.
    case file(String)

    var encoded: String {
        switch self {
        case .page(let p): "page:" + p
        case .source(let id): "source:" + id
        case .event(let id): "event:" + id
        case .project(let s): "project:" + s
        case .projectTasks(let s): "tasks:" + s
        case .task(let id): "task:" + id
        case .action(let a): "action:" + a.rawValue
        case .file(let p): "file:" + p
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
        case "task": self = .task(value)
        case "action": guard let a = SearchAction(rawValue: value) else { return nil }; self = .action(a)
        case "file": self = .file(value)
        default: return nil
        }
    }
}

struct SearchItem: Identifiable, Hashable {
    /// Unique per row (two rows can open the same place).
    var id: String { group.rawValue + "|" + target.encoded + "|" + uid }
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
    /// Tells apart rows that open the same place (the task's id); empty for everything else.
    var uid: String
    /// The wiki page whose text this row stands for in the full-text index (its page; a project's overview).
    var docPath: String?
    /// Set on a result found by its text: the passage around the match, matches in bold.
    var snippet: [SnippetPart]?

    init(group: SearchGroup, title: String, subtitle: String = "", symbol: String = "doc.text", emoji: String? = nil,
         date: Date? = nil, target: SearchTarget, extra: String = "", uid: String = "", docPath: String? = nil) {
        self.uid = uid
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.emoji = emoji
        self.date = date
        self.target = target
        self.docPath = docPath
        key = SearchIndex.fold(extra.isEmpty ? title : title + " " + extra)
    }
}

/// One group of results: the rows shown, and how many more "Ver n más" shows.
struct SearchSection: Identifiable {
    let group: SearchGroup
    let items: [SearchItem]
    let more: Int
    var id: SearchGroup { group }
}

@MainActor @Observable
final class SearchIndex {
    static let shared = SearchIndex()

    private(set) var items: [SearchItem] = []
    /// The text of every wiki page (thread-safe; refreshed off the main thread).
    @ObservationIgnored let fullText = FullTextIndex()
    @ObservationIgnored private var builtKey: String?
    @ObservationIgnored private var fullTextGeneration: Int?
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    static let maxPerGroup = 4
    /// An expanded group ("Ver n más") stops here.
    static let maxExpanded = 40
    static let recentsKey = "search.recent"

    // MARK: Building

    /// The language is part of it: action titles, "Sin asignar" and "Todo el cerebro" are stored already translated.
    private func revisionKey(_ state: AppState) -> String {
        "\(state.vaultGeneration)-\(state.vaultRevision)-\(state.tasksRevision)-\(state.accountsRevision)-\(state.projects.count)-\(state.config.uiLanguage)"
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
            guard let self, !Task.isCancelled else { return }
            let built = await self.build(state: state)
            guard !Task.isCancelled else { return }
            self.items = built
            self.builtKey = key
        }
    }

    /// Builds now and waits (snapshots).
    func rebuild(state: AppState) async {
        buildTask?.cancel()
        items = await build(state: state)
        builtKey = revisionKey(state)
    }

    /// Brings the full-text index up to date (only new and changed files are read), off the main thread.
    private func refreshFullText(state: AppState) async {
        if fullTextGeneration != state.vaultGeneration {
            fullText.reset()   // another vault: nothing of the old one applies
            fullTextGeneration = state.vaultGeneration
        }
        let index = fullText, root = state.engine.vault.root
        _ = await Task.detached(priority: .userInitiated) { index.refresh(root: root) }.value
    }

    private func build(state: AppState) async -> [SearchItem] {
        await refreshFullText(state: state)
        let engine = state.engine
        var out: [SearchItem] = []
        func projectLabel(_ slug: String?) -> String { state.projectName(slug) }
        let projectsBySlug = Dictionary(state.projects.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })

        // Every wiki page, as the full-text index read it. Meetings, email threads and documents are found by the
        // title Claude gave their page, which is what people remember ("Comité de la alianza"), not by the
        // recording's default title ("Reunión 26 oct 09:00").
        let pages = fullText.pages().sorted { $0.path < $1.path }
        var pageByPath: [String: SearchPageInfo] = [:]
        for page in pages { pageByPath[page.path.lowercased()] = page }
        func displayTitle(_ title: String, in slug: String?) -> String {
            guard let project = slug.flatMap({ projectsBySlug[$0] }) else { return title }
            for prefix in [project.name + " — ", project.name + " - "] where title.hasPrefix(prefix) {
                return String(title.dropFirst(prefix.count))
            }
            return title
        }
        /// The summary page of a source (meeting page, email-thread page, document page).
        func summaryPage(of source: SourceRecord) -> SearchPageInfo? {
            guard let slug = source.projectSlug, let raw = source.rawPath else { return nil }
            let key = ((raw as NSString).lastPathComponent as NSString).deletingPathExtension
            let path: String
            switch source.kind {
            case .meeting, .inPerson: path = "projects/\(slug)/wiki/meetings/\(key).md"
            case .email: path = "projects/\(slug)/wiki/emails/\(source.threadKey ?? key).md"
            case .note, .document, .url, .image: path = "projects/\(slug)/wiki/sources/\(key).md"
            case .github: return nil
            }
            return pageByPath[path.lowercased()]
        }
        var covered = Set<String>()   // lowercased paths a source row already stands for

        // v0.7 (§17.2): Archivos — every file, found by its name, its thread and the text of its summary page.
        let sources = engine.sources, root = engine.vault.root
        let files = await Task.detached(priority: .userInitiated) {
            FileIndex.shared(vaultRoot: root).refresh(sources: sources)
        }.value
        let fileSources = Set(files.compactMap(\.sourceId))
        for file in files {
            var sub = projectLabel(file.projectSlug)
            if let subject = file.threadSubject { sub += " · ✉️ " + subject }
            sub += " · " + Fmt.dayTime(file.date)
            out.append(SearchItem(group: .files, title: file.name, subtitle: sub, symbol: file.type.symbol, date: file.date,
                                  target: .file(file.path),
                                  extra: [file.summaryTitle, file.threadSubject, file.sender?.display].compactMap { $0 }
                                      .joined(separator: " "),
                                  uid: file.path, docPath: file.summaryPath))
        }

        // Sources: meetings, notes/documents/links, and one row per email thread (its newest message).
        var threads: [String: SourceRecord] = [:]
        var threadCounts: [String: Int] = [:]
        func sourceItem(_ source: SourceRecord, group: SearchGroup, symbol: String) -> SearchItem {
            let sub = projectLabel(source.projectSlug) + " · " + Fmt.dayTime(source.timelineDate)
            if let page = summaryPage(of: source) {
                covered.insert(page.path.lowercased())
                let title = displayTitle(page.title, in: page.projectSlug)
                return SearchItem(group: group, title: title, subtitle: sub, symbol: symbol, date: source.timelineDate,
                                  target: .page(page.path), extra: title == source.title ? "" : source.title,
                                  docPath: page.path)
            }
            return SearchItem(group: group, title: source.title, subtitle: sub, symbol: symbol,
                              date: source.timelineDate, target: .source(source.id))
        }
        for source in engine.sources {
            switch source.kind {
            case .meeting:
                out.append(sourceItem(source, group: .meetings, symbol: "waveform"))
            case .inPerson:   // v0.7 (§17.3)
                out.append(sourceItem(source, group: .meetings, symbol: source.kind.symbol))
            case .note, .document, .url:
                out.append(sourceItem(source, group: .notes, symbol: source.kind.symbol))
            case .image:   // v0.7 (§17.2): an image is a file; its Archivos row stands for it (below)
                if !fileSources.contains(source.id) { out.append(sourceItem(source, group: .files, symbol: source.kind.symbol)) }
            case .email:
                let key = source.threadKey ?? source.id
                threadCounts[key, default: 0] += 1
                if let current = threads[key], current.timelineDate >= source.timelineDate { continue }
                threads[key] = source
            case .github:
                continue
            }
        }
        for (key, source) in threads {
            var item = sourceItem(source, group: .mail, symbol: "envelope")
            item.subtitle += " · " + L("thread.count", threadCounts[key] ?? 1)   // v0.7 (§17.4): "· 7 correos"
            out.append(item)
        }

        // Pages no source row stands for (people, companies, topics, decisions, saved questions, repos, facts.md, and
        // meeting, email and document pages written on another Mac or imported), each in the group of its folder.
        for page in pages where !covered.contains(page.path.lowercased()) {
            let project = page.projectSlug.flatMap { projectsBySlug[$0] }
            // A project's overview is the text of its project row ("En breve"), not a row of its own.
            if let project, page.path == "projects/\(project.slug)/wiki/overview.md" { continue }
            let (group, symbol) = SearchGroup.of(page.kind)
            let title = displayTitle(page.title, in: page.projectSlug)
            var sub = project.map { $0.emoji + " " + $0.name } ?? (page.kind == .person ? "" : L("search.globalPage"))
            let dated: Set<SearchGroup> = [.meetings, .mail, .notes, .decisions, .questions]
            if let date = page.date, dated.contains(group) { sub += " · " + Fmt.dayTime(date) }
            out.append(SearchItem(group: group, title: title, subtitle: sub, symbol: symbol,
                                  date: dated.contains(group) ? page.date : nil, target: .page(page.path),
                                  extra: project?.name ?? "", docPath: page.path))
        }

        // Open tasks: each opens its project's Pendientes with the row highlighted.
        for task in await engine.tasks(projectSlug: nil) where !task.done {
            var sub = projectLabel(task.projectSlug)
            if let due = task.due { sub += " · " + Fmt.relativeDay(due) }
            out.append(SearchItem(group: .tasks, title: task.text, subtitle: sub, symbol: "circle", date: task.due,
                                  target: .task(task.id), extra: task.ownerName ?? "", uid: task.id))
        }

        for project in state.projects {
            out.append(SearchItem(group: .projects, title: project.name, subtitle: project.description,
                                  emoji: project.emoji, target: .project(project.slug),
                                  docPath: "projects/\(project.slug)/wiki/overview.md"))
        }
        for action in SearchAction.allCases {
            out.append(SearchItem(group: .actions, title: action.title, symbol: action.symbol, target: .action(action)))
        }
        return out
    }

    // MARK: Matching

    /// The index's folding (no accents, no case), so titles and page text compare the same way.
    nonisolated static func fold(_ s: String) -> String { FullTextIndex.fold(s) }

    /// 3 prefix, 2 start of a word, 1 contains (every word of the query must appear), 0 no match.
    nonisolated static func score(_ key: String, query q: String) -> Double { FullTextIndex.titleScore(key, query: q) }

    /// Up to +0.9 for things that happened (or are due) close to now.
    static func recencyBoost(_ date: Date?, now: Date) -> Double {
        guard let date else { return 0 }
        let days = abs(date.timeIntervalSince(now)) / 86_400
        return 0.9 * exp(-days / 30)
    }

    /// Grouped results for a non-empty query (upcoming events come live from the agenda, not the index). A row whose
    /// title holds the query scores `titleBoost` + 1…3; one found only by its page's text scores ≤ `maxBodyScore` and
    /// carries a snippet. Groups in `expanded` show up to `maxExpanded` rows instead of `maxPerGroup`. Body scores
    /// (≤ 1.5) + recency (≤ 0.9) stay under `titleBoost`, so a title match always heads its group.
    func results(for query: String, expanded: Set<SearchGroup> = [], now: Date = Date()) -> [SearchSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = Self.fold(trimmed)
        guard !q.isEmpty else { return [] }
        var hits: [String: FullTextHit] = [:]
        for hit in fullText.search(trimmed) { hits[hit.path] = hit }
        let actionOrder = Dictionary(uniqueKeysWithValues: SearchAction.allCases.enumerated().map { ($1, $0) })
        var scored: [SearchGroup: [(score: Double, item: SearchItem, needsSnippet: Bool)]] = [:]
        for item in items + Self.upcomingEvents(now: now) {
            let title = Self.score(item.key, query: q)
            var score = title > 0 ? FullTextIndex.titleBoost + title : 0
            var needsSnippet = false
            if let path = item.docPath, let hit = hits[path], hit.score > score {
                score = hit.score
                needsSnippet = !hit.titleMatch && hit.bodyOffset != nil
            }
            guard score > 0 else { continue }
            scored[item.group, default: []].append((score + Self.recencyBoost(item.date, now: now), item, needsSnippet))
        }
        // Groups in §16.7's order, but those with a title match first: typing "comi" shows "Comité de la alianza"
        // before the people whose pages merely mention it.
        let byTitle = SearchGroup.resultOrder.filter { group in
            scored[group]?.contains { $0.score >= FullTextIndex.titleBoost } ?? false
        }
        let order = byTitle + SearchGroup.resultOrder.filter { !byTitle.contains($0) }
        return order.compactMap { group in
            guard let list = scored[group], !list.isEmpty else { return nil }
            let sorted = list.sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if case .action(let x) = a.item.target, case .action(let y) = b.item.target {
                    return actionOrder[x, default: 0] < actionOrder[y, default: 0]
                }
                return a.item.title < b.item.title
            }
            let limit = expanded.contains(group) ? Self.maxExpanded : Self.maxPerGroup
            let shown = sorted.prefix(limit).map { entry -> SearchItem in
                guard entry.needsSnippet, let path = entry.item.docPath else { return entry.item }
                var item = entry.item
                item.snippet = fullText.snippet(path: path, query: trimmed)
                return item
            }
            return SearchSection(group: group, items: shown, more: sorted.count - shown.count)
        }
    }

    /// Empty query: today's meetings and the last things opened from here.
    func suggestions(now: Date = Date()) -> [SearchSection] {
        var out: [SearchSection] = []
        let today = MeetingsModel.shared.events(in: .today, now: now).filter { $0.end > now }.prefix(Self.maxPerGroup)
            .map { event in
                SearchItem(group: .today, title: event.title, subtitle: Fmt.time(event.start), symbol: "calendar",
                           date: event.start, target: .event(event.id))
            }
        if !today.isEmpty { out.append(SearchSection(group: .today, items: Array(today), more: 0)) }
        let recents = Self.recents(state: AppState.shared)
        if !recents.isEmpty { out.append(SearchSection(group: .recent, items: recents, more: 0)) }
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

    /// One list per vault: a recent from another vault would open nothing.
    private static func recentsKey(_ state: AppState) -> String { recentsKey + "|" + state.config.vaultPath }

    static func noteOpened(_ item: SearchItem, state: AppState) {
        if case .action = item.target { return }   // actions are not "opened"
        var list = storedRecents(state).filter { $0.target != item.target.encoded }
        list.insert(RecentEntry(title: item.title, subtitle: item.subtitle, symbol: item.symbol, emoji: item.emoji,
                                target: item.target.encoded), at: 0)
        store(Array(list.prefix(5)), state: state)
    }

    private static func forget(_ target: SearchTarget, state: AppState) {
        let list = storedRecents(state)
        let kept = list.filter { $0.target != target.encoded }
        if kept.count != list.count { store(kept, state: state) }
    }

    private static func store(_ list: [RecentEntry], state: AppState) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: recentsKey(state))
        }
    }

    private static func storedRecents(_ state: AppState) -> [RecentEntry] {
        guard let data = UserDefaults.standard.data(forKey: recentsKey(state)),
              let list = try? JSONDecoder().decode([RecentEntry].self, from: data) else { return [] }
        return list
    }

    /// Only what still opens something: a deleted project, source, page or task drops out of the list.
    private static func recents(state: AppState) -> [SearchItem] {
        storedRecents(state).compactMap { entry in
            guard let target = SearchTarget(encoded: entry.target), resolves(target, state: state) else { return nil }
            return SearchItem(group: .recent, title: entry.title, subtitle: entry.subtitle, symbol: entry.symbol,
                              emoji: entry.emoji, target: target)
        }
    }

    private static func resolves(_ target: SearchTarget, state: AppState) -> Bool {
        switch target {
        case .page(let path): FileManager.default.fileExists(atPath: state.engine.vault.url(for: path).path)
        case .source(let id): state.engine.sources.contains { $0.id == id }
        case .project(let slug), .projectTasks(let slug): state.project(slug) != nil
        case .task(let id):
            // Still open in the index (a recent of a task done since then would highlight nothing).
            shared.items.isEmpty || shared.items.contains { $0.uid == id }
        case .event, .action: true
        case .file(let path): FileManager.default.fileExists(atPath: state.engine.vault.url(for: path).path)
        }
    }

    // MARK: Opening

    static func perform(_ target: SearchTarget, state: AppState) {
        guard resolves(target, state: state) else {
            forget(target, state: state)
            return
        }
        switch target {
        case .page(let path):
            state.navigate(to: .entity(path, .brain))
        case .source(let id):
            if let source = state.engine.sources.first(where: { $0.id == id }) { state.open(source: source) }
        case .event(let id):
            state.navigate(to: .event(id, prepare: false))
        case .project(let slug):
            state.navigate(to: .sidebar(.project(slug)))
        case .projectTasks(let slug):
            state.navigate(to: .projectTab(slug, .tasks))
        case .task(let id):
            state.navigate(to: .task(id))
        case .action(let action):
            perform(action, state: state)
        case .file(let path):
            FilesModel.reveal(path, state: state)
        }
    }

    private static func perform(_ action: SearchAction, state: AppState) {
        switch action {
        case .newNote: state.noteRequest = NoteRequest(projectSlug: state.currentProjectSlug)
        case .addFile: addFiles(state: state)
        case .pasteLink: state.linkRequest = LinkRequest(projectSlug: state.currentProjectSlug)
        case .pasteMail: state.requestEmail()
        case .record: state.recordNow(placement: .sidebar)
        case .newProject: state.showNewProject = true
        case .settings: SettingsLink.open(tab: "general")
        case .rules: SettingsLink.open(tab: "rules")
        case .formats: SettingsLink.open(tab: "formats")
        case .facts: state.navigate(to: .entity(SearchAction.factsPath, .brain))
        }
    }

    /// "Agregar archivo": like the sidebar's "+ Agregar › Archivo…", into the project on screen.
    private static func addFiles(state: AppState) {
        guard let batch = SourceImport.chooseFiles() else { return }
        let slug = state.currentProjectSlug
        Task {
            let failed = await SourceImport.importURLs(batch.urls, projectSlug: slug, state: state)
            guard !failed.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = L("common.oops")
            alert.informativeText = failed.joined(separator: "\n")
            alert.runModal()
        }
    }
}
