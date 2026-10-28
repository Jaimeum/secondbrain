import Foundation

// v0.7 (CONTRACT §17.1): email attachments as the providers list them, and the provider calls to list and download
// them. Read-only like the rest of the mail API: nothing is ever sent, moved or marked.

/// One attachment of a message, as the provider lists it (nothing downloaded yet).
public struct AttachmentInfo: Codable, Identifiable, Hashable, Sendable {
    /// The provider's attachment id (Graph attachment id, Gmail `attachmentId`; the demo's own).
    public var id: String
    public var name: String
    public var mimeType: String
    /// Bytes, as reported by the provider (0 when unknown).
    public var size: Int
    /// Shown inside the body (`Content-Disposition: inline` / Graph `isInline`), typically logos and signatures.
    public var isInline: Bool
    /// `Content-ID` without the angle brackets, matched against `cid:` references in the HTML body.
    public var contentId: String?
    /// False for things that are not files (Graph `itemAttachment` / `referenceAttachment`): listed by name only.
    public var isDownloadable: Bool

    public init(id: String, name: String, mimeType: String, size: Int, isInline: Bool = false, contentId: String? = nil,
                isDownloadable: Bool = true) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.size = size; self.isInline = isInline
        self.contentId = contentId; self.isDownloadable = isDownloadable
    }

    /// Lowercased extension of `name` ("" when it has none).
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

public enum AttachmentError: Error, Equatable {
    /// v0.7 foundation placeholder until the provider implements the call.
    case notImplemented
    /// Graph item/reference attachments: they have a name but no file.
    case notDownloadable
}

extension AttachmentError: LocalizedError {
    public var errorDescription: String? {
        let lang = Lang(AppConfig.load().uiLanguage)
        switch self {
        case .notImplemented: return lang.t("Todavía no puedo traer adjuntos de esta cuenta.", "I can't fetch attachments from this account yet.")
        case .notDownloadable: return lang.t("Este adjunto no es un archivo.", "This attachment isn't a file.")
        }
    }
}

/// Defaults of the `MailCalendarProvider` attachment requirements (§17.1): they keep providers without mail (the Mac
/// calendar) and test doubles compiling. Graph, Google and the demo implement both.
public extension MailCalendarProvider {
    func listAttachments(messageId: String) async throws -> [AttachmentInfo] { throw AttachmentError.notImplemented }
    func downloadAttachment(messageId: String, id: String) async throws -> Data { throw AttachmentError.notImplemented }
}
