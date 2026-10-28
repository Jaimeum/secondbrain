import BrainCore
import SwiftUI

// MARK: v0.6 facts — after a hand edit: /propagate, "Revisar cambios en el cerebro", facts.md (CONTRACT §16.6)

/// One hand edit on its way through the brain. Lives while the review is pending, even with the sheet closed
/// ("Seguir en segundo plano"): the sheet comes back when Claude has something to show.
@MainActor @Observable
final class CorrectionsModel {
    static let shared = CorrectionsModel()

    enum Phase: Equatable {
        /// `/propagate` is running.
        case searching
        /// Proposed edits to review.
        case review
        /// Nothing else said it; the facts (if any) were recorded already.
        case nothing(factsAdded: Int)
        /// `/propagate` failed (Claude missing, usage limit…): the hand edit stays saved.
        case failed(String)
    }

    struct Session {
        let path: String
        let title: String
        let before: String
        let after: String
        var phase: Phase = .searching
        var proposal = Propagation()
        /// Page titles of the proposed edits (path → title).
        var titles: [String: String] = [:]
        /// Checked edits (`ProposedEdit.id`); all of them to start with.
        var selected: Set<String> = []
        /// Apply refused (e.g. Claude busy editing): shown in the sheet's footer.
        var error: String?
    }

    private(set) var session: Session?
    /// The review sheet is on screen (MainView, `.correctionsReview()`).
    var isPresented = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Called right after the editor saved `path`: asks `/propagate` and shows the sheet ("Buscando…" first).
    func start(state: AppState, path: String, before: String, after: String) {
        task?.cancel()
        session = Session(path: path, title: state.engine.vault.title(of: path), before: before, after: after)
        task = Task { [weak self] in
            // The editor sheet is still closing: presenting another one in the same pass is dropped by SwiftUI.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.isPresented = true
            await self.run(state: state)
        }
    }

    func retry(state: AppState) {
        guard var s = session else { return }
        s.phase = .searching
        s.error = nil
        session = s
        task?.cancel()
        task = Task { [weak self] in await self?.run(state: state) }
    }

    private func run(state: AppState) async {
        guard let s = session else { return }
        do {
            let proposal = try await state.engine.proposeCorrections(path: s.path, before: s.before, after: s.after)
            guard !Task.isCancelled, session?.path == s.path else { return }
            if proposal.edits.isEmpty {
                // §16.6: nothing to propagate → the fact is still recorded, and I say so (the sheet comes back if it
                // was hidden while searching).
                let added = try await recordFacts(proposal.facts, editedPath: s.path, state: state)
                guard !Task.isCancelled, session?.path == s.path else { return }
                session?.phase = .nothing(factsAdded: added)
                isPresented = true
                return
            }
            let vault = state.engine.vault
            let paths = Array(Set(proposal.edits.map(\.path)))
            let titles = await Task.detached { Dictionary(uniqueKeysWithValues: paths.map { ($0, vault.title(of: $0)) }) }.value
            session?.proposal = proposal
            session?.titles = titles
            session?.selected = Set(proposal.edits.map(\.id))
            session?.phase = .review
            isPresented = true
        } catch {
            guard !Task.isCancelled else { return }
            Log.error("propagate \(s.path) failed: \(error)")
            session?.phase = .failed(FriendlyError.message(error))
            isPresented = true
        }
    }

    /// Appends `facts` to `facts.md`. While Claude is editing the brain the write is refused (its Historial entry would
    /// take the line): wait for it to finish and try again, still "Buscando…", instead of dropping the facts.
    private func recordFacts(_ facts: [String], editedPath: String, state: AppState) async throws -> Int {
        guard !facts.isEmpty else { return 0 }
        while true {
            do {
                return try state.engine.applyCorrections([], facts: facts, editedPath: editedPath).factsAdded
            } catch EngineError.busy {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// "Aplicar n" (`onlyThisPage == false`) or "Solo esta página": writes the checked edits (or none) and the facts.
    func apply(state: AppState, onlyThisPage: Bool) {
        guard let s = session else { return }
        let edits = onlyThisPage ? [] : s.proposal.edits.filter { s.selected.contains($0.id) }
        do {
            let result = try state.engine.applyCorrections(edits, facts: s.proposal.facts, editedPath: s.path)
            if !result.stale.isEmpty { Log.info("corrections: \(result.stale.count) edits no longer matched their page") }
            close()
        } catch {
            session?.error = FriendlyError.message(error)
        }
    }

    /// Hides the sheet; while searching, the work goes on and the sheet returns with the result.
    func hide() {
        isPresented = false
        if session?.phase != .searching { close() }
    }

    func toggle(_ edit: ProposedEdit) {
        guard session != nil else { return }
        if session!.selected.contains(edit.id) { session!.selected.remove(edit.id) } else { session!.selected.insert(edit.id) }
    }

    private func close() {
        isPresented = false
        session = nil
        task = nil
    }

    /// Snapshots only (DebugSnapshots): a model that shows `session` as is, without running anything.
    static func preview(_ session: Session) -> CorrectionsModel {
        let model = CorrectionsModel()
        model.session = session
        return model
    }

    /// Snapshot shots of the editor and of the review sheet in each phase, on pages of the (demo) vault.
    static func snapshotShots(state: AppState) -> [(String, CGSize, AnyView)] {
        let vault = state.engine.vault
        let people = vault.pages(projectSlug: nil).filter { $0.path.hasPrefix("people/") }
        guard let person = people.first else { return [] }
        let other = people.dropFirst().first ?? person
        let project = state.projects.first.flatMap { vault.pages(projectSlug: $0.slug).first { $0.path.hasSuffix("/overview.md") } }
        func lines(_ path: String, _ n: Int) -> String {
            let body = ((try? vault.read(path)) ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("- ") || $0.hasPrefix("> ") }
            return body.prefix(n).joined(separator: "\n")
        }
        let first = lines(other.path, 2).isEmpty ? "- \(person.title)" : lines(other.path, 2)
        var edits = [ProposedEdit(path: other.path, before: first,
                                  after: first.components(separatedBy: "\n").first! + " (sin \(person.title))",
                                  reason: "Ponía a \(person.title) en el equipo de \(other.title).")]
        if let project {
            let before = lines(project.path, 1).isEmpty ? "- \(person.title)" : lines(project.path, 1)
            edits.append(ProposedEdit(path: project.path, before: before, after: before + " (sin \(person.title))",
                                      reason: "Decía que \(person.title) era parte del equipo."))
        }
        var review = Session(path: person.path, title: person.title, before: "", after: "")
        review.phase = .review
        review.proposal = Propagation(facts: ["\(person.title) no forma parte del equipo de \(other.title). ([[a]], [[b|\(other.title)]])"],
                                      edits: edits)
        review.titles = Dictionary(uniqueKeysWithValues: edits.map { ($0.path, vault.title(of: $0.path)) })
        review.selected = Set(edits.prefix(1).map(\.id))
        var searching = review
        searching.phase = .searching
        var nothing = review
        nothing.phase = .nothing(factsAdded: 1)
        var failed = review
        failed.phase = .failed(FriendlyError.message(ClaudeError.notInstalled))
        return [
            ("editor", CGSize(width: 760, height: 520), AnyView(PageEditorHost(path: person.path))),
            ("editor-min", CGSize(width: 620, height: 420), AnyView(PageEditorHost(path: person.path))),
            ("corrections-review", CGSize(width: 760, height: 520), AnyView(CorrectionsReviewSheet(model: preview(review)))),
            ("corrections-review-min", CGSize(width: 620, height: 420), AnyView(CorrectionsReviewSheet(model: preview(review)))),
            ("corrections-searching", CGSize(width: 760, height: 520), AnyView(CorrectionsReviewSheet(model: preview(searching)))),
            ("corrections-nothing", CGSize(width: 760, height: 520), AnyView(CorrectionsReviewSheet(model: preview(nothing)))),
            ("corrections-failed", CGSize(width: 620, height: 420), AnyView(CorrectionsReviewSheet(model: preview(failed)))),
        ]
    }

    static let snapshotDarkNames: Set<String> = ["editor", "corrections-review"]
}

extension View {
    /// MainView: the "Revisar cambios en el cerebro" sheet of `CorrectionsModel`.
    func correctionsReview() -> some View {
        modifier(CorrectionsReviewPresenter())
    }
}

private struct CorrectionsReviewPresenter: ViewModifier {
    private var model: CorrectionsModel { CorrectionsModel.shared }

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { model.isPresented && model.session != nil },
                                           set: { if !$0 { model.hide() } })) {
            CorrectionsReviewSheet()
        }
    }
}

// MARK: - Sheet

struct CorrectionsReviewSheet: View {
    @Environment(AppState.self) private var state
    /// `.shared`; snapshots pass their own.
    var model: CorrectionsModel = .shared

    var body: some View {
        VStack(spacing: 0) {
            header
            if let session = model.session {
                switch session.phase {
                case .searching:
                    message(icon: nil, title: L("corrections.searching"), detail: L("corrections.searchingDetail"))
                case .review:
                    review(session)
                case .nothing(let added):
                    message(icon: "checkmark.circle", title: L("corrections.nothing"),
                            detail: added > 0 ? L("corrections.factSaved") : L("corrections.nothingDetail"))
                case .failed(let error):
                    message(icon: "exclamationmark.triangle", title: L("corrections.failed"), detail: error)
                }
                footer(session)
            }
        }
        .background(Brand.color.surface)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 420, idealHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("corrections.title"))
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
            if let session = model.session {
                Text(L("corrections.subtitle", session.title))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Brand.spacing.contentWide)
        .padding(.top, Brand.spacing.xl)
        .padding(.bottom, Brand.spacing.s)
    }

    private func message(icon: String?, title: String, detail: String) -> some View {
        VStack(spacing: Brand.spacing.s) {
            if let icon {
                Image(systemName: icon).font(Brand.font(24)).foregroundStyle(Brand.color.text2)
            } else {
                BrandLoader(size: 24)
            }
            Text(title)
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let facts = model.session?.proposal.facts, case .nothing = model.session?.phase, !facts.isEmpty {
                factsBox(facts).frame(maxWidth: 520)
            }
        }
        .padding(Brand.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func review(_ session: CorrectionsModel.Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.spacing.l) {
                if !session.proposal.facts.isEmpty { factsBox(session.proposal.facts) }
                Text(L("corrections.intro"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(grouped(session), id: \.path) { group in
                    VStack(alignment: .leading, spacing: Brand.spacing.s) {
                        HStack(spacing: Brand.spacing.xs) {
                            Image(systemName: "doc.text").foregroundStyle(Brand.color.text3)
                            Text(session.titles[group.path] ?? group.path)
                                .font(Brand.callout)
                                .foregroundStyle(Brand.color.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let slug = Scope.projectSlug(ofPath: group.path),
                               !(session.titles[group.path] ?? "").contains(state.project(slug)?.name ?? slug) {
                                Text(state.projectName(slug))
                                    .font(Brand.caption)
                                    .foregroundStyle(Brand.color.text3)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer(minLength: 0)
                        }
                        ForEach(group.edits) { edit in
                            EditRow(edit: edit, checked: session.selected.contains(edit.id)) { model.toggle(edit) }
                        }
                    }
                }
            }
            .padding(.horizontal, Brand.spacing.contentWide)
            .padding(.vertical, Brand.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .brandScrollEdgeFade(.top)
        .brandScrollEdgeFade(.bottom)
    }

    /// "Lo guardaré como hecho confirmado": the facts, wikilinks shown as plain names.
    private func factsBox(_ facts: [String]) -> some View {
        VStack(alignment: .leading, spacing: Brand.spacing.xs) {
            Label(L("corrections.factsTitle"), systemImage: "checkmark.seal")
                .font(Brand.font(11, .semibold))
                .foregroundStyle(Brand.color.text2)
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                Text(Self.plain(fact))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Brand.spacing.m)
        .background(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).fill(Brand.color.accentSoft))
    }

    @ViewBuilder private func footer(_ session: CorrectionsModel.Session) -> some View {
        HStack(spacing: Brand.spacing.s) {
            if let error = session.error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.color.warning)
                Text(error)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(2)
            }
            Spacer(minLength: Brand.spacing.s)
            switch session.phase {
            case .searching:
                Button(L("corrections.background")) { model.hide() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
            case .review:
                let n = session.selected.count
                Button(L("corrections.onlyThisPage")) { model.apply(state: state, onlyThisPage: true) }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                    .help(L("corrections.onlyThisPageHelp"))
                Button(L("corrections.apply", n)) { model.apply(state: state, onlyThisPage: false) }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(n == 0)
            case .nothing:
                Button(L("corrections.done")) { model.hide() }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button(L("common.close")) { model.hide() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
                Button(L("corrections.retry")) { model.retry(state: state) }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Brand.spacing.contentWide)
        .padding(.top, Brand.spacing.m)
        .padding(.bottom, Brand.spacing.xl)
    }

    private func grouped(_ session: CorrectionsModel.Session) -> [(path: String, edits: [ProposedEdit])] {
        var order: [String] = []
        var byPath: [String: [ProposedEdit]] = [:]
        for edit in session.proposal.edits {
            if byPath[edit.path] == nil { order.append(edit.path) }
            byPath[edit.path, default: []].append(edit)
        }
        return order.map { ($0, byPath[$0] ?? []) }
    }

    /// `[[javier-ruiz|Javier]]` → "Javier", `[[javier-ruiz]]` → "javier-ruiz".
    static func plain(_ markdown: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#) else { return markdown }
        let ns = markdown as NSString
        var out = markdown
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            let label = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : ns.substring(with: match.range(at: 1))
            out = (out as NSString).replacingCharacters(in: match.range, with: label)
        }
        return out
    }
}

/// One proposed edit: checkbox, Claude's reason, and the lines it removes / adds.
private struct EditRow: View {
    let edit: ProposedEdit
    let checked: Bool
    let toggle: () -> Void

    /// Snippets are a few lines; a long one shows its first lines.
    private static let maxLines = 14

    var body: some View {
        HStack(alignment: .top, spacing: Brand.spacing.s) {
            Toggle("", isOn: Binding(get: { checked }, set: { _ in toggle() }))
                .toggleStyle(.brandCheckbox)
                .labelsHidden()
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Brand.spacing.xs) {
                if !edit.reason.isEmpty {
                    Text(edit.reason)
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let lines = Self.removedFirst(LineDiff.lines(before: edit.before, after: edit.after))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.prefix(Self.maxLines)) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(sign(line.kind)).foregroundStyle(Brand.color.text3).frame(width: 10)
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.kind == .same ? Brand.color.text2 : Brand.color.text)
                                .strikethrough(line.kind == .removed, color: Brand.color.text3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(background(line.kind))
                    }
                    if lines.count > Self.maxLines {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(Brand.color.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                }
                .font(Brand.mono)
                .textSelection(.enabled)
                .clipShape(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.lineSoft))
            }
            .opacity(checked ? 1 : 0.55)
        }
        .padding(Brand.spacing.s)
        .background(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).fill(Brand.color.card))
    }

    /// In each run of changed lines, what goes away reads before what replaces it.
    static func removedFirst(_ lines: [LineDiff.Line]) -> [LineDiff.Line] {
        var out: [LineDiff.Line] = [], run: [LineDiff.Line] = []
        func flush() {
            out += run.filter { $0.kind == .removed } + run.filter { $0.kind == .added }
            run.removeAll()
        }
        for line in lines {
            if line.kind == .same { flush(); out.append(line) } else { run.append(line) }
        }
        flush()
        return out
    }

    private func sign(_ kind: LineDiff.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .same: " "
        }
    }

    private func background(_ kind: LineDiff.Kind) -> Color {
        switch kind {
        case .added: Brand.color.accentSoft
        case .removed: Brand.color.recordSoft
        case .same: .clear
        }
    }
}

// MARK: - Facts from elsewhere in the app

extension AppState {
    /// Appends one dated line to `facts.md` ("Hechos confirmados por ti", §16.6) with an undoable Historial entry —
    /// e.g. the project's Personas tab: "Javier Ruiz no forma parte de 🚀 Kickoff." `about`: page names to link when
    /// the sentence has no wikilink of its own (`["javier-ruiz"]`). Errors are logged; returns whether it was written.
    @discardableResult
    func recordFact(_ fact: String, about: [String] = [], projectSlug: String? = nil) -> Bool {
        do {
            return try engine.recordFact(fact, about: about, projectSlug: projectSlug) != nil
        } catch {
            Log.error("recordFact failed: \(error)")
            return false
        }
    }
}
