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

    var color: Color {
        switch self {
        case .recording: .red
        case .queued: .secondary
        case .transcribing, .ingesting: .blue
        case .needsProject: .orange
        case .done: .green
        case .failed: .red
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
        }
    }

    var label: String {
        switch self {
        case .meeting: L("kind.meeting")
        case .document: L("kind.document")
        case .note: L("kind.note")
        case .url: L("kind.url")
        }
    }
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
        let text = (error as NSError).localizedDescription
        return text.isEmpty ? L("error.generic") : text
    }
}
