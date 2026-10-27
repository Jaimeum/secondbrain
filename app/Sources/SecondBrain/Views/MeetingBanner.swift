import AppKit
import BrainCore
import SwiftUI

// The one recording control (CONTRACT §15.2), shared by the sidebar footer and the menu bar:
// - a meeting on now (§12.7): a record-soft card "● Grabar «Kickoff…»" · "hace 3 min" · "o grabar otra cosa";
// - no meeting: a plain "Grabar" (with "Siguiente: X · 15:30" above it when one starts within the hour);
// - recording: "Detener 12:04" (or "¿Sigues en la reunión?" when it runs past the meeting's end).
// Warnings and errors of the recorder show right under it.

enum RecordControlPlacement {
    /// Main window: a new recording goes to the project being viewed (or is classified, outside a project).
    case sidebar
    /// Menu bar: the project/format/title chosen under "Detalles" are kept.
    case menuBar
}

struct RecordControl: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    var placement: RecordControlPlacement = .sidebar

    private var model: MeetingsModel { MeetingsModel.shared }

    /// No TimelineView at this level: the clock comes from `MeetingsModel.now` (ticks every 20 s), so an empty state
    /// never takes a slot in the stacks around it.
    var body: some View {
        let now = model.now
        VStack(alignment: .leading, spacing: 6) {
            content(now: now)
            if let warning = state.recorderWarning {
                notice(warning, symbol: "exclamationmark.triangle", color: Brand.color.warning)
            }
            if let error = state.recordingError {
                notice(error, symbol: "exclamationmark.circle", color: Brand.color.danger)
            }
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if state.isRecording {
            if let id = state.recordingEventId, let event = model.event(id: id),
               MeetingAgenda.isOverrunning(event, now: now, recordingEventId: id) {
                MeetingOverrunRow(event: event, now: now, compact: true)
            } else {
                recordingBlock
            }
        } else if let live = MeetingBanner.recordableNow(state: state, now: now) {
            meetingCard(live, now: now)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let next = MeetingAgenda.next(in: model.events, now: now), next.start.timeIntervalSince(now) <= 3600 {
                    nextLine(next)
                }
                plainButton
            }
        }
    }

    // MARK: Pieces

    private var recordingBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                BrandRecordingDot(size: 7)
                Text(recordingLabel)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Button {
                Task { await state.stopRecording() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    if let since = state.recordingSince, !state.isRecorderBusy {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(L("record.stopWithTime", Fmt.duration(context.date.timeIntervalSince(since))))
                                .monospacedDigit()
                        }
                    } else {
                        Text(L("record.stopping"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brandRecord)
            .disabled(state.isRecorderBusy)
            .help(state.config.hotkeyEnabled ? L("record.hotkeyHint") : "")
        }
    }

    private var recordingLabel: String {
        let title = state.recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [title.isEmpty ? L("status.recording") : title]
        if let slug = state.recordingProjectSlug, state.project(slug) != nil { parts.append(state.projectName(slug)) }
        return parts.joined(separator: " · ")
    }

    private var plainButton: some View {
        Button(action: recordPlain) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                Text(state.isRecorderBusy
                     ? (state.recorder.state == .starting ? L("record.starting") : L("record.stopping"))
                     : L("record.start"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.brandRecord)
        .disabled(state.isRecorderBusy)
        .help(destinationHelp)
    }

    /// "● Grabar «Kickoff…»" on a record-soft card, with the time and "o grabar otra cosa" under it.
    private func meetingCard(_ live: CalendarEvent, now: Date) -> some View {
        let when = now < live.start
            ? L("record.control.in", Fmt.shortDuration(live.start.timeIntervalSince(now)))
            : L("record.control.ago", Fmt.shortDuration(now.timeIntervalSince(live.start)))
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await model.record(live, state: state) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                    Text(L("record.control.meeting", live.title))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brandRecord)
            .disabled(state.isRecorderBusy)
            .help(live.title + " · " + when)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Button { openMeetings(live) } label: {
                        Text(when).lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.color.text2)
                    .help(L("meetings.openAgenda"))
                    Spacer(minLength: 4)
                    elseLink
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    elseLink
                }
            }
            .font(Brand.caption)
        }
        .padding(8)
        .background(Brand.color.recordSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
    }

    private var elseLink: some View {
        Button(L("record.control.else"), action: recordPlain)
            .buttonStyle(.plain)
            .font(Brand.font(11, .medium))
            .foregroundStyle(Brand.color.accent)
            .lineLimit(1)
            .fixedSize()
            .disabled(state.isRecorderBusy)
            .help(destinationHelp)
    }

    private func nextLine(_ next: CalendarEvent) -> some View {
        Button { openMeetings(next) } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(Brand.color.text3)
                Text(L("meetings.nextAt", next.title, Fmt.time(next.start)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(Brand.caption)
            .foregroundStyle(Brand.color.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("meetings.openAgenda"))
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        Label {
            Text(text).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(Brand.caption)
        .foregroundStyle(color)
    }

    // MARK: Actions

    /// Where a plain "Grabar" goes, said in the tooltip (with the global shortcut).
    private var destinationHelp: String {
        var parts: [String] = []
        if placement == .sidebar, let slug = state.currentProjectSlug {
            parts.append(L("record.control.into", state.projectName(slug)))
        }
        if state.config.hotkeyEnabled { parts.append(L("record.hotkeyHint")) }
        return parts.joined(separator: "\n")
    }

    private func recordPlain() {
        // From the main window a new recording belongs to the project on screen; elsewhere it gets classified.
        if placement == .sidebar, !state.isRecording { state.recordingProjectSlug = state.currentProjectSlug }
        state.toggleRecording()
    }

    private func openMeetings(_ event: CalendarEvent) {
        if placement == .menuBar {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        state.pendingEventId = event.id
        state.selection = .meetings
    }
}

/// Kept for source compatibility (v0.3 name of the footer banner): it is now part of `RecordControl`.
struct MeetingBanner: View {
    var inMenuBar = false

    var body: some View {
        RecordControl(placement: inMenuBar ? .menuBar : .sidebar)
    }

    /// The meeting the control offers to record right now (its own "Grabar"), if any.
    @MainActor static func recordableNow(state: AppState, now: Date) -> CalendarEvent? {
        let model = MeetingsModel.shared
        guard !state.isRecording, let live = MeetingAgenda.current(in: model.events, now: now),
              model.phase(of: live, state: state, now: now) == .recordable else { return nil }
        return live
    }
}

/// Kept for source compatibility: the old standalone record button is now `RecordControl`.
struct RecordButton: View {
    var large = false

    var body: some View {
        RecordControl(placement: large ? .sidebar : .menuBar)
    }
}

/// Top of Reuniones while a recording runs past the meeting's end.
struct MeetingOverrunBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            if let id = state.recordingEventId, let event = MeetingsModel.shared.event(id: id),
               MeetingAgenda.isOverrunning(event, now: context.date, recordingEventId: id) {
                MeetingOverrunRow(event: event, now: context.date, compact: false)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// "¿Sigues en la reunión? · Detener".
struct MeetingOverrunRow: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    let now: Date
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "questionmark.circle").foregroundStyle(Brand.color.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("meetings.stillThere"))
                        .font(compact ? Brand.font(12, .semibold) : Brand.callout)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                    Text(L("meetings.endedAgoTitle", event.title, Fmt.shortDuration(now.timeIntervalSince(event.end))))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(compact ? 1 : 2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !compact { stopButton }
            }
            if compact { stopButton.frame(maxWidth: .infinity) }
        }
        .padding(compact ? 8 : 10)
        .background(Brand.color.warningSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
    }

    private var stopButton: some View {
        Button {
            Task { await state.stopRecording() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                Text(L("meetings.stop"))
            }
            .frame(maxWidth: compact ? .infinity : nil)
        }
        .buttonStyle(.brandRecord)
        .disabled(state.isRecorderBusy)
    }
}

/// "Procesando 2…", "Transcribiendo “Kickoff”… 42 %", "Esperando a Claude hasta las 15:40" (never "pendientes":
/// that is the word for tasks). The clock comes from `MeetingsModel.now` (no TimelineView: an empty one still takes a
/// slot in the surrounding stack).
struct QueueStatusLine: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let status = state.queueStatus(now: MeetingsModel.shared.now) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if status.waiting {
                        Image(systemName: "hourglass")
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.warning)
                            .frame(width: 14, height: 14)
                    } else {
                        BrandLoader(size: 14)
                    }
                    Text(status.text)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .monospacedDigit()
                }
                if let progress = status.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Brand.color.accent)
                        .controlSize(.mini)
                }
            }
            .help(status.text)
        }
    }
}
