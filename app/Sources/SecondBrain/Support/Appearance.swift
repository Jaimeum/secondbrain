import SwiftUI

/// Light / dark / follow macOS (CONTRACT §12.1). Stored as `AppConfig.appearance`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L("theme.system")
        case .light: L("theme.light")
        case .dark: L("theme.dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
