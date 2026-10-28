import CryptoKit
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

    /// Kept without asking (§17.1 step 3).
    public static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "csv", "txt", "md", "rtf", "zip",
    ]
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg",
    ]
    /// Calendar invitations, contact cards, Outlook's TNEF wrapper and S/MIME signatures (§17.1 step 2).
    static let junkExtensions: Set<String> = ["ics", "vcf", "p7s", "p7m", "p7c"]
    static let junkNames: Set<String> = ["winmail.dat", "smime.p7s", "smime.p7m"]
    static let junkMimes: Set<String> = [
        "text/calendar", "text/vcard", "text/x-vcard", "application/ms-tnef", "application/vnd.ms-tnef",
        "application/pkcs7-signature", "application/x-pkcs7-signature", "application/pkcs7-mime",
    ]
    /// Image names that are almost always decoration: `image001.png`, `logo…`, `signature…`, `firma…`, `outlook…`, `banner…`.
    static func isJunkImageName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.firstMatch(of: #/^image\d{3}\./#) != nil { return true }
        return ["logo", "signature", "firma", "outlook", "banner"].contains { n.hasPrefix($0) }
    }

    /// An image by extension or MIME type.
    public static func isImage(_ a: AttachmentInfo) -> Bool {
        imageExtensions.contains(a.fileExtension) || a.mimeType.lowercased().hasPrefix("image/")
    }

    /// A document by extension (or, without one, by a document MIME type).
    public static func isDocument(_ a: AttachmentInfo) -> Bool {
        if documentExtensions.contains(a.fileExtension) { return true }
        guard a.fileExtension.isEmpty else { return false }
        let mime = a.mimeType.lowercased()
        return mime == "application/pdf" || mime.hasPrefix("text/plain") || mime.hasPrefix("text/csv")
            || mime.contains("officedocument") || mime == "application/msword" || mime == "application/vnd.ms-excel"
    }

    /// §17.1 rules, in order: > 25 MB → tooBig; obvious junk → discard; documents → keep; anything else → ask.
    /// `isDownloadable == false` (Graph item/reference attachments) is the caller's: those can't be saved at all.
    public static func classify(_ attachment: AttachmentInfo, context: Context = Context()) -> AttachmentDecision {
        let a = attachment
        if a.size > maxAutoBytes { return .tooBig }
        let image = isImage(a)
        // Inline and shown by the body (`cid:` reference): a logo or a signature. Without the body's references (Graph
        // hands out the text body), the provider's inline flag decides.
        if a.isInline, a.size < inlineJunkBytes, image || a.contentId != nil {
            let referenced: Bool
            if let cid = a.contentId.map(normalizedContentId), let ids = context.inlineContentIds {
                referenced = ids.contains(cid)
            } else {
                referenced = context.inlineContentIds == nil || a.contentId == nil
            }
            if referenced { return .discard(.inlineImage) }
        }
        if image, a.size > 0, a.size < smallImageBytes { return .discard(.smallImage) }
        if image, isJunkImageName(a.name) { return .discard(.junkName) }
        if junkExtensions.contains(a.fileExtension) || junkNames.contains(a.name.lowercased())
            || junkMimes.contains(a.mimeType.lowercased()) {
            return .discard(.junkType)
        }
        if let hash = context.sha256, context.savedHashes.contains(hash) { return .discard(.duplicate) }
        if isDocument(a) { return .keep }
        return .ask
    }

    /// `<ABC@01D9>` → `abc@01d9` (how `inlineContentIds` stores them).
    public static func normalizedContentId(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")).lowercased()
    }

    /// The `cid:` references of an HTML body, normalized, in order of appearance.
    public static func contentIds(inHTML html: String) -> [String] {
        var out: [String] = []
        for m in html.matches(of: #/(?i)cid:([^"'\s>)]+)/#) {
            let raw = String(m.output.1)
            let id = normalizedContentId(raw.removingPercentEncoding ?? raw)
            if !id.isEmpty, !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// Hex SHA-256 of the bytes.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
