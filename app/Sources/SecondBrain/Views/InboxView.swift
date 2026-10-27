import BrainCore
import SwiftUI

/// "Sin asignar": recordings, files and emails that still need a project. I suggest one; one click assigns it.
/// Failed ones offer Reintentar / Eliminar; the ones still being processed sit in a compact "En proceso" list.
struct InboxView: View {
    @Environment(AppState.self) private var state
    @ViewState private var error: String?
    @ViewState private var showNote = false
    // MARK: v0.4 routing
    /// §14.3 offer after "Asignar" of an email (or a recording tied to a calendar event).
    @ViewState private var ruleOffer = RuleOffer()

    /// Needs a project, or failed without one: one row per email thread (the engine moves the whole thread).
    private var toSort: [SourceRecord] {
        Self.onePerThread(state.engine.sources.filter {
            $0.status == .needsProject || ($0.projectSlug == nil && $0.status == .failed)
        })
    }

    private var inProgress: [SourceRecord] {
        state.engine.sources.filter { $0.projectSlug == nil && $0.status.isInProgress }
    }

    /// Keeps the newest source of each email thread (others pass through), in the original order.
    static func onePerThread(_ sources: [SourceRecord]) -> [SourceRecord] {
        var newest: [String: SourceRecord] = [:]
        for source in sources {
            guard let thread = source.threadKey else { continue }
            if let current = newest[thread], current.timelineDate >= source.timelineDate { continue }
            newest[thread] = source
        }
        return sources.filter { source in
            guard let thread = source.threadKey else { return true }
            return newest[thread]?.id == source.id
        }
    }

    var body: some View {
        Group {
            if toSort.isEmpty && inProgress.isEmpty {
                EmptyStateView(symbol: "tray", title: L("inbox.emptyTitle"), message: L("inbox.emptyMessage"))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Brand.spacing.xxl) {
                        if !toSort.isEmpty {
                            VStack(alignment: .leading, spacing: Brand.spacing.m) {
                                BrandSectionHeader(title: L("inbox.needsProject"), count: toSort.count)
                                ForEach(toSort) { source in
                                    InboxRow(source: source, onError: { error = $0 }, onAssigned: offerRule)
                                }
                            }
                        }
                        if !inProgress.isEmpty {
                            VStack(alignment: .leading, spacing: Brand.spacing.m) {
                                BrandSectionHeader(title: L("inbox.inProgress"), count: inProgress.count)
                                BrandCard(padding: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(inProgress.enumerated()), id: \.element.id) { index, source in
                                            if index > 0 { Rectangle().fill(Brand.color.line).frame(height: 1) }
                                            InProgressRow(source: source)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(Brand.spacing.contentWide)
                    .frame(maxWidth: 880, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Brand.color.surface)
        .safeAreaInset(edge: .bottom) {
            if ruleOffer.current != nil {
                RuleOfferBar(offer: ruleOffer)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(Brand.motion.standard, value: ruleOffer.current)
        .animation(Brand.motion.fast, value: toSort.map(\.id))
        .navigationTitle(L("inbox.title"))
        .toolbar {
            Button { state.requestEmail(projectSlug: nil) } label: { Label(L("email.add"), systemImage: "envelope.badge") }
                .help(L("email.addHelp"))
            Button { showNote = true } label: { Label(L("sources.newNote"), systemImage: "square.and.pencil") }
        }
        .sheet(isPresented: $showNote) { NoteSheet(projectSlug: nil) }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// The row is gone once assigned, so the offer lives at the bottom of the list. `subject` was read before the move.
    private func offerRule(_ subject: RoutingSubject?, _ slug: String) {
        ruleOffer.propose(subject, projectSlug: slug, state: state)
    }
}

/// "En proceso": one compact line (kind, title, status).
private struct InProgressRow: View {
    let source: SourceRecord

    var body: some View {
        HStack(spacing: Brand.spacing.s) {
            Image(systemName: source.symbol)
                .foregroundStyle(Brand.color.text2)
                .frame(width: 18)
                .help(source.kind.label)
            Text(source.title)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(source.title)
            Spacer(minLength: Brand.spacing.s)
            StatusPill(status: source.status, progress: source.progress)
        }
        .padding(.horizontal, Brand.spacing.m)
        .padding(.vertical, 10)
    }
}

/// One thing to sort: what it is, when it happened, and the decision in one line — my suggestion + Asignar + "Otro ▾"
/// (or "Pensando…" / "Elegir proyecto ▾"). A failed one shows what went wrong with Reintentar / Eliminar.
/// Embedded by Inicio ("Por ordenar"); `showsCard: false` drops the card when the host draws its own container.
struct InboxRow: View {
    @Environment(AppState.self) private var state
    let source: SourceRecord
    var onError: (String) -> Void
    var onAssigned: (RoutingSubject?, String) -> Void = { _, _ in }
    var showsCard = true

    @ViewState private var showNewProject = false
    @ViewState private var confirmDelete = false
    @ViewState private var showThread = false

    var body: some View {
        Group {
            if showsCard {
                BrandCard(padding: Brand.spacing.m + 2) { content }
            } else {
                content.padding(.vertical, Brand.spacing.s)
            }
        }
        .contextMenu {
            if source.kind == .email, source.threadKey != nil {
                Button(L("sources.openEmail")) { showThread = true }
            }
            Button(L("sources.delete"), role: .destructive) { confirmDelete = true }
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet { project in assign(project.slug) }
        }
        .sheet(isPresented: $showThread) {
            if let thread = source.threadKey { ThreadSheet(threadKey: thread) }
        }
        .confirmationDialog(L("sources.deleteConfirm", source.title), isPresented: $confirmDelete) {
            Button(L("sources.delete"), role: .destructive, action: delete)
        } message: {
            Text(L("sources.deleteMessage"))
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Brand.spacing.m) {
            Image(systemName: source.symbol)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .frame(width: 18, height: 18)
                .help(source.kind.label)
            VStack(alignment: .leading, spacing: Brand.spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(source.title)
                    Text(subtitle)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .help(source.datesHelp)
                }
                if source.status == .failed {
                    failedActions
                } else {
                    decision
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Needs a project

    private var suggestedProject: Project? { state.project(source.suggestedProject) }

    /// No suggestion and no reason yet, and it changed recently: I'm still thinking. After a minute without news the
    /// row stops pretending and just asks.
    private func isThinking(at now: Date) -> Bool {
        source.suggestedProject == nil && source.suggestionReason == nil && now.timeIntervalSince(source.updatedAt) < 60
    }

    @ViewBuilder private var decision: some View {
        if let suggestion = suggestedProject {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Brand.spacing.s) {
                        suggestionText(suggestion)
                        assignButton(suggestion)
                        projectMenu(L("inbox.other"))
                    }
                    VStack(alignment: .leading, spacing: Brand.spacing.s) {
                        suggestionText(suggestion)
                        HStack(spacing: Brand.spacing.s) {
                            assignButton(suggestion)
                            projectMenu(L("inbox.other"))
                        }
                    }
                }
                if let reason = source.suggestionReason, !reason.isEmpty {
                    Text(reason)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                HStack(spacing: Brand.spacing.m) {
                    if isThinking(at: context.date) {
                        BrandLoader(size: 14, text: L("inbox.thinkingShort"))
                    } else {
                        Text(source.suggestionReason == nil ? L("inbox.pick") : L("inbox.noSuggestion"))
                            .font(Brand.body)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(2)
                    }
                    projectMenu(L("inbox.choose"))
                }
            }
        }
    }

    private func suggestionText(_ project: Project) -> some View {
        Text(L("inbox.suggestion", "\(project.emoji) \(project.name)"))
            .font(Brand.body)
            .foregroundStyle(Brand.color.text)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func assignButton(_ project: Project) -> some View {
        Button(L("inbox.assign")) { assign(project.slug) }
            .buttonStyle(.brandPrimary)
            .fixedSize()
    }

    private func projectMenu(_ title: String) -> some View {
        Menu(title) {
            ForEach(state.projects) { project in
                Button("\(project.emoji) \(project.name)") { assign(project.slug) }
            }
            Divider()
            Button(L("sidebar.newProject")) { showNewProject = true }
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(Brand.color.accent)
        .fixedSize()
    }

    // MARK: Failed

    private var failedActions: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.color.danger)
                Text(source.error.flatMap { $0.isEmpty ? nil : $0 } ?? L("sources.failedLearn"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.danger)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Brand.spacing.s) {
                Button(L("sources.retry")) { state.engine.retry(sourceId: source.id) }
                    .buttonStyle(.brandSecondary)
                    .fixedSize()
                Button(L("sources.delete")) { confirmDelete = true }
                    .buttonStyle(.plain)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.danger)
                    .fixedSize()
            }
        }
    }

    // MARK: Helpers

    /// The other messages of the same email thread that are waiting with it.
    private var threadSiblings: [SourceRecord] {
        guard let thread = source.threadKey else { return [] }
        return state.engine.sources.filter {
            $0.id != source.id && $0.threadKey == thread && $0.projectSlug == source.projectSlug && $0.status == source.status
        }
    }

    /// "23 oct, 5:36 · 2 correos" / "hoy 10:02 · 45 min".
    private var subtitle: String {
        var parts = [source.datesLine]
        if let d = source.durationSeconds, d > 0 { parts.append(Fmt.shortDuration(d)) }
        let siblings = threadSiblings.count
        if siblings > 0 { parts.append(L("email.messages", siblings + 1)) }
        return parts.joined(separator: " · ")
    }

    private func delete() {
        for id in [source.id] + threadSiblings.map(\.id) {
            do { try state.engine.delete(sourceId: id) } catch { onError(L("sources.deleteFailed")); return }
        }
    }

    private func assign(_ slug: String) {
        // An email from its raw (read before the move); a recording through its calendar event, asked of the calendar
        // when the agenda doesn't have it (a meeting before today).
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
