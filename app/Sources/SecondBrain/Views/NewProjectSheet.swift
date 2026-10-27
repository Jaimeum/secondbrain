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
                VStack(alignment: .leading, spacing: 20) {
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
                .padding(24)
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? L("newProject.create") : L("newProject.save")) { save() }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.isValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(Brand.color.surface)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 360, idealHeight: 440)
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("newProject.name")).font(Brand.callout).foregroundStyle(Brand.color.text)
                TextField(L("newProject.namePlaceholder"), text: $form.name)
                    .brandField()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("newProject.emoji")).font(Brand.callout).foregroundStyle(Brand.color.text)
                EmojiPicker(selection: $form.emoji)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("newProject.description")).font(Brand.callout).foregroundStyle(Brand.color.text)
                Text(L("newProject.descriptionHint"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                // Room for the 1–2 sentences it asks for: three lines reserved, up to five.
                TextField(L("newProject.descriptionPlaceholder"), text: $form.description, axis: .vertical)
                    .lineLimit(3...5)
                    .brandField()
            }
        }
    }
}

/// A brand text field: plain text on `card` with a hairline `line` border and 8 pt of inner room, so the name and
/// the description share one look and one height per line.
private struct BrandFieldStyle: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(Brand.body)
            .foregroundStyle(Brand.color.text)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(shape.fill(Brand.color.card))
            .overlay(shape.strokeBorder(focused ? Brand.color.accent : Brand.color.line, lineWidth: focused ? 1.5 : 1))
    }
}

private extension View {
    func brandField() -> some View { modifier(BrandFieldStyle()) }
}

/// Two rows of six (fits a 380 pt sheet). A project's own emoji outside the list shows first.
struct EmojiPicker: View {
    static let options = ["📁", "🚀", "💼", "🎯", "🧪", "📚", "🏠", "💡", "🎨", "🤝", "🌱", "⭐️"]
    @Binding var selection: String

    private var choices: [String] {
        Self.options.contains(selection) ? Self.options : [selection] + Self.options
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
            ForEach(choices, id: \.self) { emoji in
                let selected = selection == emoji
                let shape = RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
                Button {
                    selection = emoji
                } label: {
                    Text(emoji)
                        .font(Brand.font(18))
                        .frame(width: 34, height: 34)
                        .background(shape.fill(selected ? Brand.color.accentSoft : Brand.color.cardAlt))
                        .overlay(shape.strokeBorder(selected ? Brand.color.accent : .clear, lineWidth: 1.5))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
