import BrainCore
import SwiftUI

/// v0.7 (CONTRACT §17.1 backwards): "Guardar" in Correo on an email with attachments. The email is saved; this sheet
/// lists its attachments (and those of the rest of the conversation saved with it) with the triage's ticks — keep and
/// ambiguous ✓, discard ☐ with its reason — and the user confirms with "Guardar los marcados". Nothing is decided until
/// then: "Listo" closes it with whatever was not confirmed still undecided, and the reader keeps the same checklist.
struct MailAttachmentReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let review: AttachmentReview
    /// The email's source in the brain (by provider message id).
    let source: (String) -> SourceRecord?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("attach.review.title"))
                    .font(Brand.title)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("attach.review.hint"))
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Brand.spacing.contentWide)
            .padding(.top, 24)
            .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.spacing.l) {
                    ForEach(review.messages, id: \.summary.id) { message in
                        VStack(alignment: .leading, spacing: Brand.spacing.s) {
                            if review.messages.count > 1 {
                                Text(Self.caption(message))
                                    .font(Brand.callout)
                                    .foregroundStyle(Brand.color.text)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            MailAttachmentsList(message: message, account: review.account, source: source(message.summary.id))
                        }
                    }
                }
                .padding(.horizontal, Brand.spacing.contentWide)
                .padding(.vertical, Brand.spacing.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .brandScrollEdgeFade(.top)
            .brandScrollEdgeFade(.bottom)
            BrandSheetFooter(horizontalPadding: Brand.spacing.contentWide) {
                Text(L("readonly.promise"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("attach.review.done")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 320, idealHeight: 460)
        .background(Brand.color.surface)
    }

    /// "Sofía Herrera · 12 oct 10:24".
    static func caption(_ m: MailMessageFull) -> String {
        "\(m.summary.from.display) · \(Fmt.dayTime(m.summary.date))"
    }
}
