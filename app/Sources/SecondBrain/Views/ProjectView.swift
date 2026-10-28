import AppKit
import BrainCore
import SwiftUI

/// A project's tabs (CONTRACT §16.2): Resumen · Contenido · Preguntar · Grafo · Pendientes · Personas.
enum ProjectTab: Hashable, CaseIterable {
    case summary, content, ask, graph, tasks, people

    var title: String {
        switch self {
        case .summary: L("project.tab.summary")
        case .content: L("tabs.content")
        case .ask: L("tab.ask")
        case .graph: L("tab.graph")
        case .tasks: L("tab.tasks")
        case .people: L("sidebar.people")
        }
    }

    var symbol: String {
        switch self {
        case .summary: "text.alignleft"
        case .content: "doc.text"
        case .ask: "bubble.left.and.text.bubble.right"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .tasks: "checklist"
        case .people: "person.2"
        }
    }
}

struct ProjectView: View {
    @Environment(AppState.self) private var state
    let project: Project

    @ViewState private var tab: ProjectTab
    @ViewState private var page: String?
    @ViewState private var graphFocus: String?
    @ViewState private var sheet: ProjectSheet?
    @ViewState private var error: String?
    /// Pages of somewhere else (a person, an org, another project) opened from inside this project: pushed as fichas
    /// filtered to this project over the current tab, with Atrás (§16.4). Empty = the tab shows.
    @ViewState private var fichas: [String] = []

    private var scope: Scope { .project(project.slug) }

    init(project: Project, initialTab: ProjectTab = .summary) {
        self.project = project
        _tab = ViewState(initialValue: initialTab)
    }

    var body: some View {
        content
            .tabBar(TabPicker(tabs: ProjectTab.allCases, selection: $tab))
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
            .onChange(of: tab) { old, _ in
                // "Ver en el grafo" centers the graph once; the next visit from the tab bar starts from the overview.
                if old == .graph { graphFocus = nil }
                fichas = []
            }
            .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L("common.ok")) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    /// Contenido stays alive under the other tabs (its list, scroll position and page survive a tab switch: no loader
    /// flash, no reload of the page); the other tabs are built when shown, over an opaque background.
    private var content: some View {
        ZStack {
            ProjectContentView(project: project, selection: $page, isActive: tab == .content)
                .opacity(tab == .content ? 1 : 0)
                .allowsHitTesting(tab == .content)
                .accessibilityHidden(tab != .content)
            if tab != .content {
                otherTab
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.color.surface)
                    .contentShape(Rectangle())
            }
            if !fichas.isEmpty {
                EntityStackView(stack: $fichas, scope: scope, onBackFromRoot: { fichas = [] }, onElsewhere: openPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.color.surface)
                    .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder private var otherTab: some View {
        switch tab {
        case .content:
            EmptyView()
        case .summary:
            ProjectSummaryView(project: project, onOpen: openPage)
        case .tasks:
            TasksView(scope: scope, onOpenPage: openPage)
        case .ask:
            AskView(scope: scope)
        case .graph:
            GraphView(scope: scope, focus: graphFocus, onOpen: openPage)
        case .people:
            ProjectPeopleView(project: project, onOpen: openPage)
        }
    }

    // MARK: Toolbar

    /// "+ Agregar" (§16.2): Nota · Archivo… · Enlace… · Pegar correo · Grabar aquí (recording last).
    private var addMenu: some View {
        Menu {
            Button { sheet = .note } label: { Label(L("add.note"), systemImage: "square.and.pencil") }
            Button(action: addFiles) { Label(L("add.file"), systemImage: "doc.badge.plus") }
            Button { sheet = .link } label: { Label(L("add.link"), systemImage: "link") }
            Button { state.requestEmail(projectSlug: project.slug) } label: {
                Label(L("add.email"), systemImage: "envelope")
            }
            Divider()
            Button {
                state.recordingProjectSlug = project.slug
                state.toggleRecording()
            } label: {
                Label(L("project.addRecordHere"), systemImage: "record.circle")
            }
            .disabled(state.isRecording)
        } label: {
            Label(L("project.add"), systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
        .help(L("project.addHelp"))
    }

    /// ⋯: settings of the project that are used rarely (§15.2: Formato por defecto ▸ · Repositorios… · Mostrar en
    /// Finder). "Revisar mi cerebro" lives in Historial, next to the changes it makes.
    private var moreMenu: some View {
        Menu {
            Menu(L("tpl.projectDefault")) {
                Button {
                    setDefault(nil)
                } label: {
                    if project.defaultTemplate == nil { Label(L("tpl.standard"), systemImage: "checkmark") } else { Text(L("tpl.standard")) }
                }
                // v0.6 (§16.2): the formats of every scope, under their scope's name.
                ForEach(TemplateScope.allCases, id: \.self) { scope in
                    let list = state.templates.filter { $0.scope == scope && $0.id != TemplateInfo.standardId }
                    if !list.isEmpty {
                        Section(scope.label) {
                            ForEach(list) { t in
                                Button {
                                    setDefault(t.id)
                                } label: {
                                    if project.defaultTemplate == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                                }
                            }
                        }
                    }
                }
            }
            Button { sheet = .repos } label: { Label(L("project.repos"), systemImage: "chevron.left.forwardslash.chevron.right") }
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

    /// Requests left by `AppState.navigate(to:)` for this project (it selected this project, so they are all ours):
    /// a page, a graph focus, a tab. Preguntar's `pendingChat` and Pendientes' `pendingTaskId` are consumed by
    /// AskView / TasksView once their tab shows.
    private func consumePending() {
        guard state.selection == .project(project.slug) else { return }
        // The tab first: the page decides last (the project's overview opens Resumen, a foreign page a ficha).
        // A requested tab is shown even when it is the current one: a ficha pushed over it would otherwise stay on
        // top (onChange(of: tab) doesn't fire) and hide the graph focus or the highlighted task.
        if let requested = state.pendingProjectTab {
            state.pendingProjectTab = nil
            fichas = []
            tab = requested
        }
        if let path = state.pendingPage {
            state.pendingPage = nil
            openPage(path)
        }
        if let focus = state.pendingGraphFocus {
            state.pendingGraphFocus = nil
            graphFocus = focus
            fichas = []
            tab = .graph
        }
    }

    /// One rule for every link inside the project (§16.4): this project's pages open in Contenido; anything else is
    /// shown as a ficha in this project's context.
    private func openPage(_ path: String) {
        if path == "projects/\(project.slug)/wiki/overview.md" {
            // The project's own ficha is its Resumen (§16.2).
            fichas = []
            tab = .summary
        } else if Scope.projectSlug(ofPath: path) == project.slug {
            fichas = []
            page = path
            tab = .content
        } else if fichas.last != path {
            fichas.append(path)
        }
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

/// The section switcher: the brand segmented control (the same as Por fecha | Por tema under it) while it fits, a
/// pop-up menu when it doesn't (never wider than its bar). No `fixedSize` (§15.2): ViewThatFits measures the
/// control's ideal width (equal 104 pt minimum segments, so labels never shift), then the chosen one fills the bar.
struct TabPicker: View {
    let tabs: [ProjectTab]
    @Binding var selection: ProjectTab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            BrandSegmentedControl(options: tabs.map { ($0, $0.title) }, selection: $selection,
                                  minSegmentWidth: 92, height: 26)
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
    /// The section switcher in a slim bar above the content (centered, at most 600 pt, 16 pt from the edges).
    func tabBar(_ picker: TabPicker) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                picker
                    .frame(maxWidth: 600)
                    .padding(.horizontal, Brand.spacing.l)
                    .padding(.vertical, Brand.spacing.s)
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Brand.color.line).frame(height: 1)
            }
            .background(Brand.color.surface)
        }
    }
}
