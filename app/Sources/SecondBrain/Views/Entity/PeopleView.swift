import BrainCore
import SwiftUI

/// Personas (CONTRACT §16.4): every person of the brain on the left — search by name, alias, role or company; each row
/// with role · company and the projects they are in — and the selected person's ficha on the right, with its own
/// navigation stack (a person, a company or a global page opened from it is pushed; Atrás ⌘[).
struct PeopleView: View {
    @Environment(AppState.self) private var state

    @ViewState private var snapshot: EntityIndex.Snapshot = .empty
    @ViewState private var loaded = false
    @ViewState private var query = ""
    /// The ficha stack: the selected person first, then what was opened from it.
    @ViewState private var stack: [String] = []

    private var people: [Entity] { PersonSearch.filter(snapshot.allPeople, query: query, snapshot: snapshot) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if !loaded {
                    BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if snapshot.allPeople.isEmpty {
                    EmptyStateView(symbol: "person.2", title: L("people.emptyTitle"), message: L("people.emptyMessage"))
                } else {
                    list.frame(width: ContentLayout.listWidth(for: geo.size.width))
                    ContentLayout.columnRule
                    if stack.isEmpty {
                        EmptyStateView(symbol: "person", title: L("people.pick"), message: "")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EntityStackView(stack: $stack, scope: .brain)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Brand.color.surface)
        .navigationTitle(L("sidebar.people"))
        .task(id: "\(state.vaultRevision)-\(state.projects.hashValue)") { await reload() }
        .onAppear(perform: consumePending)
        .onChange(of: state.pendingPage) { consumePending() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            SearchFieldRow(placeholder: L("people.search"), text: $query)
                .padding(Brand.spacing.m)
            if people.isEmpty {
                Text(L("people.noMatch"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .padding(Brand.spacing.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(people) { person in
                                PersonRow(person: person, snapshot: snapshot, isSelected: stack.first == person.path) {
                                    stack = [person.path]
                                }
                                .id(person.path)
                            }
                        }
                        .padding(Brand.spacing.s)
                    }
                    .onAppear { if let first = stack.first { proxy.scrollTo(first, anchor: .center) } }
                }
            }
        }
        .background(Brand.color.surface)
    }

    private func reload() async {
        guard state.engineStarted else { return }
        let snap = await EntityIndex.snapshot(vaultRoot: state.engine.vault.root)
        guard !Task.isCancelled else { return }
        snapshot = snap
        loaded = true
        // A person deleted in the background: back to the first one.
        if let first = stack.first, snap.entity(first) == nil { stack = [] }
        if stack.isEmpty, let first = snap.allPeople.first(where: { !$0.isOwner }) ?? snap.allPeople.first {
            stack = [first.path]
        }
    }

    /// A person opened from elsewhere (`AppState.navigate(to: .entity)`, ⌘K, a link): their ficha, as a new stack.
    private func consumePending() {
        guard state.selection == .people, let path = state.pendingPage else { return }
        state.pendingPage = nil
        stack = [path]
    }
}

// MARK: - Shared pieces (Personas, a project's Personas)

/// Search over people: name, aliases, role, company; accents and case ignored.
enum PersonSearch {
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    static func filter(_ people: [Entity], query: String, snapshot: EntityIndex.Snapshot) -> [Entity] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return people }
        return people.filter { p in
            ([p.title, p.role ?? "", snapshot.orgName(p.org) ?? ""] + p.aliases).contains { fold($0).contains(q) }
        }
    }
}

/// 🔍 field in a list column: `card` with a `lineSoft` edge at rest and the brand focus halo (a `focusRing` glow and a
/// `focusBorder` edge) while typing, like `brandField`. Never the system focus ring.
struct SearchFieldRow: View {
    let placeholder: String
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.color.text3)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text)
                .focused($focused)
                .focusEffectDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.color.text3)
                }
                .buttonStyle(.plain)
                .help(L("mail.clearSearch"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Brand.color.card, in: shape)
        .overlay(shape.strokeBorder(focused ? Brand.color.focusBorder : Brand.color.lineSoft, lineWidth: 1))
        .brandFocusHalo(focused)
        .animation(Brand.motion.fast, value: focused)
    }
}

/// A person in a list: initials, name, role · company, and the emojis of their projects.
struct PersonRow: View {
    @Environment(AppState.self) private var state
    let person: Entity
    let snapshot: EntityIndex.Snapshot
    var isSelected = false
    var action: () -> Void

    @ViewState private var hovering = false

    private var detail: String? {
        let parts = [person.role, snapshot.orgName(person.org)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var projectEmojis: String {
        snapshot.projects(of: person.path).compactMap { state.project($0)?.emoji }.joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: Brand.spacing.s) {
            InitialsCircle(address: EmailAddress(name: person.title, email: nil), size: 26, ring: .clear)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.title)
                    .font(isSelected ? Brand.callout : Brand.body)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            if !projectEmojis.isEmpty {
                Text(projectEmojis)
                    .font(Brand.font(11))
                    .lineLimit(1)
                    .help(snapshot.projects(of: person.path).compactMap { state.project($0)?.name }.joined(separator: ", "))
            }
        }
        .padding(.horizontal, Brand.spacing.s)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(isSelected ? Brand.color.accentSoft : (hovering ? Brand.color.hover : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
        .onTapGesture(perform: action)
        .help(person.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
