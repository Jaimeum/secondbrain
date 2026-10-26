import Foundation

/// Where a calendar event stands in the before → during → after loop (CONTRACT §12.7 "Reuniones"). Each phase has ONE
/// primary action in the UI.
public enum MeetingPhase: String, Sendable, Equatable {
    /// Before start − 2 min → "Prepararme".
    case upcoming
    /// From start − 2 min to end + 5 min and not recorded yet → red pulsing "Grabar".
    case recordable
    /// This event is being recorded right now → timer + "Detener".
    case recording
    /// A source with this `calendarEventId` is being transcribed / learned → "Aprendiendo…".
    case learning
    /// Learned → "Ver resumen ✓".
    case done
    /// Learning failed → "Reintentar".
    case failed
    /// Ended (end + 5 min) without a recording, or an all-day event that is over.
    case over
}

/// Pure agenda logic shared by the app and the self-tests: phases, dedupe across accounts, "Ahora / Siguiente".
public enum MeetingAgenda {
    /// "Grabar" shows up this long before the start…
    public static let recordLead: TimeInterval = 2 * 60
    /// …and stays until this long after the end ("¿Sigues en la reunión?" when still recording).
    public static let recordGrace: TimeInterval = 5 * 60

    /// The phase of `event` at `now`. `recordingEventId` = the event being recorded (nil = not recording one);
    /// `source` = the newest source whose `calendarEventId` is this event's id.
    public static func phase(of event: CalendarEvent, now: Date, recordingEventId: String?, source: SourceRecord?) -> MeetingPhase {
        if let recordingEventId, recordingEventId == event.id { return .recording }
        if let source {
            switch source.status {
            case .done: return .done
            case .failed: return .failed
            case .recording, .queued, .transcribing, .needsProject, .ingesting: return .learning
            }
        }
        if event.isAllDay {
            return now < event.end ? .upcoming : .over
        }
        if now < event.start.addingTimeInterval(-recordLead) { return .upcoming }
        if now <= event.end.addingTimeInterval(recordGrace) { return .recordable }
        return .over
    }

    /// Recording this event and it ended more than 5 minutes ago: ask "¿Sigues en la reunión?".
    public static func isOverrunning(_ event: CalendarEvent, now: Date, recordingEventId: String?) -> Bool {
        recordingEventId == event.id && !event.isAllDay && now >= event.end.addingTimeInterval(recordGrace)
    }

    /// The meeting happening now (start − 2 min … end), preferring the one that started last; all-day events never count.
    public static func current(in events: [CalendarEvent], now: Date) -> CalendarEvent? {
        events.filter { $0.isInProgress(at: now) }.max { $0.start < $1.start }
    }

    /// The next meeting that hasn't reached its "Grabar" window yet (all-day events skipped).
    public static func next(in events: [CalendarEvent], now: Date) -> CalendarEvent? {
        events.filter { !$0.isAllDay && $0.start.addingTimeInterval(-recordLead) > now }.min { $0.start < $1.start }
    }

    /// Same meeting seen through two accounts (an invite to both work and personal calendars) → one row. Two events are
    /// the same when their titles match (case, accents and spacing ignored) and they start in the same minute. The kept
    /// copy is the richest one (attendees, join link, notes) and borrows what it lacks from the others.
    public static func dedupe(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var order: [String] = []
        var byKey: [String: CalendarEvent] = [:]
        for event in events {
            let key = dedupeKey(event)
            guard var kept = byKey[key] else {
                order.append(key)
                byKey[key] = event
                continue
            }
            var other = event
            if richness(other) > richness(kept) { swap(&kept, &other) }
            if kept.joinURL == nil { kept.joinURL = other.joinURL }
            if kept.notes?.isEmpty ?? true { kept.notes = other.notes }
            if kept.location?.isEmpty ?? true { kept.location = other.location }
            if kept.seriesId == nil { kept.seriesId = other.seriesId }
            byKey[key] = kept
        }
        return order.compactMap { byKey[$0] }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    public static func dedupeKey(_ event: CalendarEvent) -> String {
        let title = event.title
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let minute = Int((event.start.timeIntervalSince1970 / 60).rounded(.down))
        return "\(title)|\(minute)"
    }

    private static func richness(_ e: CalendarEvent) -> Int {
        e.attendees.count * 2 + (e.joinURL == nil ? 0 : 3) + ((e.notes?.isEmpty ?? true) ? 0 : 1)
    }
}
