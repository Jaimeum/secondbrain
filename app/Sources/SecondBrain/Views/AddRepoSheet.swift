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
    /// Only a successful fetch can say a followed branch is gone (a failed one says nothing).
    @ViewState private var branchesLoaded = false
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
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420, idealHeight: 520)
        .background(Brand.color.surface)
        .sheet(isPresented: $showOrgHelp) { GitHubOrgHelpSheet() }
    }

    // MARK: Step 1 — which repository

    private var repoStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("repos.addSheet.title")).font(Brand.title).foregroundStyle(Brand.color.text)
                Text(L("repos.addSheet.hint", state.projectName(projectSlug)))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                searchField(L("repos.addSheet.search"), text: $query, busy: loadingRepos || resolving, onSubmit: submitQuery)
                    .padding(.top, 6)
            }
            .padding(.horizontal, Self.inset)
            .padding(.top, Self.inset)
            .padding(.bottom, Brand.spacing.m)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            List {
                if let pasted {
                    Button {
                        resolve(owner: pasted.owner, name: pasted.name)
                    } label: {
                        Label(L("repos.addSheet.usePasted", "\(pasted.owner)/\(pasted.name)"), systemImage: "link")
                            .font(Brand.callout)
                            .foregroundStyle(Brand.color.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(resolving)
                    .listRowInsets(Self.rowInsets)
                }
                ForEach(filteredRepos) { info in
                    RepoPickRow(info: info, alreadyFollowed: isFollowed(info)) { choose(info) }
                        .listRowInsets(Self.rowInsets)
                }
                if !loadingRepos, filteredRepos.isEmpty, pasted == nil {
                    Text(myRepos.isEmpty ? L("repos.addSheet.noneYet") : L("repos.addSheet.noMatch"))
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text2)
                        .padding(.vertical, 8)
                        .listRowInsets(Self.rowInsets)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            errorBanner
            Rectangle().fill(Brand.color.line).frame(height: 1)
            footer {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
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
                            Image(systemName: "chevron.left").foregroundStyle(Brand.color.text2)
                        }
                        .buttonStyle(.borderless)
                        .help(L("common.back"))
                    }
                    Text(info.fullName)
                        .font(Brand.title)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(L("repos.branches.hint"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if branches.count > 20 {
                    searchField(L("repos.branches.search"), text: $branchQuery, busy: false, onSubmit: {})
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, Self.inset)
            .padding(.top, Self.inset)
            .padding(.bottom, Brand.spacing.m)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            if loadingBranches && branches.isEmpty {
                BrandLoader(size: 24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleBranches(info), id: \.self) { name in
                        BranchPickRow(name: name, isDefault: name == info.defaultBranch, isSuggested: isSuggested(name),
                                      isProtected: branches.first { $0.name == name }?.isProtected ?? false,
                                      isGone: branchesLoaded && !branches.contains { $0.name == name },
                                      isOn: Binding(get: { selected.contains(name) },
                                                    set: { if $0 { selected.insert(name) } else { selected.remove(name) } }))
                            .listRowInsets(Self.rowInsets)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("repos.readCode.toggle"), isOn: $readCode)
                    .font(Brand.body)
                    .disabled(tooBig(info))
                Text(tooBig(info) ? L("repos.readCode.tooBig") : L("repos.readCode.hint"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Self.inset)
            .padding(.vertical, Brand.spacing.m)
            errorBanner
            Rectangle().fill(Brand.color.line).frame(height: 1)
            footer {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(followTitle) { save(info) }
                    .buttonStyle(.brandPrimary)
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
        branchesLoaded = false
        defer { loadingBranches = false }
        do {
            let list = try await github.branches(owner: info.owner, name: info.name)
            branches = list
            branchesLoaded = true
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

    /// One inset for header, list rows, toggle block and footer.
    private static let inset: CGFloat = Brand.spacing.content
    private static let rowInsets = EdgeInsets(top: 4, leading: inset, bottom: 4, trailing: inset)

    private func searchField(_ prompt: String, text: Binding<String>, busy: Bool, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.color.text3)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(Brand.body)
                .onSubmit(onSubmit)
            if busy { BrandLoader(size: 14) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.line))
    }

    /// Errors get their own full-width line above the footer (long GitHub messages stay readable).
    @ViewBuilder private var errorBanner: some View {
        if let error {
            HStack(alignment: .firstTextBaseline, spacing: Brand.spacing.s) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.color.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if orgRestricted {
                        Button(L("github.org.howTo")) { showOrgHelp = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Brand.color.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Brand.spacing.m)
            .background(Brand.color.warningSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            .padding(.horizontal, Self.inset)
            .padding(.bottom, Brand.spacing.m)
        }
    }

    private func footer(@ViewBuilder buttons: () -> some View) -> some View {
        HStack(spacing: Brand.spacing.s) {
            Spacer()
            buttons()
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, Brand.spacing.m)
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
                    .foregroundStyle(Brand.color.text2)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.fullName)
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let description = info.description, !description.isEmpty {
                        Text(description).font(Brand.body).foregroundStyle(Brand.color.text2).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    if alreadyFollowed {
                        BrandChip(text: L("repos.addSheet.following"), symbol: "checkmark", tint: Brand.color.success)
                    }
                    if let pushed = info.pushedAt {
                        Text(Fmt.relative(pushed)).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
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
                Text(name)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDefault { BrandChip(text: L("repos.branches.primary"), active: true) }
                if isProtected {
                    Image(systemName: "lock").font(Brand.caption).foregroundStyle(Brand.color.text2).help(L("repos.branches.protected"))
                }
                if isGone { BrandChip(text: L("repos.branch.gone"), symbol: "xmark", tint: Brand.color.danger) }
                Spacer(minLength: 4)
                if isSuggested && !isDefault {
                    Text(L("repos.branches.suggested")).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }
}
