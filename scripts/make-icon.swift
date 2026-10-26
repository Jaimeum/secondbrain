// Renders the SecondBrain app icon (1024x1024 PNG): usage `swift make-icon.swift out.png`
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: ~824pt rounded square centered in 1024 with a soft shadow.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.85, alpha: 1).setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.62, alpha: 1),
    NSColor(calibratedRed: 0.55, green: 0.33, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.22, green: 0.45, blue: 0.98, alpha: 1),
])!
gradient.draw(in: path, angle: -60)

// Soft highlight on the top half.
NSGraphicsContext.saveGraphicsState()
path.addClip()
NSColor.white.withAlphaComponent(0.12).setFill()
NSBezierPath(ovalIn: NSRect(x: rect.minX - 200, y: rect.midY, width: rect.width + 400, height: rect.height)).fill()
NSGraphicsContext.restoreGraphicsState()

let emoji = "🧠" as NSString
let font = NSFont.systemFont(ofSize: 520)
let attributes: [NSAttributedString.Key: Any] = [.font: font]
let textSize = emoji.size(withAttributes: attributes)
emoji.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2 - 10), withAttributes: attributes)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
