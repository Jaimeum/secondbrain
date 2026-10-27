import AppKit
import SwiftUI

/// Loads the brand images from `Resources/Brand` once and keeps them. The source files keep the kit's clear space
/// (≈16 % per side); the marks here are cropped to the symbol so `BrandMark(size: 20)` really is 20 pt.
@MainActor
enum BrandAssets {
    private static var marks: [Int: NSImage] = [:]

    /// Gradient mark, the smallest of 128/256/512 that covers `points` at 2×.
    static func mark(points: CGFloat) -> NSImage? {
        let pixels = points * 2
        let res = pixels <= 128 ? 128 : pixels <= 256 ? 256 : 512
        if let cached = marks[res] { return cached }
        let url = AppResources.brandDirectory.appendingPathComponent("mark-\(res).png")
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let crop = squareCrop(alphaBounds(of: cg) ?? CGRect(x: 0, y: 0, width: cg.width, height: cg.height), in: cg)
        let cropped = cg.cropping(to: crop).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } ?? image
        marks[res] = cropped
        return cropped
    }

    /// The solid mark (SVG) as a vector image, plus the normalized rect of the symbol inside its 1000×1000 canvas.
    static let solidMark: (image: NSImage, bounds: CGRect)? = {
        guard let svg = NSImage(contentsOf: AppResources.brandDirectory.appendingPathComponent("mark-solid.svg")) else { return nil }
        // Rasterize once at 128 px to find the symbol's bounds.
        let px = 128
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (svg, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage(), let box = alphaBounds(of: cg) else { return (svg, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let square = squareCrop(box, in: cg)
        // CGImage rows are top-down; convert to a bottom-up unit rect for AppKit drawing.
        let unit = CGRect(x: square.minX / CGFloat(px), y: 1 - square.maxY / CGFloat(px),
                          width: square.width / CGFloat(px), height: square.height / CGFloat(px))
        return (svg, unit)
    }()

    /// Draws the solid mark so its symbol fills `rect` (AppKit coordinates, current context).
    static func drawSolidMark(in rect: NSRect) {
        guard let (svg, unit) = solidMark else { return }
        let scale = rect.width / unit.width
        let full = NSRect(x: rect.minX - unit.minX * scale, y: rect.minY - unit.minY * scale, width: scale, height: scale)
        svg.draw(in: full)
    }

    /// Bounding box (pixels, top-down) of pixels with alpha above ~4 %.
    static func alphaBounds(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // Rows in the buffer are top-down, like CGImage cropping coordinates.
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where alpha[y * w + x] > 10 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// A square around `box`'s center (side = its longer edge), clamped to the image.
    private static func squareCrop(_ box: CGRect, in image: CGImage) -> CGRect {
        let side = min(max(box.width, box.height), CGFloat(min(image.width, image.height)))
        var x = box.midX - side / 2, y = box.midY - side / 2
        x = min(max(0, x), CGFloat(image.width) - side)
        y = min(max(0, y), CGFloat(image.height) - side)
        return CGRect(x: x, y: y, width: side, height: side).integral
    }
}
