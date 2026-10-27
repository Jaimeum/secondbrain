import AppKit
import BrainCore
import Foundation
import Observation

/// Keeps the followed GitHub repos up to date while the app lives (CONTRACT §13.4): checks once a minute whether a sync
/// is due (`engine.github.isDue`, i.e. right at launch when overdue and then every `githubSyncMinutes`), runs it through
/// `engine.syncGitHub` (the network work happens in the `GitHubSync` actor, off the main thread), and says so calmly when
/// something new was learned. Errors stay on the repo cards and in one soft line, never in an alert.
@MainActor @Observable
final class GitHubModel {
    static let shared = GitHubModel()
    static let tick: Duration = .seconds(60)

    /// A sync started here (scheduled, "Sincronizar ahora", or one repo) is running.
    private(set) var isSyncing = false
    /// "Aprendí cosas nuevas de 2 repositorios" (cleared after a while or when dismissed).
    private(set) var notice: String?
    /// The last sync's problem, in one line (nil when it went fine).
    private(set) var problem: String?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var noticeClear: Task<Void, Never>?
    @ObservationIgnored private var running: Task<GitHubSyncReport, Never>?

    /// Starts the loop once (AppState.startEngine). Snapshots never sync.
    func start(state: AppState) {
        guard loop == nil, DebugSnapshots.directory == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if state.engine.github.isDue, !self.isSyncing { _ = await self.sync(state: state, scheduled: true) }
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    /// Syncs everything (nil/nil), one project's repos or one repo. A second call while one runs waits for it instead
    /// of starting another (GitHubSync runs one at a time anyway).
    @discardableResult
    func sync(state: AppState, project: String? = nil, repoId: String? = nil, scheduled: Bool = false) async -> GitHubSyncReport? {
        // Every waiter re-checks after waking: the first one takes the slot (synchronously, below), the rest wait again.
        while let running { _ = await running.value }
        let engine = state.engine
        guard engine.github.isConnected else { return nil }
        isSyncing = true
        let task = Task { await engine.syncGitHub(project: project, repoId: repoId) }
        running = task
        let report = await task.value
        if running == task { running = nil; isSyncing = false }
        guard engine === state.engine else { return report }
        absorb(report, state: state, scheduled: scheduled)
        return report
    }

    /// Fire-and-forget variant for buttons.
    func syncNow(state: AppState, project: String? = nil, repoId: String? = nil) {
        Task { await sync(state: state, project: project, repoId: repoId) }
    }

    func dismissNotice() {
        noticeClear?.cancel()
        notice = nil
    }

    private func absorb(_ report: GitHubSyncReport, state: AppState, scheduled: Bool) {
        let errors = report.repos.compactMap(\.error)
        problem = errors.first.map { errors.count > 1 ? L("github.problem.many", $0, errors.count - 1) : $0 }
        let changed = report.repos.filter(\.changed)
        guard !changed.isEmpty else { return }
        let names = changed.compactMap { r in state.engine.github.repo(id: r.repoId)?.name }
        let text = changed.count == 1 ? L("github.learned.one", names.first ?? "") : L("github.learned.many", changed.count)
        notice = text
        noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
        // A scheduled sync happens while the user is elsewhere: tell them once, like a finished meeting.
        if scheduled, !NSApp.isActive {
            Notifier.post(title: L("github.learned.title"), body: text, id: "github-\(Int(report.finishedAt.timeIntervalSince1970))")
        }
    }

    // MARK: Helpers for the views

    /// "Cada hora" / "Solo a mano" for `githubSyncMinutes`.
    static func intervalTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: L("github.interval.manual")
        case 15: L("github.interval.15")
        case 60: L("github.interval.60")
        case 360: L("github.interval.360")
        case 1440: L("github.interval.1440")
        default: L("github.interval.custom", minutes)
        }
    }

    /// The errors the core writes for "the organization has to approve SecondBrain" end with this in both languages.
    static func isOrgRestricted(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.contains("SecondBrain en GitHub") || message.contains("SecondBrain on GitHub")
    }
}
