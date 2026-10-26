import BrainCore
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var state
    @ViewState private var showNewProject = false

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView(showNewProject: $showNewProject)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet { project in state.selection = .project(project.slug) }
        }
        .sheet(item: $state.emailRequest) { request in
            AddEmailSheet(request: request)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.isSwitchingVault {
                VaultSwitchingNotice()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.1))
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
                EmptyStateView(symbol: "folder", title: L("project.missing"), message: "",
                               actionTitle: L("sidebar.brain")) { state.selection = .brain }
            }
        case .inbox:
            InboxView()
        case .mail:
            MailView()
        case .meetings:
            MeetingsView()
        case .people:
            PeopleView()
        case .myTasks:
            MyTasksView()
        case .templates:
            TemplatesView()
        case .brain, nil:
            BrainView()
        }
    }
}

struct RestartBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            Text(L("restart.message"))
            Spacer()
            Button(L("restart.now")) { state.relaunch() }
                .buttonStyle(.borderedProminent)
                .disabled(state.isRecording)
                .help(state.isRecording ? L("restart.whileRecording") : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
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
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(L("migration.title")).font(.callout.weight(.medium))
                Spacer()
                Button(expanded ? L("migration.less") : L("migration.more")) { expanded.toggle() }
                    .buttonStyle(.borderless)
                Button(L("migration.dismiss")) { state.dismissMigrationNotice() }
            }
            if expanded {
                Text(L("migration.explain")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }
}

/// Shown while the engine finishes its current job before moving to the newly chosen vault.
struct VaultSwitchingNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("vault.switching")).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Menus (Edit, View, Window…) keep the launch language until SecondBrain restarts.
struct MenuLanguageNotice: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").foregroundStyle(.secondary)
            Text(L("restart.menuLanguage")).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("restart.now")) { state.relaunch() }
                .disabled(state.isRecording)
                .help(state.isRecording ? L("restart.whileRecording") : "")
        }
    }
}

/// Calm, centered placeholder used across empty lists and errors.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            if !message.isEmpty {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
