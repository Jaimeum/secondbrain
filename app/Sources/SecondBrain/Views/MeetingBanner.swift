import AppKit
import BrainCore
import SwiftUI

/// Sidebar footer and menu bar (CONTRACT §12.7): "Kickoff · empezó hace 3 min — Grabar" while a meeting is on,
/// "Siguiente: X · 15:30" when the next one starts within an hour, "¿Sigues en la reunión? · Detener" when a recording
/// runs past the end. Nothing otherwise. Grabar from here brings the title, project and attendees.
struct MeetingBanner: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    var inMenuBar = false

    private var model: MeetingsModel { MeetingsModel.shared }

    /// No TimelineView or modifiers here: with nothing to say the banner must be truly empty, so the stacks around it
    /// keep their spacing. The clock comes from `MeetingsModel.now` (ticks every 20 s; the model is started with the engine).
    var body: some View {
        content(now: model.now)
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if let id = state.recordingEventId, let event = model.event(id: id),
           MeetingAgenda.isOverrunning(event, now: now, recordingEventId: id) {
            MeetingOverrunRow(event: event, now: now, compact: true)
        } else if !state.isRecording, let live = MeetingAgenda.current(in: model.events, now: now),
                  model.phase(of: live, state: state, now: now) == .recordable {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(live.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(now < live.start ? L("meetings.startsIn", Fmt.shortDuration(live.start.timeIntervalSince(now)))
                                          : L("meetings.startedAgo", Fmt.shortDuration(now.timeIntervalSince(live.start))))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: openMeetings)
                Button {
                    let slug = model.projectSlug(for: live, state: state)
                    Task { await state.startRecording(for: live, projectSlug: slug) }
                } label: {
                    HStack(spacing: 4) {
                        PulsingDot()
                        Text(L("meetings.record"))
                    }
                }
                .buttonStyle(RecordPillStyle())
                .disabled(state.isRecorderBusy)
                .help(L("meetings.recordHelp"))
            }
            .padding(8)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else if let next = MeetingAgenda.next(in: model.events, now: now), next.start.timeIntervalSince(now) <= 3600 {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text(L("meetings.nextAt", next.title, Fmt.time(next.start)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture(perform: openMeetings)
            .help(L("meetings.openAgenda"))
        }
    }

    private func openMeetings() {
        if inMenuBar {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        state.selection = .meetings
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
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("meetings.stillThere")).font((compact ? Font.caption : .callout).weight(.semibold))
                Text(L("meetings.endedAgoTitle", event.title, Fmt.shortDuration(now.timeIntervalSince(event.end))))
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("meetings.stop")) { Task { await state.stopRecording() } }
                .controlSize(compact ? .small : .regular)
                .disabled(state.isRecorderBusy)
        }
        .padding(compact ? 8 : 10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
