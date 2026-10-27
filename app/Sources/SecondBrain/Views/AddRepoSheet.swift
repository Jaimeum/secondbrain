import BrainCore
import SwiftUI

/// "Agregar repositorio" (CONTRACT §13.6): (1) pick one of the user's repositories, or paste its URL / `owner/name`;
/// (2) choose the branches to follow — the primary one and the usual `develop|testing|staging…` come preselected — and
/// whether to read its code. "Seguir N ramas" saves and starts the first sync. With `editing` it opens on step 2 for
/// that repo ("Elegir ramas").
struct AddRepoSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let projectSlug: String
    let editing: TrackedRepo?

    @ViewState private var chosen: GitHubRepoInfo?
    @ViewState private var query = ""
    @ViewState private var myRepos: [GitHubRepoInfo] = []
    @ViewState private var loadingRepos = false
    @ViewState private var resolving = false
    @ViewState private var branches: [GitHubBranchInfo] = []
    @ViewState private var loadingBranches = false
    @ViewState private var selected: Set<String> = []
    @ViewState private var branchQuery = ""
    @ViewState private var readCode = true
    @ViewState private var error: String?
    @ViewState private var orgRestricted = false
    @ViewState private var showOrgHelp = false

    init(projectSlug: String, editing: TrackedRepo? = nil, initialRepo: GitHubRepoInfo? = nil) {
        self.projectSlug = projectSlug
        self.editing = editing
        let start = editing.map {
            GitHubRepoInfo(owner: $0.owner, name: $0.name, description: $0.description, defaultBranch: $0.primaryBranch,
                           sizeKB: $0.sizeKB ?? 0)
        } ?? initialRepo
        _chosen = ViewState(initialValue: start)
        _readCode = ViewState(initialValue: editing?.readCode ?? true)
    }

    private var github: GitHubStore { state.engine.github }

    var body: some View {
        VStack(spacing: 0) {
            if let chosen {
                branchStep(chosen)
            } else {
                repoStep
            }
        }
        .frame(width: 580, height: 580)
        .sheet(isPresented: $showOrgHelp) { GitHubOrgHelpSheet() }
    }

    // MARK: Step 1 — which repository

    private var repoStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("repos.addSheet.title")).font(.title2.weight(.semibold))
                Text(L("repos.addSheet.hint", state.projectName(projectSlug)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("repos.addSheet.search"), text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit(submitQuery)
                    if loadingRepos || resolving { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)
            Divider()
            List {
                if let pasted {
                    Button {
                        resolve(owner: pasted.owner, name: pasted.name)
                    } label: {
                        Label(L("repos.addSheet.usePasted", "\(pasted.owner)/\(pasted.name)"), systemImage: "link")
                    }
                    .buttonStyle(.plain)
                    .disabled(resolving)
                }
                ForEach(filteredRepos) { info in
                    RepoPickRow(info: info, alreadyFollowed: isFollowed(info)) { choose(info) }
                }
                if !loadingRepos, filteredRepos.isEmpty, pasted == nil {
                    Text(myRepos.isEmpty ? L("repos.addSheet.noneYet") : L("repos.addSheet.noMatch"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .listStyle(.inset)
            Divider()
            footer {
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .task { await loadRepos(refresh: false) }
    }

    /// A pasted URL / `owner/name` that isn't simply a search word.
    private var pasted: (owner: String, name: String)? {
        guard query.contains("/"), let p = GitHubRepoInfo.parse(query) else { return nil }
        return myRepos.contains { $0.id == "\(p.owner)/\(p.name)".lowercased() } ? nil : p
    }

    private var filteredRepos: [GitHubRepoInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return myRepos }
        if let p = GitHubRepoInfo.parse(q), q.contains("/") {
            return myRepos.filter { $0.id == "\(p.owner)/\(p.name)".lowercased() }
        }
        return myRepos.filter { $0.id.contains(q) || ($0.description?.lowercased().contains(q) ?? false) }
    }

    private func isFollowed(_ info: GitHubRepoInfo) -> Bool {
        github.repo(id: TrackedRepo.makeId(projectSlug: projectSlug, owner: info.owner, name: info.name)) != nil
    }

    private func submitQuery() {
        if let pasted { resolve(owner: pasted.owner, name: pasted.name) } else if filteredRepos.count == 1 { choose(filteredRepos[0]) }
    }

    private func loadRepos(refresh: Bool) async {
        loadingRepos = true
        defer { loadingRepos = false }
        do { myRepos = try await github.listMyRepos(refresh: refresh) } catch { show(error) }
    }

    private func resolve(owner: String, name: String) {
        resolving = true
        Task {
            defer { resolving = false }
            do { choose(try await github.repoInfo(owner: owner, name: name)) } catch { show(error) }
        }
    }

    private func choose(_ info: GitHubRepoInfo) {
        error = nil
        orgRestricted = false
        selected = []
        branches = []
        branchQuery = ""
        let existing = github.repo(id: TrackedRepo.makeId(projectSlug: projectSlug, owner: info.owner, name: info.name))
        readCode = existing?.readCode ?? (info.sizeKB <= GitHubLimits.maxRepoKB)
        chosen = info
    }

    // MARK: Step 2 — which branches

    private func branchStep(_ info: GitHubRepoInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if editing == nil {
                        Button {
                            chosen = nil
                            error = nil
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .help(L("common.back"))
                    }
                    Text(info.fullName).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                }
                Text(L("repos.branches.hint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if branches.count > 20 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("repos.branches.search"), text: $branchQuery).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)
            Divider()
            if loadingBranches && branches.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleBranches(info), id: \.self) { name in
                        BranchPickRow(name: name, isDefault: name == info.defaultBranch, isSuggested: isSuggested(name),
                                      isProtected: branches.first { $0.name == name }?.isProtected ?? false,
                                      isGone: !loadingBranches && !branches.contains { $0.name == name },
                                      isOn: Binding(get: { selected.contains(name) },
                                                    set: { if $0 { selected.insert(name) } else { selected.remove(name) } }))
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("repos.readCode.toggle"), isOn: $readCode)
                    .disabled(tooBig(info))
                Text(tooBig(info) ? L("repos.readCode.tooBig") : L("repos.readCode.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()
            footer {
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(followTitle) { save(info) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .task(id: info.id) { await loadBranches(info) }
    }

    private var followTitle: String {
        if editing != nil { return L("repos.branches.save") }
        return selected.count == 1 ? L("repos.branches.followOne") : L("repos.branches.follow", selected.count)
    }

    private func tooBig(_ info: GitHubRepoInfo) -> Bool { info.sizeKB > GitHubLimits.maxRepoKB }

    private func isSuggested(_ name: String) -> Bool { GitHubStore.suggestedBranches.contains(name.lowercased()) }

    private var followed: TrackedRepo? {
        guard let chosen else { return nil }
        return github.repo(id: TrackedRepo.makeId(projectSlug: projectSlug, owner: chosen.owner, name: chosen.name))
    }

    /// Primary first, then the suggested ones, then the rest; followed branches that no longer exist stay listed.
    private func visibleBranches(_ info: GitHubRepoInfo) -> [String] {
        var names = branches.map(\.name)
        for b in followed?.branches ?? [] where !names.contains(b.name) { names.append(b.name) }
        let q = branchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { names = names.filter { $0.lowercased().contains(q) || selected.contains($0) } }
        func rank(_ n: String) -> Int { n == info.defaultBranch ? 0 : isSuggested(n) ? 1 : 2 }
        return names.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func loadBranches(_ info: GitHubRepoInfo) async {
        loadingBranches = true
        defer { loadingBranches = false }
        do {
            let list = try await github.branches(owner: info.owner, name: info.name)
            branches = list
            guard selected.isEmpty else { return }
            if let followed {
                selected = Set(followed.branches.map(\.name))
            } else {
                let names = Set(list.map(\.name))
                selected = Set(([info.defaultBranch] + GitHubStore.suggestedBranches).filter(names.contains))
                if selected.isEmpty, let first = list.first { selected = [first.name] }
            }
        } catch {
            show(error)
            if let followed, selected.isEmpty { selected = Set(followed.branches.map(\.name)) }
        }
    }

    private func save(_ info: GitHubRepoInfo) {
        let before = followed
        let names = visibleBranches(info).filter(selected.contains)
        do {
            let repo = try github.add(info, project: projectSlug, branches: names, readCode: readCode && !tooBig(info))
            let newBranches = Set(names).subtracting(before?.branches.map(\.name) ?? [])
            let codeTurnedOn = repo.readCode && !(before?.readCode ?? false)
            if before == nil || !newBranches.isEmpty || codeTurnedOn {
                GitHubModel.shared.syncNow(state: state, repoId: repo.id)
            }
            dismiss()
        } catch {
            show(error)
        }
    }

    // MARK: Shared

    @ViewBuilder
    private func footer(@ViewBuilder buttons: () -> some View) -> some View {
        HStack(spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .lineLimit(2)
                    .help(error)
                if orgRestricted {
                    Button(L("github.org.howTo")) { showOrgHelp = true }.buttonStyle(.link)
                }
            }
            Spacer()
            buttons()
        }
        .padding(14)
    }

    private func show(_ error: Error) {
        if case GitHubError.orgRestricted = error { orgRestricted = true }
        self.error = FriendlyError.message(error)
    }
}

private struct RepoPickRow: View {
    let info: GitHubRepoInfo
    let alreadyFollowed: Bool
    var onChoose: () -> Void

    var body: some View {
        Button(action: onChoose) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: info.isPrivate ? "lock" : "book.closed")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.fullName).fontWeight(.medium).lineLimit(1)
                    if let description = info.description, !description.isEmpty {
                        Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if alreadyFollowed {
                        Chip(text: L("repos.addSheet.following"), tint: .green, symbol: "checkmark")
                    }
                    if let pushed = info.pushedAt {
                        Text(Fmt.relative(pushed)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct BranchPickRow: View {
    let name: String
    let isDefault: Bool
    let isSuggested: Bool
    let isProtected: Bool
    let isGone: Bool
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if isDefault { Chip(text: L("repos.branches.primary"), tint: .accentColor) }
                if isProtected { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help(L("repos.branches.protected")) }
                if isGone { Chip(text: L("repos.branch.gone"), tint: .red, symbol: "xmark") }
                Spacer()
                if isSuggested && !isDefault { Text(L("repos.branches.suggested")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }
}
