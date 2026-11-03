import Foundation

// MARK: v0.7.3 auto-updates — the app-side rules around Sparkle (SecondBrain/Support/Updates.swift), kept here so
// `sb selftest` can check them without a bundle or a network.

public enum UpdatePolicy {
    /// Where the running bundle lives, as far as updating it in place goes.
    public enum Location: Equatable, Sendable {
        /// /Applications or ~/Applications: Sparkle replaces it at the same path, permissions survive.
        case applications
        /// Opened straight from Downloads after Gatekeeper's App Translocation: a read-only random path.
        case translocated
        /// Running from the mounted DMG (/Volumes/…): read-only.
        case diskImage
        /// Anywhere else (a build folder, the Desktop): updates still work, but the user should move it.
        case elsewhere
    }

    public static func location(bundlePath: String, home: String = NSHomeDirectory()) -> Location {
        let path = (bundlePath as NSString).standardizingPath
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        let userApps = (home as NSString).appendingPathComponent("Applications")
        for dir in ["/Applications", userApps] where path.hasPrefix(dir + "/") { return .applications }
        return .elsewhere
    }

    /// A transcription in progress: an install (which quits the app) would cut it short.
    public static func isTranscribing(_ jobs: [Job]) -> Bool {
        jobs.contains { $0.kind == .transcribe && $0.status == .running }
    }

    /// "Reiniciar y actualizar" is offered only when quitting interrupts nothing: no recording (or one starting or
    /// stopping) and no transcription running.
    public static func canInstallNow(isRecording: Bool, recorderBusy: Bool, jobs: [Job]) -> Bool {
        !isRecording && !recorderBusy && !isTranscribing(jobs)
    }
}
