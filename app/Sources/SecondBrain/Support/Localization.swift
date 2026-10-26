import Foundation

/// Locates the app's SwiftPM resource bundle without relying on `Bundle.module`, whose generated
/// accessor looks next to the .app bundle (not in Contents/Resources) and traps if it is missing.
enum AppResources {
    static let bundle: Bundle = {
        let name = "SecondBrain_SecondBrain.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        // Not `Bundle.module`: its accessor traps when the bundle is missing. Without it, keys show instead of a crash.
        return Bundle.main
    }()

    static var webDirectory: URL {
        bundle.url(forResource: "web", withExtension: nil) ?? bundle.bundleURL.appendingPathComponent("web")
    }
}

/// In-app language switch: strings come from the explicitly chosen .lproj, not the system locale.
enum Localizer {
    nonisolated(unsafe) private static var current: (language: String, bundle: Bundle)?

    static var language: String {
        get { current?.language ?? "es" }
        set {
            let lang = newValue == "en" ? "en" : "es"
            let path = AppResources.bundle.path(forResource: lang, ofType: "lproj")
            current = (lang, path.flatMap(Bundle.init(path:)) ?? AppResources.bundle)
        }
    }

    static var locale: Locale { Locale(identifier: language == "en" ? "en_US" : "es_MX") }

    static func string(_ key: String) -> String {
        if current == nil { language = "es" }
        let bundle = current?.bundle ?? AppResources.bundle
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

/// Localized string for `key`, formatted with `args` when given (`%@`, `%d`, `%.0f` …).
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Localizer.string(key)
    return args.isEmpty ? format : String(format: format, locale: Localizer.locale, arguments: args)
}
