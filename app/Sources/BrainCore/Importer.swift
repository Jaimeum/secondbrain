import AppKit
import Foundation
import PDFKit

/// Creates raw markdown files for documents, web pages and notes (CONTRACT §4 step 6, §6).
@MainActor
enum Importer {
    struct Imported {
        var sourceId: String
        var title: String
        var rawURL: URL
    }

    private static let plainText: Set<String> = ["md", "markdown", "txt", "text", "csv", "json", "yaml", "yml"]
    private static let richText: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive"]

    static func importFile(_ file: URL, into dir: URL, project: String?, sourceURL: URL? = nil,
                           kind: SourceKind = .document, title: String? = nil) throws -> Imported {
        let fm = FileManager.default
        guard !fm.isDirectory(file) else { throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: file.path]) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = SessionManifest.newId()
        let title = title ?? file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension.lowercased()
        let base = fileBase(title: title)

        var original: String?
        var body: String
        if plainText.contains(ext) {
            // Exports from Windows/Excel are often Latin-1 / Windows-1252 rather than UTF-8.
            var encoding = String.Encoding.utf8
            body = try (try? String(contentsOf: file, encoding: .utf8))
                ?? (try? String(contentsOf: file, usedEncoding: &encoding))
                ?? String(contentsOf: file, encoding: .windowsCP1252)
            if ext == "md" || ext == "markdown" { body = Frontmatter.strip(body) }
        } else {
            let copy = fm.uniqueURL(in: dir, name: base, ext: ext)
            try fm.copyItem(at: file, to: copy)
            original = copy.lastPathComponent
            if ext == "pdf" {
                body = pdfText(file) ?? ""
            } else if richText.contains(ext) {
                body = (try? NSAttributedString(url: file, options: [:], documentAttributes: nil).string) ?? ""
            } else {
                body = ""
            }
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body = "_(Contenido en el archivo original: `\(copy.lastPathComponent)`.)_"
            }
        }

        var fields: [(String, String)] = [("original_file", YAML.scalar(original))]
        if let sourceURL { fields.append(("source_url", YAML.scalar(sourceURL.absoluteString))) }
        let raw = try writeRaw(type: kind == .url ? "url" : "document", id: id, title: title, project: project,
                               extra: fields.filter { $0.1 != "null" },
                               body: body, dir: dir, base: base)
        return Imported(sourceId: id, title: title, rawURL: raw)
    }

    static func importURL(_ url: URL, into dir: URL, project: String?) async throws -> Imported {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (Macintosh) SecondBrain", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EngineError.download("HTTP \(http.statusCode) — \(url.absoluteString)")
        }
        let mime = response.mimeType?.lowercased() ?? ""
        let fallbackTitle = url.host.map { $0 + url.path } ?? url.absoluteString

        if mime == "application/pdf" || url.pathExtension.lowercased() == "pdf" {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let name = url.lastPathComponent.isEmpty || !url.lastPathComponent.lowercased().hasSuffix(".pdf")
                ? "document.pdf" : url.lastPathComponent
            let file = tmp.appendingPathComponent(name)
            try data.write(to: file)
            let title = (name as NSString).deletingPathExtension
            return try importFile(file, into: dir, project: project, sourceURL: url, kind: .url, title: title)
        }

        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let isHTML = mime.contains("html") || html.range(of: "<html", options: .caseInsensitive) != nil
        let title = isHTML ? (htmlTitle(html) ?? fallbackTitle) : fallbackTitle
        let body = isHTML ? htmlToText(html) : html
        let id = SessionManifest.newId()
        let base = fileBase(title: title)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = try writeRaw(type: "url", id: id, title: title, project: project,
                               extra: [("source_url", YAML.scalar(url.absoluteString))], body: body, dir: dir, base: base)
        return Imported(sourceId: id, title: title, rawURL: raw)
    }

    static func writeNote(title: String, body: String, into dir: URL, project: String?) throws -> Imported {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = SessionManifest.newId()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Fmt.local(Date(), "yyyy-MM-dd HH:mm") : title
        let raw = try writeRaw(type: "note", id: id, title: title, project: project, extra: [], body: body,
                               dir: dir, base: fileBase(title: title))
        return Imported(sourceId: id, title: title, rawURL: raw)
    }

    // MARK: Helpers

    private static func fileBase(title: String) -> String {
        let slug = slugify(title)
        let date = Fmt.local(Date(), "yyyy-MM-dd")
        return slug.isEmpty ? date : "\(date)-\(slug)"
    }

    private static func writeRaw(type: String, id: String, title: String, project: String?, extra: [(String, String)],
                                 body: String, dir: URL, base: String) throws -> URL {
        var front = """
        ---
        type: \(type)
        source_id: \(id)
        title: \(YAML.scalar(title))
        project: \(YAML.scalar(project))
        date: \(Fmt.iso8601Local(Date()))

        """
        for (k, v) in extra { front += "\(k): \(v)\n" }
        front += "---\n\n# \(title)\n\n"
        let url = FileManager.default.uniqueURL(in: dir, name: base, ext: "md")
        try (front + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let text = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                pages.append("<!-- page \(i + 1) -->\n\(text)")
            }
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }

    static func htmlTitle(_ html: String) -> String? {
        guard let r = html.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression) else { return nil }
        let inner = html[r].replacingOccurrences(of: #"(?is)</?title[^>]*>"#, with: "", options: .regularExpression)
        let decoded = (try? NSAttributedString(data: Data(inner.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                                                  .characterEncoding: String.Encoding.utf8.rawValue],
                                               documentAttributes: nil).string) ?? inner
        let t = decoded.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.isEmpty ? nil : t
    }

    /// HTML → plain text via NSAttributedString, after dropping scripts, styles and external resources.
    static func htmlToText(_ html: String) -> String {
        var cleaned = html
        for pattern in [#"(?is)<script\b.*?</script>"#, #"(?is)<style\b.*?</style>"#, #"(?is)<noscript\b.*?</noscript>"#,
                        #"(?is)<svg\b.*?</svg>"#, #"(?is)<(img|link|iframe|video|audio|source|meta)\b[^>]*>"#] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let text = (try? NSAttributedString(data: Data(cleaned.utf8),
                                            options: [.documentType: NSAttributedString.DocumentType.html,
                                                      .characterEncoding: String.Encoding.utf8.rawValue],
                                            documentAttributes: nil).string)
            ?? cleaned.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }
}
