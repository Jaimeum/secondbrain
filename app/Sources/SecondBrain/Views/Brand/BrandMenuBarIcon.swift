import AppKit

/// Menu bar images from `mark-solid.svg` (CONTRACT §15.1): an 18 pt template silhouette, and while recording the
/// same symbol in the menu bar's label color plus a 6 pt `record` dot (not a template, so the dot keeps its color).
@MainActor
enum BrandMenuBarIcon {
    static let side: CGFloat = 18

    static let idle: NSImage = {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            drawMark(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "secondbrain"
        return image
    }()

    static let recording: NSImage = {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Drawn at display time, so `labelColor` resolves against the menu bar's own appearance.
            drawMark(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let dot: CGFloat = 6
            let dotRect = NSRect(x: rect.maxX - dot, y: rect.minY, width: dot, height: dot)
            // A clear ring around the dot keeps it legible over the symbol.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            Brand.nsColor(isDark ? 0xD27A66 : 0xB4533E).set()   // `Brand.color.record`, dark / light
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = L("status.recording")
        return image
    }()

    /// The symbol's silhouette, inset 1 pt so it sits optically with system menu bar icons.
    private static func drawMark(in rect: NSRect) {
        let inset = rect.insetBy(dx: 1, dy: 1)
        if BrandAssets.solidMark != nil {
            BrandAssets.drawSolidMark(in: inset)
        } else if let png = BrandAssets.mark(points: inset.width) {
            png.draw(in: inset)   // fallback: the gradient PNG's alpha is the same silhouette
        }
    }

    private static var isDark: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
