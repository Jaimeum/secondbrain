import AppKit
import BrainCore
import Foundation

// MARK: v0.6 navigation (CONTRACT §16.1, §16.12): the sidebar, the one router and what it leaves for each screen.

/// Sidebar destinations (§16.1): Inicio ⌘1 · Preguntar ⌘2 · Grafo ⌘3 · Pendientes ⌘4 · Personas ⌘5 — Fuentes: Correo ⌘6 ·
/// Reuniones ⌘7 · Sin asignar (only while something waits) — Proyectos.
enum SidebarItem: Hashable {
    case home
    case ask
    case graph
    case tasks
    case people
    case mail
    case meetings
    case unassigned
    case project(String)

    /// The items above "Fuentes", in order (⌘1–⌘5).
    static let main: [SidebarItem] = [.home, .ask, .graph, .tasks, .people]
    /// "Fuentes" (⌘6, ⌘7; Sin asignar has no shortcut and only shows with a count).
    static let sources: [SidebarItem] = [.mail, .meetings]

    var title: String {
        switch self {
        case .home: L("home.title")
        case .ask: L("sidebar.ask")
        case .graph: L("sidebar.graph")
        case .tasks: L("tasks.title")
        case .people: L("sidebar.people")
        case .mail: L("sidebar.mail")
        case .meetings: L("sidebar.meetings")
        case .unassigned: L("inbox.title")
        case .project(let slug): slug
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .ask: "bubble.left.and.text.bubble.right"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .tasks: "checklist"
        case .people: "person.2"
        case .mail: "envelope"
        case .meetings: "calendar"
        case .unassigned: "tray"
        case .project: "folder"
        }
    }

    /// ⌘1–⌘7 (the "Ir" menu).
    var shortcut: Character? {
        switch self {
        case .home: "1"
        case .ask: "2"
        case .graph: "3"
        case .tasks: "4"
        case .people: "5"
        case .mail: "6"
        case .meetings: "7"
        case .unassigned, .project: nil
        }
    }
}

/// Screens pushed inside Inicio's NavigationStack.
enum HomeRoute: Hashable {
    /// A global page's ficha (index.md, log.md, orgs/…, questions/…) opened from a global place (§16.4).
    case entity(String)
    /// "Ver todo por fecha": the timeline of every project.
    case timeline
}

/// The one router's targets (§16.12). Every way of going somewhere (sidebar, ⌘K, notifications, links, Inicio)
/// ends in `AppState.navigate(to:)`.
enum Destination: Hashable {
    /// A sidebar item as is (⌘1–⌘7, a row click). Re-selecting Inicio pops it to its root.
    case sidebar(SidebarItem)
    /// A vault page's ficha (§16.4), opened in the context of `scope`: inside a project, its own pages open in
    /// Contenido and any other page is pushed as a ficha filtered to the project; from the brain, a project page
    /// opens in its project, a person in Personas, anything else in Inicio.
    case entity(String, Scope)
    /// A project on one of its tabs.
    case projectTab(String, ProjectTab)
    /// A task (`TaskItem.id`, "projects/<slug>/wiki/tasks.md#…"): its project's Pendientes with the row highlighted.
    case task(String)
    /// A calendar event in Reuniones; `prepare` opens it on its preparation ("Prepararme").
    case event(String, prepare: Bool = false)
    /// Preguntar of a scope: a saved conversation (`threadId`), or the current one when nil.
    case chat(Scope, String?)
    /// Grafo of a scope, centered on a vault path when given ("Ver en el grafo").
    case graph(Scope, String?)
}

/// What Preguntar does once on screen (left by the router in `AppState.pendingChat`).
struct ChatRequest: Equatable {
    var scope: Scope
    /// A saved conversation to show (§16.3); nil = the current one (or a new one with `newThread`).
    var threadId: String?
    /// Asked as soon as Preguntar shows (⌘K "Preguntar a todo el cerebro: «…»").
    var question: String?
    /// Start a new conversation first.
    var newThread = false
}

/// "Historial" over any screen (notifications of failed jobs and limits, §16.12).
struct HistoryRequest: Identifiable, Equatable {
    let id = UUID()
    var projectSlug: String?
}

/// "Enlace…" from the sidebar's "+ Agregar" (MainView presents `PasteLinkSheet`).
struct LinkRequest: Identifiable, Equatable {
    let id = UUID()
    var projectSlug: String?
}

extension AppState {
    /// The single router (§16.12). Every pending request of the previous navigation is dropped first, so nothing
    /// stale is consumed later by a screen it wasn't meant for; then only the requests of this destination are set,
    /// and the screen that consumes them clears them. A project that doesn't exist (any more) is selected without
    /// requests: MainView shows "Este proyecto ya no está".
    func navigate(to destination: Destination) {
        clearPending()
        searchPresented = false
        switch destination {
        case .sidebar(let item):
            select(item)

        case .entity(let path, let scope):
            if let slug = scope.projectSlug, project(slug) != nil {
                // In a project: its own page in Contenido, any other as a ficha filtered to it (ProjectView decides).
                pendingPage = path
                if Scope.projectSlug(ofPath: path) == slug { pendingProjectTab = .content }
                select(.project(slug))
            } else if let slug = Scope.projectSlug(ofPath: path), project(slug) != nil {
                pendingPage = path
                pendingProjectTab = .content
                select(.project(slug))
            } else if path.hasPrefix("people/") {
                pendingPage = path
                select(.people)
            } else {
                homeRoute = .entity(path)
                select(.home)
            }

        case .projectTab(let slug, let tab):
            if project(slug) != nil { pendingProjectTab = tab }
            select(.project(slug))

        case .task(let id):
            pendingTaskId = id
            if let slug = Scope.projectSlug(ofPath: id), project(slug) != nil {
                pendingProjectTab = .tasks
                select(.project(slug))
            } else {
                select(.tasks)
            }

        case .event(let id, let prepare):
            pendingEventId = id
            pendingEventPrepare = prepare
            select(.meetings)

        case .chat(let scope, let threadId):
            routeChat(ChatRequest(scope: scope, threadId: threadId))

        case .graph(let scope, let focus):
            if let slug = scope.projectSlug {
                guard project(slug) != nil else { select(.project(slug)); return }
                pendingGraphFocus = focus
                pendingProjectTab = .graph
                select(.project(slug))
            } else {
                pendingGraphFocus = focus
                select(.graph)
            }
        }
    }

    /// Drops every request a screen hasn't consumed yet.
    func clearPending() {
        pendingPage = nil
        pendingProjectTab = nil
        pendingGraphFocus = nil
        pendingEventId = nil
        pendingEventPrepare = false
        pendingTaskId = nil
        pendingChat = nil
        pendingSourceHighlight = nil
        homeRoute = nil
    }

    /// Selects a sidebar item; Inicio re-selected (row, ⌘1) goes back to its root.
    private func select(_ item: SidebarItem) {
        if item == .home, selection == .home { homePopToken += 1 }
        selection = item
    }

    private func routeChat(_ request: ChatRequest) {
        if let slug = request.scope.projectSlug {
            guard project(slug) != nil else { select(.project(slug)); return }
            pendingChat = request
            pendingProjectTab = .ask
            select(.project(slug))
        } else {
            pendingChat = request
            select(.ask)
        }
    }

    // MARK: Thin wrappers (kept for existing callers)

    /// Opens any vault page where it lives, from a global place (§16.4).
    func open(path: String) {
        navigate(to: .entity(path, .brain))
    }

    /// A source from a list (Recientes, ⌘K, a notification): its page once learned, else its project's Contenido (or
    /// Sin asignar).
    func open(source: SourceRecord) {
        if source.status == .done, let path = engine.pagePath(forSourceId: source.id) {
            navigate(to: .entity(path, Scope(projectSlug: source.projectSlug)))
        } else if let slug = source.projectSlug, project(slug) != nil {
            navigate(to: .projectTab(slug, .content))
        } else {
            openUnassigned(highlighting: source.status == .failed ? source.id : nil)
        }
    }

    /// "Preguntar: «…»": asked in a new conversation of `scope` (⌘K always asks the whole brain, §16.7).
    func ask(_ question: String, scope: Scope = .brain) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        clearPending()
        searchPresented = false
        routeChat(ChatRequest(scope: scope, question: q, newThread: true))
    }

    /// Sin asignar, optionally with one source's row highlighted (a "failed" notification).
    func openUnassigned(highlighting sourceId: String? = nil) {
        navigate(to: .sidebar(.unassigned))
        pendingSourceHighlight = sourceId
    }

    /// Opens a vault page from Reuniones: a project page inside its project. Returns false for people and global
    /// pages, which the caller shows in place.
    @discardableResult
    func openProjectPage(_ path: String) -> Bool {
        guard let slug = Scope.projectSlug(ofPath: path) else { return false }
        navigate(to: .entity(path, .project(slug)))
        return true
    }

    /// "Editar" on a page or ficha (§16.6): MainView presents `PageEditorHost` over everything.
    func editPage(_ path: String) {
        editingPage = path
    }

    /// The project being viewed, if any ("Grabar" and "+ Agregar" from the window go into it).
    var currentProjectSlug: String? {
        if case .project(let slug) = selection { return slug }
        return nil
    }

    /// The place on screen as a scope (a project, else the whole brain).
    var currentScope: Scope { Scope(projectSlug: currentProjectSlug) }

    /// Sin asignar's count, as its list shows it (needs a project, or failed without one; one row per email thread).
    var unassignedCount: Int {
        InboxView.onePerThread(engine.sources.filter {
            $0.status == .needsProject || ($0.projectSlug == nil && $0.status == .failed)
        }).count
    }

    // MARK: Notifications (§16.12)

    /// Notification ids are `notifyOnce` keys: `done-<source>-…` → the source's ficha; `inbox-<source>` → Sin asignar;
    /// `failed-<source>-…` → Sin asignar with the row highlighted; `job-…`/`rate-…` → Historial; `automail-<t>-<slug>`
    /// (rule auto-add) → the project's Contenido.
    func route(notificationId id: String) {
        func source(after prefix: String) -> SourceRecord? {
            let rest = id.dropFirst(prefix.count)
            return engine.sources.first { rest.hasPrefix($0.id + "-") || rest == $0.id }
        }
        if id.hasPrefix("done-") {
            if let source = source(after: "done-") { open(source: source) } else { navigate(to: .sidebar(.home)) }
        } else if id.hasPrefix("inbox-") {
            navigate(to: .sidebar(.unassigned))
        } else if id.hasPrefix("failed-") {
            let source = source(after: "failed-")
            if let source, let slug = source.projectSlug, project(slug) != nil {
                navigate(to: .projectTab(slug, .content))
            } else {
                openUnassigned(highlighting: source?.id)
            }
        } else if id.hasPrefix("job-") || id.hasPrefix("rate-") || id.hasPrefix("hist-") {
            clearPending()
            historyRequest = HistoryRequest(projectSlug: nil)
        } else if id.hasPrefix("automail-") {
            // "automail-<unix time>-<slug>" (slugs may contain dashes).
            let rest = id.dropFirst("automail-".count)
            if let dash = rest.firstIndex(of: "-") {
                navigate(to: .projectTab(String(rest[rest.index(after: dash)...]), .content))
            } else {
                navigate(to: .sidebar(.home))
            }
        }
    }
}
