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
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.restartNeeded { RestartBanner() }
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case .project(let slug):
            if let project = state.project(slug) {
                ProjectView(project: project).id(slug)
            } else {
                EmptyStateView(symbol: "folder", title: L("project.missing"), message: "")
            }
        case .inbox:
            InboxView()
        case .people:
            PeopleView()
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
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
