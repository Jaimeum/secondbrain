import CryptoKit
import Foundation

/// What `VaultStore.migrateIfNeeded()` did (CONTRACT §11.6).
public struct VaultMigration: Sendable, Equatable {
    public var fromVersion: Int          // 0 = fresh install
    public var toVersion: Int
    public var copied: [String]          // files that were missing and got added
    public var updatedCommands: [String] // app-owned files refreshed (.claude/commands, built-in templates)
    public var replacedClaudeMd: Bool
    /// The user had edited CLAUDE.md: it was kept and the new manual was written to this file (vault-relative).
    public var pendingManual: String?
}

public extension VaultStore {
    /// SHA256 of every CLAUDE.md the app ever shipped. A vault whose CLAUDE.md matches one was not edited by the
    /// user, so it can be replaced. (v0.1: commit 009517c, unchanged until 39ee3c2; then 1756d9f and 2e4fc40, the
    /// manual up to template v4 — v0.6 also recognises those when `.secondbrain/claude-md.sha256` is missing.)
    static let shippedClaudeMdHashes: Set<String> = [
        "6d0a92b551f4ca7ddec3a92e8ace3e5acb6335db078d69cd485f090c0d978a47",
        "e00dd97bf2e250ef7b10db97bc9dd8cff71ae519b3531cfe54a205253ddcd5f7",
        "72d77ea50d0315632c382075f856deb4dccef267b1ffec282e1031bbb19a1618",
    ]
    static let stateDir = ".secondbrain"
    static let versionFile = ".secondbrain/template-version"
    /// Hash of the CLAUDE.md the app installed last (so later app versions can recognise an unedited one).
    static let installedClaudeHashFile = ".secondbrain/claude-md.sha256"
    /// `{"templates/<id>.md": sha256}` of the built-in templates as installed (hand-edited ones are then left alone).
    static let installedTemplatesFile = ".secondbrain/builtin-templates.json"

    /// Version of the bundled template (`vault-template/vault/.secondbrain/template-version`).
    static var bundledTemplateVersion: Int {
        guard let url = templateURL?.appendingPathComponent("vault/\(versionFile)"),
              let text = try? String(contentsOf: url, encoding: .utf8), let v = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 1 }
        return v
    }

    /// Kept for v0.1 callers: same as `migrateIfNeeded()`.
    func installTemplateIfNeeded() throws {
        _ = try migrateIfNeeded()
    }

    /// Installs the template into an empty vault, or upgrades an older one:
    /// - copies files that are missing (new commands, `templates/`, `_inbox/emails/`, v0.6 `facts.md` and `orgs/`, and
    ///   per project `wiki/timeline.md`, `wiki/emails/`, `raw/emails/`); existing wiki pages are never touched;
    /// - always refreshes app-owned files: `.claude/commands/*` and built-in templates (`builtin: true`);
    /// - CLAUDE.md: replaced when it is one the app shipped (unedited); otherwise kept, and the new one is written
    ///   as `CLAUDE.v<N>.md` next to it (`pendingManual`).
    @discardableResult
    func migrateIfNeeded() throws -> VaultMigration {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let templateRoot = Self.templateURL, fm.isDirectory(templateRoot.appendingPathComponent("vault")) else {
            Log.error("vault template not found in bundle")
            return VaultMigration(fromVersion: 0, toVersion: 0, copied: [], updatedCommands: [], replacedClaudeMd: false)
        }
        let template = templateRoot.appendingPathComponent("vault")
        let target = Self.bundledTemplateVersion
        let claude = url(for: "CLAUDE.md")
        let bundledClaude = template.appendingPathComponent("CLAUDE.md")
        var result = VaultMigration(fromVersion: 0, toVersion: target, copied: [], updatedCommands: [], replacedClaudeMd: false)

        // Fresh vault.
        guard fm.fileExists(atPath: claude.path) else {
            result.copied = try Self.copyMissing(from: template, to: root)
            _ = try refreshAppOwned(from: template)   // records the built-in templates as installed
            for dir in ["_inbox/meetings", "_inbox/docs", "_inbox/notes", "_inbox/emails", "projects", "people", "orgs", "templates"] {
                try fm.createDirectory(at: url(for: dir), withIntermediateDirectories: true)
            }
            try writeState(version: target, claudeHash: Self.sha256(bundledClaude))
            Log.info("installed vault template v\(target) into \(root.path)")
            return result
        }

        let current = (try? String(contentsOf: url(for: Self.versionFile), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        result.fromVersion = current

        // App-owned files: always current.
        result.updatedCommands = try refreshAppOwned(from: template)

        // CLAUDE.md.
        let vaultHash = Self.sha256(claude)
        let bundledHash = Self.sha256(bundledClaude)
        let installedHash = (try? String(contentsOf: url(for: Self.installedClaudeHashFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manualName = "CLAUDE.v\(target).md"
        if let bundledHash, vaultHash != bundledHash {
            if let vaultHash, Self.shippedClaudeMdHashes.contains(vaultHash) || vaultHash == installedHash {
                try Data(contentsOf: bundledClaude).write(to: claude, options: .atomic)
                result.replacedClaudeMd = true
                try? fm.removeItem(at: url(for: manualName))
                Log.info("CLAUDE.md updated to template v\(target)")
            } else {
                let manual = url(for: manualName)
                if Self.sha256(manual) != bundledHash {
                    try Data(contentsOf: bundledClaude).write(to: manual, options: .atomic)
                    Log.info("CLAUDE.md was edited by the user: new manual written to \(manualName)")
                }
                result.pendingManual = manualName
            }
        } else if fm.fileExists(atPath: url(for: manualName).path) {
            try? fm.removeItem(at: url(for: manualName))   // the user adopted the new manual
        }

        if current < target {
            result.copied += try Self.copyMissing(from: template, to: root, skip: ["CLAUDE.md"])
            try fm.createDirectory(at: url(for: "_inbox/emails"), withIntermediateDirectories: true)
            result.copied += try addMissingProjectFiles()
        }
        let claudeHashToRecord = result.pendingManual == nil ? bundledHash : installedHash
        try writeState(version: max(current, target), claudeHash: claudeHashToRecord)
        if current < target { Log.info("vault migrated from template v\(current) to v\(target)") }
        return result
    }

    // MARK: Internals

    private func writeState(version: Int, claudeHash: String?) throws {
        try FileManager.default.createDirectory(at: url(for: Self.stateDir), withIntermediateDirectories: true)
        try "\(version)\n".write(to: url(for: Self.versionFile), atomically: true, encoding: .utf8)
        if let claudeHash { try "\(claudeHash)\n".write(to: url(for: Self.installedClaudeHashFile), atomically: true, encoding: .utf8) }
    }

    /// `.claude/commands/*` (overwritten when different) and built-in templates (added when missing, refreshed
    /// while still `builtin: true`; the user's copies are never touched).
    private func refreshAppOwned(from template: URL) throws -> [String] {
        let fm = FileManager.default
        var changed: [String] = []
        // Built-in templates as the app last installed them: one the user edited by hand (still `builtin: true`)
        // no longer matches and is kept.
        let installedURL = url(for: Self.installedTemplatesFile)
        var installed = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: installedURL))) ?? [:]
        let installedBefore = installed
        for sub in [".claude/commands", Self.templatesDir] {
            let dir = template.appendingPathComponent(sub)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".md") {
                let src = dir.appendingPathComponent(name)
                let rel = "\(sub)/\(name)"
                let dest = url(for: rel)
                let srcHash = Self.sha256(src)
                if fm.fileExists(atPath: dest.path) {
                    let destHash = Self.sha256(dest)
                    if sub == Self.templatesDir {
                        guard Frontmatter.field("builtin", in: (try? String(contentsOf: dest, encoding: .utf8)) ?? "")?.lowercased() == "true"
                        else { continue }
                        if destHash == srcHash { installed[rel] = srcHash; continue }
                        if let recorded = installed[rel], recorded != destHash {
                            Log.info("built-in template \(rel) was edited by hand: kept")
                            continue
                        }
                    }
                    guard destHash != srcHash else { continue }
                }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: src).write(to: dest, options: .atomic)
                if sub == Self.templatesDir { installed[rel] = srcHash }
                changed.append(rel)
            }
        }
        if installed != installedBefore {
            try fm.createDirectory(at: url(for: Self.stateDir), withIntermediateDirectories: true)
            try JSONEncoder().encode(installed).write(to: installedURL, options: .atomic)
        }
        return changed
    }

    /// New per-project files (timeline.md, emails folders…) for every existing project; existing files untouched.
    private func addMissingProjectFiles() throws -> [String] {
        let fm = FileManager.default
        guard let template = Self.templateURL?.appendingPathComponent("project"), fm.isDirectory(template) else { return [] }
        var added: [String] = []
        let pm = ProjectManager(vaultRoot: root)
        for project in pm.list() {
            let fill = ProjectManager.placeholderFiller(name: project.name, slug: project.slug, description: project.description,
                                                        date: Fmt.local(Date(), "yyyy-MM-dd"))
            let dest = url(for: "projects/\(project.slug)")
            added += try Self.copyMissing(from: template, to: dest, transform: fill).map { "projects/\(project.slug)/\($0)" }
        }
        return added
    }

    /// Copies files that don't exist at the destination; returns their relative paths.
    static func copyMissing(from src: URL, to dest: URL, skip: Set<String> = [], transform: ((String) -> String)? = nil) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var copied: [String] = []
        for case let url as URL in walker {
            guard let rel = url.relativePath(from: src), url.lastPathComponent != ".DS_Store", !skip.contains(rel) else { continue }
            let target = dest.appendingPathComponent(rel)
            if fm.isDirectory(url) {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let transform, url.pathExtension == "md", let text = try? String(contentsOf: url, encoding: .utf8) {
                try transform(text).write(to: target, atomically: true, encoding: .utf8)
            } else {
                try fm.copyItem(at: url, to: target)
            }
            copied.append(rel)
        }
        return copied
    }

    static func sha256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
