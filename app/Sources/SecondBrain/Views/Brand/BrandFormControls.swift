import AppKit
import SwiftUI

// Shared controls for sheets, forms and Settings (CONTRACT §15.1 "calm surfaces"): brand pull-downs instead of the
// system pop-up buttons (blue chevron box), a brand checkbox, quiet icon buttons, the sheet footer without a rule, a
// soft scroll-edge fade instead of hairlines, and the text-area look of `brandField`.

// MARK: Menu label

/// The label of a brand pull-down ("Usar por defecto ▾", "📁 Acme ▾"): a quiet `cardAlt` tone with no border, the
/// `hover` veil under the pointer and a faint `text3` chevron (the same language as `AddControlLabel`). Use inside
/// `Menu { … } label: { BrandMenuLabel(…) }.menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()`,
/// or through `BrandMenuPicker`. `maxWidth` truncates a long title (project names) instead of growing the row.
struct BrandMenuLabel: View {
    let title: String
    var symbol: String? = nil
    var maxWidth: CGFloat? = nil
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(Brand.color.text2) }
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxWidth, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(Brand.font(9, .semibold))
                .foregroundStyle(Brand.color.text3)
        }
        .font(Brand.callout)
        .foregroundStyle(Brand.color.text)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(shape.fill(Brand.color.cardAlt))
        .overlay { if hovering { shape.fill(Brand.color.hover) } }
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
    }
}

// MARK: Menu picker

/// A brand pull-down that picks one value: the same items (and checkmark) as a system `Picker`, shown from a
/// `BrandMenuLabel` instead of the system pop-up button. `title` is what the label shows for the current selection.
/// `content` holds the picker's tagged rows (sections and dividers allowed), exactly as inside a `Picker`.
struct BrandMenuPicker<Value: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Value
    var symbol: String? = nil
    var maxWidth: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            Picker("", selection: $selection) { content }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            BrandMenuLabel(title: title, symbol: symbol, maxWidth: maxWidth)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityValue(title)
    }
}

/// "Guardar en: 📁 Acme ▾" — Inbox (when `includeInbox`) and every project, as a brand pull-down. With
/// `includeInbox == false` and nothing picked yet, the label shows `placeholder` and the menu has no "none" row.
struct BrandProjectMenu: View {
    @Environment(AppState.self) private var state
    @Binding var selection: String?
    var includeInbox = true
    var placeholder: String? = nil
    var maxWidth: CGFloat? = 220

    var body: some View {
        BrandMenuPicker(title: title, selection: $selection, maxWidth: maxWidth) {
            if includeInbox {
                Text(L("inbox.title")).tag(String?.none)
                Divider()
            }
            ForEach(state.projects) { project in
                Text("\(project.emoji) \(project.name)").tag(Optional(project.slug))
            }
        }
    }

    private var title: String {
        if let slug = selection, let project = state.project(slug) { return "\(project.emoji) \(project.name)" }
        return includeInbox ? L("inbox.title") : (placeholder ?? "")
    }
}

// MARK: More menu

/// The "⋯" of a row's overflow menu: a plain `ellipsis` in `text2` inside a 26 pt circle that fills with `hover`
/// under the pointer. Use with `.menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()`.
struct BrandMoreMenuLabel: View {
    @ViewState private var hovering = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(Brand.font(12, .semibold))
            .foregroundStyle(Brand.color.text2)
            .frame(width: 26, height: 26)
            .background(Circle().fill(hovering ? Brand.color.hover : .clear))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(Brand.motion.fast, value: hovering)
            .accessibilityLabel(L("project.more"))
    }
}

// MARK: Icon button

// Icon-only actions (close ×, remove −) use `.buttonStyle(.brandIcon)` from BrandControls.swift.

// MARK: Checkbox

/// The brand checkbox: a 16 pt continuously rounded square (radius 5); off = `card` with a `line` edge, on = `accent`
/// with an `onAccent` checkmark; the `hover` veil under the pointer, an `easeOut` change. The AppKit checkbox fills
/// with the system accent (blue) and draws a hard white square; this one stays in the brand.
struct BrandCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandCheckbox(configuration: configuration)
    }

    private struct BrandCheckbox: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            Button {
                withAnimation(Brand.motion.fast) { configuration.isOn.toggle() }
            } label: {
                HStack(spacing: 6) {
                    ZStack {
                        shape.fill(configuration.isOn ? Brand.color.accent : Brand.color.card)
                        shape.strokeBorder(configuration.isOn ? Color.clear : (hovering ? Brand.color.focusBorder : Brand.color.line),
                                           lineWidth: 1)
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Brand.color.onAccent)
                        }
                    }
                    .frame(width: 16, height: 16)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(Brand.motion.fast, value: hovering)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
        }
    }
}

extension ToggleStyle where Self == BrandCheckboxToggleStyle {
    static var brandCheckbox: BrandCheckboxToggleStyle { BrandCheckboxToggleStyle() }
}

// MARK: Text area

/// `brandField` for a `TextEditor`: `card` fill, radius `field`, a `lineSoft` edge at rest, the soft focus halo and
/// `focusBorder` edge when focused, no system scroller track (the legacy scroller drew a grey strip with hard edges
/// inside the rounded box) and no system focus ring.
struct BrandTextAreaStyle: ViewModifier {
    @FocusState private var focused: Bool
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
        content
            .font(Brand.body)
            .foregroundStyle(Brand.color.text)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($focused)
            .focusEffectDisabled()
            .padding(.horizontal, 7)
            .padding(.vertical, 8)
            .background(shape.fill(Brand.color.card))
            .overlay(shape.strokeBorder(focused ? Brand.color.focusBorder : hovering ? Brand.color.line : Brand.color.lineSoft,
                                        lineWidth: 1))
            .brandFocusHalo(focused)
            .onHover { hovering = $0 }
            .animation(Brand.motion.fast, value: hovering)
    }
}

extension View {
    /// `BrandTextAreaStyle` on a `TextEditor`.
    func brandTextArea() -> some View { modifier(BrandTextAreaStyle()) }

    /// A soft fade into `color` over the given edge of a scrolling region (12–16 pt), instead of a 1 px rule between
    /// a scrolling body and a sheet's header or footer.
    func brandScrollEdgeFade(_ edge: VerticalEdge, color: Color = Brand.color.surface, height: CGFloat = 14) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            LinearGradient(colors: [color.opacity(0), color],
                           startPoint: edge == .top ? .bottom : .top, endPoint: edge == .top ? .top : .bottom)
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }
}

// MARK: Search field

/// A search box in the `brandField` look: magnifier, plain field, optional loader; `lineSoft` at rest, the soft
/// focus halo and `focusBorder` while typing.
struct BrandSearchField: View {
    let prompt: String
    @Binding var text: String
    var busy = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.color.text3)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Brand.body)
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit(onSubmit)
            if busy { BrandLoader(size: 14) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(Brand.color.card))
        .overlay(shape.strokeBorder(focused ? Brand.color.focusBorder : hovering ? Brand.color.line : Brand.color.lineSoft,
                                    lineWidth: 1))
        .brandFocusHalo(focused)
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
    }
}

// MARK: Sheet footer

/// A sheet's button row, the NewProjectSheet way: trailing buttons, 28 pt sides, 12 pt above, 22 pt below, and no
/// rule over it (spacing separates it from the body; a scrolling body ends with `brandScrollEdgeFade(.bottom)`).
/// Put a `Spacer()` first in `content` for trailing alignment.
struct BrandSheetFooter<Content: View>: View {
    var horizontalPadding: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Brand.spacing.s) { content }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 22)
    }
}

// MARK: Date field

/// A date (and time) you type into, in the `brandField` look: the same keyboard-editable AppKit date field as
/// `DatePicker(.field)`, but without its square white bezel, stepper box and system focus ring, set on `card` with a
/// `lineSoft` edge, radius `field`. `upTo` caps the date (e.g. no further than a year from now).
struct BrandDateField: View {
    @Binding var selection: Date
    var upTo: Date? = nil
    var showsTime = true
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
        BareDatePicker(selection: $selection, upTo: upTo, showsTime: showsTime)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(shape.fill(Brand.color.card))
            .overlay(shape.strokeBorder(hovering ? Brand.color.line : Brand.color.lineSoft, lineWidth: 1))
            .onHover { hovering = $0 }
            .animation(Brand.motion.fast, value: hovering)
    }

    /// `NSDatePicker` in its text-field style with no border, bezel, background or focus ring.
    private struct BareDatePicker: NSViewRepresentable {
        @Binding var selection: Date
        var upTo: Date?
        var showsTime: Bool

        func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

        func makeNSView(context: Context) -> NSDatePicker {
            let picker = NSDatePicker()
            picker.datePickerStyle = .textField
            picker.datePickerMode = .single
            picker.isBordered = false
            picker.isBezeled = false
            picker.drawsBackground = false
            picker.focusRingType = .none
            picker.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            picker.target = context.coordinator
            picker.action = #selector(Coordinator.changed(_:))
            return picker
        }

        func updateNSView(_ picker: NSDatePicker, context: Context) {
            context.coordinator.selection = $selection
            picker.datePickerElements = showsTime ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
            picker.maxDate = upTo
            if picker.dateValue != selection { picker.dateValue = selection }
            picker.textColor = NSColor(Brand.color.text)
        }

        final class Coordinator: NSObject {
            var selection: Binding<Date>
            init(selection: Binding<Date>) { self.selection = selection }
            @MainActor @objc func changed(_ sender: NSDatePicker) { selection.wrappedValue = sender.dateValue }
        }
    }
}
