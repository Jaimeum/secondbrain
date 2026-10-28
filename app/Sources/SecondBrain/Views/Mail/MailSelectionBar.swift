import BrainCore
import SwiftUI

// v0.7 (CONTRACT §17.6): the bar under Correo's list while messages are checked —
// "3 seleccionados · Guardar en 🚀 Acme ▾ · Cancelar". The button opens the confirmation sheet (whole conversations,
// attachments to confirm); the chevron picks another project. Wraps to two lines in a narrow list (§15.3).

struct MailSelectionBar: View {
    @Environment(AppState.self) private var state
    let selection: MailSelection
    let model: MailModel
    /// The destination the user picked from ▾ (nil = suggested).
    @Binding var picked: String??
    let onSave: (String?) -> Void

    /// Picked, else where the rules send all of them (when they agree), else the last project used from Correo.
    var destination: String? {
        if let picked { return picked }
        let checked = model.messages.filter { selection.contains($0.id) }
        let routed = Set(checked.map { model.routedDestination(for: $0)?.projectSlug })
        if routed.count == 1, let only = routed.first, let slug = only { return slug }
        if let last = state.config.lastMailProjectSlug, state.project(last) != nil { return last }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Brand.spacing.m) {
                    count
                    Spacer(minLength: 4)
                    saveButton.frame(maxWidth: 240)
                    cancel
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: Brand.spacing.s) {
                        count
                        Spacer(minLength: 4)
                        cancel
                    }
                    saveButton
                }
            }
        }
        .padding(.horizontal, Brand.spacing.m)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.color.card)
        .overlay(alignment: .top) { Rectangle().fill(Brand.color.line).frame(height: 1) }
    }

    private var count: some View {
        Text(L("batch.selected", selection.count))
            .font(Brand.font(13, .semibold))
            .foregroundStyle(Brand.color.text)
            .lineLimit(1)
            .monospacedDigit()
    }

    private var cancel: some View {
        Button(L("common.cancel")) {
            selection.clear()
            picked = nil
        }
        .buttonStyle(.plain)
        .font(Brand.callout)
        .foregroundStyle(Brand.color.accent)
        .lineLimit(1)
        .keyboardShortcut(.cancelAction)
    }

    private var saveButton: some View {
        let slug = destination
        let title = state.project(slug).map { L("mail.saveTo", "\($0.emoji) \($0.name)") } ?? L("mail.saveNoProject")
        return BatchSplitButton(title: title, help: L("batch.saveHelp") + "\n" + L("readonly.promise"),
                                menuHelp: L("mail.changeProject")) {
            onSave(slug)
        } menu: {
            Section(L("mail.changeProject")) {
                ForEach(state.projects) { project in
                    Button { picked = .some(project.slug) } label: {
                        if slug == project.slug {
                            Label("\(project.emoji) \(project.name)", systemImage: "checkmark")
                        } else {
                            Text("\(project.emoji) \(project.name)")
                        }
                    }
                }
                Button { picked = .some(nil) } label: {
                    if slug == nil { Label(L("inbox.title"), systemImage: "checkmark") } else { Text(L("inbox.title")) }
                }
            }
        }
        .disabled(MailBatchSaver.shared.isRunning)
    }
}

/// A primary button with an attached ▾ menu (the look of Correo's smart button), without its ⌘↩: the reader keeps it.
struct BatchSplitButton<MenuContent: View>: View {
    let title: String
    let help: String
    let menuHelp: String
    let action: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
        HStack(spacing: 0) {
            Button(action: action) {
                Text(title)
                    .font(Brand.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Brand.color.onAccent)
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            Rectangle().fill(Brand.color.onAccent.opacity(0.3)).frame(width: 1, height: 16)
            Menu(content: menu) {
                Image(systemName: "chevron.down")
                    .font(Brand.font(10, .semibold))
                    .foregroundStyle(Brand.color.onAccent)
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()   // a fixed glyph, not text
            .help(menuHelp)
        }
        .background(Brand.color.accent, in: shape)
        .clipShape(shape)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The checkbox of a mail row (the column shows it on hover and while a selection is going on).
struct MailRowCheckbox: View {
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(Brand.font(14))
                .foregroundStyle(checked ? Brand.color.accent : Brand.color.text3)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(checked ? L("batch.uncheck") : L("batch.check"))
        .accessibilityLabel(L("batch.check"))
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
