import AppKit
import BrainCore
import SwiftUI

// v0.7 attach (CONTRACT §17.1): the attachments of the message open in Correo, each with where it stands —
// Guardado · Descartado (razón) · No guardado · Muy grande — and "Guardar" for what isn't in the brain yet (only once
// the email itself is saved: an attachment always lives next to its email). Read-only on the mailbox.
struct MailAttachmentsList: View {
    @Environment(AppState.self) private var state
    let message: MailMessageFull
    let account: ConnectedAccount
    /// The email's source, when it is in the brain.
    let source: SourceRecord?

    @ViewState private var attachments: [AttachmentInfo]?
    @ViewState private var states: [String: AttachmentState] = [:]
    @ViewState private var loadError: String?
    @ViewState private var saving: Set<String> = []
    @ViewState private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("attach.title"), systemImage: "paperclip")
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text2)
            if let attachments {
                VStack(spacing: 0) {
                    ForEach(Array(attachments.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Rectangle().fill(Brand.color.line).frame(height: 1) }
                        row(a)
                    }
                }
                .background(Brand.color.surface, in: RoundedRectangle(cornerRadius: Brand.radius.control))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius.control).stroke(Brand.color.line, lineWidth: 1))
                if source == nil, attachments.contains(where: { if case .notSaved = states[$0.id] { true } else { false } }) {
                    Text(L("attach.saveEmailFirst")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let loadError {
                Text(L("attach.failed", loadError)).font(Brand.caption).foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: Brand.spacing.s) {
                    ProgressView().controlSize(.small)
                    Text(L("attach.loading")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                }
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(Brand.caption).foregroundStyle(Brand.color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: message.summary.id) { await load() }
        .onChange(of: source?.id) { refreshStates() }
        .onChange(of: state.vaultRevision) { refreshStates() }
    }

    // MARK: Row

    private func row(_ a: AttachmentInfo) -> some View {
        let st = states[a.id] ?? .notSaved(.ask)
        return HStack(spacing: Brand.spacing.s) {
            Image(systemName: Self.symbol(a))
                .font(.system(size: 14))
                .foregroundStyle(Brand.color.text2)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(a.name)
                Text(detail(a, st))
                    .font(Brand.caption)
                    .foregroundStyle(color(st))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action(a, st)
        }
        .padding(.horizontal, Brand.spacing.m)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func action(_ a: AttachmentInfo, _ st: AttachmentState) -> some View {
        if saving.contains(a.id) {
            ProgressView().controlSize(.small)
        } else {
            switch st {
            case .saved(let entry):
                Button { open(entry) } label: { Text(L("attach.open")).lineLimit(1) }
                    .buttonStyle(.plain)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.accent)
                    .fixedSize()
            case .notSaved, .tooBig, .discarded:
                let anyway: Bool = { if case .tooBig = st { return true }; return false }()
                Button { save(a) } label: { Text(L(anyway ? "attach.saveAnyway" : "attach.save")).lineLimit(1) }
                    .buttonStyle(.plain)
                    .font(Brand.callout)
                    .foregroundStyle(source == nil ? Brand.color.text3 : Brand.color.accent)
                    .disabled(source == nil)
                    .fixedSize()
                    .help(source == nil ? L("attach.saveEmailFirst") : L("attach.save.help"))
            case .notAFile:
                EmptyView()
            }
        }
    }

    /// "182 KB · Guardado", "4 KB · Descartado (logo o firma)", "30 MB · Muy grande".
    private func detail(_ a: AttachmentInfo, _ st: AttachmentState) -> String {
        let size = a.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file) + " · " : ""
        return size + Self.stateLabel(st)
    }

    static func stateLabel(_ st: AttachmentState) -> String {
        switch st {
        case .saved: L("attach.state.saved")
        case .discarded(let item): L("attach.state.discarded", item.reason.label)
        case .notSaved: L("attach.state.notSaved")
        case .tooBig: L("attach.state.tooBig")
        case .notAFile: L("attach.state.notAFile")
        }
    }

    private func color(_ st: AttachmentState) -> Color {
        switch st {
        case .saved: Brand.color.success
        case .tooBig: Brand.color.warning
        default: Brand.color.text2
        }
    }

    static func symbol(_ a: AttachmentInfo) -> String {
        if AttachmentTriage.isImage(a) { return "photo" }
        switch a.fileExtension {
        case "pdf": return "doc.richtext"
        case "xls", "xlsx", "csv", "numbers": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        case "zip": return "doc.zipper"
        case "ics": return "calendar"
        case "eml": return "envelope"
        default: return "doc.text"
        }
    }

    // MARK: Actions

    private func load() async {
        attachments = nil
        loadError = nil
        saveError = nil
        let provider = state.engine.accounts.provider(for: account)
        do {
            let list = try await provider.listAttachments(messageId: message.summary.id)
            guard !Task.isCancelled else { return }
            attachments = list
            refreshStates()
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            loadError = FriendlyError.message(error)
        }
    }

    private func refreshStates() {
        guard let attachments else { return }
        states = state.engine.attachmentStates(messageSourceId: source?.id, attachments: attachments,
                                               inlineContentIds: message.inlineContentIds)
    }

    private func save(_ a: AttachmentInfo) {
        guard source != nil, !saving.contains(a.id) else { return }
        saving.insert(a.id)
        saveError = nil
        let engine = state.engine
        Task {
            defer { saving.remove(a.id) }
            do {
                let report = try await engine.saveAttachments(for: message, account: account, mode: .confirmed([a.id]),
                                                              attachments: attachments)
                if !report.failed.isEmpty { saveError = L("attach.saveFailed", a.name) }
                state.bumpVault()
            } catch {
                saveError = FriendlyError.message(error)
            }
            refreshStates()
        }
    }

    private func open(_ entry: ThreadAttachment) {
        NSWorkspace.shared.open(state.engine.vault.url(for: entry.file))
    }
}

extension MailModel {
    /// Snapshot (`mail-attachments`): the demo contract email saved, its attachments triaged forward (Claude simulated:
    /// it keeps the whiteboard photo) → Guardado · Descartado (logo o firma) · Guardado. Writes to the scratch vault.
    static func snapshotAttachments(state: AppState) async -> MailModel? {
        state.engine.autoProcess = false
        let model = MailModel()
        model.start(state: state)
        await model.waitUntilReady()
        guard let account = model.account,
              let target = model.messages.first(where: { $0.hasAttachments && $0.id == "demo-m11" }) ?? model.messages.first(where: \.hasAttachments)
        else { return nil }
        model.select(target.id)
        await model.waitUntilReady()
        if model.source(for: target.id) == nil { model.add(onlyThis: true) }
        model.dismissToast()
        guard let message = model.detail?.message else { return model }
        _ = try? await state.engine.saveAttachments(for: message, account: account, mode: .automatic) { _, candidates, _ in
            candidates.map { AttachmentTriageVerdict(name: $0.name, keep: true, reason: nil) }
        }
        state.bumpVault()
        try? await Task.sleep(for: .milliseconds(300))
        return model
    }
}

extension DiscardReason {
    /// Why it was left out, short ("logo o firma", "ya estaba guardado", Claude's own words…), for Correo, Archivos ›
    /// Descartados and the save sheet.
    var label: String {
        switch self {
        case .inlineImage: L("attach.reason.inlineImage")
        case .smallImage: L("attach.reason.smallImage")
        case .junkName: L("attach.reason.junkName")
        case .junkType: L("attach.reason.junkType")
        case .duplicate: L("attach.reason.duplicate")
        case .claude(let why): why.isEmpty ? L("attach.reason.claude") : why
        case .user: L("attach.reason.user")
        }
    }
}
