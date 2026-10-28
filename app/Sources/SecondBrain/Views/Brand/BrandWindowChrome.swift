import AppKit
import SwiftUI

// MARK: Window chrome

/// The main window's titlebar and toolbar blend into the content (CONTRACT §15.1 "calm surfaces"): the titlebar is
/// transparent, so the sidebar's `bg` and the detail's `surface` run up to the top edge, and no AppKit separator line
/// is drawn under it, neither on the window nor on the split view's columns. The toolbar, the sidebar and the detail
/// meet without a hard edge or a corner (before, the system's whitish toolbar band and its separator met the sidebar
/// in a square corner under the title). Content that scrolls under the toolbar gets the system's soft scroll-edge
/// fade on macOS 26+. `toolbarBackground` keeps the toolbar in `surface` wherever AppKit still draws one.
struct BrandWindowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(Brand.color.surface, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .background(BrandWindowAccessor())
    }
}

extension View {
    /// Toolbar in the content's tone and no titlebar separator. Applied once, on the main window's root.
    func brandWindowChrome() -> some View { modifier(BrandWindowChrome()) }
}

/// Reaches the hosting `NSWindow` to drop the separators SwiftUI has no modifier for. Re-applied when the view moves
/// to a window, on every SwiftUI update and once more shortly after (NavigationSplitView builds its split view items
/// lazily and may reset them).
private struct BrandWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> AccessorView { AccessorView() }
    func updateNSView(_ nsView: AccessorView, context: Context) { nsView.apply() }

    final class AccessorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The split view controller appears a little after the first layout.
            DispatchQueue.main.async { [weak self] in self?.apply() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window else { return }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            window.backgroundColor = NSColor(Brand.color.bg)
            let controllers = Self.splitControllers(in: window.contentViewController)
                + Self.splitViews(in: window.contentView).compactMap { $0.delegate as? NSSplitViewController }
            for split in controllers {
                for item in split.splitViewItems where item.titlebarSeparatorStyle != .none {
                    item.titlebarSeparatorStyle = .none
                }
            }
        }

        private static func splitControllers(in controller: NSViewController?) -> [NSSplitViewController] {
            guard let controller else { return [] }
            var found: [NSSplitViewController] = []
            if let split = controller as? NSSplitViewController { found.append(split) }
            for child in controller.children { found += splitControllers(in: child) }
            return found
        }

        private static func splitViews(in view: NSView?) -> [NSSplitView] {
            guard let view else { return [] }
            var found: [NSSplitView] = []
            if let split = view as? NSSplitView { found.append(split) }
            for sub in view.subviews { found += splitViews(in: sub) }
            return found
        }
    }
}
