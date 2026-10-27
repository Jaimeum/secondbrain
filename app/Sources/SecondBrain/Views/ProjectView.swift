import BrainCore
import SwiftUI

enum ProjectTab: Hashable {
    case wiki, graph, sources, tasks, timeline, ask, activity

    var title: String {
        switch self {
        case .wiki: L("tab.wiki")
        case .graph: L("tab.graph")
        case .sources: L("tab.sources")
        case .tasks: L("tab.tasks")
        case .timeline: L("tab.timeline")
        case .ask: L("tab.ask")
        case .activity: L("tab.activity")
        }
    }

    var symbol: String {
        switch self {
        case .wiki: "book"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .sources: "tray.full"
        case .tasks: "checklist"
        case .timeline: "calendar.day.timeline.left"
        case .ask: "bubble.left.and.text.bubble.right"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

struct ProjectView: View {
    @Environment(AppState.self) private var state
    let project: Project

    @ViewState private var tab: ProjectTab = .wiki
    @ViewState private var wikiPage: String?
    @ViewState private var graphFocus: String?
    @ViewState private var chat = ChatModel()
    @ViewState private var error: String?

    var body: some View {
        content
            .tabBar(TabPicker(tabs: [.wiki, .graph, .sources, .tasks, .timeline, .ask, .activity], selection: $tab))
            .navigationTitle("\(project.emoji) \(project.name)")
            .navigationSubtitle(project.description)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { projectMenu }
            }
            .onAppear(perform: consumePendingPage)
            .onChange(of: state.pendingPage) { consumePendingPage() }
            .onAppear(perform: consumePendingGraphFocus)
            .onChange(of: state.pendingGraphFocus) { consumePendingGraphFocus() }
            .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L("common.ok")) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    private var projectMenu: some View {
        Menu {
            Button {
                state.requestEmail(projectSlug: project.slug)
            } label: {
                Label(L("email.add"), systemImage: "envelope.badge")
            }
            Menu(L("tpl.projectDefault")) {
                Button {
                    setDefault(nil)
                } label: {
                    if project.defaultTemplate == nil { Label(L("tpl.standard"), systemImage: "checkmark") } else { Text(L("tpl.standard")) }
                }
                Divider()
                ForEach(state.templates(for: .meeting).filter { $0.id != TemplateInfo.standardId }) { t in
                    Button {
                        setDefault(t.id)
                    } label: {
                        if project.defaultTemplate == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
            }
        } label: {
            Label(L("project.more"), systemImage: "ellipsis.circle")
        }
        .help(L("project.more"))
    }

    private func setDefault(_ id: String?) {
        do {
            try state.engine.setDefaultTemplate(projectSlug: project.slug, templateId: id)
            state.reloadProjects()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    private func consumePendingPage() {
        guard let page = state.pendingPage else { return }
        state.pendingPage = nil
        openPage(page)
    }

    /// "Ver en el grafo" from a page of this project: open the Grafo tab centered on it.
    private func consumePendingGraphFocus() {
        guard let page = state.pendingGraphFocus, page.hasPrefix("projects/\(project.slug)/") else { return }
        state.pendingGraphFocus = nil
        graphFocus = page
        tab = .graph
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .wiki:
            WikiBrowser(scope: .project(project.slug), selection: $wikiPage)
        case .graph:
            GraphView(scope: .project(project.slug), focus: graphFocus, onOpen: openPage)
        case .sources:
            SourcesView(projectSlug: project.slug, onOpen: openPage)
        case .tasks:
            ProjectTasksView(project: project, onOpen: openPage)
        case .timeline:
            BrainTimelineView(projectSlug: project.slug) { path, _ in openPage(path) }
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
    @Environment(AppState.self) private var state
    @ViewState private var tab: ProjectTab = .wiki
    @ViewState private var wikiPage: String?
    @ViewState private var graphFocus: String?
    @ViewState private var chat = ChatModel()

    var body: some View {
        Group {
            switch tab {
            case .wiki: WikiBrowser(scope: .global, selection: $wikiPage)
            case .graph: GraphView(scope: .global, focus: graphFocus, onOpen: openAnywhere)
            case .ask: ChatView(model: chat, projectSlug: nil, onOpenPage: openPage)
            case .activity: ActivityView(projectSlug: nil, onOpenPage: openPage)
            case .timeline:
                BrainTimelineView(projectSlug: nil) { path, project in
                    if let project {
                        state.pendingPage = path
                        state.selection = .project(project)
                    } else {
                        openPage(path)
                    }
                }
            case .sources, .tasks: EmptyView()
            }
        }
        .tabBar(TabPicker(tabs: [.wiki, .graph, .timeline, .ask, .activity], selection: $tab))
        .navigationTitle(L("sidebar.brain"))
        .navigationSubtitle(L("brain.subtitle"))
        .onAppear(perform: consumePendingGraphFocus)
        .onChange(of: state.pendingGraphFocus) { consumePendingGraphFocus() }
    }

    private func openPage(_ path: String) {
        wikiPage = path
        tab = .wiki
    }

    /// A page of a project opens inside that project; global pages and people open here.
    private func openAnywhere(_ path: String) {
        let parts = path.split(separator: "/")
        if parts.count > 2, parts[0] == "projects" {
            state.pendingPage = path
            state.selection = .project(String(parts[1]))
        } else {
            openPage(path)
        }
    }

    /// "Ver en el grafo" from a global or people page.
    private func consumePendingGraphFocus() {
        guard let page = state.pendingGraphFocus, !page.hasPrefix("projects/") else { return }
        state.pendingGraphFocus = nil
        graphFocus = page
        tab = .graph
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

extension View {
    /// The section switcher ("Wiki · Grafo · Fuentes · Pendientes · …") in a slim bar above the content:
    /// seven tabs don't fit in the toolbar next to the title at the default window width.
    func tabBar(_ picker: TabPicker) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                picker.padding(.vertical, 8).frame(maxWidth: .infinity)
                Divider()
            }
            .background(.bar)
        }
    }
}
