import SwiftUI

// MARK: Buttons

/// Shared shape of the brand buttons: radius `control`, height 28 (34 with `.controlSize(.large)`), one line,
/// hover = a faint `hover` veil, pressed = 0.92 opacity, disabled = 0.45 opacity, no springs.
private struct BrandButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let background: Color
    let foreground: Color
    var border: Color? = nil
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        let large = controlSize == .large || controlSize == .extraLarge
        let shape = RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
        configuration.label
            .font(large ? Brand.font(14, .medium) : Brand.callout)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(foreground)
            .padding(.horizontal, large ? 16 : 12)
            .frame(minHeight: large ? 34 : 28, maxHeight: large ? 34 : 28)
            .background(shape.fill(background))
            .overlay { if hovering && isEnabled { shape.fill(Brand.color.hover) } }
            .overlay { if let border { shape.strokeBorder(border, lineWidth: 1) } }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.45)
            .onHover { hovering = $0 }
            .animation(Brand.motion.fast, value: configuration.isPressed)
            .animation(Brand.motion.fast, value: hovering)
    }
}

/// Primary action: `accent` background, `onAccent` text.
struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, background: Brand.color.accent, foreground: Brand.color.onAccent)
    }
}

/// Secondary action: a soft `cardAlt` tone with the `text` label and no border (§15.1 quiet controls: a tone, not
/// an outline, sets it apart from the primary).
struct BrandSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, background: Brand.color.cardAlt, foreground: Brand.color.text)
    }
}

/// Ghost action (Cancelar, Cerrar, quiet toolbar-like buttons inside content): no fill at rest, `text2` label, the
/// `hover` veil under the pointer.
struct BrandGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, background: .clear, foreground: Brand.color.text2)
    }
}

/// Record / stop: muted `record` background, `onRecord` label. The app's only red control.
struct BrandRecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, background: Brand.color.record, foreground: Brand.color.onRecord)
    }
}

extension ButtonStyle where Self == BrandPrimaryButtonStyle {
    static var brandPrimary: BrandPrimaryButtonStyle { BrandPrimaryButtonStyle() }
}

extension ButtonStyle where Self == BrandSecondaryButtonStyle {
    static var brandSecondary: BrandSecondaryButtonStyle { BrandSecondaryButtonStyle() }
}

extension ButtonStyle where Self == BrandGhostButtonStyle {
    static var brandGhost: BrandGhostButtonStyle { BrandGhostButtonStyle() }
}

extension ButtonStyle where Self == BrandRecordButtonStyle {
    static var brandRecord: BrandRecordButtonStyle { BrandRecordButtonStyle() }
}

// MARK: Chip

/// Neutral capsule chip (`cardAlt`; label in `text`, symbol in `text2`; one line, truncates). `active` = `accentSoft` +
/// `accent` (selected filter). `tint` colors the symbol only (e.g. a project's tone). The label is `text`, not `text2`:
/// 11 pt medium is small text, and only `text` keeps it well over 4.5:1 on `cardAlt` in both themes.
struct BrandChip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color? = nil
    var active: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(tint ?? (active ? Brand.color.accent : Brand.color.text2))
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(active ? Brand.color.accent : Brand.color.text)
        }
        .font(Brand.font(11, .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(active ? Brand.color.accentSoft : Brand.color.cardAlt))
        .contentShape(Capsule())
    }
}

// MARK: Card

/// Container: `card` background, 1 px `line` border, radius `card`. No shadow (shadows are for overlays only).
struct BrandCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Brand.color.card))
            .overlay(shape.strokeBorder(Brand.color.line, lineWidth: 1))
    }
}

// MARK: Section header

/// "Por ordenar  3" — title in `section`, optional count in `text3`, optional trailing content (e.g. "Ver todo →").
struct BrandSectionHeader<Trailing: View>: View {
    let title: String
    let count: Int?
    let trailing: Trailing

    init(title: String, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.count = count
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
            if let count {
                Text(count, format: .number)
                    .font(Brand.font(13, .medium))
                    .foregroundStyle(Brand.color.text3)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension BrandSectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

// MARK: Text field

/// The brand text field (§15.1): plain text on `card`, radius `field`, 12 × 9 pt of inner room, a `lineSoft` edge at
/// rest (`line` under the pointer) and, when focused, a soft halo: a 3 pt `focusRing` glow outside the field and a
/// `focusBorder` edge. Never the system focus ring and never a dark stroke. Works for one-line and `axis: .vertical`
/// fields alike, so a form's fields share one look and one height per line.
struct BrandFieldStyle: ViewModifier {
    @FocusState private var focused: Bool
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(Brand.body)
            .foregroundStyle(Brand.color.text)
            .focused($focused)
            .focusEffectDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(shape.fill(Brand.color.card))
            .overlay(shape.strokeBorder(focused ? Brand.color.focusBorder : hovering ? Brand.color.line : Brand.color.lineSoft,
                                        lineWidth: 1))
            .brandFocusHalo(focused)
            .onHover { hovering = $0 }
            .animation(Brand.motion.fast, value: hovering)
    }
}

extension View {
    /// `BrandFieldStyle` on a `TextField` (or `TextEditor`-like content): the one text-field look of the app.
    func brandField() -> some View { modifier(BrandFieldStyle()) }

    /// The soft focus halo of `brandField`, for any control that tracks its own focus: a `focusRing` glow 3 pt
    /// outside the view's bounds (corner `cornerRadius` + 3) while `active`.
    func brandFocusHalo(_ active: Bool, cornerRadius: CGFloat = Brand.radius.field) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                .fill(Brand.color.focusRing)
                .padding(-3)
                .opacity(active ? 1 : 0)
        }
        .animation(Brand.motion.fast, value: active)
    }
}

// MARK: Form label

/// A form field's label (12 medium, `text2`) with an optional hint under it (`caption`, `text2`).
struct BrandFieldLabel: View {
    let title: String
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Brand.font(12, .medium))
                .foregroundStyle(Brand.color.text2)
            if let hint {
                Text(hint)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
