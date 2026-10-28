import AppKit
import BrainCore
import SwiftUI

// Pieces of Inicio (CONTRACT §16.9, layout §15.2). Rows have fixed heights so sections don't jump while they load.

/// Agenda (§16.9): one compact card with the meeting on now or next (today or tomorrow) and the rest of today, 3
/// rows at most, plus "Ver agenda →". Hidden without a connected calendar and on a day with nothing left: no
/// permanent "connect your calendar" line (that lives in Reuniones and Ajustes).
struct HomeAgendaSection: View {
    @Environment(AppState.self) private var state

    static let maxRows = 3

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        let rows = Self.rows(now: model.now)
        if !state.engine.accounts.accounts.isEmpty, !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                BrandSectionHeader(title: L("home.agenda")) {
                    HomeLink(title: L("home.seeAgenda")) { state.navigate(to: .sidebar(.meetings)) }
                }
                BrandCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.event.id) { offset, row in
                            if offset > 0 { HomeDivider() }
                            HomeEventRow(event: row.event, tag: row.tag)
                        }
                    }
                }
            }
        }
    }

    /// The hero ("Ahora" in its record window, else "Siguiente" when it is today or tomorrow) first, then what is
    /// left of today.
    @MainActor static func rows(now: Date) -> [(event: CalendarEvent, tag: String?)] {
        let model = MeetingsModel.shared
        var rows: [(event: CalendarEvent, tag: String?)] = []
        if let hero = heroEvent(now: now) {
            rows.append((hero.event, hero.isNow ? L("home.now") : L("home.next")))
        }
        let heroId = rows.first?.event.id
        for event in model.events(in: .today, now: now) where event.end > now && !event.matches(heroId) {
            guard rows.count < maxRows else { break }
            rows.append((event, nil))
        }
        return rows
    }

    @MainActor static func heroEvent(now: Date) -> (event: CalendarEvent, isNow: Bool)? {
        guard let hero = MeetingsModel.shared.hero(now: now) else { return nil }
        if hero.isNow { return hero }
        return Fmt.daysFromToday(hero.event.start) <= 1 ? hero : nil
    }
}

/// "AHORA · 10:30 · Revisión semanal · 🚀 Atlas" (opens it in Reuniones). A tomorrow event says "mañana 10:30".
struct HomeEventRow: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    var tag: String?

    private var when: String {
        if event.isAllDay { return L("home.allDay") }
        return Fmt.daysFromToday(event.start) == 0 ? Fmt.time(event.start) : Fmt.dayTime(event.start)
    }

    var body: some View {
        Button {
            state.navigate(to: .event(event.id, prepare: false))
        } label: {
            HStack(spacing: 12) {
                Text(when)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 84, alignment: .leading)
                if state.isRecording, event.matches(state.recordingEventId) {
                    BrandRecordingDot(size: 7)
                } else if let tag {
                    Text(tag)
                        .textCase(.uppercase)
                        .font(Brand.font(10, .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Brand.color.accent)
                        .lineLimit(1)
                }
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

/// What a "Lo último que aprendí" card shows: a source of this Mac (in progress or learned), a followed GitHub repo
/// (its syncs folded into one card), or a page from a project's timeline.
struct HomeRecentItem: Identifiable {
    let id: String
    let symbol: String
    let kindLabel: String
    let title: String
    /// One caption line under the title ("3 actualizaciones esta semana" on a repo).
    var detail: String?
    let projectSlug: String?
    let date: Date
    /// Newest change, for the order of the grid.
    var sortDate: Date
    var source: SourceRecord?
    var pagePath: String?
    /// v0.7: the email thread this card stands for.
    var threadKey: String?
    var sourceId: String? { source?.id }

    init(source: SourceRecord) {
        id = "source:" + source.id
        symbol = source.kind.symbol
        kindLabel = source.kind.label
        title = source.title
        projectSlug = source.projectSlug
        date = source.timelineDate
        sortDate = source.updatedAt
        self.source = source
    }

    /// One repo: every sync of it is a source (one raw per sync, §13.3), so its commits and PRs read as one card
    /// that opens the repo's living page (through the newest sync). `syncs` is newest first, never empty.
    init(repo: String, syncs: [SourceRecord], now: Date = Date()) {
        let latest = syncs[0]
        id = "repo:" + repo
        symbol = latest.kind.symbol
        kindLabel = latest.kind.label
        title = repo
        let week = syncs.filter { now.timeIntervalSince($0.timelineDate) < 7 * 86_400 }.count
        detail = week > 0 ? L("home.repoUpdates", week) : L("home.repoChanges")
        projectSlug = latest.projectSlug
        date = latest.timelineDate
        sortDate = latest.updatedAt
        source = latest
    }

    /// v0.7 (§17.4): one email thread (`mails` newest first, never empty): its subject, "7 correos · último hace 2 h ·
    /// Ana, Tú, Luis", opening the thread through its newest email. Senders come from the source titles
    /// ("Asunto — Ana"), so no file is read while Inicio draws.
    init(thread mails: [SourceRecord], now: Date = Date()) {
        let latest = mails[0]
        id = "thread:" + (latest.threadKey ?? latest.id)
        symbol = latest.kind.symbol
        kindLabel = L("thread.kind")
        let parts = { (s: SourceRecord) in s.title.components(separatedBy: " — ") }
        title = parts(latest).first ?? latest.title
        var senders: [String] = []
        for mail in mails.reversed() {
            let who = parts(mail).dropFirst().joined(separator: " — ")
            let name = ["tú", "you"].contains(who.lowercased()) ? L("thread.you") : (who.split(separator: " ").first.map(String.init) ?? "")
            if !name.isEmpty, !senders.contains(name) { senders.append(name) }
        }
        detail = ThreadText.caption(count: mails.count, last: latest.timelineDate, senders: senders, now: now)
        projectSlug = latest.projectSlug
        date = latest.timelineDate
        sortDate = mails.map(\.updatedAt).max() ?? latest.updatedAt
        source = latest
        threadKey = latest.threadKey
    }

    @MainActor init(entry: TimelineEntry) {
        id = "entry:" + entry.id
        symbol = entry.kind.symbol
        kindLabel = entry.thread == nil ? entry.kind.label : L("thread.kind")
        if let thread = entry.thread {
            detail = ThreadText.caption(thread, last: entry.date)
            threadKey = thread.key
        }
        title = entry.title
        projectSlug = entry.projectSlug
        date = entry.date
        sortDate = entry.date
        pagePath = entry.pagePath
        if let sourceId = entry.sourceId { source = AppState.shared.engine.source(sourceId) }
    }

    /// "owner/name" of a GitHub sync: from `externalId` ("github:owner/name@sha,…"), else the title before " — ".
    static func repoName(of source: SourceRecord) -> String {
        if let ext = source.externalId, ext.hasPrefix("github:") {
            let rest = ext.dropFirst("github:".count)
            return String(rest.split(separator: "@", maxSplits: 1).first ?? rest)
        }
        return source.title.components(separatedBy: " — ").first ?? source.title
    }
}

/// A "Lo último que aprendí" card (mockup page-10): kind, date (or progress), title, project. Fixed height.
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
                        .lineLimit(item.detail == nil ? 2 : 1)
                        .truncationMode(item.detail == nil ? .tail : .middle)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = item.detail {
                        Text(detail)
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                    }
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

/// One of the five equal actions of an empty Inicio (Nota · Archivo · Enlace · Correo · Grabar).
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
