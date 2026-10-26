import BrainCore
import SwiftUI

enum ProjectTab: Hashable {
    case wiki, sources, ask, activity

    var title: String {
        switch self {
        case .wiki: L("tab.wiki")
        case .sources: L("tab.sources")
        case .ask: L("tab.ask")
        case .activity: L("tab.activity")
        }
    }
}

struct ProjectView: View {
    @Environment(AppState.self) private var state
    let project: Project

    @ViewState private var tab: ProjectTab = .wiki
    @ViewState private var wikiPage: String?
    @ViewState private var chat = ChatModel()

    var body: some View {
        content
            .navigationTitle("\(project.emoji) \(project.name)")
            .navigationSubtitle(project.description)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TabPicker(tabs: [.wiki, .sources, .ask, .activity], selection: $tab)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .wiki:
            WikiBrowser(scope: .project(project.slug), selection: $wikiPage)
        case .sources:
            SourcesView(projectSlug: project.slug, onOpen: openPage)
        case .ask:
            ChatView(model: chat, projectSlug: project.slug, onOpenPage: openPage)
        case .activity:
            ActivityView(projectSlug: project.slug, onOpenPage: openPage)
        }
    }

    private func openPage(_ path: String) {
        wikiPage = path
        tab = .wiki
    }
}

/// "Todo el cerebro": global pages, questions across every project, all activity.
struct BrainView: View {
    @ViewState private var tab: ProjectTab = .wiki
    @ViewState private var wikiPage: String?
    @ViewState private var chat = ChatModel()

    var body: some View {
        Group {
            switch tab {
            case .wiki: WikiBrowser(scope: .global, selection: $wikiPage)
            case .ask: ChatView(model: chat, projectSlug: nil, onOpenPage: openPage)
            case .activity: ActivityView(projectSlug: nil, onOpenPage: openPage)
            case .sources: EmptyView()
            }
        }
        .navigationTitle(L("sidebar.brain"))
        .navigationSubtitle(L("brain.subtitle"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                TabPicker(tabs: [.wiki, .ask, .activity], selection: $tab)
            }
        }
    }

    private func openPage(_ path: String) {
        wikiPage = path
        tab = .wiki
    }
}

struct PeopleView: View {
    @ViewState private var page: String?

    var body: some View {
        WikiBrowser(scope: .people, selection: $page)
            .navigationTitle(L("sidebar.people"))
            .navigationSubtitle(L("people.subtitle"))
    }
}

struct TabPicker: View {
    let tabs: [ProjectTab]
    @Binding var selection: ProjectTab

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(tabs, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
