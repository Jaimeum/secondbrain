import Foundation
import AppKit

/// Renders wiki markdown to the export formats of CONTRACT §11.4 (all native, no runtime deps):
/// markdown → ExportPreprocessor (frontmatter, [[wikilinks]], callouts, comments) → swift-markdown
/// AST → HTML (ExportHTML) · plain text (ExportText) · WordprocessingML (ExportDocx) ·
/// NSAttributedString (ExportAttributed) → RTF / paginated PDF / clipboard (ExportRich).
public enum Exporter {

    public enum ExportError: Error, LocalizedError {
        case writeFailed(String)
        public var errorDescription: String? {
            switch self { case .writeFailed(let detail): return detail }
        }
    }

    /// Renders markdown (wiki flavour: frontmatter, [[wikilinks]], callouts, checkboxes, tables) to a file.
    @MainActor public static func export(markdown: String, title: String, format: ExportFormat,
                                         options: ExportOptions, to url: URL) throws {
        let lang = Lang(AppConfig.load().uiLanguage)
        let pre = prepared(markdown, title: title, format: format, options: options, lang: lang)
        do {
            switch format {
            case .markdown:
                try write(pre.markdown.hasSuffix("\n") ? pre.markdown : pre.markdown + "\n", to: url)
            case .text:
                try write(ExportTextRenderer.render(pre.markdown), to: url)
            case .html:
                let body = ExportHTMLRenderer.render(pre.markdown)
                try write(ExportHTMLDocument.page(title: title, body: body, lang: lang), to: url)
            case .docx:
                try ExportDocx.data(markdown: pre.markdown, title: title, lang: lang).write(to: url, options: .atomic)
            case .rtf:
                let rich = ExportAttributedRenderer.render(pre.markdown, target: .portable)
                try ExportRich.rtfData(rich, title: title).write(to: url, options: .atomic)
            case .pdf:
                let rich = ExportAttributedRenderer.render(pre.markdown, target: .screen)
                try ExportRich.writePDF(rich, title: title, to: url, lang: lang)
            }
        } catch {
            Log.error("export \(format.rawValue) → \(url.path) failed: \(error)")
            throw ExportError.writeFailed(lang.t("No se pudo exportar «\(title)» (\(formatName(format, lang: lang))): \(error.localizedDescription)",
                                                 "Couldn't export “\(title)” (\(formatName(format, lang: lang))): \(error.localizedDescription)"))
        }
    }

    /// Rich text + plain text for the clipboard.
    @MainActor public static func copyToPasteboard(markdown: String, options: ExportOptions) {
        copyToPasteboard(markdown: markdown, options: options, pasteboard: .general)
    }

    @MainActor static func copyToPasteboard(markdown: String, options: ExportOptions, pasteboard: NSPasteboard) {
        let lang = Lang(AppConfig.load().uiLanguage)
        let pre = ExportPreprocessor.run(markdown, format: .html, options: options, lang: lang)
        let body = ExportHTMLRenderer.render(pre.markdown)
        let html = ExportHTMLDocument.forClipboard(body: body)
        let plain = ExportTextRenderer.render(pre.markdown)
        let rich = ExportAttributedRenderer.render(pre.markdown, target: .portable)
        ExportRich.copy(rich: rich, html: html, plain: plain, to: pasteboard)
    }

    public static func plainText(markdown: String, options: ExportOptions) -> String {
        let lang = Lang(AppConfig.load().uiLanguage)
        let pre = ExportPreprocessor.run(markdown, format: .text, options: options, lang: lang)
        return ExportTextRenderer.render(pre.markdown)
    }

    /// Human name of a format, for menus and messages.
    public static func formatName(_ f: ExportFormat, english: Bool) -> String {
        formatName(f, lang: Lang(english ? "en" : "es"))
    }

    // MARK: - Internals

    /// Preprocessed markdown with the title as `# H1` when the document has none.
    static func prepared(_ markdown: String, title: String, format: ExportFormat, options: ExportOptions, lang: Lang) -> ExportPreprocessor.Output {
        var pre = ExportPreprocessor.run(markdown, format: format, options: options, lang: lang)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !pre.hasH1, !t.isEmpty else { return pre }
        let heading = "# " + escapeInline(t) + "\n\n"
        if pre.markdown.hasPrefix("---\n"), let end = pre.markdown.range(of: "\n---\n\n") {
            pre.markdown.insert(contentsOf: heading, at: end.upperBound)
        } else {
            pre.markdown = heading + pre.markdown
        }
        pre.hasH1 = true
        return pre
    }

    /// Backslash-escapes markdown punctuation so a title is rendered literally.
    static func escapeInline(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\`*_[]<>~".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func formatName(_ f: ExportFormat, lang: Lang) -> String {
        switch f {
        case .markdown: return "Markdown"
        case .text: return lang.t("Texto", "Text")
        case .docx: return "Word"
        case .pdf: return "PDF"
        case .html: return "HTML"
        case .rtf: return lang.t("Texto enriquecido (RTF)", "Rich Text (RTF)")
        }
    }
}
