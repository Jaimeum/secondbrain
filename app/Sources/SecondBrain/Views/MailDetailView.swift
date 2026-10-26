import BrainCore
import SwiftUI

/// Right side of Correo: the message (compact headers, the new text, earlier messages folded) and the action bar
/// with the one smart button "Agregar a 🚀 Proyecto ▾" (CONTRACT §12.7).
struct MailDetailView: View {
    @Environment(AppState.self) private var state
    let model: MailModel

    var body: some View {
        if let detail = model.detail {
            VStack(spacing: 0) {
                ScrollView {
                    message(detail)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                actionBar(detail)
            }
        } else if model.detailLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.detailError {
            EmptyStateView(symbol: "exclamationmark.triangle", title: L("mail.openFailed"), message: error,
                           actionTitle: L("mail.retry")) { let id = model.selectedId; model.select(nil); model.select(id) }
        } else {
            EmptyStateView(symbol: "envelope.open", title: L("mail.title"), message: L("mail.pickMessage"))
        }
    }

    // MARK: Message

    private func message(_ detail: MailModel.Detail) -> some View {
        let s = detail.message.summary
        return VStack(alignment: .leading, spacing: 14) {
            Text(s.subject.isEmpty ? L("mail.noSubject") : s.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                Initials(name: s.from.display)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.from.name ?? s.from.email ?? "?").font(.headline).lineLimit(1)
                        if s.from.name != nil, let email = s.from.email {
                            Text(email).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if !s.to.isEmpty {
                        Text(L("mail.to", names(s.to))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !detail.message.cc.isEmpty {
                        Text(L("mail.cc", names(detail.message.cc))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Fmt.dayTime(s.date)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if s.hasAttachments {
                        Label(L("mail.attachments"), systemImage: "paperclip").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }
            if detail.thread.count > 1 {
                Label(L("mail.conversation", detail.thread.count), systemImage: "bubble.left.and.bubble.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(detail.parsed.body.isEmpty ? L("mail.onlyQuoted") : detail.parsed.body)
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let quoted = detail.parsed.quotedHistory {
                QuotedHistory(text: quoted)
            }
        }
    }

    private func names(_ list: [EmailAddress]) -> String {
        let mine = Set(model.accounts.map(\.email))
        return list.map { mine.contains($0.email ?? "") ? L("mail.you") : $0.display }.joined(separator: ", ")
    }

    // MARK: Action bar

    @ViewBuilder private func actionBar(_ detail: MailModel.Detail) -> some View {
        let pending = model.newInThread
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                if pending.isEmpty, let source = model.source(for: detail.message.summary.id) {
                    HStack(spacing: 8) {
                        InBrainChip(source: source, model: model)
                        Text(L("mail.alreadyIn", destination(source.projectSlug)))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    smartButton(detail, pending: pending.count)
                }
                Text(L("mail.readOnly")).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let error = model.actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .lineLimit(3)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func smartButton(_ detail: MailModel.Detail, pending: Int) -> some View {
        let conversation = detail.thread.count > 1 && pending > 1
        let dest = destination(detail.projectLocked ? detail.existingThreadProject : model.projectSlug)
        let title = conversation ? L("mail.addConversationTo", pending, dest) : L("mail.addTo", dest)
        let selectedIn = model.source(for: detail.message.summary.id) != nil
        return Menu {
            if detail.projectLocked {
                Text(L("email.projectLocked"))   // "Va al proyecto del hilo"
            } else {
                projectChoices
            }
            if conversation, !selectedIn {
                Divider()
                Button(L("mail.onlyThis")) { model.add(onlyThis: true) }
            }
        } label: {
            Label(title, systemImage: "brain.head.profile")
        } primaryAction: {
            model.add(onlyThis: false)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fixedSize()
        .disabled(model.isSaving)
        .help(conversation ? L("mail.addConversation.help") : L("mail.addTo.help"))
    }

    /// "Cambiar proyecto": every project, then Sin asignar; ✓ on the current one.
    @ViewBuilder private var projectChoices: some View {
        Section(L("mail.changeProject")) {
            ForEach(state.projects) { project in
                Button { model.pickProject(project.slug) } label: {
                    if model.projectSlug == project.slug {
                        Label("\(project.emoji) \(project.name)", systemImage: "checkmark")
                    } else {
                        Text("\(project.emoji) \(project.name)")
                    }
                }
            }
            Button { model.pickProject(nil) } label: {
                if model.projectSlug == nil {
                    Label(destination(nil), systemImage: "checkmark")
                } else {
                    Text(destination(nil))
                }
            }
        }
    }

    /// "🚀 Kickoff", or "📥 Sin asignar".
    private func destination(_ slug: String?) -> String {
        if let project = state.project(slug) { return "\(project.emoji) \(project.name)" }
        return "📥 " + L("inbox.title")
    }
}

/// Earlier messages quoted in this one, folded.
private struct QuotedHistory: View {
    let text: String
    @ViewState private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Text(L("mail.quoted")).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Round initials of a sender.
private struct Initials: View {
    let name: String

    var body: some View {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360   // stable per name
        Text(letters.isEmpty ? "?" : letters)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color(hue: hue, saturation: 0.45, brightness: 0.7), in: Circle())
    }
}
