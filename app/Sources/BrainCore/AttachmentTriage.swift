import Foundation

// v0.7 (CONTRACT §17.1): what to do with each attachment of a saved email. Deterministic rules first; what they can't
// tell goes to Claude for mail saved going forward (`.claude/commands/triage-attachments.md`) and to the user's
// checkboxes for mail saved by hand (backwards).

/// Why an attachment was not kept. `claude` carries Claude's own words; `user` = unticked in the save sheet.
public enum DiscardReason: Codable, Hashable, Sendable {
    case inlineImage      // inline, referenced by `cid:` in the HTML, < 100 KB (logos, signatures)
    case smallImage       // any image < 20 KB
    case junkName         // image001.png, logo*, signature*, firma*, outlook*, banner*
    case junkType         // .ics, .vcf, winmail.dat, smime.p7s
    case duplicate        // same SHA-256 as a file already saved in the project
    case claude(String)
    case user
}

/// The triage's verdict. `ask` = ambiguous (Claude decides going forward; the checkbox starts ticked backwards).
/// `tooBig` (> 25 MB) is never downloaded by itself ("Guardar de todos modos").
public enum AttachmentDecision: Codable, Hashable, Sendable {
    case keep
    case discard(DiscardReason)
    case ask
    case tooBig

    /// Whether the backwards save sheet starts with its checkbox ticked (keep ✓, ambiguous ✓, the rest ☐).
    public var preselected: Bool {
        switch self {
        case .keep, .ask: true
        case .discard, .tooBig: false
        }
    }
}

public enum AttachmentTriage {
    /// Above this an attachment is `tooBig`: listed, never downloaded by itself.
    public static let maxAutoBytes = 25 * 1024 * 1024
    /// Inline images referenced by the HTML body under this are logos/signatures.
    public static let inlineJunkBytes = 100 * 1024
    /// Any image under this is junk.
    public static let smallImageBytes = 20 * 1024

    /// What the rules know besides the attachment itself.
    public struct Context: Sendable {
        /// `cid:` ids the HTML body references (lowercased, no angle brackets); nil = unknown.
        public var inlineContentIds: Set<String>?
        /// SHA-256 (hex) of the downloaded bytes, when already downloaded.
        public var sha256: String?
        /// SHA-256 of every file already saved in the destination project (or `_inbox`).
        public var savedHashes: Set<String>
        public init(inlineContentIds: Set<String>? = nil, sha256: String? = nil, savedHashes: Set<String> = []) {
            self.inlineContentIds = inlineContentIds; self.sha256 = sha256; self.savedHashes = savedHashes
        }
    }

    /// §17.1 rules, in order: > 25 MB → tooBig; obvious junk → discard; documents → keep; anything else → ask.
    // v0.7: filled in by attach (stub: everything is ambiguous).
    public static func classify(_ attachment: AttachmentInfo, context: Context = Context()) -> AttachmentDecision {
        .ask
    }
}
