import AppKit
import BrainCore
import SwiftUI

/// The GitHub repositories this project follows (CONTRACT §13.6, shown in the project's "Repositorios…" sheet since
/// v0.5): one card per repo with a chip per followed branch (synced · rewritten · gone · syncing), how the other
/// branches compare to the primary one, and how often it all refreshes. One sync control: "Actualizar" in the header.
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.color.surface)
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
            ScrollView {
                VStack(spacing: Brand.spacing.m) {
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
                .padding(Brand.spacing.content)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .brandScrollEdgeFade(.top)
            .brandScrollEdgeFade(.bottom)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: Brand.spacing.s) {
            Text(repos.count == 1 ? L("repos.count.one") : L("repos.count.many", repos.count))
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(1)
            Spacer(minLength: Brand.spacing.s)
            ViewThatFits(in: .horizontal) {
                headerButtons(iconsOnly: false)
                headerButtons(iconsOnly: true)
            }
        }
        .padding(.horizontal, Brand.spacing.content)
        .padding(.vertical, Brand.spacing.m)
    }

    private func headerButtons(iconsOnly: Bool) -> some View {
        HStack(spacing: Brand.spacing.s) {
            Button {
                model.syncNow(state: state, project: projectSlug)
            } label: {
                HStack(spacing: 6) {
                    if isProjectSyncing {
                        BrandLoader(size: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    if !iconsOnly { Text(isProjectSyncing ? L("repos.syncing") : L("project.reposSync")) }
                }
            }
            .buttonStyle(.brandSecondary)
            .disabled(!github.isConnected || isProjectSyncing)
            .help(L("github.syncNow"))
            Button {
                sheet = RepoSheetRequest(mode: .add)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    if !iconsOnly { Text(L("repos.add")) }
                }
            }
            .buttonStyle(.brandPrimary)
            .disabled(!github.isConnected)
            .help(L("repos.add"))
        }
        .fixedSize()
    }

    /// Without the app's OAuth App (no client id yet), the GitHub CLI's session is the way to connect.
    private var connectMethod: GitHubAuthMethod {
        GitHubAuth.clientId(config: state.config) == nil && ghAvailable ? .ghCLI : .deviceFlow
    }

    private var connectTitle: String { connectMethod == .ghCLI ? L("github.useCLI") : L("github.connect") }

    private var isProjectSyncing: Bool { repos.contains { github.syncing.contains($0.id) } }

    private var disconnectedBanner: some View {
        HStack(spacing: Brand.spacing.m) {
            Image(systemName: "powerplug").foregroundStyle(Brand.color.warning)
            Text(L("repos.disconnected"))
                .font(Brand.body)
                .foregroundStyle(Brand.color.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(connectTitle) { showConnect = true }
                .buttonStyle(.brandSecondary)
        }
        .padding(Brand.spacing.m)
        .background(Brand.color.warningSoft, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: Brand.spacing.m) {
            Image(systemName: "sparkles").foregroundStyle(Brand.color.accent)
            Text(text)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.dismissNotice() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.brandIcon)
            .help(L("common.close"))
        }
        .padding(Brand.spacing.m)
        .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Brand.color.text3)
            Text(footerText)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: "·").foregroundStyle(Brand.color.text3)
            Button(L("github.change")) { openGitHubSettings() }
                .buttonStyle(.settingsLink)
                .fixedSize()
            Spacer(minLength: Brand.spacing.s)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.color.warning)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(problem)
            }
        }
        .font(Brand.caption)
        .padding(.horizontal, Brand.spacing.content)
        .padding(.vertical, Brand.spacing.s)
    }

    private var footerText: String {
        let minutes = state.config.githubSyncMinutes
        return minutes == 0 ? L("project.reposManual") : L("project.reposEvery", GitHubModel.intervalTitle(minutes).lowercased())
    }

    /// Ajustes › GitHub (the `settings.selectedTab` deep link, CONTRACT §15.2).
    private func openGitHubSettings() {
        SettingsTab.open(.github)
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
    private var gone: [TrackedBranch] { repo.branches.filter { $0.state == .gone } }

    var body: some View {
        BrandCard(padding: Brand.spacing.l) {
            VStack(alignment: .leading, spacing: Brand.spacing.m) {
                HStack(alignment: .top, spacing: Brand.spacing.m) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(Brand.font(13, .semibold))
                        .foregroundStyle(Brand.color.text2)
                        .frame(width: 30, height: 30)
                        .background(Brand.color.cardAlt, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        (Text(repo.owner + "/").foregroundStyle(Brand.color.text2)
                            + Text(repo.name).foregroundStyle(Brand.color.text).fontWeight(.semibold))
                            .font(Brand.section)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let description = repo.description, !description.isEmpty {
                            Text(description).font(Brand.body).foregroundStyle(Brand.color.text2).lineLimit(2)
                        }
                        HStack(spacing: 6) {
                            if syncing { BrandLoader(size: 12) }
                            Text(updatedText)
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text2)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    menu
                }

                FlowLayout(spacing: 6) {
                    ForEach(repo.branches) { branch in
                        BranchChip(branch: branch, isPrimary: branch.name == repo.primaryBranch, syncing: syncing)
                    }
                    if !repo.readCode {
                        BrandChip(text: L("repos.noCode"), symbol: "eye.slash")
                            .help(L("repos.noCode.help"))
                    }
                }

                ForEach(comparisons, id: \.name) { branch in
                    Text(compareText(branch))
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !gone.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "xmark.circle").foregroundStyle(Brand.color.danger)
                        Text(gone.count == 1 ? L("repos.gone.one", gone[0].name) : L("repos.gone.many", gone.map(\.name).joined(separator: ", ")))
                            .foregroundStyle(Brand.color.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("repos.chooseBranches"), action: onEditBranches)
                            .buttonStyle(.settingsLink)
                    }
                    .font(Brand.body)
                }

                if let error = repo.lastError {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.color.warning)
                        Text(error)
                            .foregroundStyle(Brand.color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if GitHubModel.isOrgRestricted(error) {
                            Button(L("github.org.howTo"), action: onOrgHelp)
                                .buttonStyle(.settingsLink)
                        }
                    }
                    .font(Brand.body)
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Button(action: onSync) { Label(L("repos.syncRepo"), systemImage: "arrow.clockwise") }
                .disabled(syncing)
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
            BrandMoreMenuLabel()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
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

/// `main ✓ a1b2c3d · hace 2 h`, `development ⚠ reescrita`, `testing ✕ ya no existe`: a tinted capsule, no border
/// (nothing to clip), one line.
private struct BranchChip: View {
    let branch: TrackedBranch
    let isPrimary: Bool
    let syncing: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(Brand.font(10, .semibold)).foregroundStyle(Brand.color.text3)
            Text(branch.name)
                .font(Brand.font(12, isPrimary ? .semibold : .regular))
                .foregroundStyle(Brand.color.text)
            Image(systemName: symbol).font(Brand.font(10, .semibold)).foregroundStyle(tint)
            if let detail {
                Text(detail).font(Brand.font(12)).foregroundStyle(Brand.color.text2)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
        .contentShape(Capsule())
        .help(help)
    }

    private var stateIsCalm: Bool { syncing || branch.state == .ok || branch.state == .pending }

    private var background: Color {
        if stateIsCalm { return Brand.color.cardAlt }
        return branch.state == .rewritten ? Brand.color.warningSoft : Brand.color.recordSoft
    }

    private var symbol: String {
        if syncing { return "arrow.triangle.2.circlepath" }
        switch branch.state {
        case .ok: return "checkmark"
        case .rewritten: return "exclamationmark.triangle"
        case .gone: return "xmark"
        case .pending: return "clock"
        case .error: return "exclamationmark.circle"
        }
    }

    private var tint: Color {
        if syncing { return Brand.color.accent }
        switch branch.state {
        case .ok: return Brand.color.success
        case .rewritten: return Brand.color.warning
        case .gone, .error: return Brand.color.danger
        case .pending: return Brand.color.text3
        }
    }

    private var shortSHA: String? { branch.lastSyncedSHA.map { String($0.prefix(7)) } }

    private var detail: String? {
        if syncing { return L("repos.branch.syncing") }
        switch branch.state {
        case .ok:
            let text = [shortSHA, branch.lastSyncedAt.map(Fmt.relative)].compactMap { $0 }.joined(separator: " · ")
            return text.isEmpty ? nil : text
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
