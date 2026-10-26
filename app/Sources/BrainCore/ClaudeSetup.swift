import Foundation
import Security

/// Onboarding helpers: find/install the Claude CLI, check auth and keep the OAuth token in the Keychain.
public enum ClaudeSetup {
    static let keychainService = "app.secondbrain.mac"
    static let keychainAccount = "claude-oauth-token"

    public static func locate(config: AppConfig) -> URL? {
        let fm = FileManager.default
        if let custom = config.claudePath, !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        for dir in ClaudeRunner.extraPathDirs {
            let path = dir + "/claude"
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let found = runSync("/bin/zsh", ["-lc", "command -v claude"], timeout: 10)
        let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        if found.status == 0, path.hasPrefix("/"), fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    /// Runs the official installer (`curl -fsSL https://claude.ai/install.sh | bash`), streaming its output.
    public static func install(log: @escaping @Sendable (String) -> Void) async throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "curl -fsSL https://claude.ai/install.sh | bash"]
        process.environment = ClaudeRunner.environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) where !line.isEmpty {
                log(line)
            }
        }
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        guard status == 0, let url = locate(config: .default) else {
            throw ClaudeError.failed("Installer exited with status \(status)")
        }
        return url
    }

    /// True when a tiny `claude -p` call succeeds (90 s timeout).
    public static func checkAuth(config: AppConfig) async -> Bool {
        guard let binary = locate(config: config) else { return false }
        return await Task.detached {
            let result = runSync(binary.path, ["-p", "Responde solo: ok", "--model", "haiku", "--output-format", "json",
                                               "--tools", "", "--strict-mcp-config"],
                                 timeout: 90, cwd: FileManager.default.temporaryDirectory)
            guard result.status == 0,
                  let line = result.output.components(separatedBy: "\n").last(where: { $0.hasPrefix("{") }),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return false }
            return (obj["is_error"] as? Bool) == false
        }.value
    }

    // MARK: Keychain

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    public static func saveToken(_ token: String) throws {
        let data = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ClaudeError.failed("Keychain error \(update)") }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClaudeError.failed("Keychain error \(status)") }
    }

    public static func loadToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    /// Removes the stored token (e.g. "disconnect Claude").
    public static func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// Pulls the last `sk-ant-oat…` token out of terminal output, tolerating ANSI codes and hard line wraps.
    public static func extractToken(from terminalOutput: String) -> String? {
        let clean = terminalOutput
            .replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\u{1B}\][^\u{07}]*\u{07}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let tokenChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard let start = clean.range(of: "sk-ant-oat", options: .backwards) else { return nil }
        var token = ""
        let lines = String(clean[start.lowerBound...]).components(separatedBy: "\n")
        for (i, rawLine) in lines.enumerated() {
            let line = i == 0 ? rawLine : rawLine.trimmingCharacters(in: .whitespaces)
            // A wrapped continuation is a non-empty line made only of token characters.
            if i > 0 && (line.isEmpty || line.unicodeScalars.contains { !tokenChars.contains($0) }) { break }
            let prefix = line.unicodeScalars.prefix { tokenChars.contains($0) }
            token += String(String.UnicodeScalarView(prefix))
            if prefix.count < line.unicodeScalars.count { break }
        }
        return token.count > "sk-ant-oat".count + 10 ? token : nil
    }

    // MARK: Helpers

    static func runSync(_ path: String, _ args: [String], timeout: TimeInterval, cwd: URL? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ClaudeRunner.environment()
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
