import BrainCore
import SwiftUI

// v0.7 (CONTRACT §17.6): the confirmation sheet of mail saved backwards — Correo's multi-select ("Guardar 3 hilos") and
// a rule's "Traer anteriores" ("Encontré 15 correos anteriores de @acme.com"). One row per conversation (checkbox;
// already-saved ones disabled), its attachments grouped by message with checkboxes preselected by the triage (§17.1:
// keep ✓, ambiguous ✓, discard ☐ with its reason in grey, too big ☐ "Muy grande"), then "Guardar n".

struct MailBatchSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MailBatchModel
    /// Snapshots: don't start loading (the caller already did).
    var autoStart = true

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 380, idealHeight: 520)
        .background(Brand.color.surface)
        .task { if autoStart { model.start(state: state) } }
        .onDisappear { model.cancel() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Brand.spacing.contentWide)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private var title: String {
        switch model.origin {
        case .selection:
            let n = model.conversations.isEmpty ? Set(selectionThreads).count : model.conversations.count
            return L("batch.title.selection", n)
        case .rule(let rule):
            if model.phase == .searching { return L("batch.title.searching") }
            let found = model.matchedCount == 0 && model.phase != .loading ? L("batch.title.none") : L("batch.title.rule", model.matchedCount)
            return Self.who(rule).map { L("batch.title.ruleFrom", found, $0) } ?? found
        }
    }

    private var subtitle: String {
        let destination = state.projectName(model.projectSlug)
        switch model.origin {
        case .selection:
            return L("batch.subtitle.selection", destination)
        case .rule(let rule):
            let window = L("batch.subtitle.window", L("batch.days", MailBackfill.days), destination)
            return Self.who(rule) == nil ? L("batch.subtitle.rule", ruleLabel(rule)) + " · " + window : window
        }
    }

    private var selectionThreads: [String] {
        if case .selection(let list, _) = model.origin { return list.map(\.threadId) }
        return []
    }

    /// "@acme.com" / "ana@acme.com" for a rule about the sender (the title says "de …"); nil for any other rule.
    static func who(_ rule: RoutingRule) -> String? {
        guard rule.conditions.count == 1, let c = rule.conditions.first, c.op == .is || c.op == .endsWith else { return nil }
        var v = c.value.trimmingCharacters(in: .whitespaces)
        switch c.field {
        case .senderDomain:
            while v.hasPrefix("@") || v.hasPrefix("*") || v.hasPrefix(".") { v.removeFirst() }
            return v.isEmpty ? nil : "@" + v
        case .senderEmail:
            return v.isEmpty ? nil : v
        default:
            return nil
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .searching:
            BrandLoader(size: 24, text: L("batch.searching"))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Brand.color.danger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Brand.spacing.contentWide)
        case .loading where model.conversations.isEmpty:
            BrandLoader(size: 24, text: L("batch.loading"))
        default:
            if model.conversations.isEmpty {
                EmptyStateView(symbol: "tray", title: L("batch.empty.title"),
                               message: L("batch.empty.message", L("batch.days", MailBackfill.days)))
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.conversations) { conversation in
                    ConversationRow(model: model, conversation: conversation)
                    if conversation.id != model.conversations.last?.id {
                        Rectangle().fill(Brand.color.lineSoft).frame(height: 1).padding(.leading, 26)
                    }
                }
                if model.phase == .loading {
                    BrandLoader(size: 18)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Brand.spacing.m)
                }
            }
            .padding(.horizontal, Brand.spacing.contentWide)
        }
        .brandScrollEdgeFade(.top)
        .brandScrollEdgeFade(.bottom)
    }

    // MARK: Footer

    private var footer: some View {
        BrandSheetFooter(horizontalPadding: Brand.spacing.contentWide) {
            Text(summary)
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("common.cancel")) { dismiss() }
                .buttonStyle(.brandGhost)
                .keyboardShortcut(.cancelAction)
            Button(model.messagesToSave > 0 ? L("batch.save", model.messagesToSave) : L("batch.saveNothing")) {
                model.save()
                dismiss()
            }
            .buttonStyle(.brandPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(model.messagesToSave == 0 || model.isBusy)
        }
    }

    /// "2 adjuntos · 1 hilo ya guardado" — or the read-only promise when there is nothing else to say.
    private var summary: String {
        var parts: [String] = []
        // "Encontré 15" counts what the rule matched; "Guardar 19" saves whole conversations: say where the 4 come from.
        if case .rule = model.origin, model.messagesToSave > model.matchedCount, model.matchedCount > 0 {
            parts.append(L("batch.wholeThreads", model.messagesToSave - model.matchedCount))
        }
        if model.attachmentsToSave > 0 { parts.append(L("batch.attachments", model.attachmentsToSave)) }
        if model.alreadySavedCount > 0 { parts.append(L("batch.alreadySaved", model.alreadySavedCount)) }
        return parts.isEmpty ? L("readonly.promise") : parts.joined(separator: " · ")
    }
}

// MARK: - Conversation row

private struct ConversationRow: View {
    @Environment(AppState.self) private var state
    @Bindable var model: MailBatchModel
    let conversation: MailBatchModel.Conversation

    private var included: Bool { model.included.contains(conversation.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { included && !conversation.isFullySaved },
                                     set: { _ in model.toggle(conversation: conversation.id) }))
                .toggleStyle(.brandCheckbox)
                .labelsHidden()
                .disabled(conversation.isFullySaved)
                .accessibilityLabel(conversation.subject)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conversation.subject.isEmpty ? L("mail.noSubject") : conversation.subject)
                        .font(Brand.font(13, .semibold))
                        .foregroundStyle(conversation.isFullySaved ? Brand.color.text2 : Brand.color.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(conversation.subject)
                    Spacer(minLength: 4)
                    Text(Fmt.dayTime(conversation.lastDate))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Text(caption)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if conversation.attachmentsLoading {
                    HStack(spacing: 6) {
                        BrandLoader(size: 12)
                        Text(L("batch.attachmentsLoading")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                    }
                    .padding(.top, 2)
                } else if !conversation.attachments.isEmpty, !conversation.isFullySaved {
                    attachments
                        .padding(.top, 4)
                        .opacity(included ? 1 : 0.5)
                }
                if let error = conversation.attachmentsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.warning)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// "3 correos · Sofía, Tú, Laura" · "Ya guardado" · "2 nuevos de 3 · Sigue en 🎨 Norte".
    private var caption: String {
        if conversation.isFullySaved { return L("batch.row.saved", state.projectName(conversation.storedProject)) }
        var parts: [String] = []
        let total = conversation.messages.count
        let missing = conversation.missing.count
        parts.append(missing == total ? L("batch.row.messages", total) : L("batch.row.newOf", L("batch.row.new", missing), total))
        if let stored = conversation.storedProject, stored != model.projectSlug {
            parts.append(L("batch.row.staysIn", state.projectName(stored)))
        }
        parts.append(people)
        return parts.joined(separator: " · ")
    }

    /// Who wrote, in order of first appearance; the account's owner is "Tú".
    private var people: String {
        let mine = Set([conversation.account.email.lowercased()] + state.engine.vault.ownerEmails())
        var seen = Set<String>()
        var names: [String] = []
        for m in conversation.messages {
            let email = (m.summary.from.email ?? m.summary.from.display).lowercased()
            guard seen.insert(email).inserted else { continue }
            names.append(mine.contains(email) ? L("mail.you") : Self.firstName(m.summary.from.display))
        }
        return names.joined(separator: ", ")
    }

    static func firstName(_ display: String) -> String {
        if display.contains("@") { return display }
        return display.split(separator: " ").first.map(String.init) ?? display
    }

    /// The attachments, grouped by message ("Sofía Herrera · ayer 10:02").
    private var attachments: some View {
        let groups = Dictionary(grouping: conversation.attachments, by: \.messageId)
        let order = conversation.missing.map(\.summary.id).filter { groups[$0] != nil }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(order, id: \.self) { messageId in
                if let message = conversation.missing.first(where: { $0.summary.id == messageId }) {
                    VStack(alignment: .leading, spacing: 4) {
                        if order.count > 1 || conversation.missing.count > 1 {
                            Text(message.summary.from.display + " · " + Fmt.dayTime(message.summary.date))
                                .font(Brand.font(11, .medium))
                                .foregroundStyle(Brand.color.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        ForEach(groups[messageId] ?? []) { item in
                            AttachmentCheckRow(item: item, checked: model.checkedAttachments.contains(item.id),
                                               enabled: included && item.info.isDownloadable) {
                                model.toggle(attachment: item.id)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.lineSoft))
    }
}

/// [✓] 📄 Contrato.pdf · 1.2 MB · (reason in grey)
private struct AttachmentCheckRow: View {
    let item: MailBatchModel.Attachment
    let checked: Bool
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { checked }, set: { _ in toggle() }))
                .toggleStyle(.brandCheckbox)
                .labelsHidden()
                .disabled(!enabled)
                .accessibilityLabel(item.info.name)
            Image(systemName: Self.symbol(item.info))
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .frame(width: 14)
            Text(item.info.name)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.info.name)
            if item.info.size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.info.size), countStyle: .file))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let reason = Self.reason(item) {
                Text(reason)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
            }
            Spacer(minLength: 0)
        }
    }

    static func symbol(_ info: AttachmentInfo) -> String {
        let ext = info.fileExtension
        if info.mimeType.hasPrefix("image/") { return "photo" }
        if info.mimeType.hasPrefix("video/") { return "film" }
        if ext == "pdf" { return "doc.richtext" }
        if ["xls", "xlsx", "csv", "numbers"].contains(ext) { return "tablecells" }
        if ["ppt", "pptx", "key"].contains(ext) { return "rectangle.on.rectangle" }
        if ext == "zip" { return "doc.zipper" }
        return "doc"
    }

    /// Why it starts unticked (§17.1), in grey; nothing for what is kept or left to the user.
    static func reason(_ item: MailBatchModel.Attachment) -> String? {
        if !item.info.isDownloadable { return L("batch.reason.notFile") }
        switch item.decision {
        case .keep, .ask: return nil
        case .tooBig: return L("batch.reason.tooBig")
        case .discard(let why):
            switch why {
            case .inlineImage, .junkName: return L("batch.reason.logo")
            case .smallImage: return L("batch.reason.small")
            case .junkType: return L("batch.reason.junkType")
            case .duplicate: return L("batch.reason.duplicate")
            case .claude(let text): return text
            case .user: return nil
            }
        }
    }
}

/// The "Traer anteriores…" sheet of a mail rule (after creating it, or from its menu): the batch sheet in rule mode,
/// saving to the rule's project.
struct RuleBackfillItem: Identifiable {
    let id = UUID()
    let rule: RoutingRule
}

struct RuleBackfillSheet: View {
    @ViewState private var model: MailBatchModel

    init(rule: RoutingRule) {
        _model = ViewState(initialValue: MailBatchModel(origin: .rule(rule), projectSlug: rule.projectSlug))
    }

    var body: some View {
        MailBatchSheet(model: model)
    }
}

/// "Traer anteriores…" is offered for rules that catch mail, when there is a mail account to look in.
@MainActor func canBackfill(_ rule: RoutingRule, state: AppState) -> Bool {
    MailBackfill.isMailRule(rule) && !state.engine.accounts.mailAccounts.isEmpty
}
