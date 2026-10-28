import AppKit
import BrainCore
import SwiftUI

// v0.7 backfill (CONTRACT §17.6, §17.8) — `SB_SNAPSHOT_WINDOW=1` shots: Correo with three messages checked and the
// selection bar ("mail-select-*"), the confirmation sheet with its attachment checklist ("batch-sheet-*") and the
// "Traer anteriores" sheet of a sender-domain rule ("batch-rule-*"). Ideal and minimum sizes, light and dark. Nothing
// is saved. Development only.
@MainActor
enum BackfillSnapshots {
    static func render(state: AppState, dir: URL) async {
        let only = ProcessInfo.processInfo.environment["SB_SNAPSHOT_ONLY"] ?? ""
        func wanted(_ name: String) -> Bool { only.isEmpty || name.hasPrefix(only) || only.hasPrefix("window-mail") }
        guard !state.engine.accounts.mailAccounts.isEmpty else { return }
        state.engine.autoProcess = false

        // Correo with a selection (the detail column of the 1100 and the minimum window).
        if wanted("mail-select") {
            let model = MailModel()
            model.start(state: state)
            await model.waitUntilReady()
            let selection = MailSelection()
            for m in model.messages.prefix(3) { selection.toggle(m.id) }
            for (size, sizeName) in [(CGSize(width: 880, height: 620), "1100"), (CGSize(width: 700, height: 580), "min")] {
                for dark in [false, true] {
                    await shot(MailView(model: model, selection: selection).environment(state), size: size, dark: dark,
                               to: dir.appendingPathComponent("mail-select-\(sizeName)-\(dark ? "dark" : "light").png"))
                }
            }
        }

        // The confirmation sheet for those conversations (synthetic attachments: the demo can't list them yet).
        if wanted("batch-sheet"), let account = state.engine.accounts.mailAccounts.first {
            let provider = state.engine.accounts.provider(for: account)
            let page = (try? await provider.listMessages(since: Date().addingTimeInterval(-30 * 86_400), pageToken: nil))?.messages ?? []
            let picked = Array(page.prefix(3))
            let model = MailBatchModel(origin: .selection(picked, account), projectSlug: state.projects.first?.slug)
            model.start(state: state)
            await model.waitUntilReady()
            model.injectSnapshotAttachments()
            await sheets("batch-sheet", MailBatchSheet(model: model, autoStart: false).environment(state), dir: dir)
        }

        // "Traer anteriores" for «De @acmelogistics.com → first project».
        if wanted("batch-rule"), let project = state.projects.first {
            // The demo vault's sender-domain rule (a new rule below it would never win for that mail).
            let rule = state.engine.routing.rules.first { $0.conditions.first?.field == .senderDomain }
                ?? RoutingRule(.senderDomain, .is, "acmelogistics.com", projectSlug: project.slug)
            let model = MailBatchModel(origin: .rule(rule), projectSlug: rule.projectSlug)
            model.start(state: state)
            await model.waitUntilReady()
            model.injectSnapshotAttachments()
            await sheets("batch-rule", MailBatchSheet(model: model, autoStart: false).environment(state), dir: dir)
        }
        // "Regla creada · Traer anteriores… · Deshacer" after "Sí, siempre" (the rule is removed again afterwards).
        if wanted("batch-offer"), let project = state.projects.first {
            let offer = RuleOffer()
            let rule = RoutingRule(.senderDomain, .is, "estudionorte.mx", projectSlug: project.slug)
            offer.show(rule, projectLabel: state.projectName(project.slug))
            offer.accept(state: state)
            offer.hold()
            for (width, name) in [(CGFloat(600), "wide"), (CGFloat(300), "narrow")] {
                for dark in [false, true] {
                    await shot(RuleOfferBar(offer: offer).padding(12).environment(state), size: CGSize(width: width, height: 110),
                               dark: dark, to: dir.appendingPathComponent("batch-offer-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
            try? state.engine.routing.remove(id: rule.id)
            offer.dismiss()
        }
    }

    /// A sheet at its ideal (620×520) and minimum (520×380) size, light and dark.
    private static func sheets(_ name: String, _ view: some View, dir: URL) async {
        for (size, sizeName) in [(CGSize(width: 620, height: 520), "ideal"), (CGSize(width: 520, height: 380), "min")] {
            for dark in [false, true] {
                await shot(view, size: size, dark: dark, to: dir.appendingPathComponent("\(name)-\(sizeName)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private static func shot(_ view: some View, size: CGSize, dark: Bool, to url: URL) async {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previous }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Brand.color.surface).brandEnvironment())
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
    }
}
