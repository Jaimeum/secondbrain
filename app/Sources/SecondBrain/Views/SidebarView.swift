import BrainCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var showNewProject: Bool

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selection) {
            Section {
                Label(L("sidebar.brain"), systemImage: "brain.head.profile")
                    .tag(SidebarItem.brain)
                Label(L("mytasks.title"), systemImage: "checklist")
                    .badge(overdueBadge)
                    .tag(SidebarItem.myTasks)
                    .help(state.overdueCount > 0 ? L("mytasks.overdueHelp", state.overdueCount) : "")
                Label(L("inbox.title"), systemImage: "tray")
                    .badge(state.inboxCount)
                    .tag(SidebarItem.inbox)
                Label(L("sidebar.mail"), systemImage: "envelope")
                    .tag(SidebarItem.mail)
                Label(L("sidebar.meetings"), systemImage: "calendar")
                    .tag(SidebarItem.meetings)
                Label(L("sidebar.people"), systemImage: "person.2")
                    .tag(SidebarItem.people)
                Label(L("tpl.title"), systemImage: "doc.richtext")
                    .tag(SidebarItem.templates)
            }

            Section(L("sidebar.projects")) {
                ForEach(state.projects) { project in
                    ProjectRow(project: project, inProgress: state.inProgressCount(project.slug))
                        .tag(SidebarItem.project(project.slug))
                        .contextMenu {
                            Button(L("email.addEllipsis")) { state.requestEmail(projectSlug: project.slug) }
                        }
                }
                Button {
                    showNewProject = true
                } label: {
                    Label(L("sidebar.newProject"), systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button(L("email.addEllipsis")) { state.requestEmail() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
    }
}

private extension SidebarView {
    /// Red count of my overdue tasks (a plain badge can't be tinted, so it's text).
    var overdueBadge: Text? {
        guard state.overdueCount > 0 else { return nil }
        return Text("\(state.overdueCount)").foregroundStyle(.red)
    }
}

private struct ProjectRow: View {
    let project: Project
    let inProgress: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(project.emoji).font(.system(size: 15))
            Text(project.name).lineLimit(1)
            Spacer(minLength: 4)
            if inProgress > 0 {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("\(inProgress)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .help(L("sidebar.inProgress", inProgress))
            }
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MeetingBanner()   // MARK: v0.3 meetings
            QueueStatusLine()
            RecordButton(large: true)
            if let warning = state.recorderWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.recordingError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

/// "Transcribing… 42%", "Learning from the meeting…", "Waiting for Claude until 15:40".
/// No TimelineView here: an empty TimelineView still takes a slot in the surrounding stack (an extra blank gap in the
/// menu bar and the sidebar footer). The clock comes from `MeetingsModel.now`, which ticks every 20 s.
struct QueueStatusLine: View {
    @Environment(AppState.self) private var state

    var body: some View {
        content(now: MeetingsModel.shared.now)
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if let status = state.queueStatus(now: now) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if status.waiting {
                        Image(systemName: "hourglass").foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let progress = status.progress {
                    ProgressView(value: progress).controlSize(.small)
                }
            }
        }
    }
}

struct RecordButton: View {
    @Environment(AppState.self) private var state
    var large = false

    /// The meeting banner above already offers "Grabar" for the meeting on now: this one becomes the plain secondary
    /// "Grabar otra cosa" (one primary action, CONTRACT §12.7).
    private var meetingOffered: Bool {
        !state.isRecording && !state.isRecorderBusy && MeetingBanner.recordableNow(state: state, now: MeetingsModel.shared.now) != nil
    }

    var body: some View {
        if meetingOffered {
            button.buttonStyle(.bordered).controlSize(.large)
        } else {
            button.buttonStyle(.borderedProminent)
                .tint(state.isRecording ? .red : .accentColor)
                .controlSize(.large)
        }
    }

    private var button: some View {
        Button {
            // From the main window, a new recording goes to the project being viewed.
            if large, !state.isRecording, case .project(let slug) = state.selection {
                state.recordingProjectSlug = slug
            }
            state.toggleRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: large ? 15 : 13, weight: .semibold))
                if let since = state.recordingSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(L("record.stopWithTime", Fmt.duration(context.date.timeIntervalSince(since))))
                            .monospacedDigit()
                    }
                } else if state.isRecorderBusy {
                    Text(state.recorder.state == .starting ? L("record.starting") : L("record.stopping"))
                } else {
                    Text(meetingOffered ? L("record.somethingElse") : L("record.start"))
                }
            }
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, large ? 9 : 7)
        }
        .disabled(state.isRecorderBusy)
        .help(state.config.hotkeyEnabled ? L("record.hotkeyHint") : "")
    }
}
