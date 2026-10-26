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
        .task(id: state.vaultRevision) { reload() }
        .task {
            // Claude edits pages in the background; keep the list fresh without user action.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                reload()
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
            ForEach(WikiGrouping.groups(for: pages, scope: scope), id: \.title) { group in
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

    private func reload() {
        guard state.engineStarted else { return }
        let vault = state.engine.vault
        let all: [WikiPage]
        switch scope {
        case .project(let slug): all = vault.pages(projectSlug: slug)
        case .global: all = vault.pages(projectSlug: nil)
        case .people: all = vault.pages(projectSlug: nil).filter { $0.path.hasPrefix("people/") && !$0.path.hasSuffix("README.md") }
        }
        if all != pages { pages = all }
        if selection == nil {
            selection = WikiGrouping.defaultPage(in: all)?.path
        }
    }
}

enum WikiGrouping {
    struct Group { let title: String; let pages: [WikiPage] }

    private static let order = ["general", "meetings", "sources", "topics", "decisions", "people", "questions"]
    private static let generalOrder = ["overview", "index", "tasks", "health", "log"]

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
            let sorted = grouped[key]!.sorted { a, b in
                if key == "general" {
                    let ia = generalOrder.firstIndex(of: baseName(a.path)) ?? 2
                    let ib = generalOrder.firstIndex(of: baseName(b.path)) ?? 2
                    if ia != ib { return ia < ib }
                }
                // Dated pages (meetings, questions) newest first; everything else alphabetical.
                if key == "meetings" || key == "questions" || key == "sources" { return a.path > b.path }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            return Group(title: title(for: key), pages: sorted)
        }
    }

    static func title(for key: String) -> String {
        switch key {
        case "general": L("wikiGroup.general")
        case "meetings": L("wikiGroup.meetings")
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
