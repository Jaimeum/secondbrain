import AppKit
import SwiftUI

/// The secondbrain design system (CONTRACT §15.1). The only place in Swift where colors, type, radii, spacing,
/// shadows and motion are defined; views read them from here and never use system colors or loose hex values.
/// Source of truth: `docs/brand/brand_tokens.json` + the brand guide; light/dark values from the §15.1 table.
enum Brand {
    // MARK: Color

    struct Palette {
        /// Window and sidebar background (ivory / dark).
        let bg = Brand.dynamic(light: 0xF5F0E8, dark: 0x202721)
        /// Content area (cream / dark2).
        let surface = Brand.dynamic(light: 0xFAF7F1, dark: 0x30382F)
        /// Cards, selectable rows, fields.
        let card = Brand.dynamic(light: 0xFFFFFF, dark: 0x3A4238)
        /// Chips, pills, soft highlight backgrounds (sand).
        let cardAlt = Brand.dynamic(light: 0xE9E0D4, dark: 0x2A322A)
        /// Dividers and 1 px borders.
        let line = Brand.dynamic(light: 0xDAD3C9, dark: 0xFFFFFF, darkAlpha: 0.10)
        /// Primary text (ink / ivory).
        let text = Brand.dynamic(light: 0x232B25, dark: 0xF5F0E8)
        /// Secondary text (AA on bg and surface).
        let text2 = Brand.dynamic(light: 0x6F766D, dark: 0xAEB5A4)
        /// Placeholders, non-essential metadata.
        let text3 = Brand.dynamic(light: 0xAEB5A4, dark: 0x818979)
        /// Primary action, selection, links, active icons (olive / mid). Text on it: `onAccent`.
        let accent = Brand.dynamic(light: 0x475243, dark: 0xAEB5A4)
        /// Text and icons on `accent`.
        let onAccent = Brand.dynamic(light: 0xF5F0E8, dark: 0x232B25)
        /// Selected row, active chip, callout background (olive 10 % / mid 14 %).
        let accentSoft = Brand.dynamic(light: 0x475243, lightAlpha: 0.10, dark: 0xAEB5A4, darkAlpha: 0.14)
        /// Gradients, decoration, avatars.
        let sage = Brand.dynamic(light: 0x818979, dark: 0x818979)
        /// Record / stop / in progress: the app's only red, muted.
        let record = Brand.dynamic(light: 0xB4533E, dark: 0xD27A66)
        /// Background of a record card or "recording" highlight (record 10 % / 16 %).
        let recordSoft = Brand.dynamic(light: 0xB4533E, lightAlpha: 0.10, dark: 0xD27A66, darkAlpha: 0.16)
        /// Notices, due today, reconnect.
        let warning = Brand.dynamic(light: 0x9A7B2E, dark: 0xD2B15C)
        /// Background of a warning banner (warning 12 % / 16 %).
        let warningSoft = Brand.dynamic(light: 0x9A7B2E, lightAlpha: 0.12, dark: 0xD2B15C, darkAlpha: 0.16)
        /// Errors, delete: text or icon only, never a saturated background.
        let danger = Brand.dynamic(light: 0xA3473A, dark: 0xD27A66)
        /// Done, ✓ (same as accent: success = calm).
        let success = Brand.dynamic(light: 0x475243, dark: 0xAEB5A4)
        /// Overlay shadow color (`0 8 24 rgba(35,43,37,0.10)`; darker in dark mode so it still reads).
        let shadow = Brand.dynamic(light: 0x232B25, lightAlpha: 0.10, dark: 0x000000, darkAlpha: 0.35)
    }

    static let color = Palette()

    /// People avatars: `cardAlt` background, initials in `text2`; never random colors.
    struct AvatarTokens {
        let background = Brand.color.cardAlt
        let initials = Brand.color.text2
        func font(_ diameter: CGFloat) -> Font { Brand.font(max(9, diameter * 0.4), .medium) }
    }

    static let avatar = AvatarTokens()

    /// Projects / graph: muted categorical palette (sage, terracotta, ochre, slate blue, mauve, moss), same in both
    /// themes. Assigned by a stable hash of the slug, never by index.
    static let projectPaletteHex: [UInt32] = [0x818979, 0xA86A55, 0xA89055, 0x6E7F93, 0x8B6F86, 0x6F8A5A]
    static let projectPalette: [Color] = projectPaletteHex.map { Color(nsColor: nsColor($0)) }

    /// Stable palette index for a project: FNV-1a 32-bit over the slug's UTF-8 bytes, then the murmur3 `fmix32`
    /// finalizer, modulo 6. Plain FNV-1a has weak low bits (`hash % 6` gave 'alianza-banco-nubia' and
    /// 'lanzamiento-atlas' the same tone); the finalizer spreads every input bit over the result (demo slugs →
    /// mauve, ochre, slate). The web graph receives the hex from here (`projectHex`), so the tone is the same everywhere.
    static func projectIndex(slug: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in slug.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        hash ^= hash >> 16
        hash = hash &* 0x85EB_CA6B
        hash ^= hash >> 13
        hash = hash &* 0xC2B2_AE35
        hash ^= hash >> 16
        return Int(hash % UInt32(projectPaletteHex.count))
    }

    static func projectColor(slug: String) -> Color { projectPalette[projectIndex(slug: slug)] }

    /// Graph halo / soft fill for a project: its tone at 13 % (light) / 16 % (dark).
    static func projectHalo(slug: String) -> Color {
        let hex = projectPaletteHex[projectIndex(slug: slug)]
        return dynamic(light: hex, lightAlpha: 0.13, dark: hex, darkAlpha: 0.16)
    }

    /// "#RRGGBB" of a project's tone, for CSS / the web graph.
    static func projectHex(slug: String) -> String {
        String(format: "#%06X", projectPaletteHex[projectIndex(slug: slug)])
    }

    // MARK: Type

    /// Inter (registered by `BrandFonts.register()`), falling back to the system font if it couldn't be loaded.
    /// Weights 400–600 in the UI. Later `.weight(_:)` / `.bold()` modifiers still work on the result.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        BrandFonts.isAvailable ? .custom(BrandFonts.family, size: size).weight(weight) : .system(size: size, weight: weight)
    }

    /// Page titles: 20 semibold.
    static var title: Font { font(20, .semibold) }
    /// Section headers: 15 semibold.
    static var section: Font { font(15, .semibold) }
    /// Default text: 13 regular (applied at the root with `.environment(\.font, Brand.body)`).
    static var body: Font { font(13) }
    /// Emphasized body, buttons: 13 medium.
    static var callout: Font { font(13, .medium) }
    /// Metadata, chips: 11 regular.
    static var caption: Font { font(11) }
    /// Code, paths, ids: SF Mono 12.
    static var mono: Font { .system(size: 12, design: .monospaced) }
    /// A larger monospaced size (e.g. a device code to type elsewhere).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    /// Wordmark tracking: −0.03 em.
    static func wordmarkTracking(_ size: CGFloat) -> CGFloat { -0.03 * size }

    // MARK: Shape, spacing, shadow

    struct Radius {
        /// Buttons, fields, rows: 8.
        let control: CGFloat = 8
        /// Cards: 12.
        let card: CGFloat = 12
        /// Sheets, overlays (⌘K palette): 14.
        let sheet: CGFloat = 14
    }

    static let radius = Radius()

    /// 4-based spacing. `Brand.spacing(3)` = 12.
    struct Spacing {
        let unit: CGFloat = 4
        let xxs: CGFloat = 2
        let xs: CGFloat = 4
        let s: CGFloat = 8
        let m: CGFloat = 12
        let l: CGFloat = 16
        let xl: CGFloat = 20
        let xxl: CGFloat = 24
        let xxxl: CGFloat = 32
        /// Content padding of a screen.
        let content: CGFloat = 20
        /// Content padding of a single-column screen (Home, onboarding).
        let contentWide: CGFloat = 24
        func callAsFunction(_ steps: CGFloat) -> CGFloat { steps * unit }
    }

    static let spacing = Spacing()

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    /// Only for overlays (⌘K palette, popovers drawn by us, toasts); never on cards. CSS: `0 8px 24px`.
    struct Shadows {
        let overlay = Shadow(color: Brand.color.shadow, radius: 12, x: 0, y: 8)
    }

    static let shadow = Shadows()

    // MARK: Motion

    /// Calm ease-out transitions; no springs, no `.snappy`. With Reduce Motion only 150 ms fades.
    struct Motion {
        let fastDuration: Double = 0.16
        let standardDuration: Double = 0.24
        let reducedDuration: Double = 0.15
        /// Hover, selection, small state changes.
        var fast: Animation { .easeOut(duration: fastDuration) }
        /// Sections appearing, sheets' inner changes, overlays.
        var standard: Animation { .easeOut(duration: standardDuration) }
        /// The only animation allowed with Reduce Motion.
        var fade: Animation { .easeOut(duration: reducedDuration) }

        /// System "Reduce motion" setting, for code without a SwiftUI environment. Views should prefer
        /// `@Environment(\.accessibilityReduceMotion)`.
        var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        /// `standard` (or `fast`), or a 150 ms fade when Reduce Motion is on.
        func animation(fast: Bool = false, reduceMotion: Bool? = nil) -> Animation {
            (reduceMotion ?? self.reduceMotion) ? fade : (fast ? self.fast : standard)
        }
    }

    static let motion = Motion()

    // MARK: Helpers

    static func nsColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A color that resolves per appearance (follows the app's light/dark/system setting and offscreen renders).
    static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        let lightColor = nsColor(light, alpha: lightAlpha)
        let darkColor = nsColor(dark, alpha: darkAlpha)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

extension View {
    /// Root styling: Inter body font and the brand accent as tint. Applied to every scene's root (and should be
    /// applied by offscreen snapshot renders so they match the app).
    func brandEnvironment() -> some View {
        environment(\.font, Brand.body)
            .tint(Brand.color.accent)
    }

    /// The overlay shadow (⌘K palette, toasts). Never on cards.
    func brandOverlayShadow() -> some View {
        let s = Brand.shadow.overlay
        return shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}
