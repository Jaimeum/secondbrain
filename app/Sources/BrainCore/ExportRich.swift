import AppKit
import Foundation

/// NSAttributedString → rtf / pdf / clipboard. AppKit text and printing: main thread only.
@MainActor
enum ExportRich {

    nonisolated static let marginPoints: CGFloat = 56.69   // 2 cm

    // MARK: Paper

    /// A4 or US Letter by region (Letter in the Americas that use it, A4 elsewhere).
    nonisolated static var paperSize: NSSize {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PR", "PH", "CL", "CO", "VE", "CR", "GT", "PA", "SV", "HN", "NI", "DO", "BZ"]
        let region = Locale.current.region?.identifier ?? "US"
        return letterRegions.contains(region) ? NSSize(width: 612, height: 792) : NSSize(width: 595.28, height: 841.89)
    }

    private static func pageAttributes(title: String) -> [NSAttributedString.DocumentAttributeKey: Any] {
        [
            .title: title,
            .paperSize: paperSize,
            .leftMargin: marginPoints, .rightMargin: marginPoints,
            .topMargin: marginPoints, .bottomMargin: marginPoints,
        ]
    }

    // MARK: Writers

    static func rtfData(_ s: NSAttributedString, title: String) throws -> Data {
        var attrs = pageAttributes(title: title)
        attrs[.documentType] = NSAttributedString.DocumentType.rtf
        return try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: attrs)
    }

    /// Paginated PDF through the print system; no window or app needed.
    static func writePDF(_ s: NSAttributedString, title: String, to url: URL, lang: Lang) throws {
        let paper = paperSize
        let width = paper.width - 2 * marginPoints

        // Explicit TextKit 1 stack: TextKit 2 doesn't draw NSTextBlock borders/backgrounds.
        let storage = NSTextStorage(attributedString: s)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = PagedTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        view.appearance = NSAppearance(named: .aqua)
        view.documentTitle = title
        view.lang = lang
        view.textContainerInset = .zero
        view.isEditable = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        storage.fixAttributes(in: NSRange(location: 0, length: storage.length))
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        view.setFrameSize(NSSize(width: width, height: ceil(used.height) + 2))

        let info = NSPrintInfo()
        info.paperSize = paper
        info.orientation = .portrait
        info.leftMargin = marginPoints; info.rightMargin = marginPoints
        info.topMargin = marginPoints; info.bottomMargin = marginPoints
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true
        // A "save" print job paginates (pdfOperation(with:inside:) would make one endless page).
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        try? FileManager.default.removeItem(at: url)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.jobTitle = title
        guard op.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    // MARK: Pasteboard

    static func copy(rich: NSAttributedString, html: String, plain: String, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let item = NSPasteboardItem()
        if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item.setData(rtf, forType: .rtf)
        }
        item.setString(html, forType: .html)
        item.setString(plain, forType: .string)
        pb.writeObjects([item])
    }
}

/// NSTextView that prints a discreet running header (title, from page 2) and a page-number footer.
final class PagedTextView: NSTextView {
    var documentTitle = ""
    var lang = Lang("es")

    private var smallAttributes: [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        return [.font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: NSColor(white: 0.45, alpha: 1), .paragraphStyle: ps]
    }

    /// Avoids a heading stranded at the bottom of a page: if a heading (or the first lines after
    /// it) would end the page, the page breaks before the heading instead.
    override func adjustPageHeightNew(_ newBottom: UnsafeMutablePointer<CGFloat>, top oldTop: CGFloat,
                                      bottom proposedBottom: CGFloat, limit bottomLimit: CGFloat) {
        super.adjustPageHeightNew(newBottom, top: oldTop, bottom: proposedBottom, limit: bottomLimit)
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        let bottom = newBottom.pointee
        let pageHeight = bottom - oldTop
        let zone = NSRect(x: 0, y: bottom - 60, width: bounds.width, height: 60)
        let glyphs = layout.glyphRange(forBoundingRect: zone, in: container)
        guard glyphs.length > 0 else { return }
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var breakAt: CGFloat? = nil
        storage.enumerateAttribute(.exportKeepWithNext, in: chars) { value, range, stop in
            guard value != nil else { return }
            let g = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 0), actualCharacterRange: nil)
            let line = layout.lineFragmentRect(forGlyphAt: min(g.location, max(layout.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            guard line.minY > oldTop + pageHeight * 0.5, line.minY < bottom else { return }
            // Only when the first line after the heading doesn't make it onto this page.
            let after = NSMaxRange(range)
            guard after < storage.length else { return }
            let ng = layout.glyphIndexForCharacter(at: after)
            let next = layout.lineFragmentRect(forGlyphAt: ng, effectiveRange: nil)
            if next.maxY > bottom { breakAt = line.minY; stop.pointee = true }
        }
        guard var y = breakAt else { return }
        // Headings right above the moved one ("## Acuerdos" + "### Mis compromisos") go along.
        while true {
            let g = layout.glyphIndex(for: NSPoint(x: 1, y: y - 3), in: container)
            let c = layout.characterIndexForGlyph(at: g)
            guard c < storage.length, storage.attribute(.exportKeepWithNext, at: c, effectiveRange: nil) != nil else { break }
            let line = layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            guard line.minY < y, line.minY > oldTop + pageHeight * 0.4 else { break }
            y = line.minY
        }
        if y >= bottomLimit { newBottom.pointee = y }
    }

    override var pageHeader: NSAttributedString {
        let page = NSPrintOperation.current?.currentPage ?? 1
        guard page > 1, !documentTitle.isEmpty else { return NSAttributedString(string: "") }
        return NSAttributedString(string: documentTitle, attributes: smallAttributes)
    }

    override var pageFooter: NSAttributedString {
        guard let op = NSPrintOperation.current else { return NSAttributedString(string: "") }
        let page = op.currentPage
        let total = op.pageRange.length
        let text = total > 1 && total < 10_000
            ? lang.t("Página \(page) de \(total)", "Page \(page) of \(total)")
            : lang.t("Página \(page)", "Page \(page)")
        return NSAttributedString(string: text, attributes: smallAttributes)
    }
}

extension NSAttributedString.Key {
    /// Marks headings so PDF pagination keeps them with the following text.
    static let exportKeepWithNext = NSAttributedString.Key("SBExportKeepWithNext")
}
