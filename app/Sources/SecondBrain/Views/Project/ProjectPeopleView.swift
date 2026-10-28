import BrainCore
import SwiftUI

/// A project's "Personas" tab (CONTRACT §16.2): the people linked to the project (links from/to its pages, their
/// `projects:`, and `project.json` `people.include` minus `exclude`), with role, company, last contact and number of
/// sources; a click opens the person's ficha filtered to the project. "+ Agregar persona" searches `people/`;
/// "Quitar del proyecto" (context menu) removes them. Both are saved in `project.json` and recorded as a confirmed
/// fact (§16.6), so Claude stops (or starts) placing them in the project.
struct ProjectPeopleView: View {
    @Environment(AppState.self) private var state
    let project: Project
    var onOpen: (String) -> Void = { _ in }

    @ViewState private var snapshot: EntityIndex.Snapshot = .empty
    @ViewState private var loaded = false
    @ViewState private var query = ""
    @ViewState private var adding = false
    @ViewState private var error: String?

    private var slug: String { project.slug }
    private var people: [ProjectPerson] { snapshot.people(ofProject: slug) }

    private var shown: [ProjectPerson] {
        let q = PersonSearch.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return people }
        return people.filter { p in [p.title, p.role ?? "", p.org ?? ""].contains { PersonSearch.fold($0).contains(q) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Brand.color.line).frame(height: 1)
            if !loaded {
                BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if people.isEmpty {
                EmptyStateView(symbol: "person.2", title: L("projectPeople.emptyTitle"), message: L("projectPeople.emptyMessage"),
                               actionTitle: L("projectPeople.add")) { adding = true }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { person in
                            ProjectPersonRow(person: person) { onOpen(person.path) }
                                .contextMenu {
                                    Button { onOpen(person.path) } label: { Label(L("page.open"), systemImage: "person") }
                                    Divider()
                                    Button(role: .destructive) { set(person.path, title: person.title, included: false) } label: {
                                        Label(L("projectPeople.remove"), systemImage: "person.badge.minus")
                                    }
                                }
                        }
                    }
                    .padding(Brand.spacing.m)
                    .frame(maxWidth: 880, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Brand.color.surface)
        .task(id: "\(state.vaultRevision)-\(state.projects.hashValue)") { await reload() }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: Brand.spacing.s) {
            SearchFieldRow(placeholder: L("people.search"), text: $query)
                .frame(maxWidth: 320)
            Spacer(minLength: Brand.spacing.s)
            Button { adding = true } label: {
                Label(L("projectPeople.add"), systemImage: "person.badge.plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.brandSecondary)
            .help(L("projectPeople.addHelp"))
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                AddPersonPopover(snapshot: snapshot, excluding: Set(people.map(\.path))) { person in
                    adding = false
                    set(person.path, title: person.title, included: true)
                }
            }
        }
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, Brand.spacing.s)
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let snap = await EntityIndex.snapshot(vaultRoot: state.engine.vault.root)
        guard !Task.isCancelled else { return }
        snapshot = snap
        loaded = true
    }

    /// Saves the choice in `project.json` and records it as a confirmed fact.
    private func set(_ path: String, title: String, included: Bool) {
        let personSlug = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        do {
            try state.engine.projects.setPerson(personSlug, included: included, in: slug)
            state.reloadProjects()
            let name = "\(project.emoji) \(project.name)"
            let fact = L(included ? "projectPeople.fact.added" : "projectPeople.fact.removed", title, name)
                + " ([[\(personSlug)]], [[projects/\(slug)/wiki/overview|\(project.name)]])"
            state.recordFact(fact)
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

/// A person of the project: initials, name, role · company; last contact and number of sources on the right (they
/// fold under the name when the row is narrow).
private struct ProjectPersonRow: View {
    @Environment(AppState.self) private var state
    let person: ProjectPerson
    var action: () -> Void

    @ViewState private var hovering = false

    private var detail: String? {
        let parts = [person.role, person.org].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var stats: String {
        var parts: [String] = []
        if let last = person.lastContact {
            parts.append(L("projectPeople.lastContact", SBDate.human(last, hasTime: false, language: state.config.uiLanguage)))
        }
        if person.sources > 0 { parts.append(L("projectPeople.sources", person.sources)) }
        if person.manual { parts.append(L("projectPeople.addedByYou")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Brand.spacing.m) {
            InitialsCircle(address: EmailAddress(name: person.title, email: nil), size: 32, ring: .clear)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Brand.spacing.m) {
                    names.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    if !stats.isEmpty {
                        Text(stats)
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    names
                    if !stats.isEmpty {
                        Text(stats)
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Brand.spacing.m)
        .padding(.vertical, Brand.spacing.s)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(hovering ? Brand.color.cardAlt.opacity(0.55) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(person.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(person.title)
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Text(detail)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// "+ Agregar persona": a search over every person of the brain not yet in the project.
private struct AddPersonPopover: View {
    let snapshot: EntityIndex.Snapshot
    let excluding: Set<String>
    var onPick: (Entity) -> Void

    @ViewState private var query = ""

    private var candidates: [Entity] {
        PersonSearch.filter(snapshot.allPeople.filter { !excluding.contains($0.path) && !$0.isOwner }, query: query,
                            snapshot: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            SearchFieldRow(placeholder: L("people.search"), text: $query)
            if candidates.isEmpty {
                Text(L("people.noMatch"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .padding(.vertical, Brand.spacing.s)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(candidates) { person in
                            PersonRow(person: person, snapshot: snapshot) { onPick(person) }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(Brand.spacing.m)
        .frame(width: 320)
    }
}
