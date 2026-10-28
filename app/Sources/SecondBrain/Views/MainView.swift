import BrainCore
import SwiftUI

/// The main window (CONTRACT §15.2, §16.1): sidebar (200/220/280) + detail, the banners on top, and the ⌘K palette
/// over it. Sheets that any screen can ask for through AppState (editor, Historial, nota, enlace, correo) live here.
struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var state = state
        ZStack {
            NavigationSplitView {
                SidebarView(showNewProject: $state.showNewProject)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            } detail: {
                detail
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .background(Brand.color.surface)
            }
            if state.searchPresented {
                SearchPalette()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(Brand.motion.animation(fast: true), value: state.searchPresented)
        .sheet(isPresented: $state.showNewProject) {
            NewProjectSheet { project in state.navigate(to: .sidebar(.project(project.slug))) }
        }
        .sheet(item: $state.emailRequest) { request in
            AddEmailSheet(request: request)
        }
        .sheet(item: $state.noteRequest) { request in
            NoteSheet(projectSlug: request.projectSlug)
        }
        .sheet(item: $state.linkRequest) { request in
            PasteLinkSheet(projectSlug: request.projectSlug)
        }
        .sheet(item: $state.historyRequest) { request in
            ActivitySheet(projectSlug: request.projectSlug) { path in
                state.historyRequest = nil
                state.navigate(to: .entity(path, Scope(projectSlug: request.projectSlug)))
            }
        }
        // §16.6: "Editar" from any page or ficha.
        .sheet(item: Binding(get: { state.editingPage.map(VaultPageItem.init(path:)) },
                             set: { state.editingPage = $0?.path })) { item in
            PageEditorHost(path: item.path)
        }
        .onAppear {
            SettingsLinkOpener.opener = { openSettings() }
        }
        // Keeps ⌘K's index fresh (debounced; the palette also refreshes when it opens).
        .task(id: "\(state.vaultRevision)-\(state.tasksRevision)-\(state.accountsRevision)-\(state.projects.count)-\(state.config.uiLanguage)") {
            SearchIndex.shared.refresh(state: state)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.isSwitchingVault {
                VaultSwitchingNotice()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.color.accentSoft)
            } else if state.restartNeeded {
                RestartBanner()
            } else if let notice = state.migrationNotice {
                MigrationBanner(notice: notice)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case .project(let slug):
            if let project = state.project(slug) {
                ProjectView(project: project).id(slug)
            } else {
                // Deleted on disk or not in this vault: offer a way out instead of a blank page.
                EmptyStateView(symbol: "folder", title: L("project.missing"), message: L("project.missing.message"),
                               actionTitle: L("project.missing.action")) { state.navigate(to: .sidebar(.home)) }
            }
        case .ask:
            AskView(scope: .brain).navigationTitle(L("sidebar.ask"))
        case .graph:
            GraphView(scope: .brain).navigationTitle(L("sidebar.graph"))
        case .tasks:
            TasksView(scope: .brain)
        case .people:
            PeopleView()
        case .mail:
            MailView()
        case .meetings:
            MeetingsView()
        case .unassigned:
            InboxView()
        case .home, nil:
            HomeView()
        }
    }
}

struct RestartBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle").foregroundStyle(Brand.color.warning)
            Text(L("restart.message"))
                .foregroundStyle(Brand.color.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("restart.now")) { state.relaunch() }
                .buttonStyle(.brandPrimary)
                .disabled(state.isRecording)
                .help(state.isRecording ? L("restart.whileRecording") : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Brand.color.warningSoft)
    }
}

/// After an update the vault got new things (formats, timeline…). If the user had edited the brain's rules
/// (CLAUDE.md), we kept theirs and left the new version beside it: explain it calmly.
struct MigrationBanner: View {
    @Environment(AppState.self) private var state
    let notice: String
    @ViewState private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                BrandMark(size: 16)
                Text(L("migration.title")).font(Brand.callout).foregroundStyle(Brand.color.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(expanded ? L("migration.less") : L("migration.more")) { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Brand.color.accent)
                Button(L("migration.dismiss")) { state.dismissMigrationNotice() }
                    .buttonStyle(.brandSecondary)
            }
            if expanded {
                Text(L("migration.explain")).font(Brand.body).foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notice).font(Brand.caption).foregroundStyle(Brand.color.text2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Brand.color.accentSoft)
    }
}

/// Shown while the engine finishes its current job before moving to the newly chosen vault.
struct VaultSwitchingNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            BrandLoader(size: 16)
            Text(L("vault.switching")).font(Brand.callout).foregroundStyle(Brand.color.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Menus (Edit, View, Window…) keep the launch language until SecondBrain restarts.
struct MenuLanguageNotice: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").foregroundStyle(Brand.color.text2)
            Text(L("restart.menuLanguage")).font(Brand.body).foregroundStyle(Brand.color.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("restart.now")) { state.relaunch() }
                .buttonStyle(.brandSecondary)
                .disabled(state.isRecording)
                .help(state.isRecording ? L("restart.whileRecording") : "")
        }
    }
}

/// Calm, centered placeholder used across empty lists and errors. `symbol: "brand"` shows the brand mark instead
/// of an SF Symbol (Home and other brand-level empty states).
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            if symbol == "brand" {
                BrandMark(size: 40).opacity(0.6)
            } else {
                Image(systemName: symbol)
                    .font(Brand.font(36))
                    .foregroundStyle(Brand.color.text3)
            }
            Text(title)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty {
                Text(message)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.brandPrimary).padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
