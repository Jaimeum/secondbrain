import ArgumentParser
import BrainCore
import Foundation

/// `sb github …` (CONTRACT §13.7): connect, follow repos per project, sync (for cron), offline self-test.
struct GitHubCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "github", abstract: "GitHub repos per project (read-only).",
        subcommands: [Status.self, Login.self, Logout.self, Add.self, Remove.self, Sync.self, GitHubSelfTestCmd.self])

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Connection, followed repos and branches.")
        @Option(help: "Only this project") var project: String?

        @MainActor func run() async throws {
            let engine = makeEngine()
            let gh = engine.github
            if let a = gh.account {
                print("GitHub: @\(a.login)" + (a.name.map { " (\($0))" } ?? "") + " · \(a.method.rawValue) · since \(stamp(a.connectedAt))")
            } else if gh.isConnected {
                print("GitHub: token from SB_GITHUB_TOKEN (no saved account)")
            } else {
                print("GitHub: not connected (sb github login --gh | --token - (stdin) | --device)")
            }
            let minutes = engine.config.githubSyncMinutes
            print("Auto sync: " + (minutes == 0 ? "manual only" : "every \(minutes) min")
                  + (gh.lastGlobalSyncAt.map { " · last \(stamp($0))" } ?? " · never") + (gh.isDue ? " · due" : ""))
            let repos = project.map { gh.repos(project: $0) } ?? gh.repos
            if repos.isEmpty { print("No repos followed" + (project.map { " in \($0)" } ?? "") + "."); return }
            for r in repos {
                print("\n\(r.id)  [\(r.projectSlug)] \(r.fullName)" + (r.readCode ? "" : " (no code)")
                      + (r.lastSyncAt.map { " · synced \(stamp($0))" } ?? " · never synced"))
                if let e = r.lastError { print("  ! \(e)") }
                for b in r.branches {
                    var line = "  \(b.name == r.primaryBranch ? "*" : " ") \(b.name): \(b.state.rawValue)"
                    if let sha = b.lastSyncedSHA { line += " \(sha.prefix(7))" }
                    if let at = b.lastSyncedAt { line += " · \(stamp(at))" }
                    if let ahead = b.ahead, let behind = b.behind { line += " · \(ahead) ahead / \(behind) behind \(r.primaryBranch)" }
                    print(line)
                }
            }
        }
    }

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Connect GitHub: --gh (GitHub CLI session), --token, or --device (OAuth device flow).")
        @Option(help: "A personal access token (fine-grained, read-only recommended). Use `--token -` to read it from stdin (keeps it out of shell history and `ps`).") var token: String?
        @Flag(help: "Copy the token of your `gh` session") var gh = false
        @Flag(help: "OAuth device flow with SecondBrain's GitHub app") var device = false

        @MainActor func run() async throws {
            let engine = makeEngine()
            let store = engine.github
            let account: GitHubAccount
            if let token {
                let value = token == "-" ? (readLine(strippingNewline: true) ?? "") : token
                if token != "-" { eprint("warning: a token on the command line ends up in shell history; prefer `--token -` (stdin)") }
                account = try await store.connect(token: value, method: .personalToken)
            } else if gh {
                account = try await store.connectWithGHCLI()
            } else if device {
                guard let clientId = GitHubAuth.clientId(config: engine.config) else {
                    throw CLIError("No GitHub OAuth App client id (set SB_GITHUB_CLIENT_ID or ~/.config/secondbrain/github-client-id.txt at build).")
                }
                let code = try await store.startDeviceFlow(clientId: clientId)
                print("Open \(code.verificationURI.absoluteString) and type the code: \(code.userCode)")
                print("Waiting for approval…")
                account = try await store.finishDeviceFlow(code)
            } else {
                throw CLIError("Choose one: --gh, --token - (reads the token from stdin) or --device")
            }
            print("Connected as @\(account.login)" + (account.name.map { " (\($0))" } ?? ""))
        }
    }

    struct Logout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget the GitHub token (followed repos and the wiki stay).")
        @MainActor func run() async throws {
            makeEngine().github.disconnect()
            print("GitHub disconnected.")
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Follow a repo in a project: sb github add owner/name --project slug --branches main,development")
        @Argument(help: "owner/name, https://github.com/owner/name or git@github.com:owner/name.git") var repo: String
        @Option var project: String
        @Option(help: "Comma-separated branches (default: the repo's default branch)") var branches: String?
        @Flag(help: "Don't download the code (only commits, PRs, issues)") var noCode = false
        @Flag(help: "Sync it right away") var sync = false

        @MainActor func run() async throws {
            let engine = makeEngine()
            guard engine.projects.get(project) != nil else { throw CLIError("Unknown project: \(project)") }
            guard let parsed = GitHubRepoInfo.parse(repo) else { throw CLIError("Not a GitHub repo: \(repo)") }
            let info = try await engine.github.repoInfo(owner: parsed.owner, name: parsed.name)
            let wanted = branches.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? [info.defaultBranch]
            let existing = Set(try await engine.github.branches(owner: info.owner, name: info.name).map(\.name))
            for b in wanted where !existing.contains(b) { eprint("warning: branch \(b) not found on GitHub (it will show as gone)") }
            let tracked = try engine.github.add(info, project: project, branches: wanted, readCode: !noCode)
            print("Following \(tracked.fullName) in \(project): \(tracked.branches.map(\.name).joined(separator: ", ")) (id \(tracked.id))")
            if sync {
                printReport(await engine.syncGitHub(repoId: tracked.id))
            } else {
                print("Run `sb github sync --repo \(tracked.id)` (then `sb run`).")
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop following a repo (its checkouts go; the wiki stays).")
        @Argument(help: "Repo id as `sb github status` shows it (project:owner/name)") var id: String
        @MainActor func run() async throws {
            try makeEngine().github.remove(repoId: id.lowercased())
            print("Removed \(id).")
        }
    }

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sync followed repos (for cron); `sb run` (or --run) then lets Claude learn the changes.")
        @Option var project: String?
        @Option(help: "One repo id") var repo: String?
        @Flag(name: .customLong("run"), help: "Process the queued ingests right away") var processQueue = false
        @Flag(help: "Only when the configured interval has passed") var ifDue = false

        @MainActor func run() async throws {
            let engine = makeEngine()
            if ifDue, !engine.github.isDue { print("Not due yet."); return }
            let report = await engine.syncGitHub(project: project, repoId: repo?.lowercased())
            printReport(report)
            if processQueue, report.repos.contains(where: \.changed) { await runQueue(engine) }
            if report.repos.contains(where: { $0.error != nil }) { throw ExitCode(1) }
        }
    }
}

func printReport(_ report: GitHubSyncReport) {
    if report.repos.isEmpty { print("Nothing to sync."); return }
    for r in report.repos {
        var line = (r.error != nil ? "✗ " : r.changed ? "✓ " : "· ") + r.repoId
        if let e = r.error { line += " — \(e)" } else if !r.changed { line += " — unchanged" }
        if r.newCommits > 0 { line += " · \(r.newCommits) commits" }
        if !r.rewrittenBranches.isEmpty { line += " · rewritten: \(r.rewrittenBranches.joined(separator: ", "))" }
        if !r.goneBranches.isEmpty { line += " · gone: \(r.goneBranches.joined(separator: ", "))" }
        if !r.codeUpdated.isEmpty { line += " · code: \(r.codeUpdated.joined(separator: ", "))" }
        if let raw = r.rawPath { line += "\n    → \(raw)" }
        print(line)
    }
}
