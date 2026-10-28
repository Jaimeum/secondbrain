import Foundation

// v0.6 "Captura rápida" (CONTRACT §16.10): one multiline field that tells by itself what was typed or pasted. A single
// URL becomes a link, text with mail headers (From:/De: plus another header) becomes an email, anything else a note.
// Pure and synchronous, so the field can re-detect on every keystroke and `sb selftest` can pin the rules.

public enum CaptureKind: Equatable, Sendable {
    case note
    case link(URL)
    case email
}

public enum CaptureDetector {
    public static func detect(_ text: String) -> CaptureKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .note }
        if let url = link(in: trimmed) { return .link(url) }
        if looksLikeEmail(trimmed) { return .email }
        return .note
    }

    /// The whole text is one web address ("https://…", "www.…" or "acme.com/…"); a URL inside a sentence stays a note.
    public static func link(in trimmed: String) -> URL? {
        guard !trimmed.contains(where: \.isWhitespace), trimmed.count <= 4000 else { return nil }
        let lower = trimmed.lowercased()
        let candidate: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            candidate = trimmed
        } else if lower.contains("://") || lower.hasPrefix("mailto:") || trimmed.contains("@") {
            return nil
        } else {
            // A bare host needs a dot and a letter-only top-level domain: "acme.com/x", "www.acme.mx" (not "v0.6", not "e.g.").
            let host = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
                  let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter),
                  labels.dropLast().allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
                  labels.dropLast().contains(where: { $0.contains(where: \.isLetter) })
            else { return nil }
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// Pasted mail: a sender header at the start of a line ("From:" / "De:") with an address, plus another header
    /// (Subject/Asunto, Date/Fecha, To/Para, Sent/Enviado); or Gmail's copy ("Ana <ana@acme.com>" then "para mí").
    public static func looksLikeEmail(_ text: String) -> Bool {
        guard text.count > 20, text.count < 400_000, text.contains("@") else { return false }
        let lines = String(text.prefix(4000)).lowercased().components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let sender = lines.contains { ($0.hasPrefix("from:") || $0.hasPrefix("de:")) && $0.contains("@") }
        let others = ["subject:", "asunto:", "date:", "fecha:", "to:", "para:", "sent:", "enviado:", "cc:"]
        let other = lines.contains { line in others.contains { line.hasPrefix($0) } }
        if sender && other { return true }
        let gmailSender = lines.contains { $0.contains("<") && $0.contains("@") && $0.hasSuffix(">") }
        let gmailTo = lines.contains { $0.hasPrefix("para mí") || $0.hasPrefix("to me") || $0.hasPrefix("para ") && $0.contains("@") }
        return gmailSender && gmailTo
    }

    /// A note's title from what was typed: its first line, shortened to `limit` characters (nil when empty).
    public static func noteTitle(_ text: String, limit: Int = 60) -> String? {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#*-•> ")) ?? ""
        guard !first.isEmpty else { return nil }
        guard first.count > limit else { return first }
        let cut = first.prefix(limit)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces) + "…"
    }
}
