import AppKit
import BrainCore
import SwiftUI

// Building blocks of Reuniones (CONTRACT §12.7, §15): the one primary action per event, attendee initials, the project
// chip, the agenda row, the row of a recorded meeting and a sheet to read a people page in place.

/// The single action of an event, which changes with time: Prepararme → Grabar → Detener → Aprendiendo… →
/// Ver resumen. Labels follow the environment's `labelStyle`, so a container can fall back to `.iconOnly`.
struct MeetingActionButton: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    var large = false
    /// false inside "Prepararme" itself and in agenda rows: before the meeting there is then nothing to show.
    var showsPrepare = true
    var onPrepare: () -> Void
    /// A page outside any project (Sin asignar transcript, people page) to show in place.
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
            .buttonStyle(.brandSecondary)
            .help(L("meetings.prepare"))
        case .recordable:
            let busyElsewhere = state.isRecording || state.isRecorderBusy
            Button {
                Task { await model.record(event, state: state) }
            } label: {
                Label { Text(L("meetings.record")) } icon: { PulsingDot(active: !busyElsewhere) }
            }
            .buttonStyle(.brandRecord)
            .disabled(busyElsewhere)
            .help(busyElsewhere ? L("meetings.alreadyRecording") : L("meetings.recordHelp"))
        case .recording:
            Button {
                Task { await state.stopRecording() }
            } label: {
                Label {
                    if let since = state.recordingSince {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(L("record.stopWithTime", Fmt.duration(context.date.timeIntervalSince(since)))).monospacedDigit()
                        }
                    } else {
                        Text(L("meetings.stop"))
                    }
                } icon: {
                    Image(systemName: "stop.fill")
                }
            }
            .buttonStyle(.brandRecord)
            .disabled(state.isRecorderBusy)
            .help(L("meetings.stop"))
        case .learning:
            BrandLoader(size: 14, text: L("meetings.learning"))
                .padding(.vertical, 4)
        case .done:
            Button {
                guard let source = state.engine.meetingSource(for: event) else { return }
                Task { if let path = await state.openMeetingSummary(source) { onShowPage(path) } }
            } label: {
                Label(L("meetings.viewSummary"), systemImage: "checkmark.circle")
            }
            .buttonStyle(.brandSecondary)
            .help(L("meetings.viewSummary"))
        case .failed:
            Button {
                if let source = state.engine.meetingSource(for: event) { state.engine.retry(sourceId: source.id) }
            } label: {
                Label(L("meetings.retry"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.brandSecondary)
            .help(L("meetings.failedHelp"))
        case .over:
            // The meeting's state, not decoration: text2 (AA on surface) and a symbol, so it never relies on color.
            Label(L("meetings.over"), systemImage: "clock")
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(1)
        }
    }
}

/// "Unirme" (only for safe join links); same metrics as the action next to it.
struct MeetingJoinButton: View {
    let event: CalendarEvent
    var large = false

    var body: some View {
        if let join = event.joinURL, JoinLink.isSafe(join) {
            Button { NSWorkspace.shared.open(join) } label: {
                Label(L("meetings.join"), systemImage: "video")
            }
            .buttonStyle(.brandSecondary)
            .controlSize(large ? .large : .regular)
            .help(L("meetings.join"))
        }
    }
}

/// "Grabar" outside the brand button style's call sites (the sidebar banner): the brand `record` button.
struct RecordPillStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        BrandRecordButtonStyle().makeBody(configuration: configuration)
            .controlSize(large ? .large : .regular)
    }
}

/// The dot inside "Grabar" (`onRecord`, same as the record button label): beats in opacity only (0.35 → 1, 1 s), never in scale or position (§15.1).
/// Static with Reduce Motion or when `active` is false.
struct PulsingDot: View {
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if active && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    Circle().fill(Brand.color.onRecord).opacity(0.675 + 0.325 * cos(phase * 2 * .pi))
                }
            } else {
                Circle().fill(Brand.color.onRecord)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }
}

/// Up to 3 initials + "+n". Hover shows the names. `ring` = the opaque background the circles sit on; `ringTint` = a
/// translucent fill drawn over it (a selected row, the live hero), so the ring matches the container exactly.
struct AttendeeInitials: View {
    let attendees: [EmailAddress]
    var size: CGFloat = 22
    var maxShown = 3
    var ring: Color = Brand.color.card
    var ringTint: Color? = nil

    var body: some View {
        if !attendees.isEmpty {
            HStack(spacing: -size * 0.18) {
                ForEach(Array(attendees.prefix(maxShown).enumerated()), id: \.offset) { _, a in
                    InitialsCircle(address: a, size: size, ring: ring, ringTint: ringTint)
                }
                if attendees.count > maxShown {
                    Text("+\(attendees.count - maxShown)")
                        .font(Brand.font(max(10, size * 0.42), .medium))
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .padding(.leading, size * 0.3)
                }
            }
            .help(attendees.map(\.display).joined(separator: ", "))
        }
    }
}

/// A person's initials on the brand avatar tokens (`cardAlt` + `text2`; no per-person colors).
struct InitialsCircle: View {
    let address: EmailAddress
    var size: CGFloat = 22
    var ring: Color = Brand.color.card
    /// Translucent container fill over `ring` (see `AttendeeInitials`).
    var ringTint: Color? = nil

    var body: some View {
        Text(Self.initials(address))
            .font(Brand.avatar.font(size))
            .foregroundStyle(Brand.avatar.initials)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: size, height: size)
            .background(Self.color(for: address.email ?? address.display), in: Circle())
            .overlay(Circle().strokeBorder(ring, lineWidth: 1.5))
            .overlay { if let ringTint { Circle().strokeBorder(ringTint, lineWidth: 1.5) } }
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

    /// Avatar background. One brand token for everyone (§15.1); kept as a function for existing callers.
    static func color(for key: String) -> Color { Brand.avatar.background }
}

/// "🚀 Acme ▾" (change) · "🚀 Acme · por regla «…»" · "¿Es de 🚀 Acme? ✓ ✗" · "Sin asignar ▾" · "Elegir proyecto ▾".
/// ✓ remembers it for the series; ✗ opens the picker. After a manual choice the §14.3 rule offer shows right under the
/// chip that was used. Used in the hero, the detail and Prepararme (agenda rows show a read-only chip instead).
struct MeetingProjectChip: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    var placement: MeetingChipPlacement = .detail
    /// false where the container shows `MeetingRuleOfferLine` itself on its own row.
    var showsOffer = true

    private var model: MeetingsModel { MeetingsModel.shared }
    /// Longest chip label before it truncates (a flexible frame still hugs short names under `fixedSize`).
    private let maxLabelWidth: CGFloat = 200

    var body: some View {
        if showsOffer {
            VStack(alignment: .leading, spacing: 6) {
                content
                MeetingRuleOfferLine(event: event, placement: placement)
            }
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        let resolution = model.resolution(for: event, state: state)
        switch resolution.origin {
        case .manual:
            picker { chip(state.projectName(resolution.projectSlug), slug: resolution.projectSlug) }
                .help(L("meetings.changeProject"))
        case .rule(let rule):
            // MARK: v0.4 routing — decided by a rule: confirmed, no question, and it says which rule.
            withSubtitle(L("rules.meetings.byRule", ruleLabel(rule))) {
                if let slug = resolution.projectSlug {
                    picker { chip(state.projectName(slug), slug: slug) }
                } else {
                    picker { chip(L("meetings.noProject"), slug: nil) }
                }
            }
            .help(L("rules.meetings.byRuleHelp", ruleLabel(rule)))
        case .defaultProject:
            withSubtitle(L("rules.meetings.byDefault")) {
                picker { chip(state.projectName(resolution.projectSlug), slug: resolution.projectSlug) }
            }
            .help(L("rules.meetings.byDefaultHelp"))
        case .suggestion(let suggestion):
            if let project = state.project(suggestion.projectSlug) {
                HStack(spacing: 6) {
                    Text(L("meetings.isItProject", "\(project.emoji) \(project.name)"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: maxLabelWidth, alignment: .leading)
                        .foregroundStyle(Brand.color.text)
                    Button {
                        model.setProject(.project(project.slug), for: event, state: state, offerAt: placement)
                    } label: {
                        Image(systemName: "checkmark").foregroundStyle(Brand.color.accent)
                    }
                    .buttonStyle(.borderless)
                    .help(event.seriesId == nil ? L("meetings.yesProject") : L("meetings.yesProjectSeries"))
                    picker {
                        Image(systemName: "xmark").foregroundStyle(Brand.color.text2)
                    }
                    .help(L("meetings.otherProject"))
                }
                .font(Brand.font(11, .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Brand.color.accentSoft))
                .help(reason(suggestion))
            }
        case .manualNone:
            picker { chip(L("meetings.noProject"), slug: nil) }
                .help(L("meetings.noProjectHelp"))
        case .none:
            // Nothing chosen yet: an active chip with a chevron, so it reads as something to click.
            picker { chip(L("meetings.chooseProject"), slug: nil, active: true) }
                .help(L("meetings.noProjectHelp"))
        }
    }

    /// "🚀 Acme  por regla «…»" on one line when it fits, else the reason under the chip.
    private func withSubtitle(_ text: String, @ViewBuilder chip: () -> some View) -> some View {
        let label = Text(text).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1).truncationMode(.tail)
        let c = chip()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { c; label }
            VStack(alignment: .leading, spacing: 3) { c; label }
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
            Button("\(project.emoji) \(project.name)") {
                model.setProject(.project(project.slug), for: event, state: state, offerAt: placement)
            }
        }
        Divider()
        Button(L("meetings.noProject")) { model.setProject(.noProject, for: event, state: state) }
    }

    private func chip(_ text: String, slug: String?, active: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxLabelWidth, alignment: .leading)
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .foregroundStyle(active ? Brand.color.accent : Brand.color.text3)
        }
        .font(Brand.font(11, .medium))
        .foregroundStyle(active ? Brand.color.accent : (slug == nil ? Brand.color.text2 : Brand.color.text))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(active ? Brand.color.accentSoft : Brand.color.cardAlt))
        .contentShape(Capsule())
    }

    private func reason(_ s: MeetingSuggestion) -> String {
        switch s.reason {
        case .title: L("meetings.reasonTitle")
        case .people(let names): L("meetings.reasonPeople", ListFormatter.localizedString(byJoining: names))
        }
    }
}

/// Where a meeting happens: a video provider (Teams, Zoom, Meet…) or a place.
enum MeetingPlace {
    private static let providers = ["teams", "zoom", "meet", "webex", "whereby", "skype", "http://", "https://"]

    static func isVideo(_ place: String) -> Bool {
        let lower = place.lowercased()
        return providers.contains { lower.contains($0) }
    }

    static func symbol(_ place: String) -> String { isVideo(place) ? "video" : "mappin.and.ellipse" }

    /// The location worth a line: nil when empty, or when it only names the provider that "Unirme" already opens.
    static func visible(_ event: CalendarEvent) -> String? {
        guard let place = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty else { return nil }
        if isVideo(place), let join = event.joinURL, JoinLink.isSafe(join) { return nil }
        return place
    }
}

/// One meeting in the agenda: time, title, who, project (if decided) and its action when it has one right now.
struct MeetingCard: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    var isSelected = false
    var onSelect: () -> Void
    var onPrepare: () -> Void
    var onShowPage: (String) -> Void

    @ViewState private var hovering = false
    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let live = event.isInProgress(at: now)
        let past = !live && event.end < now
        let phase = model.phase(of: event, state: state, now: now)
        let shape = RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                if event.isAllDay {
                    Text(L("meetings.allDay"))
                        .font(Brand.font(11, .medium))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                } else {
                    Text(Fmt.time(event.start))
                        .font(Brand.callout)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(Fmt.time(event.end))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: 56, alignment: .trailing)
            .foregroundStyle(past ? Brand.color.text2 : Brand.color.text)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(live ? Brand.color.record : (past ? Brand.color.line : Brand.color.sage))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if phase == .recording { BrandRecordingDot(size: 7) }
                    Text(event.title)
                        .font(Brand.font(13, .medium))
                        .foregroundStyle(past ? Brand.color.text2 : Brand.color.text)
                        .lineLimit(2)
                }
                meta(live: live, ringTint: isSelected ? Brand.color.accentSoft : (hovering ? Brand.color.cardAlt.opacity(0.5) : nil))
                // Only a decided project, read-only (it changes in the detail); why it was decided goes to the tooltip.
                let resolution = model.resolution(for: event, state: state)
                if let slug = resolution.recordingProject {
                    BrandChip(text: state.projectName(slug))
                        .help(projectReason(resolution))
                }
                if phase != .upcoming && phase != .over {
                    MeetingActionButton(event: event, showsPrepare: false, onPrepare: onPrepare, onShowPage: onShowPage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(shape.fill(isSelected ? Brand.color.accentSoft : (hovering ? Brand.color.cardAlt.opacity(0.5) : .clear)))
        .contentShape(shape)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func projectReason(_ r: MeetingProjectResolution) -> String {
        switch r.origin {
        case .rule(let rule): L("rules.meetings.byRule", ruleLabel(rule))
        case .defaultProject: L("rules.meetings.byDefault")
        default: state.projectName(r.recordingProject)
        }
    }

    /// "En curso" · initials · place, on one line that truncates.
    @ViewBuilder private func meta(live: Bool, ringTint: Color?) -> some View {
        let others = model.others(in: event)
        let place = MeetingPlace.visible(event)
        let video = event.joinURL.map(JoinLink.isSafe) ?? false
        if live || !others.isEmpty || place != nil || video {
            HStack(spacing: 8) {
                if live {
                    Text(L("meetings.inProgress"))
                        .font(Brand.font(11, .medium))
                        .foregroundStyle(Brand.color.record)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                AttendeeInitials(attendees: others, size: 20, ring: Brand.color.surface, ringTint: ringTint)
                if let place {
                    Label(place, systemImage: MeetingPlace.symbol(place))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if video {
                    Image(systemName: "video")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text3)
                        .help(event.location ?? L("meetings.join"))
                }
            }
        }
    }
}

/// A meeting in "Anteriores": title, when, project, its state while processing, and the one thing to do with it —
/// "Ver resumen" once learned, "Reintentar" when it failed, "Elegir proyecto ▾" while it waits for a project.
struct PastMeetingRow: View {
    @Environment(AppState.self) private var state
    let item: PastMeetingItem
    var onOpenSummary: () -> Void

    @ViewState private var hovering = false
    @ViewState private var assignError: String?

    private var source: SourceRecord? {
        if case .source(let s, _) = item { return s }
        return nil
    }

    /// Learned: the row opens its summary.
    private var opens: Bool {
        switch item {
        case .source(let s, _): s.status == .done
        case .page(let e): e.pagePath != nil
        }
    }

    /// A timeline line reads "Comité de la alianza — Comité mensual: el piloto…": the name is the title, the rest is
    /// what happened (one line under it).
    private var titleParts: (title: String, gist: String?) {
        switch item {
        case .source(let s, let title):
            return (title ?? s.title, nil)
        case .page(let e):
            guard let r = e.title.range(of: " — ") else { return (e.title, nil) }
            let gist = e.title[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return (String(e.title[..<r.lowerBound]), gist.isEmpty ? nil : gist)
        }
    }

    private var projectSlug: String? {
        switch item {
        case .source(let s, _): s.projectSlug
        case .page(let e): e.projectSlug
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .font(Brand.font(13))
                .foregroundStyle(Brand.color.text2)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Brand.color.cardAlt))
            VStack(alignment: .leading, spacing: 4) {
                let parts = titleParts
                Text(parts.title)
                    .font(Brand.font(13, .medium))
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(2)
                if let line = [when, parts.gist].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(line)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(parts.gist ?? "")
                }
                HStack(spacing: 6) {
                    BrandChip(text: state.projectName(projectSlug), symbol: projectSlug == nil ? "tray" : nil)
                    if let source, source.status.isInProgress || source.status == .needsProject {
                        StatusPill(status: source.status, progress: source.progress)
                    }
                }
                if let assignError {
                    Text(assignError)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.danger)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
                .layoutPriority(1)   // a short verb: measured first, the title wraps instead
        }
        .padding(10)
        .background(shape.fill(hovering && opens ? Brand.color.cardAlt.opacity(0.5) : .clear))
        .contentShape(shape)
        .onTapGesture { if opens { onOpenSummary() } }
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(opens ? .isButton : [])
    }

    /// "10:30 · 45 min" (the list groups rows by day); nil for a date-only timeline line.
    private var when: String? {
        switch item {
        case .source(let s, _):
            var parts = [Fmt.time(s.timelineDate)]
            if let seconds = s.durationSeconds, seconds > 0 { parts.append(MeetingTimes.duration(seconds)) }
            return parts.joined(separator: " · ")
        case .page(let e):
            return e.hasTime ? Fmt.time(e.date) : nil
        }
    }

    /// Rows that can't open yet say why (still learning, waiting for a project).
    private var help: String {
        guard let source else { return opens ? L("meetings.seeSummary") : "" }
        if source.status.isInProgress { return L("meetings.past.learningHelp") }
        if source.status == .needsProject { return L("meetings.past.needsProjectHelp") }
        if source.status == .failed { return source.error ?? L("meetings.failedHelp") }
        return L("meetings.seeSummary")
    }

    @ViewBuilder private var action: some View {
        if opens {
            Button(action: onOpenSummary) {
                Label(L("meetings.seeSummary"), systemImage: "doc.text")
            }
            .buttonStyle(.brandSecondary)
            .help(L("meetings.seeSummary"))
        } else if let source, source.status == .failed {
            Button { state.engine.retry(sourceId: source.id) } label: {
                Label(L("meetings.retry"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.brandSecondary)
            .help(source.error ?? L("meetings.failedHelp"))
        } else if let source, source.status == .needsProject {
            projectMenu(source)
        }
    }

    /// "Elegir proyecto ▾" (the suggested project first): resolves the recording right here, as Sin asignar does.
    private func projectMenu(_ source: SourceRecord) -> some View {
        let suggested = source.suggestedProject.flatMap { state.project($0) }
        return Menu {
            if let suggested {
                Button("\(suggested.emoji) \(suggested.name)") { assign(source, to: suggested.slug) }
                Divider()
            }
            ForEach(state.projects.filter { $0.slug != suggested?.slug }) { project in
                Button("\(project.emoji) \(project.name)") { assign(source, to: project.slug) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(L("meetings.chooseProject")).lineLimit(1)
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .font(Brand.callout)
            .foregroundStyle(Brand.color.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Brand.color.accentSoft))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("meetings.past.needsProjectHelp"))
    }

    private func assign(_ source: SourceRecord, to slug: String) {
        do {
            try state.engine.assign(sourceId: source.id, to: slug)
            assignError = nil
        } catch {
            assignError = (error as? EngineError)?.errorDescription ?? L("sources.moveFailed")
        }
    }
}

/// A vault page (people page, meeting summary) read without leaving Reuniones. Links stay in the sheet; a project page
/// offers "Abrir en el proyecto". Sized per §15.3.
struct VaultPageSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let path: String
    @ViewState private var current: String?

    private var shown: String { current ?? path }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(state.engine.vault.title(of: shown))
                    .font(Brand.section)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if shown.hasPrefix("projects/") {
                    let open = Button {
                        let target = shown
                        dismiss()
                        state.openProjectPage(target)
                    } label: {
                        Label(L("meetings.openInProject"), systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.brandSecondary)
                    .help(L("meetings.openInProject"))
                    ViewThatFits(in: .horizontal) {
                        open.fixedSize()
                        open.labelStyle(.iconOnly).fixedSize()
                    }
                }
                Button(L("common.close")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Brand.spacing.l)
            .padding(.vertical, Brand.spacing.m)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            WikiWebView(vault: state.engine.vault, path: shown) { next in current = next }
        }
        .background(Brand.color.surface)
        .frame(minWidth: 560, idealWidth: 680, maxWidth: .infinity, minHeight: 420, idealHeight: 520, maxHeight: .infinity)
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
