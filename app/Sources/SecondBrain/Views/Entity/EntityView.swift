import AppKit
import BrainCore
import SwiftUI

/// "Qué sabemos de X" (CONTRACT §16.4): the ficha of any vault page — person, org, topic, decision, meeting, email,
/// document, project, saved question, repo. Opened in `scope`: from a global place it shows everything; inside a
/// project its sections are filtered to that project and the header says so ("En 🚀 X · Ver todo →").
/// Layout: the header (Atrás, kind, title, actions; then the front matter as clickable chips) over the page Claude
/// wrote, with the automatic sections (Proyectos · Reuniones · Correos · Documentos y notas · Decisiones · Pendientes ·
/// Relacionados) rendered after it in the same scroll.
struct EntityView: View {
    @Environment(AppState.self) private var state
    let path: String
    var scope: Scope = .brain
    /// A link inside the ficha (a wikilink, a chip, a section row): default = the router, in this scope. Hosts with a
    /// navigation stack pass a push (`EntityStackView`).
    var onOpen: ((String) -> Void)? = nil
    /// Atrás (⌘[): shown when the host has somewhere to go back to.
    var onBack: (() -> Void)? = nil

    @ViewState private var snapshot: EntityIndex.Snapshot = .empty
    @ViewState private var loaded = false
    /// The page's own `##` headings: an automatic section Claude's page already has (its "Proyectos", "En
    /// reuniones"…) isn't repeated under it.
    @ViewState private var pageHeadings: [String] = []

    private var entity: Entity? { snapshot.entity(path) }

    private var shownTitle: String {
        entity?.title ?? WikiGrouping.humanize(path)
    }

    /// The project the ficha is filtered to: the scope's, unless the page lives there anyway (nothing to filter).
    private var filterSlug: String? {
        guard let slug = scope.projectSlug, state.project(slug) != nil else { return nil }
        return entity?.projectSlug == slug ? nil : slug
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Brand.color.line).frame(height: 1)
            WikiWebView(vault: state.engine.vault, path: path, hideType: true, showsChrome: false,
                        appendix: loaded ? EntityMarkdown.sections(
                            EntityMarkdown.withoutDuplicates(snapshot.sections(for: path, projectSlug: filterSlug),
                                                             pageHeadings: pageHeadings),
                            snapshot: snapshot) : nil) { next in
                follow(next)
            }
        }
        .background(Brand.color.surface)
        .navigationTitle(shownTitle)
        .task(id: "\(path)-\(state.vaultRevision)-\(state.tasksRevision)-\(state.projects.hashValue)") {
            let vault = state.engine.vault, page = path
            let snap = await EntityIndex.snapshot(vaultRoot: vault.root)
            let headings = await Task.detached { EntityMarkdown.headings(in: (try? vault.read(page)) ?? "") }.value
            guard !Task.isCancelled else { return }
            snapshot = snap
            pageHeadings = headings
            loaded = true
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            HStack(spacing: Brand.spacing.s) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Brand.color.text2)
                    .keyboardShortcut("[", modifiers: .command)
                    .help(L("wiki.back"))
                }
                Image(systemName: EntityStyle.symbol(entity?.kind, path: path)).foregroundStyle(Brand.color.text2)
                Text(shownTitle)
                    .font(Brand.section)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(2)   // narrow hosts (Preguntar's citation panel) wrap instead of cutting the name
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(shownTitle)
                Spacer(minLength: Brand.spacing.s)
                ViewThatFits(in: .horizontal) {
                    actions(iconOnly: false)
                    actions(iconOnly: true)
                }
            }
            if let slug = filterSlug, let project = state.project(slug) {
                scopeBar(project)
            }
            if let entity {
                EntityChips(entity: entity, snapshot: snapshot, here: filterSlug ?? scope.projectSlug) { follow($0) }
            }
        }
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, Brand.spacing.m)
    }

    /// "En 🚀 Kickoff · Ver todo →": the ficha is filtered to this project; "Ver todo" opens the global one.
    private func scopeBar(_ project: Project) -> some View {
        HStack(spacing: Brand.spacing.xs) {
            Text(String(format: L("entity.inProject"), "\(project.emoji) \(project.name)"))
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("·").font(Brand.caption).foregroundStyle(Brand.color.text3)
            Button {
                state.navigate(to: .entity(path, .brain))
            } label: {
                HStack(spacing: 3) {
                    Text(L("entity.seeAll")).lineLimit(1)
                    Image(systemName: "arrow.right").imageScale(.small)
                }
                .font(Brand.font(11, .medium))
                .foregroundStyle(Brand.color.accent)
            }
            .buttonStyle(.plain)
            .help(L("entity.seeAllHelp"))
        }
    }

    private func actions(iconOnly: Bool) -> some View {
        HStack(spacing: Brand.spacing.s) {
            if EntityView.isEditable(path) {
                let edit = Button { state.editPage(path) } label: { Label(L("entity.edit"), systemImage: "pencil") }
                    .buttonStyle(.brandSecondary)
                    .help(L("entity.editHelp"))
                if iconOnly { edit.labelStyle(.iconOnly) } else { edit.labelStyle(.titleAndIcon) }
            }
            if WikiGrouping.isInGraph(path) {
                Button { state.navigate(to: .graph(scope, path)) } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.borderless)
                .help(L("graph.seeInGraph"))
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([state.engine.vault.url(for: path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(L("wiki.showInFinder"))
        }
        .foregroundStyle(Brand.color.text2)
    }

    // MARK: Links

    /// The single click rule (§16.4): a project row goes to that project's Resumen, a task to its row in Pendientes,
    /// a page to the host (push) or the router.
    private func follow(_ target: String) {
        switch EntityMarkdown.decode(target) {
        case .project(let slug):
            state.navigate(to: .projectTab(slug, .summary))
        case .task(let id):
            state.navigate(to: .task(id))
        case .page(let next):
            if let onOpen { onOpen(next) } else { state.navigate(to: .entity(next, scope)) }
        }
    }

    /// Wiki pages and fichas can be edited; sources under `raw/`, `_inbox/` and the schema never (§16.6; the editor's
    /// own rule, `Corrections.isEditable`).
    static func isEditable(_ path: String) -> Bool { Corrections.isEditable(path) }

    /// Whether a link from a ficha shown in `scope` is pushed as another ficha in the same host (true), or goes to its
    /// own place through the router (false): inside a project, its own pages open in Contenido; from the brain, a
    /// project's page opens in its project. Everything else (people, orgs, global pages, other projects' pages seen
    /// from a project) is pushed (§16.4).
    static func pushes(_ path: String, in scope: Scope) -> Bool {
        let owner = Scope.projectSlug(ofPath: path)
        if let slug = scope.projectSlug { return owner != slug }
        return owner == nil
    }
}

// MARK: - Header chips

/// The front matter as chips (§16.4 item 1): kind, projects, org, role, date, status and the pages it names
/// (people:, topics:…). Chips that point somewhere are buttons; they wrap, never widen the header.
struct EntityChips: View {
    @Environment(AppState.self) private var state
    let entity: Entity
    let snapshot: EntityIndex.Snapshot
    /// The project the ficha is shown in (its own chip is left out).
    var here: String?
    var onOpen: (String) -> Void
    /// The compact card shows fewer.
    var limit = 8

    private struct Item: Identifiable {
        let id: String
        let text: String
        let symbol: String?
        let target: String?
    }

    private var items: [Item] {
        var out: [Item] = [Item(id: "kind", text: EntityStyle.label(entity.kind), symbol: nil, target: nil)]
        for slug in entityProjects where slug != here {
            guard let p = state.project(slug) else { continue }
            out.append(Item(id: "p-\(slug)", text: "\(p.emoji) \(p.name)", symbol: nil, target: EntityMarkdown.encode(.project(slug))))
        }
        if let role = entity.role { out.append(Item(id: "role", text: role, symbol: "person.text.rectangle", target: nil)) }
        if let org = snapshot.orgName(entity.org) {
            out.append(Item(id: "org", text: org, symbol: "building.2", target: snapshot.orgPath(entity.org)))
        }
        if let date = entity.eventDate, entity.kind != .person {
            out.append(Item(id: "date", text: SBDate.human(date, hasTime: false, language: state.config.uiLanguage),
                            symbol: "calendar", target: nil))
        }
        if let status = entity.status {
            let key = "prop.status.\(status.lowercased())"
            let text = L(key)
            out.append(Item(id: "status", text: text == key ? status : text, symbol: nil, target: nil))
        }
        let orgPath = snapshot.orgPath(entity.org)
        for link in entity.frontLinks where link != orgPath {
            guard let e = snapshot.entity(link), e.kind != .project else { continue }
            out.append(Item(id: "l-\(link)", text: e.title, symbol: EntityStyle.symbol(e.kind, path: link), target: link))
        }
        return Array(out.prefix(limit))
    }

    /// People, orgs and global pages: every project they touch; project pages: none (the header says where).
    private var entityProjects: [String] {
        entity.projectSlug == nil ? snapshot.projects(of: entity.path) : []
    }

    var body: some View {
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items) { item in
                if let target = item.target {
                    Button { onOpen(target) } label: {
                        BrandChip(text: item.text, symbol: item.symbol, active: true)
                    }
                    .buttonStyle(.plain)
                    .help(item.text)
                } else {
                    BrandChip(text: item.text, symbol: item.symbol)
                        .help(item.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sections as markdown

/// The ficha's sections, written as markdown after the page (one scroll, the page's own type and link styles). Rows
/// link with `sbwiki://page/<target>`; targets that are not pages are encoded as `@project/<slug>` / `@task/<id>`.
enum EntityMarkdown {
    static func encode(_ target: EntityTarget) -> String {
        switch target {
        case .page(let p): p
        case .project(let s): "@project/\(s)"
        case .task(let t): "@task/\(t)"
        }
    }

    static func decode(_ raw: String) -> EntityTarget {
        if raw.hasPrefix("@project/") { return .project(String(raw.dropFirst("@project/".count))) }
        if raw.hasPrefix("@task/") { return .task(String(raw.dropFirst("@task/".count))) }
        return .page(raw)
    }

    /// The `## ` headings of a page (front matter and code blocks skipped).
    static func headings(in text: String) -> [String] {
        var inFence = false
        return text.components(separatedBy: "\n").compactMap { line in
            if line.hasPrefix("```") { inFence.toggle(); return nil }
            guard !inFence, line.hasPrefix("## ") else { return nil }
            return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Heading names (es/en, lowercased, no accents) that mean the same as an automatic section. Pendientes is
    /// never dropped (its rows are the live checklist, not the page's plain bullets), nor Relacionados (it adds the
    /// backlinks, which a page's own "Relacionado" never lists).
    static let synonyms: [EntitySectionKind: Set<String>] = [
        .projects: ["proyectos", "projects", "en proyectos", "in projects"],
        .meetings: ["reuniones", "en reuniones", "meetings", "in meetings"],
        .emails: ["correos", "hilos de correo", "emails", "email threads", "mail"],
        .documents: ["documentos y notas", "documentos", "documents and notes", "documents"],
        .decisions: ["decisiones", "decisiones relacionadas", "decisions", "related decisions"],
    ]

    static func normalized(_ heading: String) -> String {
        heading.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces).union(.whitespaces))
    }

    /// `sections` without the ones the page already has under a heading of the same meaning.
    static func withoutDuplicates(_ sections: [EntitySection], pageHeadings: [String]) -> [EntitySection] {
        let have = Set(pageHeadings.map(normalized))
        guard !have.isEmpty else { return sections }
        return sections.filter { section in
            guard let names = synonyms[section.kind] else { return true }
            return have.isDisjoint(with: names)
        }
    }

    static func sections(_ sections: [EntitySection], snapshot: EntityIndex.Snapshot) -> String {
        guard !sections.isEmpty else { return "" }
        var out = ["---", ""]
        for section in sections {
            out.append("## \(EntityStyle.sectionTitle(section.kind))")
            out.append("")
            for row in section.rows.prefix(40) {
                out.append(line(row, in: section.kind))
            }
            if section.rows.count > 40 { out.append("- …") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private static func line(_ row: EntityRow, in kind: EntitySectionKind) -> String {
        let link = "[\(escape(row.title))](sbwiki://page/\(percent(encode(row.target))))"
        var parts: [String] = []
        if kind == .tasks {
            if let owner = row.detail { parts.append(escape(owner)) }
            if let due = row.date { parts.append("📅 " + day(due)) }
            return "- [\(row.done ? "x" : " ")] " + ([link] + parts).joined(separator: " · ")
        }
        if let detail = row.detail { parts.append(escape(detail)) }
        if let date = row.date { parts.append(day(date)) }
        if kind == .related { parts.insert(EntityStyle.label(row.kind), at: 0) }
        return "- " + ([link] + parts).joined(separator: " · ")
    }

    /// "2026-10-27" (wiki.js shows bare ISO dates as "27 oct 2026").
    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\[]*_`<>#|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }
}

// MARK: - Words and symbols

enum EntityStyle {
    static func label(_ kind: EntityKind) -> String { L("entity.kind.\(kind.rawValue)") }

    static func sectionTitle(_ kind: EntitySectionKind) -> String { L("entity.section.\(kind.rawValue)") }

    static func symbol(_ kind: EntityKind?, path: String) -> String {
        switch kind {
        case .person: "person"
        case .org: "building.2"
        case .project: "sparkles"
        case .meeting: "waveform"
        case .email: "envelope"
        case .document: "doc.text"
        case .note: "note.text"
        case .url: "link"
        case .topic: "lightbulb"
        case .decision: "checkmark.seal"
        case .question: "questionmark.bubble"
        case .repo: "chevron.left.forwardslash.chevron.right"
        case .facts: "pin"
        case .page, nil: WikiGrouping.symbol(for: path)
        }
    }
}
