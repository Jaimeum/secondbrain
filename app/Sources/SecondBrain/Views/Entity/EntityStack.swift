import BrainCore
import SwiftUI

/// A ficha with its own navigation stack (CONTRACT §16.4, the single click rule): links that belong in this host are
/// pushed, with Atrás (⌘[) back to the previous ficha; links that live elsewhere (a project page seen from the brain,
/// this project's page seen from a project) go to their place. Used by Personas, a project's pushed fichas and any
/// panel that shows a ficha (Preguntar's citation inspector can reuse it).
struct EntityStackView: View {
    @Environment(AppState.self) private var state
    @Binding var stack: [String]
    var scope: Scope = .brain
    /// Atrás on the first ficha (a project: back to the tab it was opened from); nil = no Atrás there.
    var onBackFromRoot: (() -> Void)? = nil
    /// A link that is not pushed (default: the router, in this scope).
    var onElsewhere: ((String) -> Void)? = nil

    var body: some View {
        if let top = stack.last {
            EntityView(path: top, scope: scope, onOpen: open, onBack: backAction)
        }
    }

    private var backAction: (() -> Void)? {
        if stack.count > 1 { return { _ = stack.popLast() } }
        return onBackFromRoot
    }

    private func open(_ next: String) {
        if EntityView.pushes(next, in: scope) {
            if stack.last != next { stack.append(next) }
            if stack.count > 50 { stack.removeFirst(stack.count - 50) }
        } else if let onElsewhere {
            onElsewhere(next)
        } else {
            state.navigate(to: .entity(next, scope))
        }
    }
}

/// The compact ficha (§16.5: the graph's side panel): kind and title, chips, the first paragraph of the page, the
/// section counts and the latest related rows; "Abrir" goes to the full ficha. Every row is clickable (`onOpen`).
/// Fills the width it is given; scrolls when taller than its container.
struct EntityCard: View {
    @Environment(AppState.self) private var state
    let path: String
    var scope: Scope = .brain
    /// "Abrir" and every row (default: the router, in this scope).
    var onOpen: ((String) -> Void)? = nil

    @ViewState private var snapshot: EntityIndex.Snapshot = .empty
    @ViewState private var excerpt = ""

    private var entity: Entity? { snapshot.entity(path) }

    private var filterSlug: String? {
        guard let slug = scope.projectSlug else { return nil }
        return entity?.projectSlug == slug ? nil : slug
    }

    private var sections: [EntitySection] { snapshot.sections(for: path, projectSlug: filterSlug) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: Brand.spacing.s) {
                    Image(systemName: EntityStyle.symbol(entity?.kind, path: path))
                        .foregroundStyle(Brand.color.text2)
                    Text(entity?.title ?? WikiGrouping.humanize(path))
                        .font(Brand.section)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let entity {
                    EntityChips(entity: entity, snapshot: snapshot, here: scope.projectSlug, onOpen: open, limit: 5)
                }
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { open(path) } label: {
                    Label(L("page.open"), systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.brandPrimary)
                .help(L("entity.openHelp"))
                ForEach(sections.filter { $0.kind != .tasks }) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        ContentListHeader(title: EntityStyle.sectionTitle(section.kind), trailing: "\(section.rows.count)")
                        ForEach(section.rows.prefix(3)) { row in
                            ContentListRow(symbol: EntityStyle.symbol(row.kind, path: rowPath(row) ?? ""), title: row.title,
                                           caption: caption(row)) {
                                open(EntityMarkdown.encode(row.target))
                            }
                        }
                    }
                }
            }
            .padding(Brand.spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.color.surface)
        .task(id: "\(path)-\(state.vaultRevision)-\(state.projects.hashValue)") {
            let root = state.engine.vault.root, vault = state.engine.vault, page = path
            async let snap = EntityIndex.snapshot(vaultRoot: root)
            let text = await Task.detached { EntityIndex.excerpt((try? vault.read(page)) ?? "") }.value
            let loaded = await snap
            guard !Task.isCancelled else { return }
            snapshot = loaded
            excerpt = text
        }
    }

    private func rowPath(_ row: EntityRow) -> String? {
        if case .page(let p) = row.target { return p }
        return nil
    }

    private func caption(_ row: EntityRow) -> String? {
        let date = row.date.map { SBDate.human($0, hasTime: false, language: state.config.uiLanguage) }
        let parts = [row.detail, date].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func open(_ raw: String) {
        switch EntityMarkdown.decode(raw) {
        case .project(let slug): state.navigate(to: .projectTab(slug, .summary))
        case .task(let id): state.navigate(to: .task(id))
        case .page(let p):
            if let onOpen { onOpen(p) } else { state.navigate(to: .entity(p, scope)) }
        }
    }
}
