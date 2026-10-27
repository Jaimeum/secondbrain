import AppKit
import BrainCore
import SwiftUI

/// "Código" (`tab.code`, CONTRACT §13.6): the GitHub repositories this project follows, one card per repo with a chip
/// per followed branch (✓ synced · ⚠ rewritten · ✕ gone · ⟳ syncing), how the other branches compare to the primary
/// one, and how often it all refreshes.
struct ReposView: View {
    @Environment(AppState.self) private var state
    let projectSlug: String

    @ViewState private var sheet: RepoSheetRequest?
    @ViewState private var showConnect = false
    @ViewState private var pendingRemove: TrackedRepo?
    @ViewState private var showOrgHelp = false
    @ViewState private var error: String?
    @ViewState private var ghAvailable = false

    private var github: GitHubStore { state.engine.github }
    private var model: GitHubModel { GitHubModel.shared }
    private var repos: [TrackedRepo] {
        github.repos(project: projectSlug).sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    var body: some View {
        Group {
            if repos.isEmpty {
                if github.isConnected {
                    EmptyStateView(symbol: "chevron.left.forwardslash.chevron.right", title: L("repos.empty.title"),
                                   message: L("repos.empty.message"), actionTitle: L("repos.add")) {
                        sheet = RepoSheetRequest(mode: .add)
                    }
                } else {
                    EmptyStateView(symbol: "chevron.left.forwardslash.chevron.right", title: L("repos.connect.title"),
                                   message: L("repos.connect.message"), actionTitle: connectTitle) {
                        showConnect = true
                    }
                }
            } else {
                list
            }
        }
        .sheet(item: $sheet) { request in
            AddRepoSheet(projectSlug: projectSlug, editing: request.repo)
        }
        .sheet(isPresented: $showConnect) { GitHubConnectSheet(method: connectMethod) }
        .task {
            if github.isDemo { return }
            ghAvailable = await Task.detached(priority: .utility) { GitHubAuth.locateGH() != nil }.value
        }
        .sheet(isPresented: $showOrgHelp) { GitHubOrgHelpSheet() }
        .confirmationDialog(L("repos.remove.confirm", pendingRemove?.fullName ?? ""),
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })) {
            Button(L("repos.remove"), role: .destructive) {
                if let repo = pendingRemove {
                    do { try github.remove(repoId: repo.id) } catch { self.error = FriendlyError.message(error) }
                }
                pendingRemove = nil
            }
        } message: {
            Text(L("repos.remove.message"))
        }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    if !github.isConnected { disconnectedBanner }
                    if let notice = model.notice { noticeBanner(notice) }
                    ForEach(repos) { repo in
                        RepoCard(repo: repo, syncing: github.syncing.contains(repo.id),
                                 onSync: { model.syncNow(state: state, repoId: repo.id) },
                                 onEditBranches: { sheet = RepoSheetRequest(mode: .edit, repo: repo) },
                                 onToggleCode: { toggleCode(repo) },
                                 onRemove: { pendingRemove = repo },
                                 onOrgHelp: { showOrgHelp = true })
                    }
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(repos.count == 1 ? L("repos.count.one") : L("repos.count.many", repos.count))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.syncNow(state: state, project: projectSlug)
            } label: {
                Label(L("github.syncNow"), systemImage: "arrow.clockwise")
            }
            .disabled(!github.isConnected || isProjectSyncing)
            Button {
                sheet = RepoSheetRequest(mode: .add)
            } label: {
                Label(L("repos.add"), systemImage: "plus")
            }
            .disabled(!github.isConnected)
        }
        .padding(12)
    }

    /// Without SecondBrain's OAuth App (no client id yet), the GitHub CLI's session is the way to connect.
    private var connectMethod: GitHubAuthMethod {
        GitHubAuth.clientId(config: state.config) == nil && ghAvailable ? .ghCLI : .deviceFlow
    }

    private var connectTitle: String { connectMethod == .ghCLI ? L("github.useCLI") : L("github.connect") }

    private var isProjectSyncing: Bool { repos.contains { github.syncing.contains($0.id) } }

    private var disconnectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "powerplug").foregroundStyle(.orange)
            Text(L("repos.disconnected")).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(connectTitle) { showConnect = true }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { model.dismissNotice() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(L("common.close"))
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            Text(footerText).foregroundStyle(.secondary)
            SettingsLink { Text(L("github.change")) }
                .buttonStyle(.link)
            Spacer()
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(problem)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footerText: String {
        let minutes = state.config.githubSyncMinutes
        return minutes == 0 ? L("repos.footer.manual") : L("repos.footer.every", GitHubModel.intervalTitle(minutes).lowercased())
    }

    private func toggleCode(_ repo: TrackedRepo) {
        var r = repo
        r.readCode.toggle()
        do {
            try github.update(r)
            if r.readCode { model.syncNow(state: state, repoId: r.id) }
        } catch { self.error = FriendlyError.message(error) }
    }
}

struct RepoSheetRequest: Identifiable {
    enum Mode { case add, edit }
    let id = UUID()
    var mode: Mode
    var repo: TrackedRepo? = nil
}

/// One followed repository.
private struct RepoCard: View {
    let repo: TrackedRepo
    let syncing: Bool
    var onSync: () -> Void
    var onEditBranches: () -> Void
    var onToggleCode: () -> Void
    var onRemove: () -> Void
    var onOrgHelp: () -> Void

    private var htmlURL: URL? { URL(string: "https://github.com/\(repo.fullName)") }
    private var primary: TrackedBranch? { repo.branches.first { $0.name == repo.primaryBranch } }
    private var gone: [TrackedBranch] { repo.branches.filter { $0.state == .gone } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(repo.owner + "/").foregroundStyle(.secondary)
                        Text(repo.name).fontWeight(.semibold)
                    }
                    .font(.headline)
                    .lineLimit(1)
                    if let description = repo.description, !description.isEmpty {
                        Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Text(updatedText).font(.caption).foregroundStyle(.secondary).fixedSize()
                    .padding(.top, 3)
                Button(action: onSync) {
                    if syncing {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(syncing)
                .help(L("repos.syncRepo"))
                menu
            }

            FlowLayout(spacing: 6) {
                ForEach(repo.branches) { branch in
                    BranchChip(branch: branch, isPrimary: branch.name == repo.primaryBranch, syncing: syncing)
                }
                if !repo.readCode {
                    Chip(text: L("repos.noCode"), symbol: "eye.slash")
                        .help(L("repos.noCode.help"))
                }
            }

            ForEach(comparisons, id: \.name) { branch in
                Text(compareText(branch))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !gone.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle").foregroundStyle(.red)
                    Text(gone.count == 1 ? L("repos.gone.one", gone[0].name) : L("repos.gone.many", gone.map(\.name).joined(separator: ", ")))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("repos.chooseBranches"), action: onEditBranches).buttonStyle(.link)
                }
                .font(.callout)
            }

            if let error = repo.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if GitHubModel.isOrgRestricted(error) {
                        Button(L("github.org.howTo"), action: onOrgHelp).buttonStyle(.link)
                    }
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var menu: some View {
        Menu {
            Button(action: onEditBranches) { Label(L("repos.chooseBranches"), systemImage: "arrow.triangle.branch") }
            Button {
                if let htmlURL { NSWorkspace.shared.open(htmlURL) }
            } label: {
                Label(L("repos.openOnGitHub"), systemImage: "safari")
            }
            Button(action: onToggleCode) {
                if repo.readCode { Label(L("repos.readCode"), systemImage: "checkmark") } else { Text(L("repos.readCode")) }
            }
            Divider()
            Button(role: .destructive, action: onRemove) { Label(L("repos.remove"), systemImage: "minus.circle") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("project.more"))
    }

    private var updatedText: String {
        if syncing { return L("repos.syncing") }
        guard let at = repo.lastSyncAt else { return L("repos.neverSynced") }
        return L("repos.updated", Fmt.relative(at))
    }

    /// Branches other than the primary with a known ahead/behind count.
    private var comparisons: [TrackedBranch] {
        repo.branches.filter { $0.name != repo.primaryBranch && $0.state != .gone && ($0.ahead ?? 0) + ($0.behind ?? 0) > 0 }
    }

    private func compareText(_ branch: TrackedBranch) -> String {
        let ahead = branch.ahead ?? 0, behind = branch.behind ?? 0
        let parts = [ahead > 0 ? L("repos.ahead", ahead) : nil, behind > 0 ? L("repos.behind", behind) : nil].compactMap { $0 }
        return L("repos.compare", branch.name, parts.joined(separator: " · "), repo.primaryBranch)
    }
}

/// `main ✓ a1b2c3d · hace 2 h`, `development ⚠ reescrita`, `testing ✕ ya no existe`, `⟳ sincronizando`.
private struct BranchChip: View {
    let branch: TrackedBranch
    let isPrimary: Bool
    let syncing: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(branch.name).fontWeight(isPrimary ? .semibold : .regular)
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(stateIsCalm ? 0 : 0.35)))
        .padding(1)   // the tooltip host clips at the frame: keep the border's curve inside it
        .help(help)
    }

    private var stateIsCalm: Bool { syncing || branch.state == .ok || branch.state == .pending }

    private var background: Color { stateIsCalm ? Color.primary.opacity(0.06) : tint.opacity(0.1) }

    private var symbol: String {
        if syncing { return "arrow.triangle.2.circlepath" }
        switch branch.state {
        case .ok: return "checkmark"
        case .rewritten: return "exclamationmark.triangle.fill"
        case .gone: return "xmark"
        case .pending: return "clock"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        if syncing { return .accentColor }
        switch branch.state {
        case .ok: return .green
        case .rewritten: return .orange
        case .gone, .error: return .red
        case .pending: return .secondary
        }
    }

    private var shortSHA: String? { branch.lastSyncedSHA.map { String($0.prefix(7)) } }

    private var detail: String? {
        if syncing { return L("repos.branch.syncing") }
        switch branch.state {
        case .ok:
            return [shortSHA, branch.lastSyncedAt.map(Fmt.relative)].compactMap { $0 }.joined(separator: " · ")
        case .rewritten: return L("repos.branch.rewritten")
        case .gone: return L("repos.branch.gone")
        case .pending: return L("repos.branch.pending")
        case .error: return L("repos.branch.error")
        }
    }

    private var help: String {
        var lines = [isPrimary ? L("repos.branch.primary", branch.name) : branch.name]
        switch branch.state {
        case .rewritten: lines.append(L("repos.branch.rewritten.help"))
        case .gone: lines.append(L("repos.branch.gone.help"))
        default: break
        }
        if let sha = branch.lastSyncedSHA, let at = branch.lastSyncedAt { lines.append("\(sha.prefix(7)) · \(Fmt.dayTime(at))") }
        return lines.joined(separator: "\n")
    }
}
