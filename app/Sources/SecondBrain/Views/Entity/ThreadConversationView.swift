import BrainCore
import SwiftUI

/// The conversation of an email thread (CONTRACT §17.4), shown by `EntityView` above the page Claude wrote for
/// `wiki/emails/<thread>.md`: each email in order (sender, date, what's new in it, attachments, "Abrir en …"), mine
/// marked "Tú".
// v0.7: filled in by threads (stub: draws nothing).
struct ThreadConversationView: View {
    @Environment(AppState.self) private var state
    let threadKey: String
    var scope: Scope = .brain

    var body: some View {
        EmptyView()
    }

    /// `<thread>` of `projects/<p>/wiki/emails/<thread>.md` (or any `wiki/emails/<thread>.md`); nil for other pages.
    static func threadKey(forPage path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[parts.count - 2] == "emails", parts[parts.count - 3] == "wiki",
              parts.last?.hasSuffix(".md") == true else { return nil }
        return ((parts.last ?? "") as NSString).deletingPathExtension
    }
}
