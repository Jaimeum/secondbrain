import AppKit
import BrainCore
import SwiftUI

enum WikiScope: Equatable {
    case project(String)
    case global
    case people
}

/// Page list on the left, rendered page on the right.
struct WikiBrowser: View {
    @Environment(AppState.self) private var state
    let scope: WikiScope
    @Binding var selection: String?

    @ViewState private var pages: [WikiPage] = []
    @ViewState private var history: [String] = []
    @ViewState private var export: ExportRequest?
    @ViewState private var threadKey: String?

    var body: some View {
        HStack(spacing: 0) {
            pageList
                .frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                if pages.isEmpty && selection == nil {
                    emptyState
                } else {
                    pageHeader
                    Divider()
                    WikiWebView(vault: state.engine.vault, path: selection) { path in
                        if let current = selection { history.append(current) }
                        selection = path
                    }
                }
            }
        }
        .task(id: state.vaultRevision) { await reload() }
        .sheet(item: $export) { ExportSheet(request: $0) }
        .sheet(item: Binding(get: { threadKey.map(ThreadKeyItem.init) }, set: { threadKey = $0?.key })) { item in
            ThreadSheet(threadKey: item.key) { path in
                if let current = selection { history.append(current) }
                selection = path
            }
        }
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

    private var pageList: some View {
        List(selection: $selection) {
            ForEach(WikiGrouping.groups(for: pages, scope: scope), id: \.key) { group in
                Section(group.title) {
                    ForEach(group.pages) { page in
                        Label(page.title, systemImage: WikiGrouping.symbol(for: page.path))
                            .lineLimit(1)
                            .tag(page.path as String?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var pageHeader: some View {
        HStack(spacing: 10) {
            Button {
                if let previous = history.popLast() { selection = previous }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(history.isEmpty)
            .help(L("wiki.back"))

            Text(pages.first { $0.path == selection }?.title ?? selection.map { ($0 as NSString).lastPathComponent } ?? "")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if let selection {
                if let key = Self.threadKey(of: selection) {
                    Button {
                        threadKey = key
                    } label: {
                        Label(L("thread.viewEmails"), systemImage: "envelope")
                    }
                    .buttonStyle(.borderless)
                }
                if Self.isInGraph(selection) {
                    Button {
                        showInGraph(selection)
                    } label: {
                        Label(L("graph.seeInGraph"), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(.borderless)
                    .help(L("graph.seeInGraph"))
                }
                Button {
                    export = ExportRequest(target: .page(path: selection, title: currentTitle))
                } label: {
                    Label(L("export.buttonEllipsis"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([state.engine.vault.url(for: selection)])
                } label: {
                    Label(L("wiki.showInFinder"), systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// "Ver en el grafo": the Grafo tab of the page's project (people and global pages: "Todo el cerebro"), centered on it.
    private func showInGraph(_ path: String) {
        state.pendingGraphFocus = path
        let parts = path.split(separator: "/")
        state.selection = parts.count > 2 && parts[0] == "projects" ? .project(String(parts[1])) : .brain
    }

    /// Logs and lint reports are not in the graph (CONTRACT §12.2); a project's index stands for the project.
    static func isInGraph(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.hasSuffix(".md") && !path.contains("/raw/") && !path.hasPrefix("_inbox/")
            && name != "log.md" && name != "health.md" && !path.hasSuffix("people/README.md")
    }

    private var currentTitle: String {
        pages.first { $0.path == selection }?.title
            ?? selection.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? ""
    }

    /// `projects/<p>/wiki/emails/<thread>.md` → the thread key.
    static func threadKey(of path: String) -> String? {
        guard path.contains("/wiki/emails/"), path.hasSuffix(".md") else { return nil }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Lists the pages off the main thread (it walks the vault folder) and applies the result only if the
    /// vault is still the same one.
    private func reload() async {
        guard state.engineStarted else { return }
        let vault = state.engine.vault
        var all: [WikiPage]
        switch scope {
        case .project(let slug): all = await vault.pagesAsync(projectSlug: slug)
        case .global: all = await vault.pagesAsync(projectSlug: nil)
        case .people:
            all = await vault.pagesAsync(projectSlug: nil)
            all = all.filter { $0.path.hasPrefix("people/") && !$0.path.hasSuffix("README.md") }
        }
        guard !Task.isCancelled, vault === state.engine.vault else { return }
        if all != pages { pages = all }
        if selection == nil {
            selection = WikiGrouping.defaultPage(in: all)?.path
        }
    }
}

enum WikiGrouping {
    struct Group { let key: String; let title: String; let pages: [WikiPage] }

    private static let order = ["general", "meetings", "emails", "sources", "topics", "decisions", "people", "questions"]
    private static let generalOrder = ["overview", "index", "tasks", "timeline", "health", "log"]

    static func groupKey(_ path: String) -> String {
        var rel = path
        if rel.hasPrefix("projects/"), let range = rel.range(of: "/wiki/") { rel = String(rel[range.upperBound...]) }
        let parts = rel.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : "general"
    }

    private static func baseName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
    }

    static func groups(for pages: [WikiPage], scope: WikiScope) -> [Group] {
        let grouped = Dictionary(grouping: pages, by: { groupKey($0.path) })
        let keys = grouped.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count, ib = order.firstIndex(of: b) ?? order.count
            return ia == ib ? a < b : ia < ib
        }
        return keys.map { key in
            let sorted = (grouped[key] ?? []).sorted { a, b in
                if key == "general" {
                    let ia = generalOrder.firstIndex(of: baseName(a.path)) ?? 2
                    let ib = generalOrder.firstIndex(of: baseName(b.path)) ?? 2
                    if ia != ib { return ia < ib }
                }
                // Dated pages (meetings, questions) newest first; everything else alphabetical.
                if key == "meetings" || key == "questions" || key == "sources" { return a.path > b.path }
                if key == "emails" { return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            return Group(key: key, title: title(for: key), pages: sorted)
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
}

private struct ThreadKeyItem: Identifiable {
    let key: String
    var id: String { key }
}
