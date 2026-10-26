import BrainCore
import SwiftUI

struct NewProjectSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var onCreated: (Project) -> Void = { _ in }

    @ViewState private var form = ProjectForm()
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("newProject.title")).font(.title2.weight(.semibold))
            ProjectFormFields(form: $form)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("newProject.create")) { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.isValid)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func create() {
        do {
            let project = try state.createProject(name: form.trimmedName, description: form.description, emoji: form.emoji)
            onCreated(project)
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
                Text(L("newProject.name")).font(.headline)
                TextField(L("newProject.namePlaceholder"), text: $form.name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("newProject.emoji")).font(.headline)
                EmojiPicker(selection: $form.emoji)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("newProject.description")).font(.headline)
                Text(L("newProject.descriptionHint")).font(.caption).foregroundStyle(.secondary)
                TextField(L("newProject.descriptionPlaceholder"), text: $form.description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...5)
            }
        }
    }
}

struct EmojiPicker: View {
    static let options = ["📁", "🚀", "💼", "🎯", "🧪", "📚", "🏠", "💡", "🎨", "🤝", "🌱", "⭐️"]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.options, id: \.self) { emoji in
                Button {
                    selection = emoji
                } label: {
                    Text(emoji)
                        .font(.system(size: 20))
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection == emoji ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selection == emoji ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
