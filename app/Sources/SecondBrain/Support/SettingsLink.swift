import AppKit
import SwiftUI

/// Opens Ajustes, optionally on a tab (CONTRACT §15.2): `SettingsLink.open(tab:)` writes `settings.selectedTab`
/// (general | accounts | github | rules | formats | advanced), which SettingsView reads and clears on appear, then
/// shows the Settings window. It shadows SwiftUI's `SettingsLink` inside this module, so it is also a drop-in view
/// with the same shape (`SettingsLink { Text("…") }`, now with an optional `tab:`).
struct SettingsLink<Label: View>: View {
    var tab: String?
    let label: Label

    init(tab: String? = nil, @ViewBuilder label: () -> Label) {
        self.tab = tab
        self.label = label()
    }

    var body: some View {
        Button { SettingsLinkOpener.open(tab: tab) } label: { label }
    }
}

extension SettingsLink where Label == EmptyView {
    static var tabKey: String { SettingsLinkOpener.tabKey }

    @MainActor static func open(tab: String? = nil) { SettingsLinkOpener.open(tab: tab) }
}

@MainActor
enum SettingsLinkOpener {
    static let tabKey = "settings.selectedTab"

    /// Set by MainView from `@Environment(\.openSettings)`, the reliable way to show Settings on macOS 14+.
    static var opener: (() -> Void)?

    static func open(tab: String?) {
        if let tab { UserDefaults.standard.set(tab, forKey: tabKey) }
        NSApp.activate(ignoringOtherApps: true)
        if let opener {
            opener()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
