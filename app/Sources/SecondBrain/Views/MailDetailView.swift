import BrainCore
import SwiftUI

/// Right side of Correo: the message (compact headers, the new text, earlier messages folded) and the action bar with
/// the one smart button "Guardar en 🚀 Proyecto ▾" (CONTRACT §12.7 + §15.2). The toast floats above the action bar;
/// the rule offer it may earn shows afterwards inside the action bar (never two floating messages).
struct MailDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: MailModel

    var body: some View {
        Group {
            if let detail = model.detail {
                VStack(spacing: 0) {
                    ScrollView {
                        message(detail)
                            .padding(.horizontal, Brand.spacing.xxl)
                            .padding(.vertical, Brand.spacing.content)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .overlay(alignment: .bottom) {
                        if let toast = model.toast {
                            MailToastView(toast: toast) { model.undo() }
                                .padding(.horizontal, Brand.spacing.l)
                                .padding(.bottom, Brand.spacing.m)
                                .transition(.opacity)
                        }
                    }
                    Rectangle().fill(Brand.color.line).frame(height: 1)
                    actionBar(detail)
                }
            } else if model.detailLoading {
                BrandLoader(size: 24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.detailError {
                EmptyStateView(symbol: "exclamationmark.triangle", title: L("mail.openFailed"), message: error,
                               actionTitle: L("mail.retry")) { let id = model.selectedId; model.select(nil); model.select(id) }
            } else {
                EmptyStateView(symbol: "envelope.open", title: L("mail.title"),
                               message: L("mail.pickMessage") + " " + L("readonly.promise"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.color.card)
        .animation(Brand.motion.animation(reduceMotion: reduceMotion), value: model.toast)
        .animation(Brand.motion.animation(reduceMotion: reduceMotion), value: model.ruleOffer.current)
    }

    // MARK: Message

    private func message(_ detail: MailModel.Detail) -> some View {
        let s = detail.message.summary
        return VStack(alignment: .leading, spacing: 14) {
            Text(s.subject.isEmpty ? L("mail.noSubject") : s.subject)
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Brand.spacing.m) {
                Initials(name: s.from.display)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.from.name ?? s.from.email ?? "?")
                        .font(Brand.font(13, .semibold))
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                    if s.from.name != nil, let email = s.from.email {
                        Text(email)
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if !s.to.isEmpty {
                        Text(L("mail.to", names(s.to))).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(2)
                    }
                    if !detail.message.cc.isEmpty {
                        Text(L("mail.cc", names(detail.message.cc))).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Fmt.dayTime(s.date)).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
                    if s.hasAttachments {
                        Label(L("mail.attachments"), systemImage: "paperclip")
                            .font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
                    }
                }
                .layoutPriority(1)
            }
            if detail.thread.count > 1 {
                Label(L("mail.conversation", detail.thread.count), systemImage: "bubble.left.and.bubble.right")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            Text(detail.parsed.body.isEmpty ? L("mail.onlyQuoted") : detail.parsed.body)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text)
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

    /// The rule offer (after the toast), then the smart button or "Guardado · Ver en el proyecto", then the error on
    /// its own full-width row. Everything wraps instead of overflowing (§15.3).
    private func actionBar(_ detail: MailModel.Detail) -> some View {
        let pending = model.newInThread
        return VStack(alignment: .leading, spacing: 10) {
            // MARK: v0.4 routing — §14.3 offer, inside the action bar (§15.2).
            if model.ruleOffer.current != nil {
                RuleOfferBar(offer: model.ruleOffer)
            }
            if pending.isEmpty, let source = model.source(for: detail.message.summary.id) {
                savedRow(source)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Brand.spacing.m) {
                        smartButton(detail, pending: pending.count)
                        if let why = why(detail, pending: pending) {
                            Text(why).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        smartButton(detail, pending: pending.count)
                        if let why = why(detail, pending: pending) {
                            Text(why).font(Brand.caption).foregroundStyle(Brand.color.text2)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
            }
            if let error = model.actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Brand.spacing.content)
        .padding(.vertical, Brand.spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.color.surface)
    }

    /// Why the button points where it does ("Por la regla «…»", "Proyecto por defecto"), or nothing.
    private func why(_ detail: MailModel.Detail, pending: [MailMessageFull]) -> String? {
        guard !pending.isEmpty, !detail.projectLocked else { return nil }
        return destinationWhy
    }

    /// After saving: a visible "✓ Guardado · Ver en el proyecto" button, where it went, and "Quitar" in ⋯.
    private func savedRow(_ source: SourceRecord) -> some View {
        let dest = destination(source.projectSlug)
        let open = Button { model.open(source) } label: {
            Label(L("mail.saved") + " · " + (source.projectSlug == nil ? L("mail.seeUnassigned") : L("mail.seeInProject")),
                  systemImage: "checkmark")
        }
        .buttonStyle(.brandSecondary)
        .help(L("mail.savedIn", dest))
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Brand.spacing.m) {
                open
                if source.projectSlug != nil {
                    Text(dest).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
                SavedMoreMenu(source: source, model: model)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Brand.spacing.s) {
                    open
                    Spacer(minLength: 0)
                    SavedMoreMenu(source: source, model: model)
                }
                if source.projectSlug != nil {
                    Text(dest).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
                }
            }
        }
    }

    /// "Guardar en 🚀 Kickoff ▾" / "Guardar sin proyecto ▾" / "Guardar hilo (3) en 🚀 Kickoff ▾": the label saves
    /// (⌘↩), the chevron picks another project or "Solo este mensaje". Truncates, never fixed-size.
    private func smartButton(_ detail: MailModel.Detail, pending: Int) -> some View {
        let conversation = detail.thread.count > 1 && pending > 1
        let slug = detail.projectLocked ? detail.existingThreadProject : model.projectSlug
        let project = state.project(slug)
        let title: String
        switch (conversation, project) {
        case (true, let p?): title = L("mail.addConversationTo", pending, "\(p.emoji) \(p.name)")
        case (true, nil): title = L("mail.saveConversationNoProject", pending)
        case (false, let p?): title = L("mail.saveTo", "\(p.emoji) \(p.name)")
        case (false, nil): title = L("mail.saveNoProject")
        }
        let selectedIn = model.source(for: detail.message.summary.id) != nil
        let help = (conversation ? L("mail.addConversation.help") : L("mail.addTo.help")) + "\n" + L("readonly.promise")
        return SplitActionButton(title: title, help: help, menuHelp: L("mail.changeProject")) {
            model.add(onlyThis: false)
        } menu: {
            if detail.projectLocked {
                Text(L("email.projectLocked"))   // "Va al proyecto del hilo"
            } else {
                projectChoices
            }
            if conversation, !selectedIn {
                Divider()
                Button(L("mail.onlyThis")) { model.add(onlyThis: true) }
            }
        }
        .disabled(model.isSaving)
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
                    Label(L("inbox.title"), systemImage: "checkmark")
                } else {
                    Text(L("inbox.title"))
                }
            }
        }
    }

    /// "Por la regla «De @acme.com → 🚀 Acme»" / "Proyecto por defecto" next to the smart button.
    private var destinationWhy: String? {
        switch model.destinationReason {
        case .rule(let rule):
            return L("rules.mail.byRule", ruleLabel(rule))
        case .defaultProject:
            return L("rules.mail.byDefault")
        default:
            return nil
        }
    }

    /// "🚀 Kickoff", or "Sin asignar" (the project emoji is data; no emoji of ours).
    private func destination(_ slug: String?) -> String {
        if let project = state.project(slug) { return "\(project.emoji) \(project.name)" }
        return L("inbox.title")
    }
}

/// A primary button with an attached ▾ menu, drawn with the brand tokens (`accent` / `onAccent`, radius `control`,
/// height 28). The label truncates when the column is narrow.
private struct SplitActionButton<MenuContent: View>: View {
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
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressOpacityStyle())
            .keyboardShortcut(.return, modifiers: .command)
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

/// Pressed = 0.92 opacity, like the brand buttons.
private struct PressOpacityStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.92 : 1)
    }
}

/// ⋯ next to "Guardado": Ver en el proyecto · Quitar (with confirmation once it was learned).
private struct SavedMoreMenu: View {
    let source: SourceRecord
    let model: MailModel
    @ViewState private var confirmRemove = false

    var body: some View {
        Menu {
            Button(source.projectSlug == nil ? L("mail.seeUnassigned") : L("mail.seeInProject")) { model.open(source) }
            Divider()
            Button(L("mail.remove"), role: .destructive) {
                if source.status == .done { confirmRemove = true } else { model.remove(source) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Brand.color.text2)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()   // a fixed glyph, not text
        .help(L("mail.more"))
        .confirmationDialog(L("mail.removeConfirm"), isPresented: $confirmRemove) {
            Button(L("mail.remove"), role: .destructive) { model.remove(source) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("mail.removeConfirm.message"))
        }
    }
}

/// Earlier messages quoted in this one, folded.
private struct QuotedHistory: View {
    let text: String
    @ViewState private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Text(L("mail.quoted")).font(Brand.callout).foregroundStyle(Brand.color.text2)
        }
    }
}

/// Round initials of a sender: `Brand.avatar` (cardAlt background, text2 initials), never random hues.
private struct Initials: View {
    let name: String

    var body: some View {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(letters.isEmpty ? "?" : letters)
            .font(Brand.avatar.font(34))
            .foregroundStyle(Brand.avatar.initials)
            .frame(width: 34, height: 34)
            .background(Brand.avatar.background, in: Circle())
            .accessibilityHidden(true)
    }
}
