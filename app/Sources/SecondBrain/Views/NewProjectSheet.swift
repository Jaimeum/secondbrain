import AppKit
import BrainCore
import SwiftUI

/// "Nuevo proyecto" and "Editar proyecto…" (name, emoji, description). The default format is chosen later in the
/// project's ⋯ menu (Estándar until then).
struct NewProjectSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    private let editing: Project?
    private let onDone: (Project) -> Void

    @ViewState private var form: ProjectForm
    @ViewState private var error: String?

    init(onCreated: @escaping (Project) -> Void = { _ in }) {
        editing = nil
        onDone = onCreated
        _form = ViewState(wrappedValue: ProjectForm())
    }

    /// Edit mode: saves through `ProjectManager.update` (the slug never changes).
    init(editing project: Project, onSaved: @escaping (Project) -> Void = { _ in }) {
        editing = project
        onDone = onSaved
        _form = ViewState(wrappedValue: ProjectForm(name: project.name, description: project.description, emoji: project.emoji))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(editing == nil ? L("newProject.title") : L("newProject.editTitle"))
                        .font(Brand.title)
                        .foregroundStyle(Brand.color.text)
                    ProjectFormFields(form: $form)
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(Brand.callout)
                            .foregroundStyle(Brand.color.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            // No hairline over the footer: space and the page's own tone separate it (§15.1 calm surfaces).
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? L("newProject.create") : L("newProject.save")) { save() }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.isValid)
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
        .background(Brand.color.surface)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 360, idealHeight: 480)
    }

    private func save() {
        if var project = editing {
            project.name = form.trimmedName
            project.description = form.description.trimmingCharacters(in: .whitespacesAndNewlines)
            project.emoji = form.emoji
            do {
                try state.updateProject(project)
                onDone(project)
                dismiss()
            } catch {
                self.error = L("newProject.saveError")
            }
            return
        }
        do {
            let project = try state.createProject(name: form.trimmedName, description: form.description, emoji: form.emoji)
            onDone(project)
            dismiss()
        } catch {
            self.error = L("newProject.error")
        }
    }
}

struct ProjectForm {
    var name = ""
    var description = ""
    var emoji = EmojiPicker.options[0]

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedName.isEmpty }
}

struct ProjectFormFields: View {
    @Binding var form: ProjectForm

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                BrandFieldLabel(title: L("newProject.name"))
                TextField(L("newProject.namePlaceholder"), text: $form.name)
                    .brandField()
            }
            EmojiPicker(selection: $form.emoji)
            VStack(alignment: .leading, spacing: 8) {
                BrandFieldLabel(title: L("newProject.description"), hint: L("newProject.descriptionHint"))
                // Room for the 1–2 sentences it asks for: three lines reserved, up to five.
                TextField(L("newProject.descriptionPlaceholder"), text: $form.description, axis: .vertical)
                    .lineLimit(3...5)
                    .brandField()
            }
        }
    }
}

/// Any emoji can be a project's icon. On the left, the icon itself in a well that is also a one-emoji field: type,
/// paste or pick from the system Character Viewer ("More emoji…", which focuses the well first) and the newest emoji
/// typed becomes the icon; letters, digits and other text are ignored. On the right, suggestions in two rows of six
/// (the well is as tall as both). It draws its own "Ícono" label, with the quiet "More emoji…" capsule at its end.
/// `Project.emoji` stays a plain string.
struct EmojiPicker: View {
    static let options = ["📁", "🚀", "💼", "🎯", "🧪", "📚", "🏠", "💡", "🎨", "🤝", "🌱", "⭐️"]
    @Binding var selection: String
    @ViewState private var draft = ""
    @FocusState private var wellFocused: Bool
    @ViewState private var wellHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                BrandFieldLabel(title: L("newProject.emoji"))
                Spacer(minLength: 8)
                moreButton
            }
            HStack(alignment: .top, spacing: 14) {
                well
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 6), alignment: .leading,
                          spacing: 6) {
                    ForEach(Self.options, id: \.self) { emoji in
                        EmojiTile(emoji: emoji, selected: selection == emoji) { selection = emoji }
                    }
                }
                .fixedSize()
            }
        }
        .onAppear { draft = selection }
        .onChange(of: selection) { _, new in if draft != new { draft = new } }
        .onChange(of: draft) { _, new in accept(new) }
    }

    /// "More emoji…": opens the Character Viewer into the well.
    private var moreButton: some View {
        Button(action: openCharacterViewer) {
            HStack(spacing: 4) {
                Image(systemName: "face.smiling")
                Text(L("newProject.emojiMore")).lineLimit(1)
            }
            .font(Brand.font(12, .medium))
            .foregroundStyle(Brand.color.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Brand.color.accentSoft))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L("newProject.emojiMoreHelp"))
    }

    /// The current icon, large, in a field that takes one emoji. The caret sits after it while focused.
    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
        return TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(Brand.font(30))
            .multilineTextAlignment(.center)
            .focused($wellFocused)
            .focusEffectDisabled()
            .frame(width: 70, height: 70)
            .background(shape.fill(Brand.color.card))
            .overlay(shape.strokeBorder(wellFocused ? Brand.color.focusBorder
                                        : wellHovering ? Brand.color.line : Brand.color.lineSoft, lineWidth: 1))
            .brandFocusHalo(wellFocused, cornerRadius: Brand.radius.card)
            .onHover { wellHovering = $0 }
            .animation(Brand.motion.fast, value: wellHovering)
            .help(L("newProject.emojiFieldHelp"))
            .accessibilityLabel(L("newProject.emoji"))
            .accessibilityHint(L("newProject.emojiFieldHelp"))
    }

    /// Focus the well, then open the Character Viewer: what is picked there is typed into the well.
    private func openCharacterViewer() {
        wellFocused = true
        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
    }

    /// The field's text after an edit: the newest emoji in it (one other than the current icon, wherever the caret
    /// was) becomes the icon; then the field shows just the icon again.
    private func accept(_ text: String) {
        let emojis = Self.emojis(in: text)
        if let picked = emojis.last(where: { $0 != selection }) ?? emojis.last {
            if picked != selection { selection = picked }
        }
        if draft != selection { draft = selection }
    }

    /// The grapheme clusters of `text` that are emoji: a scalar shown as emoji by default (🚀), or an emoji-capable
    /// scalar made into an emoji by what follows it (☺️ with U+FE0F, 1️⃣, flags, ZWJ sequences, skin tones). Plain
    /// letters, digits, "#" or "*" alone are not.
    static func emojis(in text: String) -> [String] {
        text.compactMap { character -> String? in
            let scalars = character.unicodeScalars
            guard let first = scalars.first else { return nil }
            let isEmoji = scalars.contains { $0.properties.isEmojiPresentation }
                || (first.properties.isEmoji && scalars.count > 1)
            return isEmoji ? String(character) : nil
        }
    }
}

/// One suggestion: the emoji on a soft `cardAlt` tile; selected = `accentSoft` with a light `focusBorder` ring.
private struct EmojiTile: View {
    let emoji: String
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.tile, style: .continuous)
        Button(action: action) {
            Text(emoji)
                .font(Brand.font(17))
                .frame(width: 32, height: 32)
                .background(shape.fill(selected ? Brand.color.accentSoft : hovering ? Brand.color.cardAlt : Brand.color.card))
                .overlay(shape.strokeBorder(selected ? Brand.color.focusBorder : Brand.color.lineSoft, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
        .animation(Brand.motion.fast, value: selected)
        .accessibilityLabel(emoji)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
