import AppKit
import BrainCore
import SwiftUI

// The one recording control (CONTRACT §15.2), shared by the sidebar footer and the menu bar:
// - a meeting on now (§12.7): a record-soft card "Kickoff… · empezó hace 3 min ›", "● Grabar", "o grabar otra cosa";
// - no meeting: a plain "Grabar" (with "Siguiente: X · 15:30" above it when one starts within the hour);
// - recording: "Detener 12:04" (or "¿Sigues en la reunión?" when it runs past the meeting's end).
// Warnings and errors of the recorder show right under it.

enum RecordControlPlacement {
    /// Main window: a new recording goes to the project being viewed (or is classified, outside a project).
    case sidebar
    /// Menu bar: the project/format/title chosen under "Detalles" are kept.
    case menuBar
}

/// Snapshots only (DebugSnapshots): a state of the control that is hard to reach offscreen.
enum RecordControlPreview {
    /// No meeting on now.
    case plain
    /// Recording for 12:04.
    case recording
}

struct RecordControl: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    var placement: RecordControlPlacement = .sidebar
    var preview: RecordControlPreview?
    @ViewState private var titleHovered = false

    private var model: MeetingsModel { MeetingsModel.shared }

    /// No TimelineView at this level: the clock comes from `MeetingsModel.now` (ticks every 20 s), so an empty state
    /// never takes a slot in the stacks around it.
    var body: some View {
        let now = model.now
        VStack(alignment: .leading, spacing: 6) {
            content(now: now)
            if let warning = state.recorderWarning {
                Label {
                    Text(warning).lineLimit(2).help(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(Brand.caption)
                .foregroundStyle(Brand.color.warning)
            }
            if let error = state.recordingError {
                errorNotice(error)
            }
        }
        // An error never stays in the footer for good: it goes away by itself after a while (or with its ×).
        .task(id: state.recordingError) {
            guard state.recordingError != nil else { return }
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            state.recordingError = nil
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if preview == .recording {
            recordingBlock
        } else if preview == .plain {
            plainButton
        } else if state.isRecording {
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
                    if let since = preview == .recording ? Date().addingTimeInterval(-724) : state.recordingSince,
                       !state.isRecorderBusy {
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
        Button { state.recordNow(placement: placement, meeting: false) } label: {
            HStack(spacing: 6) {
                if state.isRecorderBusy {
                    Text(state.recorder.state == .starting ? L("record.starting") : L("record.stopping"))
                } else {
                    PulsingDot(active: false)
                    Text(L("record.start"))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.brandRecord)
        .disabled(state.isRecorderBusy)
        .help(destinationHelp)
    }

    /// A record-soft card, ≤ 64 pt: the meeting's title (a link to Reuniones) with when it started, then "● Grabar" and
    /// "o grabar otra cosa". The title never goes inside the button, so it is never cut there. Wide: "Kickoff rediseño
    /// de la app · empezó hace 10 min" over "● Grabar … o grabar otra cosa"; at the default 220 pt the title keeps its
    /// line and the time moves beside the button, above the link; narrower still, the title gives way.
    private func meetingCard(_ live: CalendarEvent, now: Date) -> some View {
        let started = now >= live.start
        let elapsed = Fmt.shortDuration(started ? now.timeIntervalSince(live.start) : live.start.timeIntervalSince(now))
        let whenLong = started ? L("record.control.startedAgo", elapsed) : L("record.control.startsIn", elapsed)
        let whenShort = started ? L("record.control.ago", elapsed) : L("record.control.in", elapsed)
        return ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 4) {
                titleLink(live, when: whenLong) {
                    HStack(spacing: 4) {
                        cardTitle(live.title).fixedSize()
                        cardWhen("· " + whenLong).fixedSize()
                    }
                }
                HStack(spacing: 0) {
                    recordMeetingButton(live).fixedSize()
                    Spacer(minLength: 6)
                    elseLink.fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                titleLink(live, when: whenLong) { cardTitle(live.title) }
                HStack(spacing: 0) {
                    recordMeetingButton(live).fixedSize()
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 0) {
                        cardWhen(whenLong).fixedSize()
                        elseLink.fixedSize()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                titleLink(live, when: whenLong) { cardTitle(live.title) }
                HStack(spacing: 0) {
                    recordMeetingButton(live).fixedSize()
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 0) {
                        cardWhen(whenShort).fixedSize()
                        elseLink.fixedSize()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                titleLink(live, when: whenLong) {
                    HStack(spacing: 4) {
                        cardTitle(live.title)
                        cardWhen("· " + whenShort).layoutPriority(1)
                    }
                }
                recordMeetingButton(live, fullWidth: true)
                elseLink
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Brand.color.recordSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
    }

    /// The card's title line: opens the meeting in Reuniones (chevron, hover tint).
    private func titleLink(_ live: CalendarEvent, when: String, @ViewBuilder label: () -> some View) -> some View {
        Button { openMeetings(live) } label: {
            HStack(spacing: 4) {
                label()
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Brand.font(9, .semibold))
                    .foregroundStyle(Brand.color.text3)
            }
            .padding(.horizontal, 4)
            .frame(height: 16)
            .background(titleHovered ? Brand.color.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { titleHovered = $0 }
        .help(live.title + " · " + when + "\n" + L("meetings.openAgenda"))
    }

    /// "● Grabar" for the meeting on now (its title, attendees and project).
    private func recordMeetingButton(_ live: CalendarEvent, fullWidth: Bool = false) -> some View {
        Button {
            Task { await model.record(live, state: state) }
        } label: {
            HStack(spacing: 6) {
                PulsingDot(active: false)
                Text(L("record.start"))
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.brandRecord)
        .disabled(state.isRecorderBusy)
        .help(L("record.control.meeting", live.title))
    }

    private func cardTitle(_ title: String) -> some View {
        Text(title)
            .font(Brand.font(12, .semibold))
            .foregroundStyle(Brand.color.text)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func cardWhen(_ text: String) -> some View {
        Text(text)
            .font(Brand.caption)
            .foregroundStyle(Brand.color.text2)
            .lineLimit(1)
    }

    private var elseLink: some View {
        Button(L("record.control.else")) { state.recordNow(placement: placement, meeting: false) }
            .buttonStyle(.plain)
            .font(Brand.font(11, .medium))
            .foregroundStyle(Brand.color.accent)
            .lineLimit(1)
            .disabled(state.isRecorderBusy)
            .help(destinationHelp)
    }

    private func nextLine(_ next: CalendarEvent) -> some View {
        Button { openMeetings(next) } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(Brand.color.text2)
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

    /// Two lines at most (the whole text in the tooltip), a × to dismiss it, and the way to the permission it needs.
    private func errorNotice(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            VStack(alignment: .leading, spacing: 2) {
                Text(text).lineLimit(2).help(text)
                if text == L("record.needsPermission") {
                    Button(L("record.openPermissions")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Brand.font(11, .medium))
                    .foregroundStyle(Brand.color.accent)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { state.recordingError = nil } label: {
                Image(systemName: "xmark").font(Brand.font(9, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.color.text2)
            .help(L("common.close"))
        }
        .font(Brand.caption)
        .foregroundStyle(Brand.color.danger)
    }

    // MARK: Actions

    /// Where a plain "Grabar" goes, said in the tooltip (with the global shortcut).
    private var destinationHelp: String {
        var parts: [String] = []
        if placement == .sidebar, let slug = state.currentProjectSlug {
            parts.append(L("record.control.into", state.projectName(slug)))
        } else if placement == .menuBar, let slug = state.recordingProjectSlug, state.project(slug) != nil {
            parts.append(L("record.control.into", state.projectName(slug)))
        }
        if state.config.hotkeyEnabled { parts.append(L("record.hotkeyHint")) }
        return parts.joined(separator: "\n")
    }

    private func openMeetings(_ event: CalendarEvent) {
        if placement == .menuBar {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        state.pendingEventPrepare = false
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
    /// The linear bar under "Transcribiendo… 42 %" (the sidebar leaves it out: the text already says it, and the
    /// footer stays ≤ 96 pt).
    var showsProgressBar = true

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
                if showsProgressBar, let progress = status.progress {
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
