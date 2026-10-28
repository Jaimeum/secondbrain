import SwiftUI

// Shared controls for sheets, forms and Settings (CONTRACT §15.1 "calm surfaces"): brand pull-downs instead of the
// system pop-up buttons (blue chevron box), a brand checkbox, quiet icon buttons, the sheet footer without a rule, a
// soft scroll-edge fade instead of hairlines, and the text-area look of `brandField`.

// MARK: Menu label

// The label itself is `BrandMenuLabel` in BrandMenuControls.swift (one look for every brand pop-up).

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

// The ⋯ of an overflow menu is `BrandMoreLabel` in BrandMenuControls.swift.

// MARK: Icon button

// Icon-only actions (close ×, remove −) use `.buttonStyle(.brandIcon)` from BrandControls.swift.

// MARK: Checkbox

// `.toggleStyle(.brandCheckbox)` is `BrandCheckboxToggleStyle` in BrandMenuControls.swift.

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

// `BrandDateField` (keyboard-editable date without the system bezel) lives in BrandMenuControls.swift.
