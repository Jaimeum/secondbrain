import AppKit
import BrainCore
import Foundation

// MARK: v0.3 meetings (CONTRACT §12.5, §12.7)

extension AppState {
    /// The calendar event being recorded right now, if the recording was started from one.
    var recordingEventId: String? {
        guard isRecording else { return nil }
        return recorder.current?.calendarEventId
    }

    /// "Grabar" on a meeting: the recording takes the event's title, project and attendees, and its source is tied to the
    /// event (`calendarEventId`, event date = start). Without a project it goes to Inbox as usual.
    func startRecording(for event: CalendarEvent, projectSlug: String?) async {
        guard !isRecording, !isRecorderBusy else { return }
        let previous = (title: recordingTitle, projectSlug: recordingProjectSlug)
        recordingTitle = event.title
        recordingProjectSlug = projectSlug
        let mine = MeetingsModel.shared.myEmails.union(engine.accounts.accounts.map(\.email))
        let names = event.attendees
            .filter { a in !(a.email.map { mine.contains($0.lowercased()) } ?? false) }
            .map(\.display)
        await startRecording(calendarEventId: event.id, attendees: names.isEmpty ? nil : names)
        if isRecording, let current = recorder.current, current.calendarEventId == event.id {
            engine.linkCalendarEvent(sourceId: current.id, event: event)
        } else {
            // It didn't start (no permission, recorder error): the next manual recording must not inherit this meeting.
            recordingTitle = previous.title
            recordingProjectSlug = previous.projectSlug
        }
    }

    /// Opens a vault page from Reuniones: a project page opens inside its project. Returns false for people and global
    /// pages, which the caller shows in place.
    @discardableResult
    func openProjectPage(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count > 2, parts[0] == "projects" else { return false }
        pendingPage = path
        pendingProjectTab = .content
        selection = .project(String(parts[1]))
        return true
    }

    // MARK: v0.5 navigation (CONTRACT §15.2)

    /// Opens any vault page where it lives: a project page inside its project (Contenido tab), a people page in
    /// Personas, a global page (index.md, log.md…) pushed inside Inicio.
    func open(path: String) {
        if openProjectPage(path) { return }
        if path.hasPrefix("people/") {
            pendingPage = path
            selection = .people
            return
        }
        selection = .home
        homeRoute = .page(path)
    }

    /// A source from a list (Recientes, ⌘K): its wiki page once learned, else its project (or Sin asignar).
    func open(source: SourceRecord) {
        if source.status == .done, let path = engine.pagePath(forSourceId: source.id) {
            open(path: path)
        } else if let slug = source.projectSlug, project(slug) != nil {
            pendingProjectTab = .content
            selection = .project(slug)
        } else {
            selection = .home
            homeRoute = .inbox
        }
    }

    /// "Preguntar: «…»" (⌘K): the whole brain in Inicio, or one project's Preguntar tab.
    func ask(_ question: String, projectSlug: String? = nil) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if let projectSlug, project(projectSlug) != nil {
            pendingQuestion = q
            pendingProjectTab = .ask
            selection = .project(projectSlug)
        } else {
            selection = .home
            homeRoute = .ask(q)
        }
    }

    /// The project being viewed, if any (⌥ in ⌘K asks it; "Grabar" from the window records into it).
    var currentProjectSlug: String? {
        if case .project(let slug) = selection { return slug }
        return nil
    }

    /// "Ver resumen ✓": the meeting page Claude wrote (else the transcript).
    func openMeetingSummary(_ source: SourceRecord) async -> String? {
        let vault = engine.vault
        let page = await Task.detached { SourcePages.summaryPage(for: source, vault: vault) }.value
        guard let path = page ?? source.rawPath else { return nil }
        return openProjectPage(path) ? nil : path
    }
}
