import AppKit
import BrainCore
import SwiftUI

/// A project's sections (CONTRACT §15.2): Contenido · Pendientes · Preguntar · Grafo.
enum ProjectTab: Hashable {
    case content, tasks, ask, graph

    var title: String {
        switch self {
        case .content: L("tabs.content")
        case .tasks: L("tab.tasks")
        case .ask: L("tab.ask")
        case .graph: L("tab.graph")
        }
    }

    var symbol: String {
        switch self {
        case .content: "doc.text"
        case .tasks: "checklist"
        case .ask: "bubble.left.and.text.bubble.right"
        case .graph: "point.3.connected.trianglepath.dotted"
        }
    }
}

struct ProjectView: View {
    @Environment(AppState.self) private var state
    let project: Project

    @ViewState private var tab: ProjectTab
    @ViewState private var page: String?
    @ViewState private var graphFocus: String?
    @ViewState private var chat = ChatModel()
    @ViewState private var sheet: ProjectSheet?
    @ViewState private var lintQueued = false
    @ViewState private var error: String?

    init(project: Project, initialTab: ProjectTab = .content) {
        self.project = project
        _tab = ViewState(initialValue: initialTab)
    }

    var body: some View {
        content
            .tabBar(TabPicker(tabs: [.content, .tasks, .ask, .graph], selection: $tab))
            .navigationTitle("\(project.emoji) \(project.name)")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    addMenu
                    Button { sheet = .history } label: {
                        Label(L("project.history"), systemImage: "clock.arrow.circlepath")
                            .labelStyle(.titleAndIcon)
                    }
                    .help(L("project.historyHelp"))
                    moreMenu
                }
            }
            .sheet(item: $sheet) { sheetView($0) }
            .onAppear(perform: consumePending)
            .onChange(of: state.pendingPage) { consumePending() }
            .onChange(of: state.pendingGraphFocus) { consumePending() }
            .onChange(of: state.pendingProjectTab) { consumePending() }
            .onChange(of: state.pendingQuestion) { consumePending() }
            .onChange(of: state.historyRevision) { lintQueued = false }   // the review finished (or anything else did)
            .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L("common.ok")) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .content:
            ProjectContentView(project: project, selection: $page)
        case .tasks:
            ProjectTasksView(project: project, onOpen: openPage)
        case .ask:
            ChatView(model: chat, projectSlug: project.slug, onOpenPage: openPage)
        case .graph:
            GraphView(scope: .project(project.slug), focus: graphFocus, onOpen: openPage)
        }
    }

    // MARK: Toolbar

    /// "+ Agregar": every way to add something to this project.
    private var addMenu: some View {
        Menu {
            Button {
                state.recordingProjectSlug = project.slug
                state.toggleRecording()
            } label: {
                Label(L("project.addRecordHere"), systemImage: "record.circle")
            }
            .disabled(state.isRecording)
            Button { state.requestEmail(projectSlug: project.slug) } label: {
                Label(L("search.action.pasteMail"), systemImage: "envelope")
            }
            Button { sheet = .note } label: { Label(L("sources.newNote"), systemImage: "square.and.pencil") }
            Divider()
            Button(action: addFiles) {
                Label(L("project.addFiles"), systemImage: "doc.badge.plus")
            }
            Button { sheet = .link } label: { Label(L("project.pasteLink"), systemImage: "link") }
        } label: {
            Label(L("project.add"), systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
        .help(L("project.addHelp"))
    }

    /// ⋯: settings of the project that are used rarely.
    private var moreMenu: some View {
        Menu {
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
            Button { sheet = .repos } label: { Label(L("project.repos"), systemImage: "chevron.left.forwardslash.chevron.right") }
            Button {
                state.engine.lint(projectSlug: project.slug)
                lintQueued = true
            } label: {
                Label(lintQueued ? L("chat.lintQueued") : L("chat.lint"), systemImage: "stethoscope")
            }
            .disabled(lintQueued)
            .help(L("chat.lintHelp"))
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([state.engine.vault.url(for: "projects/\(project.slug)")])
            } label: {
                Label(L("wiki.showInFinder"), systemImage: "folder")
            }
        } label: {
            Label(L("project.more"), systemImage: "ellipsis.circle")
        }
        .help(L("project.more"))
    }

    @ViewBuilder private func sheetView(_ sheet: ProjectSheet) -> some View {
        switch sheet {
        case .note: NoteSheet(projectSlug: project.slug)
        case .link: PasteLinkSheet(projectSlug: project.slug)
        case .files(let batch): ImportFilesSheet(urls: batch.urls, projectSlug: project.slug)
        case .history:
            ActivitySheet(projectSlug: project.slug) { path in
                self.sheet = nil
                openPage(path)
            }
        case .repos: ReposSheet(projectSlug: project.slug)
        }
    }

    /// Files import right away with their own dates (like a drop); the sheet only shows up when there is a real
    /// choice to make: a recording and more than one format.
    private func addFiles() {
        guard let batch = SourceImport.chooseFiles() else { return }
        let hasMedia = batch.urls.contains { AudioPrep.isMedia($0) }
        if hasMedia, state.templates(for: .meeting).count > 1 {
            sheet = .files(batch)
            return
        }
        let slug = project.slug
        Task {
            let failed = await SourceImport.importURLs(batch.urls, projectSlug: slug, state: state)
            if !failed.isEmpty { error = failed.joined(separator: "\n") }
        }
    }

    private func setDefault(_ id: String?) {
        do {
            try state.engine.setDefaultTemplate(projectSlug: project.slug, templateId: id)
            state.reloadProjects()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    // MARK: Navigation

    /// Requests from elsewhere (Inicio, ⌘K, Pendientes, "Ver en el grafo"): a page, a tab, a question.
    private func consumePending() {
        if let path = state.pendingPage {
            state.pendingPage = nil
            openPage(path)
        }
        if let focus = state.pendingGraphFocus, focus.hasPrefix("projects/\(project.slug)/") {
            state.pendingGraphFocus = nil
            graphFocus = focus
            tab = .graph
        }
        if let requested = state.pendingProjectTab {
            state.pendingProjectTab = nil
            tab = requested
        }
        // ChatView sends the question when it appears (and clears it).
        if state.pendingQuestion != nil { tab = .ask }
    }

    private func openPage(_ path: String) {
        page = path
        tab = .content
    }
}

private enum ProjectSheet: Identifiable {
    case note, link, files(ImportBatch), history, repos

    var id: String {
        switch self {
        case .note: "note"
        case .link: "link"
        case .files(let batch): "files-\(batch.id)"
        case .history: "history"
        case .repos: "repos"
        }
    }
}

/// "Repositorios…" (§13.6 inside a sheet): the followed repositories and their add/edit flow.
private struct ReposSheet: View {
    @Environment(\.dismiss) private var dismiss
    let projectSlug: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("project.reposTitle"))
                    .font(Brand.title)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                Spacer()
                Button(L("common.close")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Brand.spacing.content)
            .padding(.vertical, Brand.spacing.l)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            ReposView(projectSlug: projectSlug)
        }
        .frame(minWidth: 600, idealWidth: 720, minHeight: 420, idealHeight: 520)
        .background(Brand.color.surface)
    }
}

/// Deprecated in v0.5 (`SidebarItem.brain` maps to Inicio): the whole brain's pages, questions and graph.
struct BrainView: View {
    @Environment(AppState.self) private var state
    @ViewState private var tab: ProjectTab = .content
    @ViewState private var wikiPage: String?
    @ViewState private var graphFocus: String?
    @ViewState private var chat = ChatModel()

    var body: some View {
        Group {
            switch tab {
            case .content, .tasks: WikiBrowser(scope: .global, selection: $wikiPage)
            case .graph: GraphView(scope: .global, focus: graphFocus, onOpen: openAnywhere)
            case .ask: ChatView(model: chat, projectSlug: nil, onOpenPage: openAnywhere)
            }
        }
        .tabBar(TabPicker(tabs: [.content, .ask, .graph], selection: $tab))
        .navigationTitle(L("sidebar.brain"))
        .onAppear(perform: consumePendingGraphFocus)
        .onChange(of: state.pendingGraphFocus) { consumePendingGraphFocus() }
    }

    /// A page of a project opens inside that project; global pages and people open here.
    private func openAnywhere(_ path: String) {
        let parts = path.split(separator: "/")
        if parts.count > 2, parts[0] == "projects" {
            state.pendingPage = path
            state.selection = .project(String(parts[1]))
        } else {
            wikiPage = path
            tab = .content
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
    }
}

/// The section switcher: segmented while it fits, a pop-up menu when it doesn't (never wider than its bar).
struct TabPicker: View {
    let tabs: [ProjectTab]
    @Binding var selection: ProjectTab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker("", selection: $selection) {
                ForEach(tabs, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("", selection: $selection) {
                ForEach(tabs, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 220)
        }
    }
}

extension View {
    /// The section switcher in a slim bar above the content (centered, at most 480 pt, 16 pt from the edges).
    func tabBar(_ picker: TabPicker) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                picker
                    .frame(maxWidth: 480)
                    .padding(.horizontal, Brand.spacing.l)
                    .padding(.vertical, Brand.spacing.s)
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Brand.color.line).frame(height: 1)
            }
            .background(Brand.color.surface)
        }
    }
}
