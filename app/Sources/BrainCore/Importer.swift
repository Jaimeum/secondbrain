import AppKit
import Foundation
import PDFKit

/// Creates raw markdown files for documents, web pages and notes (CONTRACT §4 step 6, §6).
/// `importFile`/`writeNote` are nonisolated (callable from a background task); HTML parsing hops to the
/// main thread because NSAttributedString's HTML importer requires it.
enum Importer {
    struct Imported {
        var sourceId: String
        var title: String
        var rawURL: URL
        var eventDate: Date
    }

    private static let plainText: Set<String> = ["md", "markdown", "txt", "text", "csv", "json", "yaml", "yml"]
    private static let richText: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive"]
    /// Formats whose NSAttributedString importer uses WebKit and must run on the main thread.
    static let mainThreadText: Set<String> = ["html", "htm", "webarchive"]

    /// `eventDate` nil = the document's own date (PDF metadata > file dates) or now (CONTRACT §11.1).
    static func importFile(_ file: URL, into dir: URL, project: String?, sourceURL: URL? = nil,
                           kind: SourceKind = .document, title: String? = nil, eventDate: Date? = nil,
                           extra: [(String, String)] = []) throws -> Imported {
        let fm = FileManager.default
        guard !fm.isDirectory(file) else { throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: file.path]) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = SessionManifest.newId()
        let title = title ?? file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension.lowercased()
        let when = eventDate ?? (sourceURL == nil ? FileDates.documentEventDate(file) : nil) ?? Date()
        let base = fileBase(title: title, date: when)

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
            } else if mainThreadText.contains(ext) {
                body = onMain { (try? NSAttributedString(url: file, options: [:], documentAttributes: nil).string) ?? "" }
            } else if richText.contains(ext) {
                body = (try? NSAttributedString(url: file, options: [:], documentAttributes: nil).string) ?? ""
            } else {
                body = DocumentText.extract(file) ?? ""   // v0.7: xlsx → CSV per sheet, pptx slides, iWork previews
            }
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body = "_(Contenido en el archivo original: `\(copy.lastPathComponent)`.)_"
            }
        }

        var fields: [(String, String)] = [("original_file", YAML.scalar(original))]
        if let sourceURL { fields.append(("source_url", YAML.scalar(sourceURL.absoluteString))) }
        fields += extra   // v0.7 (§17.3): e.g. `origin: dump`
        let raw = try writeRaw(type: kind == .url ? "url" : kind == .image ? "image" : "document", id: id, title: title, project: project,
                               extra: fields.filter { $0.1 != "null" },
                               body: body, dir: dir, base: base, eventDate: when)
        return Imported(sourceId: id, title: title, rawURL: raw, eventDate: when)
    }

    @MainActor
    static func importURL(_ url: URL, into dir: URL, project: String?, eventDate: Date? = nil) async throws -> Imported {
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
            return try importFile(file, into: dir, project: project, sourceURL: url, kind: .url, title: title,
                                  eventDate: eventDate ?? Date())
        }

        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let isHTML = mime.contains("html") || html.range(of: "<html", options: .caseInsensitive) != nil
        let title = isHTML ? (htmlTitle(html) ?? fallbackTitle) : fallbackTitle
        let body = isHTML ? htmlToText(html) : html
        let id = SessionManifest.newId()
        // A web page: the date the user gave, else its published date when it declares one, else now.
        let when = eventDate ?? (isHTML ? htmlPublishedDate(html) : nil) ?? Date()
        let base = fileBase(title: title, date: when)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = try writeRaw(type: "url", id: id, title: title, project: project,
                               extra: [("source_url", YAML.scalar(url.absoluteString))], body: body, dir: dir, base: base,
                               eventDate: when)
        return Imported(sourceId: id, title: title, rawURL: raw, eventDate: when)
    }

    /// `base`: the file name without extension (default `YYYY-MM-DD-<slug>`); v0.7 dump notes use `YYYY-MM-DD-dump-<slug>`.
    static func writeNote(title: String, body: String, into dir: URL, project: String?, eventDate: Date? = nil,
                          base: String? = nil, extra: [(String, String)] = []) throws -> Imported {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = SessionManifest.newId()
        let when = eventDate ?? Date()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Fmt.local(when, "yyyy-MM-dd HH:mm") : title
        let raw = try writeRaw(type: "note", id: id, title: title, project: project, extra: extra, body: body,
                               dir: dir, base: base ?? fileBase(title: title, date: when), eventDate: when)
        return Imported(sourceId: id, title: title, rawURL: raw, eventDate: when)
    }

    // MARK: Helpers

    /// Runs `body` on the main thread (directly when already there).
    private static func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    /// `YYYY-MM-DD-<slug>`, dated by when it happened (the event date).
    private static func fileBase(title: String, date: Date) -> String {
        let slug = slugify(title)
        let date = Fmt.local(date, "yyyy-MM-dd")
        return slug.isEmpty ? date : "\(date)-\(slug)"
    }

    /// Raw frontmatter: `date:` = when it happened, `added:` = now (both ISO 8601 with the local offset).
    private static func writeRaw(type: String, id: String, title: String, project: String?, extra: [(String, String)],
                                 body: String, dir: URL, base: String, eventDate: Date) throws -> URL {
        var front = """
        ---
        type: \(type)
        source_id: \(id)
        title: \(YAML.scalar(title))
        project: \(YAML.scalar(project))
        date: \(SBDate.iso(eventDate))
        added: \(SBDate.iso(Date()))

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

    /// `<meta property="article:published_time" content="…">` / JSON-LD `"datePublished": "…"`.
    static func htmlPublishedDate(_ html: String) -> Date? {
        let patterns = [#"(?is)<meta[^>]+(?:property|name|itemprop)\s*=\s*["'](?:article:published_time|datePublished|date|pubdate|publishdate|dc\.date)["'][^>]*content\s*=\s*["']([^"']+)["']"#,
                        #"(?is)<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]*(?:property|name|itemprop)\s*=\s*["'](?:article:published_time|datePublished)["']"#,
                        #"(?is)"datePublished"\s*:\s*"([^"]+)""#]
        for p in patterns {
            if let m = EmailParser.firstMatch(p, in: html, options: []), let v = m[1],
               let d = SBDate.parseISO(v)?.date ?? EmailParser.parseDate(v), FileDates.plausible(d) { return d }
        }
        return nil
    }

    @MainActor
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
    @MainActor
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
