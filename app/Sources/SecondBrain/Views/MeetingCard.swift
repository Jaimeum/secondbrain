import AppKit
import BrainCore
import SwiftUI

// Building blocks of Reuniones (CONTRACT §12.7): the one primary action per event, attendee initials, the project chip,
// the agenda row and a sheet to read a people page in place.

/// The single action of an event, which changes with time: Prepararme → Grabar (pulsing red) → Detener →
/// Aprendiendo… → Ver resumen ✓.
struct MeetingActionButton: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    var large = false
    /// false inside "Prepararme" itself: before the meeting there is then nothing to show.
    var showsPrepare = true
    var onPrepare: () -> Void
    /// A page outside any project (Inbox transcript, people page) to show in place.
    var onShowPage: (String) -> Void = { _ in }

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            content(phase: model.phase(of: event, state: state, now: context.date))
        }
        .controlSize(large ? .large : .regular)
    }

    @ViewBuilder private func content(phase: MeetingPhase) -> some View {
        switch phase {
        case .upcoming where !showsPrepare:
            EmptyView()
        case .upcoming:
            Button(action: onPrepare) {
                Label(L("meetings.prepare"), systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
        case .recordable:
            let busyElsewhere = state.isRecording || state.isRecorderBusy
            Button {
                let slug = model.projectSlug(for: event, state: state)
                Task { await state.startRecording(for: event, projectSlug: slug) }
            } label: {
                HStack(spacing: 6) {
                    PulsingDot(active: !busyElsewhere)
                    Text(L("meetings.record"))
                }
            }
            .buttonStyle(RecordPillStyle(large: large))
            .disabled(busyElsewhere)
            .help(busyElsewhere ? L("meetings.alreadyRecording") : L("meetings.recordHelp"))
        case .recording:
            Button {
                Task { await state.stopRecording() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    if let since = state.recordingSince {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(L("record.stopWithTime", Fmt.duration(context.date.timeIntervalSince(since)))).monospacedDigit()
                        }
                    } else {
                        Text(L("meetings.stop"))
                    }
                }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(state.isRecorderBusy)
        case .learning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("meetings.learning")).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        case .done:
            Button {
                guard let source = state.engine.meetingSource(for: event) else { return }
                Task { if let path = await state.openMeetingSummary(source) { onShowPage(path) } }
            } label: {
                Label(L("meetings.viewSummary"), systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.bordered)
            .tint(.green)
        case .failed:
            Button {
                if let source = state.engine.meetingSource(for: event) { state.engine.retry(sourceId: source.id) }
            } label: {
                Label(L("meetings.retry"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .help(L("meetings.failedHelp"))
        case .over:
            Text(L("meetings.over")).font(.callout).foregroundStyle(.tertiary)
        }
    }
}

/// Solid red "Grabar", red even when the window isn't key (a prominent button turns gray there).
struct RecordPillStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 16 : 12)
            .padding(.vertical, large ? 7 : 4)
            .background(Color.red.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: large ? 8 : 6))
            .contentShape(RoundedRectangle(cornerRadius: large ? 8 : 6))
    }
}

/// A softly pulsing dot for "Grabar".
struct PulsingDot: View {
    var active = true
    @ViewState private var on = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 8, height: 8)
            .opacity(active && on ? 0.35 : 1)
            .scaleEffect(active && on ? 0.8 : 1)
            .animation(active ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
    }
}

/// Up to 4 initials + "+n". Hover shows the names.
struct AttendeeInitials: View {
    let attendees: [EmailAddress]
    var size: CGFloat = 22
    var maxShown = 4

    var body: some View {
        if !attendees.isEmpty {
            HStack(spacing: -5) {
                ForEach(Array(attendees.prefix(maxShown).enumerated()), id: \.offset) { _, a in
                    InitialsCircle(address: a, size: size)
                }
                if attendees.count > maxShown {
                    Text("+\(attendees.count - maxShown)")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 9)
                }
            }
            .help(attendees.map(\.display).joined(separator: ", "))
        }
    }
}

struct InitialsCircle: View {
    let address: EmailAddress
    var size: CGFloat = 22

    var body: some View {
        Text(Self.initials(address))
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(for: address.email ?? address.display), in: Circle())
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
    }

    static func initials(_ a: EmailAddress) -> String {
        if let name = a.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains("@") {
            let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." }).filter { $0.first?.isLetter == true }
            let letters = words.count >= 2 ? [words.first!, words.last!] : Array(words.prefix(1))
            let s = letters.compactMap { $0.first.map(String.init) }.joined().uppercased()
            if !s.isEmpty { return s }
        }
        return (a.email?.first).map { String($0).uppercased() } ?? "?"
    }

    /// Stable color per person (not `hashValue`, which changes on every launch).
    static func color(for key: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown, .cyan, .mint]
        let hash = key.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))].opacity(0.85)
    }
}

/// "🚀 Acme" (change) · "¿Es de 🚀 Acme? ✓ ✗" · gray "Sin proyecto". ✓ remembers it for the series; ✗ opens the picker.
struct MeetingProjectChip: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        if let slug = model.projectSlug(for: event, state: state) {
            picker { chip(state.projectName(slug), color: .accentColor) }
                .help(L("meetings.changeProject"))
        } else if let suggestion = model.suggestion(for: event, state: state), let project = state.project(suggestion.projectSlug) {
            HStack(spacing: 4) {
                Text(L("meetings.isItProject", "\(project.emoji) \(project.name)"))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Button {
                    model.setProject(.project(project.slug), for: event, state: state)
                } label: {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .help(event.seriesId == nil ? L("meetings.yesProject") : L("meetings.yesProjectSeries"))
                picker {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .help(L("meetings.otherProject"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .help(reason(suggestion))
        } else if model.choice(for: event) == .noProject {
            picker { chip(L("meetings.noProject"), color: .secondary, chevron: true) }
                .help(L("meetings.noProjectHelp"))
        } else {
            // Nothing chosen yet: it must read as something to click, not as a tag.
            picker {
                HStack(spacing: 3) {
                    Text(L("meetings.chooseProject"))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
            .help(L("meetings.noProjectHelp"))
        }
    }

    /// The project menu with a custom label (a borderless menu would drop the chip's background).
    private func picker(@ViewBuilder label: () -> some View) -> some View {
        Menu { items } label: { label() }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    @ViewBuilder private var items: some View {
        ForEach(state.projects) { project in
            Button("\(project.emoji) \(project.name)") { model.setProject(.project(project.slug), for: event, state: state) }
        }
        Divider()
        Button(L("meetings.noProject")) { model.setProject(.noProject, for: event, state: state) }
    }

    private func chip(_ text: String, color: Color, chevron: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(text)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color == .secondary ? Color.secondary : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(color == .secondary ? 0.1 : 0.14), in: Capsule())
    }

    private func reason(_ s: MeetingSuggestion) -> String {
        switch s.reason {
        case .title: L("meetings.reasonTitle")
        case .people(let names): L("meetings.reasonPeople", ListFormatter.localizedString(byJoining: names))
        }
    }
}

/// One meeting in the agenda: time, title, who, project, and its one action.
struct MeetingCard: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    var isSelected = false
    var onSelect: () -> Void
    var onPrepare: () -> Void
    var onShowPage: (String) -> Void

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let live = event.isInProgress(at: now)
        let past = !live && event.end < now
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                if event.isAllDay {
                    Text(L("meetings.allDay")).font(.caption.weight(.semibold)).multilineTextAlignment(.trailing)
                } else {
                    Text(Fmt.time(event.start)).font(.callout.weight(.semibold)).monospacedDigit()
                    Text(Fmt.time(event.end)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 58, alignment: .trailing)
            .foregroundStyle(past ? .secondary : .primary)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(live ? Color.red : (past ? Color.secondary.opacity(0.3) : Color.accentColor.opacity(0.6)))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(past ? .secondary : .primary)
                        .lineLimit(2)
                    if live {
                        Text(L("meetings.inProgress"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                    }
                }
                HStack(spacing: 10) {
                    AttendeeInitials(attendees: model.others(in: event), size: 22)
                    if let place = event.location, !place.isEmpty {
                        Label(place, systemImage: event.joinURL != nil ? "video" : "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                MeetingProjectChip(event: event)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MeetingActionButton(event: event, onPrepare: onPrepare, onShowPage: onShowPage)
                .fixedSize()
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onSelect)
    }
}

/// A people (or other non-project) page, read without leaving Reuniones.
struct VaultPageSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let path: String
    @ViewState private var current: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.engine.vault.title(of: current ?? path)).font(.headline).lineLimit(1)
                Spacer()
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            WikiWebView(vault: state.engine.vault, path: current ?? path) { next in
                if !state.openProjectPage(next) { current = next } else { dismiss() }
            }
        }
        .frame(width: 680, height: 600)
    }
}

/// `.sheet(item:)` wrapper for a vault path.
struct VaultPageItem: Identifiable, Equatable {
    let path: String
    var id: String { path }
}

/// Notes of an invitation as text with clickable links.
struct LinkedText: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text)).textSelection(.enabled)
    }

    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let target = Range<AttributedString.Index>(range, in: out) else { continue }
            out[target].link = url
        }
        return out
    }
}
