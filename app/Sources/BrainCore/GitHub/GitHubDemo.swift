import Foundation

/// `SB_DEMO_GITHUB=1`: an invented account and two followed repos for snapshots and UX review (CONTRACT §13.6). No
/// network, nothing written. One repo has `main` + `development` (development rewritten by a force-push, ahead/behind
/// of main); the other has `main` + a `testing` branch that no longer exists on GitHub.
public enum GitHubDemo {
    public static let projectSlug = "lanzamiento-atlas"

    public static var account: GitHubAccount {
        GitHubAccount(login: "jaime-ruiz", name: "Jaime Ruiz", avatarURL: nil, connectedAt: Date().addingTimeInterval(-86_400 * 12),
                      method: .deviceFlow)
    }

    public static func repos(projectSlug: String = GitHubDemo.projectSlug, now: Date = Date()) -> [TrackedRepo] {
        var app = TrackedRepo(projectSlug: projectSlug, owner: "acme", name: "atlas-app", primaryBranch: "main",
                              branches: [
                                TrackedBranch(name: "main", lastSyncedSHA: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
                                              lastSyncedAt: now.addingTimeInterval(-7_200), state: .ok, knownCommits: []),
                                TrackedBranch(name: "development", lastSyncedSHA: "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432",
                                              lastSyncedAt: now.addingTimeInterval(-300), state: .rewritten, knownCommits: [],
                                              ahead: 12, behind: 3),
                              ],
                              readCode: true, description: "App móvil Atlas para clientes de Acme (iOS + Android, React Native)",
                              sizeKB: 48_200, addedAt: now.addingTimeInterval(-86_400 * 10))
        app.lastSyncAt = now.addingTimeInterval(-300)
        app.lastActivitySync = now.addingTimeInterval(-300)
        var api = TrackedRepo(projectSlug: projectSlug, owner: "acme", name: "atlas-api", primaryBranch: "main",
                              branches: [
                                TrackedBranch(name: "main", lastSyncedSHA: "0c1d2e3f405162738495a6b7c8d9e0f1a2b3c4d5",
                                              lastSyncedAt: now.addingTimeInterval(-3_600), state: .ok),
                                TrackedBranch(name: "testing", lastSyncedSHA: "5d4c3b2a1908f7e6d5c4b3a29180f7e6d5c4b3a2",
                                              lastSyncedAt: now.addingTimeInterval(-86_400 * 2), state: .gone),
                              ],
                              readCode: false, description: "API de Atlas (Go): autenticación, pagos y notificaciones",
                              sizeKB: 12_900, addedAt: now.addingTimeInterval(-86_400 * 8))
        api.lastSyncAt = now.addingTimeInterval(-3_600)
        api.lastActivitySync = now.addingTimeInterval(-3_600)
        return [app, api]
    }

    public static var myRepos: [GitHubRepoInfo] {
        let now = Date()
        return [
            GitHubRepoInfo(owner: "acme", name: "atlas-app", description: "App móvil Atlas para clientes de Acme", defaultBranch: "main",
                           isPrivate: true, sizeKB: 48_200, pushedAt: now.addingTimeInterval(-300)),
            GitHubRepoInfo(owner: "acme", name: "atlas-api", description: "API de Atlas (Go)", defaultBranch: "main",
                           isPrivate: true, sizeKB: 12_900, pushedAt: now.addingTimeInterval(-3_600)),
            GitHubRepoInfo(owner: "acme", name: "design-system", description: "Componentes y tokens de diseño de Acme",
                           defaultBranch: "main", isPrivate: false, sizeKB: 8_100, pushedAt: now.addingTimeInterval(-86_400 * 3)),
            GitHubRepoInfo(owner: "jaime-ruiz", name: "dotfiles", description: nil, defaultBranch: "master",
                           isPrivate: false, sizeKB: 300, pushedAt: now.addingTimeInterval(-86_400 * 40)),
        ]
    }

    public static var branches: [GitHubBranchInfo] {
        [
            GitHubBranchInfo(name: "main", sha: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", isProtected: true),
            GitHubBranchInfo(name: "development", sha: "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"),
            GitHubBranchInfo(name: "staging", sha: "1122334455667788990011223344556677889900"),
            GitHubBranchInfo(name: "feature/onboarding-v2", sha: "aabbccddeeff00112233445566778899aabbccdd"),
            GitHubBranchInfo(name: "fix/push-notifications", sha: "ffeeddccbbaa99887766554433221100ffeeddcc"),
        ]
    }
}
