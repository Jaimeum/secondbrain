import Foundation

// MARK: - Slugs

/// ASCII-folds accents, lowercases, joins words with dashes and caps the length (default 50).
public func slugify(_ text: String, maxLength: Int = 50) -> String {
    var s = text.applyingTransform(.toLatin, reverse: false) ?? text
    s = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    s = s.lowercased()
    var out = ""
    var lastDash = true
    for scalar in s.unicodeScalars {
        if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
            out.unicodeScalars.append(scalar)
            lastDash = false
        } else if !lastDash {
            out.append("-")
            lastDash = true
        }
    }
    if out.count > maxLength { out = String(out.prefix(maxLength)) }
    while out.hasSuffix("-") { out.removeLast() }
    return out
}

// MARK: - Localized strings used by the engine (UI strings live in the app)

struct Lang: Sendable {
    let en: Bool
    init(_ code: String) { en = code.lowercased().hasPrefix("en") }

    func t(_ es: String, _ en: String) -> String { self.en ? en : es }

    func meSpeaker() -> String { t("Yo", "Me") }
    func speaker(_ n: String) -> String { t("Hablante \(n)", "Speaker \(n)") }
    func defaultMeetingTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return t("Reunión ", "Meeting ") + f.string(from: date)
    }
    func learnedFrom(_ title: String) -> String { t("Aprendió de: \(title)", "Learned from: \(title)") }
    func lintTitle(_ scope: String?) -> String {
        scope.map { t("Revisión del cerebro: \($0)", "Brain check-up: \($0)") } ?? t("Revisión del cerebro", "Brain check-up")
    }
    func savedAnswer(_ q: String) -> String {
        let short = q.count > 60 ? String(q.prefix(57)) + "…" : q
        return t("Guardó la respuesta: \(short)", "Saved answer: \(short)")
    }
}

// MARK: - Frontmatter

enum Frontmatter {
    /// Splits `---\nyaml\n---\nbody`. Returns nil yaml when there is no frontmatter.
    static func split(_ text: String) -> (yaml: String?, body: String) {
        let normalized = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard normalized.hasPrefix("---\n") || normalized.hasPrefix("---\r\n") else { return (nil, normalized) }
        let lines = normalized.components(separatedBy: "\n")
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            let yaml = lines[1..<i].joined(separator: "\n")
            var body = lines[(i + 1)...].joined(separator: "\n")
            while body.hasPrefix("\n") { body.removeFirst() }
            return (yaml, body)
        }
        return (nil, normalized)
    }

    static func strip(_ text: String) -> String { split(text).body }

    /// Value of a top-level scalar key, unquoted. `null`/`~`/empty → nil.
    static func field(_ key: String, in text: String) -> String? {
        guard let yaml = split(text).yaml else { return nil }
        for line in yaml.components(separatedBy: "\n") where line.hasPrefix(key + ":") {
            var value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            // Quoted: up to the closing quote (a " #" inside is text, e.g. `subject: "Factura #123"`, not a comment).
            if let q = value.first, q == "\"" || q == "'" {
                var out = "", escaped = false, closed = false
                let inner = q == "'" && value.count > 2 ? value.dropFirst().replacingOccurrences(of: "''", with: "\u{0}") : String(value.dropFirst())
                for ch in inner {
                    if ch == "\u{0}" { out.append("'"); continue }   // YAML single-quote escape ''
                    if escaped { out.append(ch); escaped = false; continue }
                    if q == "\"", ch == "\\" { escaped = true; continue }
                    if ch == q { closed = true; break }
                    out.append(ch)
                }
                if closed { return out.isEmpty ? nil : out }
            }
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
                if f == "\"" { value = value.replacingOccurrences(of: "\\\"", with: "\"") }
            }
            return value.isEmpty || value == "null" || value == "~" ? nil : value
        }
        return nil
    }

    /// Replaces (or inserts) a top-level `key: value` line. `value` must already be YAML-formatted.
    static func setField(_ key: String, to value: String, in text: String) -> String {
        let parts = split(text)
        guard let yaml = parts.yaml else { return "---\n\(key): \(value)\n---\n\n" + text }
        var lines = yaml.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
            lines[i] = "\(key): \(value)"
        } else {
            lines.append("\(key): \(value)")
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n\n" + parts.body
    }
}

enum YAML {
    /// A YAML scalar, quoted only when needed.
    static func scalar(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "null" }
        let special = CharacterSet(charactersIn: ":#{}[],&*?|<>=!%@`\"'\\\n")
        let reserved = ["null", "true", "false", "yes", "no", "~"]
        let needsQuotes = s.rangeOfCharacter(from: special) != nil
            || s.first == " " || s.last == " " || s.first == "-"
            || reserved.contains(s.lowercased()) || Double(s) != nil
        return needsQuotes ? quoted(s) : s
    }

    static func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    static func list(_ items: [String]) -> String { "[" + items.map(quoted).joined(separator: ", ") + "]" }
}

// MARK: - Dates & ids

enum Fmt {
    static func iso8601Local(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func local(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f.string(from: date)
    }

    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}

// MARK: - Files

extension FileManager {
    /// `base/name.ext`, or `base/name-2.ext`, `-3`… if taken.
    func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var url = dir.appendingPathComponent(name + suffix)
        var n = 2
        while fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name)-\(n)\(suffix)")
            n += 1
        }
        return url
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

extension URL {
    /// Path of `self` relative to `base`, or nil when outside it.
    func relativePath(from base: URL) -> String? {
        // /private is only stripped from paths that exist, so normalize it by hand too.
        func variants(_ u: URL) -> [String] {
            [u.path, u.standardizedFileURL.path, u.resolvingSymlinksInPath().path].flatMap { p in
                p.hasPrefix("/private/") ? [p, String(p.dropFirst("/private".count))] : [p]
            }
        }
        let candidates = variants(base)
        let paths = variants(self)
        for b in candidates {
            let prefix = b.hasSuffix("/") ? b : b + "/"
            for p in paths where p.hasPrefix(prefix) { return String(p.dropFirst(prefix.count)) }
        }
        return nil
    }
}

// MARK: - Logging

/// Append-only log at data/logs/secondbrain.log, rotated to `.1` past 5 MB.
public enum Log {
    private static let queue = DispatchQueue(label: "app.secondbrain.log")
    nonisolated(unsafe) private static var fileURL: URL?

    nonisolated(unsafe) private static var flushAtExit = false

    public static func configure(logsDir: URL) {
        queue.sync {
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            fileURL = logsDir.appendingPathComponent("secondbrain.log")
            if !flushAtExit {
                flushAtExit = true
                atexit { Log.flush() }   // short-lived `sb` commands exit before queued lines are written
            }
        }
    }

    /// Waits until every queued line is written.
    public static func flush() { queue.sync {} }

    public static func info(_ message: String) { write("INFO", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            guard let url = fileURL, let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
