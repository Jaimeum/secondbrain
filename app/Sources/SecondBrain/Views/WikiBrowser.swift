import AppKit
import BrainCore
import SwiftUI

enum WikiScope: Equatable {
    case project(String)
    case global
    case people
}

/// Page list on the left, rendered page on the right (Personas; a project's "Por tema" uses the same pieces).
struct WikiBrowser: View {
    @Environment(AppState.self) private var state
    let scope: WikiScope
    @Binding var selection: String?

    @ViewState private var pages: [WikiPage] = []
    /// The first listing came back (until then a loader, not the empty state).
    @ViewState private var loaded = false

    private var projectName: String? {
        if case .project(let slug) = scope { return state.project(slug)?.name }
        return nil
    }

    private var groups: [WikiGrouping.Group] { WikiGrouping.groups(for: pages, scope: scope, projectName: projectName) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if !loaded {
                    BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pages.isEmpty && selection == nil {
                    emptyState
                } else {
                    WikiPageList(groups: groups, selection: $selection)
                        .frame(width: ContentLayout.listWidth(for: geo.size.width))
                    Rectangle().fill(Brand.color.line).frame(width: 1)
                    WikiPagePane(selection: $selection,
                                 title: WikiGrouping.title(of: selection, in: pages, projectName: projectName))
                }
            }
        }
        .background(Brand.color.surface)
        .task(id: state.vaultRevision) { await reload() }
        .task {
            // Claude edits pages in the background; keep the list fresh without user action.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled { break }
                await reload()
            }
        }
    }

    private var emptyState: some View {
        switch scope {
        case .people:
            EmptyStateView(symbol: "person.2", title: L("people.emptyTitle"), message: L("people.emptyMessage"))
        default:
            EmptyStateView(symbol: "book.closed", title: L("wiki.emptyTitle"), message: L("wiki.emptyMessage"))
        }
    }

    /// Lists the pages off the main thread (it walks the vault folder) and applies the result only if the
    /// vault is still the same one.
    private func reload() async {
        guard state.engineStarted else { return }
        let vault = state.engine.vault
        let all = await WikiGrouping.loadPages(scope: scope, vault: vault)
        guard !Task.isCancelled, vault === state.engine.vault else { return }
        if all != pages { pages = all }
        // A page deleted or renamed in the background: fall back to the default page.
        if let current = selection, !current.contains("/raw/"), !all.contains(where: { $0.path == current }),
           !FileManager.default.fileExists(atPath: vault.url(for: current).path) {
            selection = nil
        }
        if selection == nil {
            selection = WikiGrouping.defaultPage(in: all)?.path
        }
        loaded = true
    }
}

/// Shared widths of the two-column content views (§15.2/§15.3: list 200–260, page takes the rest).
enum ContentLayout {
    static func listWidth(for total: CGFloat) -> CGFloat { min(260, max(200, (total * 0.3).rounded())) }
}

// MARK: - Page list

/// Grouped page rows ("Reuniones", "Temas"…) with brand selection; scrolls to the selected page.
struct WikiPageList: View {
    let groups: [WikiGrouping.Group]
    @Binding var selection: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups, id: \.key) { group in
                        if !group.title.isEmpty {
                            ContentListHeader(title: group.title)
                        }
                        ForEach(group.pages, id: \.page.path) { item in
                            ContentListRow(symbol: WikiGrouping.symbol(for: item.page.path), title: item.title,
                                           isSelected: selection == item.page.path) {
                                selection = item.page.path
                            }
                            .id(item.page.path)
                        }
                    }
                }
                .padding(.horizontal, Brand.spacing.s)
                .padding(.vertical, Brand.spacing.s)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: selection) { scroll(proxy, animated: true) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let selection, groups.contains(where: { $0.pages.contains { $0.page.path == selection } }) else { return }
        if animated {
            withAnimation(Brand.motion.animation(fast: true)) { proxy.scrollTo(selection, anchor: .center) }
        } else {
            proxy.scrollTo(selection, anchor: .center)
        }
    }
}

/// A small group title in a content list ("Reuniones", "Octubre de 2026").
struct ContentListHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Brand.font(11, .semibold))
                .foregroundStyle(Brand.color.text2)
                .textCase(.uppercase)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(Brand.caption).foregroundStyle(Brand.color.text2).monospacedDigit()
            }
        }
        .padding(.horizontal, Brand.spacing.s)
        .padding(.top, Brand.spacing.m)
        .padding(.bottom, Brand.spacing.xs)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One selectable row of a content list: icon, title (two lines max), optional caption. Selected = `accentSoft`.
struct ContentListRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var caption: String? = nil
    var isSelected = false
    var dimmed = false
    let trailing: Trailing
    var action: () -> Void

    @ViewState private var hovering = false

    init(symbol: String, title: String, caption: String? = nil, isSelected: Bool = false, dimmed: Bool = false,
         @ViewBuilder trailing: () -> Trailing, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.caption = caption
        self.isSelected = isSelected
        self.dimmed = dimmed
        self.trailing = trailing()
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Brand.spacing.s) {
            Image(systemName: symbol)
                .font(Brand.font(12))
                .foregroundStyle(isSelected ? Brand.color.accent : Brand.color.text2)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(isSelected ? Brand.callout : Brand.body)
                    .foregroundStyle(dimmed ? Brand.color.text2 : Brand.color.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let caption {
                    Text(caption)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, Brand.spacing.s)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(isSelected ? Brand.color.accentSoft : (hovering ? Brand.color.cardAlt.opacity(0.55) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension ContentListRow where Trailing == EmptyView {
    init(symbol: String, title: String, caption: String? = nil, isSelected: Bool = false, dimmed: Bool = false,
         action: @escaping () -> Void) {
        self.init(symbol: symbol, title: title, caption: caption, isSelected: isSelected, dimmed: dimmed,
                  trailing: { EmptyView() }, action: action)
    }
}

// MARK: - Page pane

/// The rendered page with its header (back · title · pendientes / grafo / exportar / Finder, folded into ⋯ below
/// 560 pt). Every page change (a wikilink or a list row) goes into the back history; Back walks it.
struct WikiPagePane: View {
    @Environment(AppState.self) private var state
    @Binding var selection: String?
    /// The page's title when the caller knows it (else read from the file).
    var title: String? = nil
    /// v0.6 entity: a wikilink (default: shown here, into the back history). Contenido passes the single click rule
    /// (§16.4): this project's pages here, anything else as a ficha.
    var onLink: ((String) -> Void)? = nil

    @ViewState private var history: [String] = []
    /// The next selection change comes from Back: not recorded.
    @ViewState private var goingBack = false
    @ViewState private var export: ExportRequest?
    @ViewState private var tasksSource: SourceRecord?
    @ViewState private var threadKey: String?
    @ViewState private var loadedTitle: String?
    @ViewState private var width: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Brand.color.line).frame(height: 1)
            // v0.7 (§17.4): a thread page opened in Contenido shows its conversation on top too.
            if let key = selection.flatMap(ThreadConversationView.threadKey(forPage:)) {
                ThreadConversationView(threadKey: key)
            }
            // The header already names the page: the "Tipo" chip would only repeat it.
            WikiWebView(vault: state.engine.vault, path: selection, hideType: true) { path in navigate(to: path) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: selection) { await loadTitle() }
        .onChange(of: selection) { old, new in
            if goingBack {
                goingBack = false
            } else if let old, let new, old != new {
                history.append(old)
                if history.count > 50 { history.removeFirst(history.count - 50) }
            }
        }
        .sheet(item: $export) { ExportSheet(request: $0) }
        .sheet(item: $tasksSource) { SourceTasksSheet(source: $0) }
        .sheet(item: Binding(get: { threadKey.map(ThreadKeyItem.init) }, set: { threadKey = $0?.key })) { item in
            ThreadSheet(threadKey: item.key) { navigate(to: $0) }
        }
    }

    private var shownTitle: String {
        title ?? loadedTitle ?? selection.map { WikiGrouping.humanize($0) } ?? ""
    }

    private var header: some View {
        HStack(spacing: Brand.spacing.s) {
            Button {
                if let previous = history.popLast() {
                    goingBack = true
                    selection = previous
                }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Brand.color.text2)
            .disabled(history.isEmpty)
            .opacity(history.isEmpty ? 0 : 1)   // keeps its 22 pt: the title never shifts
            .accessibilityHidden(history.isEmpty)
            .help(L("wiki.back"))

            Text(shownTitle)
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(shownTitle)

            if let selection {
                if width >= 560 {
                    iconActions(selection)
                } else {
                    moreMenu(selection)
                }
            }
        }
        .padding(.horizontal, Brand.spacing.m)
        .frame(height: 40)
        .background(Brand.color.surface)
    }

    /// The meeting a summary page was written from (done), for "Pendientes y acuerdos".
    private func meetingSource(of path: String) -> SourceRecord? {
        guard path.contains("/wiki/meetings/") else { return nil }
        return state.engine.sources.first {
            $0.kind == .meeting && $0.status == .done && SourcePages.candidates(for: $0).contains(path)
        }
    }

    private func iconActions(_ path: String) -> some View {
        HStack(spacing: 2) {
            // §16.6: every wiki page can be corrected by hand where it is read.
            if Corrections.isEditable(path) {
                iconButton("pencil", help: L("entity.editHelp")) { state.editPage(path) }
            }
            if let source = meetingSource(of: path) {
                iconButton("checklist", help: L("srctasks.title")) { tasksSource = source }
            }
            if let key = WikiGrouping.threadKey(of: path) {
                iconButton("envelope", help: L("thread.viewEmails")) { threadKey = key }
            }
            if WikiGrouping.isInGraph(path) {
                iconButton("point.3.connected.trianglepath.dotted", help: L("graph.seeInGraph")) { showInGraph(path) }
            }
            iconButton("square.and.arrow.up", help: L("export.buttonEllipsis")) {
                export = ExportRequest(target: .page(path: path, title: shownTitle))
            }
            iconButton("folder", help: L("wiki.showInFinder")) { showInFinder(path) }
        }
    }

    private func moreMenu(_ path: String) -> some View {
        Menu {
            if Corrections.isEditable(path) {
                Button { state.editPage(path) } label: { Label(L("entity.edit"), systemImage: "pencil") }
                Divider()
            }
            if let source = meetingSource(of: path) {
                Button { tasksSource = source } label: { Label(L("srctasks.title"), systemImage: "checklist") }
            }
            if let key = WikiGrouping.threadKey(of: path) {
                Button { threadKey = key } label: { Label(L("thread.viewEmails"), systemImage: "envelope") }
            }
            if WikiGrouping.isInGraph(path) {
                Button { showInGraph(path) } label: {
                    Label(L("graph.seeInGraph"), systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            Button { export = ExportRequest(target: .page(path: path, title: shownTitle)) } label: {
                Label(L("export.buttonEllipsis"), systemImage: "square.and.arrow.up")
            }
            Button { showInFinder(path) } label: { Label(L("wiki.showInFinder"), systemImage: "folder") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Brand.color.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("project.more"))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Brand.font(13))
                .foregroundStyle(Brand.color.text2)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    /// A wikilink: the selection change itself goes into the history (`onChange(of: selection)`).
    private func navigate(to path: String) {
        if let onLink { onLink(path) } else { selection = path }
    }

    private func loadTitle() async {
        loadedTitle = nil
        guard title == nil, let path = selection else { return }
        let vault = state.engine.vault
        let t = await Task.detached { vault.title(of: path) }.value
        guard !Task.isCancelled, path == selection else { return }
        loadedTitle = t
    }

    private func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([state.engine.vault.url(for: path)])
    }

    /// "Ver en el grafo": the Grafo of the page's project, else the whole brain's Grafo, centered on the page.
    /// v0.6: filled in by C/B — the graph of the *current* scope (§16.5).
    private func showInGraph(_ path: String) {
        state.navigate(to: .graph(Scope(projectSlug: Scope.projectSlug(ofPath: path)), path))
    }
}

private struct ThreadKeyItem: Identifiable {
    let key: String
    var id: String { key }
}

// MARK: - Grouping

enum WikiGrouping {
    struct Item {
        let page: WikiPage
        /// The title shown in lists ("<project> — " prefix removed, overview = "Resumen del proyecto").
        let title: String
    }

    struct Group {
        let key: String
        /// Empty = no header (the pinned overview).
        let title: String
        let pages: [Item]
    }

    private static let order = ["pinned", "general", "meetings", "emails", "sources", "topics", "decisions", "repos",
                                "questions", "people"]
    private static let generalOrder = ["overview", "index", "tasks", "timeline", "health", "log"]
    /// Pages the app writes for its own screens (Pendientes, Contenido por fecha, Historial): not listed per project.
    private static let autoPages: Set<String> = ["index", "tasks", "timeline", "health", "log"]

    static func groupKey(_ path: String) -> String {
        var rel = path
        if rel.hasPrefix("projects/"), let range = rel.range(of: "/wiki/") { rel = String(rel[range.upperBound...]) }
        let parts = rel.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : "general"
    }

    static func baseName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
    }

    /// Lists a scope's pages (walks the vault: call off the main thread through the async API).
    static func loadPages(scope: WikiScope, vault: VaultStore) async -> [WikiPage] {
        switch scope {
        case .project(let slug):
            return await vault.pagesAsync(projectSlug: slug)
        case .global:
            // People have their own screen; logs and health reports open from Historial / ⌘K.
            return await vault.pagesAsync(projectSlug: nil).filter {
                !$0.path.hasPrefix("people/") && !["log", "health"].contains(baseName($0.path))
            }
        case .people:
            return await vault.pagesAsync(projectSlug: nil).filter { $0.path.hasPrefix("people/") && !$0.path.hasSuffix("README.md") }
        }
    }

    /// The list title of a page: in a project, without the "<project> — " prefix; the overview is "Resumen del proyecto".
    static func displayTitle(_ page: WikiPage, projectName: String?) -> String {
        guard let projectName else { return page.title }
        if baseName(page.path) == "overview", groupKey(page.path) == "general" { return L("graph.overviewLabel") }
        for separator in [" — ", " - ", ": "] where page.title.hasPrefix(projectName + separator) {
            let rest = String(page.title.dropFirst(projectName.count + separator.count))
            return rest.prefix(1).uppercased() + rest.dropFirst()
        }
        return page.title
    }

    /// The header title of a selected page, when it is in the list.
    static func title(of path: String?, in pages: [WikiPage], projectName: String?) -> String? {
        guard let path, let page = pages.first(where: { $0.path == path }) else { return nil }
        return displayTitle(page, projectName: projectName)
    }

    static func groups(for pages: [WikiPage], scope: WikiScope, projectName: String? = nil) -> [Group] {
        let isProject: Bool = { if case .project = scope { return true }; return false }()
        var visible = pages
        if isProject {
            visible = pages.filter { groupKey($0.path) != "general" || !autoPages.contains(baseName($0.path)) }
        }
        let grouped = Dictionary(grouping: visible) { page -> String in
            let key = groupKey(page.path)
            return isProject && key == "general" && baseName(page.path) == "overview" ? "pinned" : key
        }
        let keys = grouped.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count - 1, ib = order.firstIndex(of: b) ?? order.count - 1
            return ia == ib ? a < b : ia < ib
        }
        return keys.map { key in
            let items = (grouped[key] ?? []).map { Item(page: $0, title: displayTitle($0, projectName: isProject ? projectName : nil)) }
            let sorted = items.sorted { a, b in
                if key == "general" {
                    let ia = generalOrder.firstIndex(of: baseName(a.page.path)) ?? 2
                    let ib = generalOrder.firstIndex(of: baseName(b.page.path)) ?? 2
                    if ia != ib { return ia < ib }
                }
                // Dated pages (meetings, questions, sources) newest first; everything else alphabetical.
                if key == "meetings" || key == "questions" || key == "sources" { return a.page.path > b.page.path }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            return Group(key: key, title: key == "pinned" ? "" : title(for: key), pages: sorted)
        }
    }

    static func title(for key: String) -> String {
        switch key {
        case "general": L("wikiGroup.general")
        case "meetings": L("wikiGroup.meetings")
        case "emails": L("wikiGroup.emails")
        case "sources": L("wikiGroup.sources")
        case "topics": L("wikiGroup.topics")
        case "decisions": L("wikiGroup.decisions")
        case "people": L("wikiGroup.people")
        case "questions": L("wikiGroup.questions")
        case "repos": L("wikiGroup.repos")   // MARK: v0.4 github
        default: key.capitalized
        }
    }

    static func symbol(for path: String) -> String {
        switch groupKey(path) {
        case "meetings": return "waveform"
        case "emails": return "envelope"
        case "sources": return "doc.text"
        case "topics": return "lightbulb"
        case "decisions": return "checkmark.seal"
        case "people": return "person"
        case "questions": return "questionmark.bubble"
        case "repos": return "chevron.left.forwardslash.chevron.right"   // MARK: v0.4 github
        default:
            switch baseName(path) {
            case "overview": return "sparkles"
            case "index": return "list.bullet"
            case "tasks": return "checklist"
            case "timeline": return "calendar"
            case "log": return "clock"
            case "health": return "stethoscope"
            default: return "doc"
            }
        }
    }

    static func defaultPage(in pages: [WikiPage]) -> WikiPage? {
        pages.first { baseName($0.path) == "overview" } ?? pages.first { baseName($0.path) == "index" } ?? pages.first
    }

    /// A readable name from a file path when no title is known: "2026-10-26-0900-comite-de-la-alianza.md" →
    /// "Comite de la alianza".
    static func humanize(_ path: String) -> String {
        var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let match = name.firstMatch(of: #/^\d{4}-\d{2}-\d{2}(-\d{4})?-/#) { name = String(name[match.range.upperBound...]) }
        let words = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Logs and lint reports are not in the graph (CONTRACT §12.2); a project's index stands for the project.
    static func isInGraph(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.hasSuffix(".md") && !path.contains("/raw/") && !path.hasPrefix("_inbox/")
            && name != "log.md" && name != "health.md" && !path.hasSuffix("people/README.md")
    }

    /// `projects/<p>/wiki/emails/<thread>.md` → the thread key.
    static func threadKey(of path: String) -> String? {
        guard path.contains("/wiki/emails/"), path.hasSuffix(".md") else { return nil }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

extension WikiBrowser {
    /// Kept for callers of the v0.4 API.
    static func isInGraph(_ path: String) -> Bool { WikiGrouping.isInGraph(path) }
    static func threadKey(of path: String) -> String? { WikiGrouping.threadKey(of: path) }
}
