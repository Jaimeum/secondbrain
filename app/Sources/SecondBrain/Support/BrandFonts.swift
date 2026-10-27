import AppKit
import CoreText
import os

extension AppResources {
    /// `Resources/Brand` inside the app's resource bundle: fonts, gradient marks (PNG), solid/outline marks (SVG).
    static var brandDirectory: URL {
        bundle.url(forResource: "Brand", withExtension: nil) ?? bundle.bundleURL.appendingPathComponent("Brand")
    }
}

/// Registers Inter (variable, OFL) for this process at launch (CONTRACT §15.1). Never crashes: if the fonts can't be
/// loaded, `Brand.font` falls back to the system font.
enum BrandFonts {
    /// The registered family name. The variable TTF registers as "Inter Variable" (PostScript names
    /// `InterVariable`, `InterVariable-Medium`, `InterVariable-SemiBold`…), not "Inter".
    static let family = "Inter Variable"

    nonisolated(unsafe) private static var registered = false
    nonisolated(unsafe) private static var available = false
    private static let lock = NSLock()
    private static let log = Logger(subsystem: "app.secondbrain.mac", category: "brand")

    /// True once Inter is usable (registered by us or already installed).
    static var isAvailable: Bool {
        register()
        lock.lock(); defer { lock.unlock() }
        return available
    }

    /// Idempotent; safe to call from anywhere (first `Brand.font` call also triggers it).
    static func register() {
        lock.lock(); defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        let dir = AppResources.brandDirectory.appendingPathComponent("Fonts")
        for name in ["InterVariable.ttf", "InterVariable-Italic.ttf"] {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                log.error("Brand font missing: \(url.path, privacy: .public)")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error), let error = error?.takeRetainedValue() {
                // Already registered (e.g. a second call or the font is installed) is fine.
                if CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue {
                    log.error("Couldn't register \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        available = NSFont(name: "InterVariable", size: 13) != nil
            || NSFontManager.shared.availableFontFamilies.contains(family)
        if !available { log.error("Inter isn't available; using the system font") }
    }
}
