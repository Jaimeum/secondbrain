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
        let hero = Self.heroEvent(now: now)
        let today = model.events(in: .today, now: now)
            .filter { $0.end > now && !$0.matches(hero?.event.id) }
            .prefix(4)
        let noAccounts = state.engine.accounts.accounts.isEmpty
        if state.isRecording || hero != nil || !today.isEmpty || noAccounts {
            VStack(alignment: .leading, spacing: 12) {
                if state.isRecording {
                    HomeRecordingCard()
                } else if let hero {
                    // The same hero as Reuniones (§15.2): countdown, project chip with its offer, place / Unirme, and
                    // the meeting's one action.
                    MeetingHeroCard(event: hero.event, isNow: hero.isNow,
                                    onSelect: { openInMeetings(hero.event, prepare: false) },
                                    onPrepare: { openInMeetings(hero.event, prepare: true) },
                                    onShowPage: { state.open(path: $0) })
                }
                if !today.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        BrandSectionHeader(title: L("home.today")) {
                            HomeLink(title: L("home.seeAgenda")) { state.navigate(to: .sidebar(.meetings)) }
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
    @MainActor static func heroEvent(now: Date) -> (event: CalendarEvent, isNow: Bool)? {
        guard let hero = MeetingsModel.shared.hero(now: now) else { return nil }
        if hero.isNow { return hero }
        let days = Fmt.daysFromToday(hero.event.start)
        return days <= 1 ? hero : nil
    }

    /// The event in Reuniones; "Prepararme" lands on its preparation, not on the plain detail.
    private func openInMeetings(_ event: CalendarEvent, prepare: Bool) {
        state.navigate(to: .event(event.id, prepare: prepare))
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
            state.navigate(to: .event(event.id, prepare: false))
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

/// What a Recientes card shows: a source of this Mac (in progress or learned), or a page from a project's timeline.
struct HomeRecentItem: Identifiable {
    let id: String
    let symbol: String
    let kindLabel: String
    let title: String
    let projectSlug: String?
    let date: Date
    var source: SourceRecord?
    var pagePath: String?
    var sourceId: String? { source?.id }

    init(source: SourceRecord) {
        id = "source:" + source.id
        symbol = source.kind.symbol
        kindLabel = source.kind.label
        title = source.title
        projectSlug = source.projectSlug
        date = source.timelineDate
        self.source = source
    }

    @MainActor init(entry: TimelineEntry) {
        id = "entry:" + entry.id
        symbol = entry.kind.symbol
        kindLabel = entry.kind.label
        title = entry.title
        projectSlug = entry.projectSlug
        date = entry.date
        pagePath = entry.pagePath
        if let sourceId = entry.sourceId { source = AppState.shared.engine.source(sourceId) }
    }
}

/// A Recientes card (mockup page-10): kind, date (or progress), title, project. Fixed height.
struct HomeRecentCard: View {
    @Environment(AppState.self) private var state
    let item: HomeRecentItem

    static let height: CGFloat = 104

    var body: some View {
        Button {
            if let path = item.pagePath {
                state.open(path: path)
            } else if let source = item.source {
                state.open(source: source)
            }
        } label: {
            BrandCard(padding: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .foregroundStyle(Brand.color.text2)
                        Text(item.kindLabel)
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let source = item.source, source.status.isInProgress {
                            StatusPill(status: source.status, progress: source.progress)
                        } else {
                            Text(Fmt.dayTime(item.date))
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text2)
                                .lineLimit(1)
                        }
                    }
                    Text(item.title)
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HomeProjectChip(slug: item.projectSlug)
                }
                .frame(height: Self.height - 24, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
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
