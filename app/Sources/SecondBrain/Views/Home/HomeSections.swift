import AppKit
import BrainCore
import SwiftUI

// Pieces of Inicio (CONTRACT §15.2). Rows have fixed heights so sections don't jump while they load.

/// "Ahora / Siguiente": the recording in progress, else the hero meeting (today or tomorrow) with its one action, then
/// the rest of today in compact rows. Without accounts, one line to connect a calendar.
struct HomeNowSection: View {
    @Environment(AppState.self) private var state
    @ViewState private var connectError: String?
    @ViewState private var connecting = false

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        let now = model.now
        let hero = heroEvent(now: now)
        let today = model.events(in: .today, now: now)
            .filter { $0.end > now && !$0.matches(hero?.event.id) }
            .prefix(4)
        let noAccounts = state.engine.accounts.accounts.isEmpty
        if state.isRecording || hero != nil || !today.isEmpty || noAccounts {
            VStack(alignment: .leading, spacing: 12) {
                if state.isRecording {
                    HomeRecordingCard()
                } else if let hero {
                    HomeHeroCard(event: hero.event, isNow: hero.isNow)
                }
                if !today.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        BrandSectionHeader(title: L("home.today")) {
                            HomeLink(title: L("home.seeAgenda")) { state.selection = .meetings }
                        }
                        BrandCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(today.enumerated()), id: \.element.id) { offset, event in
                                    if offset > 0 { HomeDivider() }
                                    HomeEventRow(event: event)
                                }
                            }
                        }
                    }
                }
                if noAccounts { connectLine }
            }
        }
    }

    /// "Ahora" in its record window, else "Siguiente" when it is today or tomorrow.
    private func heroEvent(now: Date) -> (event: CalendarEvent, isNow: Bool)? {
        guard let hero = model.hero(now: now) else { return nil }
        if hero.isNow { return hero }
        let days = Fmt.daysFromToday(hero.event.start)
        return days <= 1 ? hero : nil
    }

    private var connectLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                connectText
                Spacer(minLength: 8)
                connectButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                connectText
                connectButtons
            }
        }
        .padding(12)
        .background(Brand.color.cardAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
    }

    private var connectText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(L("home.connectCalendar"), systemImage: "calendar")
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(2)
            if let connectError {
                Text(connectError)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.danger)
                    .lineLimit(2)
            }
        }
    }

    private var connectButtons: some View {
        HStack(spacing: 8) {
            Button(L("accounts.macCalendar")) {
                connecting = true
                connectError = nil
                Task {
                    defer { connecting = false }
                    do { try await state.connectAccount(.local) } catch { connectError = FriendlyError.message(error) }
                }
            }
            .buttonStyle(.brandSecondary)
            .disabled(connecting)
            Button(L("home.connectAccounts")) { SettingsLink.open(tab: "accounts") }
                .buttonStyle(.brandSecondary)
        }
    }
}

/// The hero of Inicio: "AHORA" / "SIGUIENTE", title, time and project, and the meeting's single action
/// (`MeetingActionButton`: Prepararme → Grabar → Detener → Aprendiendo… → Ver resumen).
struct HomeHeroCard: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    let isNow: Bool

    var body: some View {
        BrandCard(padding: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    info
                    Spacer(minLength: 12)
                    action
                }
                VStack(alignment: .leading, spacing: 12) {
                    info
                    action
                }
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isNow { Circle().fill(Brand.color.record).frame(width: 6, height: 6) }
                Text(isNow ? L("home.now") : L("home.next"))
                    .textCase(.uppercase)
                    .font(Brand.font(11, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isNow ? Brand.color.record : Brand.color.text2)
            }
            Text(event.title)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(when)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .layoutPriority(1)
                HomeProjectChip(slug: MeetingsModel.shared.resolution(for: event, state: state).projectSlug)
            }
        }
    }

    private var action: some View {
        MeetingActionButton(event: event, large: true,
                            onPrepare: { state.pendingEventId = event.id; state.selection = .meetings },
                            onShowPage: { state.open(path: $0) })
    }

    private var when: String {
        let range = Fmt.time(event.start) + " – " + Fmt.time(event.end)
        return Calendar.current.isDateInToday(event.start) ? range : Fmt.relativeDay(event.start) + " · " + range
    }
}

/// While recording: what is being recorded, where it goes, and "Detener mm:ss".
struct HomeRecordingCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        BrandCard(padding: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    info
                    Spacer(minLength: 12)
                    stop
                }
                VStack(alignment: .leading, spacing: 12) {
                    info
                    stop
                }
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                BrandRecordingDot(size: 7)
                Text(L("home.now"))
                    .textCase(.uppercase)
                    .font(Brand.font(11, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Brand.color.record)
            }
            Text(title)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .lineLimit(2)
            HomeProjectChip(slug: state.recordingProjectSlug)
        }
    }

    private var title: String {
        let t = state.recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? L("status.recording") : t
    }

    private var stop: some View {
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
                    Text(L("record.stop"))
                }
            }
        }
        .buttonStyle(.brandRecord)
        .controlSize(.large)
        .disabled(state.isRecorderBusy)
    }
}

/// "10:30 · Revisión semanal · 🚀 Atlas" (opens it in Reuniones).
struct HomeEventRow: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent

    var body: some View {
        Button {
            state.pendingEventId = event.id
            state.selection = .meetings
        } label: {
            HStack(spacing: 12) {
                Text(event.isAllDay ? L("home.allDay") : Fmt.time(event.start))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 64, alignment: .leading)
                Text(event.title)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                HomeProjectChip(slug: MeetingsModel.shared.resolution(for: event, state: state).projectSlug, showsNone: false)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A source without project in "Por ordenar": what it is, and the decision in one line — my suggestion + Asignar +
/// "Otro…" (or "Pensando…" + "Elegir proyecto"). Same engine calls as Sin asignar's row (InboxRow is private to
/// InboxView at this base; after the tasks branch lands it could be reused here as `InboxRow(…, showsCard: false)`).
struct HomeSortRow: View {
    @Environment(AppState.self) private var state
    let source: SourceRecord
    var onError: (String) -> Void
    var onAssigned: (RoutingSubject?, String) -> Void

    @ViewState private var showNewProject = false

    private var suggested: Project? { state.project(source.suggestedProject) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                info
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                info
                buttons
            }
        }
        .frame(minHeight: 44)
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet { project in assign(project.slug) }
        }
    }

    private var info: some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind.symbol)
                .foregroundStyle(Brand.color.text2)
                .frame(width: 18)
                .help(source.kind.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(source.title)
                Text(hint)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(source.suggestionReason ?? "")
            }
        }
    }

    private var hint: String {
        if let suggested { return L("inbox.suggestion", "\(suggested.emoji) \(suggested.name)") }
        return source.suggestedProject == nil && source.suggestionReason == nil ? L("inbox.thinking") : L("inbox.noSuggestion")
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if let suggested {
                Button(L("inbox.assign")) { assign(suggested.slug) }
                    .buttonStyle(.brandPrimary)
            }
            Menu {
                ForEach(state.projects) { project in
                    Button("\(project.emoji) \(project.name)") { assign(project.slug) }
                }
                Divider()
                Button(L("sidebar.newProject")) { showNewProject = true }
            } label: {
                Text(suggested == nil ? L("inbox.choose") : L("inbox.other")).lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.brandSecondary)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func assign(_ slug: String) {
        let source = source
        let subject = source.kind == .email ? state.engine.routingSubject(forSourceId: source.id) : nil
        do {
            try state.engine.assign(sourceId: source.id, to: slug)
        } catch {
            onError((error as? EngineError)?.errorDescription ?? L("sources.moveFailed"))
            return
        }
        guard source.kind == .meeting, source.calendarEventId != nil else { return onAssigned(subject, slug) }
        let state = state, onAssigned = onAssigned
        Task {
            let event = await MeetingsModel.shared.event(for: source, state: state)
            onAssigned(state.engine.routingSubject(forSourceId: source.id, event: event), slug)
        }
    }
}

/// A failed source in "Por ordenar": Reintentar · Eliminar.
struct HomeFailedRow: View {
    @Environment(AppState.self) private var state
    let source: SourceRecord
    var onError: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                info
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                info
                buttons
            }
        }
        .frame(minHeight: 44)
    }

    private var info: some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind.symbol).foregroundStyle(Brand.color.text2).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Label(source.error.map { $0.isEmpty ? L("status.failed") : $0 } ?? L("status.failed"),
                      systemImage: "exclamationmark.circle")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(L("sources.retry")) { state.engine.retry(sourceId: source.id) }
                .buttonStyle(.brandSecondary)
            Button(L("sources.delete"), role: .destructive) {
                do { try state.engine.delete(sourceId: source.id) } catch { onError(L("sources.deleteFailed")) }
            }
            .buttonStyle(.plain)
            .font(Brand.callout)
            .foregroundStyle(Brand.color.danger)
        }
    }
}

/// A Recientes card (mockup page-10): kind, date (or progress), title, project. Fixed height.
struct HomeRecentCard: View {
    @Environment(AppState.self) private var state
    let source: SourceRecord

    static let height: CGFloat = 104

    var body: some View {
        Button {
            state.open(source: source)
        } label: {
            BrandCard(padding: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: source.kind.symbol)
                            .foregroundStyle(Brand.color.text2)
                        Text(source.kind.label)
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if source.status.isInProgress {
                            StatusPill(status: source.status, progress: source.progress)
                        } else {
                            Text(Fmt.dayTime(source.timelineDate))
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text3)
                                .lineLimit(1)
                        }
                    }
                    Text(source.title)
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HomeProjectChip(slug: source.projectSlug)
                }
                .frame(height: Self.height - 24, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source.title)
    }
}

/// "🚀 Lanzamiento Atlas" in a neutral chip (or "Sin asignar").
struct HomeProjectChip: View {
    @Environment(AppState.self) private var state
    let slug: String?
    var showsNone = true

    var body: some View {
        if let slug, let project = state.project(slug) {
            BrandChip(text: "\(project.emoji) \(project.name)")
        } else if showsNone {
            BrandChip(text: L("inbox.title"), symbol: "tray")
        }
    }
}

/// "Ver todo →": a small accent link (constant text).
struct HomeLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "arrow.right").imageScale(.small)
            }
            .font(Brand.callout)
            .foregroundStyle(Brand.color.accent)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HomeDivider: View {
    var body: some View {
        Rectangle().fill(Brand.color.line).frame(height: 1)
    }
}

/// One of the three big actions of an empty Inicio.
struct HomeBigAction: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let tint: Color
    var dashed = false
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(Brand.font(22))
                    .foregroundStyle(tint)
                    .frame(height: 28)
                Text(title)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(shortcut ?? " ")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 112)
            .background(shape.fill(Brand.color.card))
            .overlay(shape.strokeBorder(Brand.color.line, style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : [])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}
