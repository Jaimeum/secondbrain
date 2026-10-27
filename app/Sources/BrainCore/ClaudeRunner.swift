import Foundation

/// Runs the user's Claude Code CLI (`claude -p … --output-format stream-json`) inside the vault.
public final class ClaudeRunner: Sendable {
    private let configProvider: @Sendable () -> AppConfig
    public let vaultURL: URL

    public init(configProvider: @escaping @Sendable () -> AppConfig, vaultURL: URL) {
        self.configProvider = configProvider
        self.vaultURL = vaultURL
    }

    /// Reads `vault/.claude/commands/<command>.md`, strips its frontmatter, fills `$ARGUMENTS` and runs it.
    /// `extraDirs` (v0.4 github): folders outside the vault Claude may also read (`--add-dir`), only in `.readOnly`.
    public func run(command: String, arguments: String, mode: ClaudeMode, model: String,
                    extraDirs: [URL] = []) -> AsyncThrowingStream<ClaudeEvent, Error> {
        let file = vaultURL.appendingPathComponent(".claude/commands/\(command).md")
        guard let template = try? String(contentsOf: file, encoding: .utf8) else {
            return AsyncThrowingStream { $0.finish(throwing: ClaudeError.failed("Missing command file \(file.path)")) }
        }
        let prompt = Frontmatter.strip(template).replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        return runPrompt(prompt, mode: mode, model: model, extraDirs: extraDirs)
    }

    public func runPrompt(_ prompt: String, mode: ClaudeMode, model: String,
                          extraDirs: [URL] = []) -> AsyncThrowingStream<ClaudeEvent, Error> {
        let config = configProvider()
        let vault = vaultURL
        return AsyncThrowingStream { continuation in
            let args = Self.arguments(mode: mode, model: model, extraDirs: extraDirs)
            let session = ClaudeProcess(arguments: args, prompt: prompt, cwd: vault,
                                        parser: ClaudeStreamParser(vaultURL: vault, language: config.uiLanguage),
                                        continuation: continuation)
            continuation.onTermination = { reason in
                if case .cancelled = reason { session.terminate() }
            }
            // Locating the binary may spawn a login shell: keep it (and the spawn) off the caller's thread.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let binary = ClaudeSetup.locate(config: config) else {
                    continuation.finish(throwing: ClaudeError.notInstalled)
                    return
                }
                session.start(binary: binary)
            }
        }
    }

    /// CLI arguments for a run confined to the vault (the process cwd).
    ///
    /// No tool is pre-approved (`--allowedTools`): Claude Code already lets Read/Glob/Grep touch the working
    /// directory, and `acceptEdits` auto-accepts Write/Edit/MultiEdit only there. Anything outside the vault
    /// would need a permission prompt, which `-p` mode denies — so a prompt injected through a source can't
    /// read `~/.ssh` or other documents into the wiki, nor write elsewhere on disk (verified with `claude -p`).
    /// `--setting-sources project` drops the user's own `~/.claude/settings*.json` (whose allow rules or
    /// `additionalDirectories` could widen that) while still loading the vault's CLAUDE.md. The deny list is
    /// only a backstop for the most sensitive folders.
    static func arguments(mode: ClaudeMode, model: String, extraDirs: [URL] = []) -> [String] {
        let tools = mode == .readOnly ? "Read,Glob,Grep" : "Read,Glob,Grep,Write,Edit,MultiEdit"
        // MARK: v0.4 github — code checkouts are added for reading only; an editing run never sees them (acceptEdits
        // would otherwise let it write there).
        let dirs = mode == .readOnly ? extraDirs.flatMap { ["--add-dir", $0.path] } : []
        return dirs + [
            "-p",
            "--output-format", "stream-json", "--verbose",
            "--model", model,
            "--permission-mode", "acceptEdits",
            "--tools", tools,
            "--disallowedTools", "Bash,WebFetch,WebSearch",
            "--setting-sources", "project",
            "--settings", backstopSettings,
            "--strict-mcp-config",
        ]
    }

    static let backstopSettings: String = {
        let paths = ["~/.ssh", "~/.aws", "~/.gnupg", "~/.config", "~/.claude", "~/Library/Keychains"]
        let deny = paths.flatMap { p in ["Read(\(p)/**)", "Edit(\(p)/**)"] }
        let json: [String: Any] = ["permissions": ["deny": deny]]
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }()

    /// Stops every Claude process this app started (on quit, so none keeps editing the vault unattended).
    public static func terminateAll() {
        ClaudeProcess.terminateAll()
    }

    // MARK: Environment shared with ClaudeSetup

    /// The process's home: `$HOME` when set (so an isolated HOME is honoured end to end, like the installer
    /// does), else the account's home directory.
    static var homeDirectory: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") { return home }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    static var extraPathDirs: [String] {
        let home = homeDirectory
        return ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var path = extraPathDirs
        for p in existing where !path.contains(p) { path.append(p) }
        env["PATH"] = path.joined(separator: ":")
        if env["HOME"] == nil { env["HOME"] = homeDirectory }
        // A token set explicitly in the environment (e.g. `sb` from a shell, tests) wins over the Keychain one.
        if (env["CLAUDE_CODE_OAUTH_TOKEN"] ?? "").isEmpty, let token = ClaudeSetup.loadToken() {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
        }
        // Running from inside another Claude Code session must not look like a nested one.
        env.removeValue(forKey: "CLAUDECODE")
        return env
    }
}

// MARK: - Process

private final class ClaudeProcess: @unchecked Sendable {
    private let process = Process()
    private let prompt: String
    private var parser: ClaudeStreamParser
    private let continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation
    private let lock = NSLock()
    private var stderrTail = Data()
    private var terminated = false

    private static let running = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: ClaudeProcess] = [:]

    static func terminateAll() {
        running.lock()
        let all = Array(live.values)
        running.unlock()
        all.forEach { $0.terminate() }
    }

    init(arguments: [String], prompt: String, cwd: URL, parser: ClaudeStreamParser,
         continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation) {
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        self.prompt = prompt
        self.parser = parser
        self.continuation = continuation
    }

    func start(binary: URL) {
        process.executableURL = binary
        process.environment = ClaudeRunner.environment()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        lock.lock()
        defer { lock.unlock() }
        // Cancelled before it even started (e.g. the user closed the chat right away).
        guard !terminated else {
            continuation.finish(throwing: CancellationError())
            return
        }
        do {
            try process.run()
        } catch {
            continuation.finish(throwing: ClaudeError.notInstalled)
            return
        }
        Self.running.lock()
        Self.live[ObjectIdentifier(self)] = self
        Self.running.unlock()
        Log.info("claude started pid=\(process.processIdentifier) args=\(process.arguments ?? [])")

        DispatchQueue.global(qos: .utility).async { [prompt] in
            try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try? stdin.fileHandleForWriting.close()
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stderr.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                self.lock.lock()
                self.stderrTail.append(data)
                if self.stderrTail.count > 16_384 { self.stderrTail = self.stderrTail.suffix(16_384) }
                self.lock.unlock()
            }
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = stdout.fileHandleForReading
            var buffer = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    self.consume(line)
                }
            }
            if !buffer.isEmpty { self.consume(buffer) }
            group.leave()
        }

        DispatchQueue.global(qos: .utility).async {
            group.wait()
            self.process.waitUntilExit()
            Self.running.lock()
            Self.live[ObjectIdentifier(self)] = nil
            Self.running.unlock()
            self.finish()
        }
    }

    private func consume(_ line: Data) {
        guard let text = String(data: line, encoding: .utf8) else { return }
        lock.lock()
        let events = parser.consume(line: text)
        lock.unlock()
        for event in events { continuation.yield(event) }
    }

    private func finish() {
        lock.lock()
        let stderr = String(decoding: stderrTail, as: UTF8.self)
        let wasTerminated = terminated
        let parser = self.parser
        lock.unlock()
        let status = process.terminationStatus
        Log.info("claude exited status=\(status) result=\(parser.result != nil) error=\(parser.isError)")
        if wasTerminated {
            continuation.finish(throwing: CancellationError())
            return
        }
        switch parser.outcome(exitStatus: status, stderr: stderr) {
        case .success(let event):
            continuation.yield(event)
            continuation.finish()
        case .failure(let error):
            if case .failed(let msg) = error { Log.error("claude failed: \(msg)") }
            continuation.finish(throwing: error)
        }
    }

    func terminate() {
        lock.lock()
        terminated = true
        let running = process.isRunning
        lock.unlock()
        if running {
            process.terminate()
            Log.info("claude cancelled pid=\(process.processIdentifier)")
        }
    }
}

// MARK: - stream-json parsing

/// Turns stream-json lines into `ClaudeEvent`s and decides how the run ended.
struct ClaudeStreamParser {
    let vaultURL: URL
    let lang: Lang
    private(set) var result: String?
    private(set) var isError = false
    private(set) var errorSubtype: String?
    private(set) var apiErrorStatus: Int?
    private(set) var rejectedResetAt: Date?
    private(set) var rateLimitRejected = false
    private(set) var plainOutput = ""

    init(vaultURL: URL, language: String) {
        self.vaultURL = vaultURL
        self.lang = Lang(language)
    }

    mutating func consume(line: String) -> [ClaudeEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            plainOutput += trimmed + "\n"
            return []
        }
        switch obj["type"] as? String {
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            var events: [ClaudeEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { events.append(.text(text)) }
                case "tool_use":
                    let name = block["name"] as? String ?? "?"
                    events.append(.tool(name: name, detail: toolDetail(name: name, input: block["input"] as? [String: Any] ?? [:])))
                default: break
                }
            }
            return events
        case "rate_limit_event":
            if let info = obj["rate_limit_info"] as? [String: Any], (info["status"] as? String) == "rejected" {
                rateLimitRejected = true
                if let ts = info["resetsAt"] as? Double { rejectedResetAt = Date(timeIntervalSince1970: ts) }
            }
            return []
        case "result":
            result = obj["result"] as? String ?? (obj["errors"] as? [String])?.joined(separator: "\n") ?? ""
            isError = obj["is_error"] as? Bool ?? false
            errorSubtype = obj["subtype"] as? String
            apiErrorStatus = obj["api_error_status"] as? Int
            return []
        default:
            return []
        }
    }

    func toolDetail(name: String, input: [String: Any]) -> String {
        func rel(_ key: String) -> String {
            guard let p = input[key] as? String else { return "" }
            return URL(fileURLWithPath: p).relativePath(from: vaultURL) ?? p
        }
        switch name {
        case "Read": return lang.t("Leyendo ", "Reading ") + rel("file_path")
        case "Write": return lang.t("Escribiendo ", "Writing ") + rel("file_path")
        case "Edit", "MultiEdit": return lang.t("Editando ", "Editing ") + rel("file_path")
        case "Glob": return lang.t("Buscando archivos ", "Looking for files ") + (input["pattern"] as? String ?? "")
        case "Grep": return lang.t("Buscando “", "Searching for “") + (input["pattern"] as? String ?? "") + "”"
        default: return name
        }
    }

    enum Outcome { case success(ClaudeEvent), failure(ClaudeError) }

    func outcome(exitStatus: Int32, stderr: String, now: Date = Date()) -> Outcome {
        let failed = isError || exitStatus != 0 || result == nil
        let diagnostics = [isError ? result ?? "" : "", stderr, plainOutput].joined(separator: "\n")
        if failed {
            if rateLimitRejected || apiErrorStatus == 429 || Self.looksRateLimited(diagnostics) {
                return .failure(.rateLimited(resetAt: rejectedResetAt ?? Self.parseReset(diagnostics, now: now)))
            }
            if apiErrorStatus == 401 || Self.looksUnauthenticated(diagnostics) { return .failure(.notAuthenticated) }
        }
        if let result { return .success(.done(result: result, isError: isError)) }
        let tail = String((stderr.isEmpty ? plainOutput : stderr).suffix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(.failed(tail.isEmpty ? "claude exited with status \(exitStatus)" : tail))
    }

    static func looksRateLimited(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["usage limit", "rate limit", "rate_limit", "limit reached", "429", "too many requests", "out of extra usage"]
            .contains { t.contains($0) }
    }

    static func looksUnauthenticated(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["not logged in", "invalid api key", "invalid token", "/login", "please log in", "authentication_error",
                "oauth token has expired", "token expired", "unauthorized"]
            .contains { t.contains($0) }
    }

    /// Finds a reset moment in limit messages: `…|1793041200`, `resets at 3pm`, `resets 15:30`.
    static func parseReset(_ text: String, now: Date = Date()) -> Date? {
        if let m = text.range(of: #"\|\s*(\d{10})\b"#, options: .regularExpression) {
            let digits = text[m].filter(\.isNumber)
            if let ts = Double(digits) { return Date(timeIntervalSince1970: ts) }
        }
        let pattern = #"(?i)resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        guard var hour = group(1).flatMap(Int.init) else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        if let ampm = group(3)?.lowercased() {
            if ampm == "pm", hour < 12 { hour += 12 }
            if ampm == "am", hour == 12 { hour = 0 }
        } else if group(2) == nil {
            return nil   // a bare number is too ambiguous
        }
        guard hour < 24, minute < 60 else { return nil }
        let cal = Calendar.current
        guard let today = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today)
    }
}
