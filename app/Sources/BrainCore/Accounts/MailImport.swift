import Foundation

/// Mail from a connected account → the existing email pipeline (CONTRACT §12.3/§12.4). No copy/paste: a
/// `MailMessageFull` becomes a `ParsedEmail` (new text and quoted history split with `EmailParser`), and is stored
/// with `externalId = "<provider>:<messageId>"` so the Correo screen knows what is already in the brain.
public enum MailImport {
    /// `"<provider>:<messageId>"` (CONTRACT §12.3).
    public static func externalId(account: ConnectedAccount, messageId: String) -> String {
        "\(account.provider.rawValue):\(messageId)"
    }

    /// The message as the pipeline expects it. `isFromOwner` = sender ∈ `ownerEmails` ∪ {account email}.
    /// `language` picks the header names of `raw` (De/Para/CC/Fecha/Asunto or From/To/Cc/Date/Subject).
    public static func parsedEmail(_ message: MailMessageFull, account: ConnectedAccount?, ownerEmails: [String],
                                   language: String = "es") -> ParsedEmail {
        let s = message.summary
        let split = splitBody(message.bodyText)
        var owners = Set(ownerEmails.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        if let account, account.provider.hasMail { owners.insert(account.email.lowercased()) }
        let subject = s.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedEmail(subject: subject.isEmpty ? nil : subject, from: s.from, to: s.to, cc: message.cc, date: s.date,
                           body: split.body, quotedHistory: split.quoted, raw: render(message, language: language),
                           isFromOwner: s.from.email.map { owners.contains($0.lowercased()) } ?? false)
    }

    /// New text vs. quoted/forwarded history ("El … escribió:", "On … wrote:", "-----Original Message-----", "> …").
    public static func splitBody(_ text: String) -> (body: String, quoted: String?) {
        let lines = EmailParser.normalize(text).components(separatedBy: "\n")
        guard let q = EmailParser.quoteStart(lines) else {
            return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let body = lines[..<q].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = lines[q...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, quoted.isEmpty ? nil : quoted)
    }

    /// Plain-text rendering with headers, so the message reads like an email anywhere.
    public static func render(_ message: MailMessageFull, language: String = "es") -> String {
        let l = Lang(language)
        let s = message.summary
        var lines = [l.t("De", "From") + ": " + EmailParser.format(s.from)]
        if !s.to.isEmpty { lines.append(l.t("Para", "To") + ": " + s.to.map(EmailParser.format).joined(separator: ", ")) }
        if !message.cc.isEmpty { lines.append(l.t("CC", "Cc") + ": " + message.cc.map(EmailParser.format).joined(separator: ", ")) }
        lines.append(l.t("Fecha", "Date") + ": " + SBDate.iso(s.date))
        lines.append(l.t("Asunto", "Subject") + ": " + s.subject)
        return (lines + ["", message.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)]).joined(separator: "\n")
    }
}

// MARK: - Known people ("Conocidos")

/// Who already has a page in `people/*.md` (frontmatter `title`, `aliases`, and any address on the page's
/// `Correo`/`Email` lines). Cheap: one read per person page. Safe off the main thread.
public struct KnownPeople: Sendable, Equatable {
    public private(set) var emails: Set<String> = []
    public private(set) var names: Set<String> = []
    /// Person pages found (0 = nobody known yet: the Correo filter starts on "Todos").
    public private(set) var pageCount = 0

    public init() {}

    public static func scan(_ vault: VaultStore) -> KnownPeople {
        var out = KnownPeople()
        for page in vault.pages(projectSlug: nil) where page.path.hasPrefix("people/") {
            guard let text = try? vault.read(page.path) else { continue }
            out.pageCount += 1
            out.add(name: Frontmatter.field("title", in: text) ?? page.title)
            out.add(name: ((page.path as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " "))
            let yaml = Frontmatter.split(text).yaml ?? ""
            for line in yaml.components(separatedBy: "\n") where line.hasPrefix("aliases:") {
                for alias in Self.listItems(String(line.dropFirst("aliases:".count))) { out.add(name: alias) }
            }
            // Addresses anywhere in the frontmatter or on "- **Correo:** …" lines of the body.
            let mailLines = text.components(separatedBy: "\n").filter {
                let l = $0.lowercased()
                return l.contains("correo") || l.contains("email") || l.hasPrefix("aliases:")
            }
            for line in [yaml] + mailLines { out.addAddresses(in: line) }
        }
        return out
    }

    /// The sender has a person page (by address, or by full name when the name has at least two words).
    public func contains(_ address: EmailAddress) -> Bool {
        if let email = address.email?.lowercased(), emails.contains(email) { return true }
        if let name = address.name.map(Self.fold), name.split(separator: " ").count >= 2, names.contains(name) { return true }
        return false
    }

    mutating func add(name: String) {
        let raw = name.trimmingCharacters(in: .whitespaces)
        if raw.contains("@") { addAddresses(in: raw); return }
        let n = Self.fold(raw)
        if n.split(separator: " ").count >= 2 { names.insert(n) }
    }

    mutating func addAddresses(in s: String) {
        let re = #/[A-Za-z0-9._%+'\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#
        for m in s.matches(of: re) { emails.insert(String(m.output).lowercased()) }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `["Ana", "ana@x.com"]` or `Ana, Ana G.` → items.
    static func listItems(_ s: String) -> [String] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Engine

public extension BrainEngine {
    /// Adds messages of a connected account to the brain, oldest first, as one thread. Messages already in the brain
    /// (same `externalId`, or an exact duplicate of a pasted one) are skipped. `threadKey`: an existing thread to
    /// continue (nil = a new one, unless one of these messages is already stored: then its thread is continued).
    /// Returns the sources created (empty when everything was already there).
    @discardableResult
    func addMailMessages(_ messages: [MailMessageFull], account: ConnectedAccount, threadKey: String?,
                         projectSlug: String?) throws -> [SourceRecord] {
        let owners = vault.ownerEmails()
        let ordered = messages.sorted { $0.summary.date < $1.summary.date }
        // v0.7 (§17.4): the provider's conversation id decides first — mail of a conversation already saved always
        // joins that thread (over the subject heuristic); then a message of this batch already stored.
        let folders = Set(vault.threadFolders().map { ($0 as NSString).lastPathComponent })
        var key = threadKey
            ?? ordered.lazy.compactMap { self.vault.threadKey(accountId: account.id, providerThreadId: $0.summary.threadId) }.first
            ?? ordered.lazy
            .compactMap { self.emailSource(externalId: MailImport.externalId(account: account, messageId: $0.summary.id))?.threadKey }
            .first { folders.contains($0) }
        var added: [SourceRecord] = []
        var firstError: Error?
        for message in ordered {
            let externalId = MailImport.externalId(account: account, messageId: message.summary.id)
            guard emailSource(externalId: externalId) == nil else { continue }
            let email = MailImport.parsedEmail(message, account: account, ownerEmails: owners, language: config.uiLanguage)
            // A batch mixing conversations: a message of another saved conversation goes to its own thread.
            let own = threadKey == nil ? vault.threadKey(accountId: account.id, providerThreadId: message.summary.threadId) : nil
            let origin = MailOrigin(accountId: account.id, providerThreadId: message.summary.threadId,
                                    webLink: message.summary.webLink)
            do {
                let src = try addEmail(email, threadKey: own ?? key, projectSlug: projectSlug, externalId: externalId,
                                       origin: origin)
                if own == nil || own == key { key = src.threadKey }
                added.append(src)
            } catch EngineError.duplicateEmail {
                continue
            } catch {
                // An empty message (only an attachment) must not stop the rest of the conversation.
                if firstError == nil { firstError = error }
            }
        }
        if added.isEmpty, let firstError { throw firstError }
        return added
    }
}
