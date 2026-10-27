import SwiftUI

// MARK: Buttons

/// Shared shape of the brand buttons: radius `control`, height 28 (34 with `.controlSize(.large)`), one line,
/// pressed = 0.92 opacity, disabled = 0.45 opacity, no springs.
private struct BrandButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let background: Color
    let foreground: Color
    var border: Color? = nil
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

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
            .overlay { if let border { shape.strokeBorder(border, lineWidth: 1) } }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.45)
            .animation(Brand.motion.fast, value: configuration.isPressed)
    }
}

/// Primary action: `accent` background, `onAccent` text.
struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, background: Brand.color.accent, foreground: Brand.color.onAccent)
    }
}

/// Secondary action: `cardAlt` background, `text` label, hairline `line` border.
struct BrandSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, background: Brand.color.cardAlt, foreground: Brand.color.text,
                        border: Brand.color.line)
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
