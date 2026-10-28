import SwiftUI
import BrainCore

enum Fmt {
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func shortDuration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return L("duration.lessThanMinute") }
        if minutes < 60 { return L("duration.minutes", minutes) }
        return L("duration.hoursMinutes", minutes / 60, minutes % 60)
    }

    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localizer.locale))
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localizer.locale))
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Localizer.locale
        f.unitsStyle = .full
        if Date().timeIntervalSince(date) < 60 { return L("date.justNow") }
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    // MARK: Calendar dates (v0.2: when it happened vs. when it was added)

    private static func formatter(_ template: String) -> DateFormatter {
        let key = Localizer.language + "|" + template
        if let cached = formatters[key] { return cached }
        let f = DateFormatter()
        f.locale = Localizer.locale
        f.timeZone = .autoupdatingCurrent   // cached: must follow the Mac's time zone if it changes (travel)
        f.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = f
        return f
    }
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    private static var calendar: Calendar { Calendar.current }

    /// "lun 26 de oct" / "Mon, Oct 26" (adds the year when it isn't this year).
    static func day(_ date: Date) -> String {
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return formatter(sameYear ? "EEEdMMM" : "EEEdMMMy").string(from: date)
    }

    /// "26 oct 2026".
    static func longDay(_ date: Date) -> String { formatter("dMMMy").string(from: date) }

    /// "26 oct 2026, 15:30" — or only the day when the hour is unknown.
    static func eventDate(_ date: Date, hasTime: Bool = true) -> String {
        hasTime ? formatter("dMMMyjm").string(from: date) : longDay(date)
    }

    /// "hoy 10:02", "ayer 18:40", "26 oct, 15:30", "26 oct 2025, 15:30".
    static func dayTime(_ date: Date, hasTime: Bool = true) -> String {
        let cal = calendar
        if cal.isDateInToday(date) { return hasTime ? L("date.todayAt", time(date)) : L("date.today") }
        if cal.isDateInYesterday(date) { return hasTime ? L("date.yesterdayAt", time(date)) : L("date.yesterday") }
        if cal.isDateInTomorrow(date) { return hasTime ? L("date.tomorrowAt", time(date)) : L("date.tomorrow") }
        let sameYear = cal.isDate(date, equalTo: Date(), toGranularity: .year)
        if hasTime { return formatter(sameYear ? "dMMMjm" : "dMMMyjm").string(from: date) }
        return formatter(sameYear ? "dMMM" : "dMMMy").string(from: date)
    }

    /// "octubre de 2026".
    static func month(_ date: Date) -> String { formatter("MMMMy").string(from: date) }

    /// "lunes, 26 de octubre".
    static func weekdayLong(_ date: Date) -> String {
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return formatter(sameYear ? "EEEEdMMMM" : "EEEEdMMMMy").string(from: date)
    }

    /// Whole days from today to `date` (negative = past), ignoring the hour.
    static func daysFromToday(_ date: Date) -> Int {
        let cal = calendar
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }

    /// Day-granular relative text: "hoy", "mañana", "ayer", "en 4 días", "hace 3 días".
    static func relativeDay(_ date: Date) -> String {
        let days = daysFromToday(date)
        switch days {
        case 0: return L("date.today")
        case 1: return L("date.tomorrow")
        case -1: return L("date.yesterday")
        case 2...: return L("date.inDays", days)
        default: return L("date.daysAgo", -days)
        }
    }

    /// "2026-10-26" for file names.
    static func fileDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

extension SourceRecord {
    /// When it happened ("Reunión: …", "Enviado: …").
    var eventLabel: String {
        switch kind {
        case .meeting, .inPerson: L("dates.meeting")
        case .email: L("dates.sent")
        case .document, .image: L("dates.document")
        case .note: L("dates.note")
        case .url: L("dates.url")
        case .github: "GitHub"   // MARK: v0.4 github (a name, same in every language)
        }
    }

    /// When it was added ("Agregada: …" / "Agregado: …").
    var addedLabel: String {
        switch kind {
        case .meeting, .note, .url, .inPerson, .image: L("dates.addedF")   // v0.7: "imagen", "reunión" (f)
        case .email, .document: L("dates.addedM")
        case .github: L("dates.addedM")   // MARK: v0.4 github
        }
    }

    /// ONE date: when it happened ("26 oct, 15:30", "hoy 10:02"). When it was added lives in `datesHelp`
    /// (CONTRACT §15: one date per row, "agregado" only in a tooltip).
    var datesLine: String { Fmt.dayTime(timelineDate) }

    /// "Agregado: hoy 10:02", only when it was added well after it happened (else nil).
    var addedLine: String? {
        guard abs(createdAt.timeIntervalSince(timelineDate)) > 30 * 60 else { return nil }
        return "\(addedLabel): \(Fmt.dayTime(createdAt))"
    }

    /// Tooltip with both dates: "Reunión: 26 oct 2026, 15:30 · Agregada: hoy 10:02".
    var datesHelp: String {
        let event = "\(eventLabel): \(Fmt.dayTime(timelineDate))"
        return addedLine.map { "\(event) · \($0)" } ?? event
    }

    /// Added much later than it happened (an old recording or email added today).
    var addedLater: Bool { createdAt.timeIntervalSince(timelineDate) > 36 * 3600 }

    /// The source key: the raw file name without extension (`[[key]]` in citations).
    var sourceKey: String? {
        guard let rawPath else { return nil }
        return ((rawPath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// SF Symbol of its kind (CONTRACT §15.1: never emoji as a UI icon).
    var symbol: String { kind.symbol }

    @available(*, deprecated, renamed: "symbol", message: "Emoji are not UI icons (CONTRACT §15.1); returns the SF Symbol name.")
    var emoji: String { kind.symbol }
}

extension SourceStatus {
    var label: String {
        switch self {
        case .recording: L("status.recording")
        case .queued: L("status.queued")
        case .transcribing: L("status.transcribing")
        case .needsProject: L("status.needsProject")
        case .ingesting: L("status.ingesting")
        case .done: L("status.done")
        case .failed: L("status.failed")
        }
    }

    /// Brand tone of the status (text/icon; pills use it at low opacity or `cardAlt`).
    var color: Color {
        switch self {
        case .recording: Brand.color.record
        case .queued: Brand.color.text2
        case .transcribing, .ingesting: Brand.color.accent
        case .needsProject: Brand.color.warning
        case .done: Brand.color.success
        case .failed: Brand.color.danger
        }
    }

    var isInProgress: Bool {
        switch self {
        case .recording, .queued, .transcribing, .ingesting: true
        default: false
        }
    }
}

extension SourceKind {
    var symbol: String {
        switch self {
        case .meeting: "waveform"
        case .document: "doc.text"
        case .note: "note.text"
        case .url: "link"
        case .email: "envelope"
        case .github: "chevron.left.forwardslash.chevron.right"   // MARK: v0.4 github
        case .image: "photo"           // v0.7 (§17.1)
        case .inPerson: "person.2"     // v0.7 (§17.3)
        }
    }

    @available(*, deprecated, renamed: "symbol", message: "Emoji are not UI icons (CONTRACT §15.1); returns the SF Symbol name.")
    var emoji: String { symbol }

    var label: String {
        switch self {
        case .meeting: L("kind.meeting")
        case .document: L("kind.document")
        case .note: L("kind.note")
        case .url: L("kind.url")
        case .email: L("kind.email")
        case .github: "GitHub"   // MARK: v0.4 github
        case .image: L("kind.image")         // v0.7
        case .inPerson: L("kind.inPerson")   // v0.7
        }
    }
}

extension TimelineKind {
    static let allKinds: [TimelineKind] = [.meeting, .email, .document, .note, .url, .decision, .milestone, .task]

    /// The same SF Symbols as the graph chips and the wiki sidebar (CONTRACT §12.7).
    var symbol: String {
        switch self {
        case .meeting: "waveform"
        case .email: "envelope"
        case .document: "doc.text"
        case .note: "note.text"
        case .url: "link"
        case .decision: "checkmark.seal"
        case .milestone: "flag"
        case .task: "calendar"   // a due date, not a done task
        }
    }

    @available(*, deprecated, renamed: "symbol", message: "Emoji are not UI icons (CONTRACT §15.1); returns the SF Symbol name.")
    var emoji: String { symbol }

    var label: String {
        switch self {
        case .meeting: L("tl.kind.meeting")
        case .email: L("tl.kind.email")
        case .document: L("tl.kind.document")
        case .note: L("tl.kind.note")
        case .url: L("tl.kind.url")
        case .decision: L("tl.kind.decision")
        case .milestone: L("tl.kind.milestone")
        case .task: L("tl.kind.task")
        }
    }
}

extension TemplateScope {
    var label: String {
        switch self {
        case .meeting: L("tpl.scope.meeting")
        case .email: L("tpl.scope.email")
        case .note: L("tpl.scope.note")
        case .document: L("tpl.scope.document")
        case .any: L("tpl.scope.any")
        }
    }
}

extension ExportFormat {
    var label: String {
        switch self {
        case .docx: L("export.fmt.docx")
        case .pdf: L("export.fmt.pdf")
        case .markdown: L("export.fmt.markdown")
        case .text: L("export.fmt.text")
        case .html: L("export.fmt.html")
        case .rtf: L("export.fmt.rtf")
        }
    }

    static let menuOrder: [ExportFormat] = [.docx, .pdf, .markdown, .text, .html, .rtf]
}

/// Human wording for errors that bubble up from the engine, Claude or the recorder.
enum FriendlyError {
    static func message(_ error: Error) -> String {
        if let claude = error as? ClaudeError {
            switch claude {
            case .notInstalled: return L("error.claudeNotInstalled")
            case .notAuthenticated: return L("error.claudeNotAuthenticated")
            case .rateLimited(let reset):
                if let reset { return L("error.rateLimitedUntil", Fmt.time(reset)) }
                return L("error.rateLimited")
            case .failed(let detail): return L("error.claudeFailed", detail)
            }
        }
        if let engine = error as? EngineError, case .busy = engine { return L("error.busyProject") }
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty { return described }
        let text = (error as NSError).localizedDescription
        return text.isEmpty ? L("error.generic") : text
    }
}
