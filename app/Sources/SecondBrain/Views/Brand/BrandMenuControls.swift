import SwiftUI

// Quiet brand replacements for the system controls that leak the user's macOS accent (blue) or draw hard edges:
// pull-down labels, pop-up pickers, checkboxes, column dividers and the fade over a bottom bar (§15.1 calm surfaces).
// Every menu here follows one pattern: an own label + `.menuStyle(.button)`, `.menuIndicator(.hidden)`,
// `.buttonStyle(.plain)`, so no system bezel or chevron box ever shows.

// MARK: Column divider

/// The vertical break between two columns of one screen (list | page, brief | side): a 1 pt `lineSoft` capsule
/// inset from the top and bottom, so it never meets another edge at a corner.
struct BrandColumnDivider: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Brand.color.lineSoft)
            .frame(width: 1)
            .padding(.vertical, Brand.spacing.l)
            .accessibilityHidden(true)
    }
}

// MARK: Edge fade

/// A soft fade from transparent to `color` (default `surface`), laid over the top edge of a bottom bar instead of a
/// hairline: content scrolling under it dissolves into the bar. Use as `.overlay(alignment: .top) { BrandEdgeFade()
/// .offset(y: -16) }` on the bar.
struct BrandEdgeFade: View {
    var color: Color = Brand.color.surface
    var height: CGFloat = 16

    var body: some View {
        LinearGradient(colors: [color.opacity(0), color], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: Add pull-down label

/// "+ Agregar ⌄" as a quiet capsule: a `+` in an `accentSoft` circle (filled `accent` under the pointer), the label,
/// a faint `text3` chevron, on `card` with a `lineSoft` edge. The label of an add `Menu` in a toolbar or header.
struct BrandAddLabel: View {
    let title: String
    @ViewState private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(Brand.font(9, .semibold))
                .foregroundStyle(hovering ? Brand.color.onAccent : Brand.color.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(hovering ? Brand.color.accent : Brand.color.accentSoft))
            Text(title)
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(Brand.font(9, .semibold))
                .foregroundStyle(Brand.color.text3)
        }
        .padding(.leading, 5)
        .padding(.trailing, 11)
        .frame(height: 28)
        .background(Capsule(style: .continuous).fill(Brand.color.card))
        .overlay(Capsule(style: .continuous).strokeBorder(Brand.color.lineSoft, lineWidth: 1))
        .contentShape(Capsule(style: .continuous))
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
    }
}

// MARK: More (⋯) label

/// The ⋯ of a quiet "more" menu: `ellipsis` in `text2` on a 28 pt circle that takes the `hover` fill under the
/// pointer. No system bezel, no chevron.
struct BrandMoreLabel: View {
    var size: CGFloat = 28
    @ViewState private var hovering = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(Brand.font(13, .semibold))
            .foregroundStyle(Brand.color.text2)
            .frame(width: size, height: size)
            .background(Circle().fill(hovering ? Brand.color.hover : .clear))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(Brand.motion.fast, value: hovering)
    }
}

// MARK: Inline action menu label

/// "Elegir proyecto ⌄" and similar inline pull-downs: `accent` text and chevron on an `accentSoft` capsule (the same
/// look as the meeting card's project menu), so the action reads the same in Correo, Sin asignar and Reuniones.
struct BrandInlineMenuLabel: View {
    let title: String
    var symbol: String? = nil
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(Brand.font(9, .semibold))
        }
        .font(Brand.callout)
        .foregroundStyle(Brand.color.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Brand.color.accentSoft))
        .overlay { if hovering { Capsule(style: .continuous).fill(Brand.color.hover) } }
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
    }
}

// MARK: Pop-up label and picker

/// The label of a brand pop-up (a value chosen from a list): the current value on `card`, radius `field`, a
/// `lineSoft` edge (`line` under the pointer), a faint `text3` up-down glyph and the `hover` fill. Fills the width
/// it is given (`maxWidth: .infinity`), so it lines up with brand fields in a form.
struct BrandMenuLabel: View {
    let title: String
    var symbol: String? = nil
    var height: CGFloat = 30
    @ViewState private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(Brand.color.text2) }
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(Brand.font(9, .semibold))
                .foregroundStyle(Brand.color.text3)
        }
        .font(Brand.callout)
        .foregroundStyle(Brand.color.text)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .background(shape.fill(Brand.color.card))
        .overlay { if hovering && isEnabled { shape.fill(Brand.color.hover) } }
        .overlay(shape.strokeBorder(hovering ? Brand.color.line : Brand.color.lineSoft, lineWidth: 1))
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
    }
}

/// A pop-up picker in brand colors (replaces `Picker` with the `.menu` style, whose bezel and chevron box take the
/// system accent): a `Menu` of the options, the chosen one with a checkmark, under a `BrandMenuLabel`. Sections are
/// optional: an option with a `section` title starts a new section when it changes.
struct BrandPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Option]
    var height: CGFloat = 30

    struct Option {
        let value: Value
        let title: String
        var section: String? = nil
    }

    init(selection: Binding<Value>, options: [Option], height: CGFloat = 30) {
        _selection = selection
        self.options = options
        self.height = height
    }

    /// Plain options from (value, title) pairs.
    init(selection: Binding<Value>, options: [(Value, String)], height: CGFloat = 30) {
        self.init(selection: selection, options: options.map { Option(value: $0.0, title: $0.1) }, height: height)
    }

    private var groups: [(title: String?, options: [Option])] {
        var result: [(title: String?, options: [Option])] = []
        for option in options {
            if let last = result.last, last.title == option.section {
                result[result.count - 1].options.append(option)
            } else {
                result.append((option.section, [option]))
            }
        }
        return result
    }

    var body: some View {
        Menu {
            ForEach(groups.indices, id: \.self) { g in
                let group = groups[g]
                if let title = group.title {
                    Section(title) { buttons(group.options) }
                } else {
                    buttons(group.options)
                }
            }
        } label: {
            BrandMenuLabel(title: options.first { $0.value == selection }?.title ?? "", height: height)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    @ViewBuilder private func buttons(_ list: [Option]) -> some View {
        ForEach(list.indices, id: \.self) { i in
            let option = list[i]
            Button {
                selection = option.value
            } label: {
                if option.value == selection { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
            }
        }
    }
}

// MARK: Checkbox

/// A brand checkbox (replaces `.toggleStyle(.checkbox)`, which fills with the user's macOS accent): a 16 pt rounded
/// square, `card` with a `line` edge at rest (`hover` under the pointer), `accent` with an `onAccent` check when on.
/// The label sits to its right; the whole row toggles.
struct BrandCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandCheckbox(configuration: configuration)
    }
}

/// The 16 pt box of the brand checkbox alone (for a row that draws its own check button, like Correo's list):
/// `card` with a `line` edge (`hover` while `hovering`), or `accent` with an `onAccent` check when `isOn`.
struct BrandCheckboxMark: View {
    let isOn: Bool
    var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            shape.fill(isOn ? Brand.color.accent : Brand.color.card)
            if isOn {
                Image(systemName: "checkmark")
                    .font(Brand.font(10, .bold))
                    .foregroundStyle(Brand.color.onAccent)
            } else {
                if hovering { shape.fill(Brand.color.hover) }
                shape.strokeBorder(Brand.color.line, lineWidth: 1)
            }
        }
        .frame(width: 16, height: 16)
        .animation(Brand.motion.fast, value: isOn)
        .animation(Brand.motion.fast, value: hovering)
    }
}

private struct BrandCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                BrandCheckboxMark(isOn: configuration.isOn, hovering: hovering)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == BrandCheckboxToggleStyle {
    /// `BrandCheckboxToggleStyle`: the app's checkbox.
    static var brand: BrandCheckboxToggleStyle { BrandCheckboxToggleStyle() }
}

// MARK: Date field

/// A date (and time) field that sits with brand fields (replaces `DatePicker` with the field style, whose square
/// bezel and focus ring are the system's): an unbezeled `NSDatePicker` in Inter on `card`, radius `field`, a
/// `lineSoft` edge and the soft focus halo while editing. The highlighted segment while typing still uses the
/// system's selection color (AppKit draws it). `stepper` keeps the little up/down arrows where the old control had
/// them.
struct BrandDateField: View {
    @Binding var date: Date
    var time = true
    var maxDate: Date? = nil
    var stepper = false
    @ViewState private var editing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
        BrandDatePickerRepresentable(date: $date, time: time, maxDate: maxDate, stepper: stepper, editing: $editing)
            .fixedSize()
            .padding(.leading, 8)
            .padding(.trailing, stepper ? 4 : 8)
            .frame(height: 30)
            .background(shape.fill(Brand.color.card))
            .overlay(shape.strokeBorder(editing ? Brand.color.focusBorder : Brand.color.lineSoft, lineWidth: 1))
            .brandFocusHalo(editing)
    }
}

private struct BrandDatePickerRepresentable: NSViewRepresentable {
    @Binding var date: Date
    let time: Bool
    let maxDate: Date?
    let stepper: Bool
    @Binding var editing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusReportingDatePicker {
        let picker = FocusReportingDatePicker()
        picker.datePickerStyle = stepper ? .textFieldAndStepper : .textField
        picker.datePickerElements = time ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.focusRingType = .none
        picker.font = NSFontManager.shared.font(withFamily: BrandFonts.family, traits: [], weight: 5, size: 13)
            ?? .systemFont(ofSize: 13)
        picker.textColor = NSColor(Brand.color.text)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.onFocus = { focused in
            DispatchQueue.main.async { context.coordinator.parent.editing = focused }
        }
        return picker
    }

    func updateNSView(_ picker: FocusReportingDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.maxDate = maxDate
        if picker.dateValue != date { picker.dateValue = date }
    }

    final class Coordinator: NSObject {
        var parent: BrandDatePickerRepresentable
        init(_ parent: BrandDatePickerRepresentable) { self.parent = parent }
        @objc func changed(_ sender: NSDatePicker) { parent.date = sender.dateValue }
    }
}

/// An `NSDatePicker` that says when it takes and loses keyboard focus (for the brand halo).
final class FocusReportingDatePicker: NSDatePicker {
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }
}

// MARK: Toolbar

extension ToolbarContent {
    /// On macOS 26+, no shared glass bezel behind brand-drawn toolbar items (they draw their own quiet capsule or
    /// circle); earlier systems draw none anyway.
    @ToolbarContentBuilder func brandOwnBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
