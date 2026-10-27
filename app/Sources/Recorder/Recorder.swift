import AppKit
import AVFAudio
import BrainCore
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit

public struct RecorderPermissions: Equatable, Sendable {
    public var screenAudio: Bool
    public var microphone: Bool
    public init(screenAudio: Bool, microphone: Bool) { self.screenAudio = screenAudio; self.microphone = microphone }
}

public enum PrivacyPane: Sendable { case screenRecording, microphone }

/// Non-fatal problems during a recording (the recording keeps going).
public enum RecorderWarning: Equatable, Sendable {
    case microphoneUnavailable   // recording system audio only
    case systemAudioLost         // ScreenCaptureKit stopped and couldn't be restarted; silence is recorded
    case diskWriteFailed
}

/// Records system audio + microphone into `sessionsDir/<sessionId>/` per docs/CONTRACT.md §3.
@MainActor @Observable public final class Recorder {
    public enum State: Equatable { case idle, starting, recording(since: Date), stopping, failed(String) }

    public private(set) var state: State = .idle
    public private(set) var systemLevel: Float = 0
    public private(set) var micLevel: Float = 0
    public private(set) var current: SessionManifest?
    /// Latest non-fatal problem of the current recording, for the UI to show. Cleared on start.
    public private(set) var warning: RecorderWarning?

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private let sessionsDir: URL
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    public init(sessionsDir: URL) {
        self.sessionsDir = sessionsDir
    }

    /// v0.3 (§12.5): `calendarEventId` / `attendees` (display names) tie the recording to its calendar event.
    public func start(title: String?, projectSlug: String?, captureMic: Bool,
                      calendarEventId: String? = nil, attendees: [String]? = nil) async throws -> SessionManifest {
        switch state {
        case .idle, .failed: break
        default: throw RecorderError.alreadyRecording
        }
        state = .starting
        warning = nil
        do {
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
            let session = try RecordingSession(sessionsDir: sessionsDir, title: title, projectSlug: projectSlug, captureMic: captureMic,
                                               calendarEventId: calendarEventId, attendees: attendees)
            session.onManifestChange = { [weak self] manifest in
                Task { @MainActor in
                    guard let self, self.current?.id == manifest.id else { return }
                    self.current = manifest
                }
            }
            session.onWarning = { [weak self] warning in
                Task { @MainActor in self?.warning = warning }
            }
            try await session.start()
            let manifest = session.snapshot
            self.session = session
            current = manifest
            state = .recording(since: manifest.startedAt)
            startMeters()
            return manifest
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func stop() async throws -> SessionManifest {
        guard let session, case .recording = state else { throw RecorderError.notRecording }
        state = .stopping
        stopMeters()
        let manifest = await session.stop()
        self.session = nil
        current = nil
        state = .idle
        return manifest
    }

    public func updateCurrent(title: String?, projectSlug: String?) {
        guard let session else { return }
        current?.title = title
        current?.projectSlug = projectSlug
        session.update(title: title, projectSlug: projectSlug)
    }

    // MARK: - Meters

    private func startMeters() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let levels = self.session?.levels.take() else { return }
                // Fast attack, smooth release.
                self.systemLevel = max(levels["system"] ?? 0, self.systemLevel * 0.75)
                self.micLevel = max(levels["mic"] ?? 0, self.micLevel * 0.75)
            }
        }
    }

    private func stopMeters() {
        meterTask?.cancel()
        meterTask = nil
        systemLevel = 0
        micLevel = 0
    }

    // MARK: - Permissions

    public static func permissions() async -> RecorderPermissions {
        RecorderPermissions(screenAudio: CGPreflightScreenCaptureAccess(),
                            microphone: AVAudioApplication.shared.recordPermission == .granted)
    }

    public static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Shows the system prompt the first time and registers the app in Privacy & Security → Screen
    /// & System Audio Recording. After the user enables it there, macOS may require relaunching
    /// the app before `permissions()` reports it.
    public static func requestScreenCapture() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return CGPreflightScreenCaptureAccess()
        }
    }

    /// "Reparar permiso": for a switch that is on in System Settings while recording still finds no permission. macOS
    /// ties each permission to the signature of the build that got it; when the signature changes (every ad-hoc build up
    /// to 0.5.2) the switch stays on but no longer applies, and macOS doesn't ask again either. Clears this app's own
    /// Screen & System Audio Recording entry (and the Microphone one, unless it works) with `tccutil`, which needs no
    /// admin rights, then asks again so the list shows this build. False if the reset failed.
    public static func repairPermissions() async -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let micWorks = AVAudioApplication.shared.recordPermission == .granted
        guard await resetPermission("ScreenCapture", bundleID: bundleID) else { return false }
        if !micWorks, await resetPermission("Microphone", bundleID: bundleID) {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        _ = await requestScreenCapture()
        return true
    }

    private nonisolated static func resetPermission(_ service: String, bundleID: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { cont.resume(returning: false) }
        }
    }

    public static func openPrivacySettings(_ pane: PrivacyPane) {
        let anchor = switch pane {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

public enum RecorderError: LocalizedError, Equatable {
    case screenCapturePermissionDenied
    case noDisplay
    case alreadyRecording
    case notRecording
    case microphoneUnavailable
    case systemAudioFailed(String)

    static func from(systemCaptureError error: Error) -> RecorderError {
        if let error = error as? RecorderError { return error }
        if !CGPreflightScreenCaptureAccess() { return .screenCapturePermissionDenied }
        if let sck = error as? SCStreamError, sck.code == .userDeclined { return .screenCapturePermissionDenied }
        return .systemAudioFailed(error.localizedDescription)
    }

    public var errorDescription: String? {
        let es = AppConfig.load().uiLanguage != "en"
        switch self {
        case .screenCapturePermissionDenied:
            return es ? "SecondBrain necesita permiso para grabar el audio de la computadora. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema."
                      : "SecondBrain needs permission to record your computer's audio. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .noDisplay:
            return es ? "No se encontró una pantalla para capturar el audio." : "No display was found to capture audio from."
        case .alreadyRecording:
            return es ? "Ya hay una grabación en curso." : "A recording is already in progress."
        case .notRecording:
            return es ? "No hay ninguna grabación en curso." : "Nothing is being recorded."
        case .microphoneUnavailable:
            return es ? "No se pudo usar el micrófono." : "The microphone couldn't be used."
        case .systemAudioFailed(let detail):
            return es ? "No se pudo empezar a grabar el audio de la computadora (\(detail))."
                      : "Couldn't start recording the computer's audio (\(detail))."
        }
    }
}
