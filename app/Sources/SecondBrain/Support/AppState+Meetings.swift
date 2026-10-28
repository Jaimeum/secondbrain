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

    /// "Ver resumen ✓": the meeting page Claude wrote (else the transcript).
    func openMeetingSummary(_ source: SourceRecord) async -> String? {
        let vault = engine.vault
        let page = await Task.detached { SourcePages.summaryPage(for: source, vault: vault) }.value
        guard let path = page ?? source.rawPath else { return nil }
        return openProjectPage(path) ? nil : path
    }
}
