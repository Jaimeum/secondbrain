import Foundation
import Observation
import BrainCore

// TEMPORARY skeleton of docs/CONTRACT.md §5.2. Agent A replaces it (same public signatures) and deletes this file.

public struct RecorderPermissions: Equatable, Sendable {
    public var screenAudio: Bool
    public var microphone: Bool
    public init(screenAudio: Bool, microphone: Bool) { self.screenAudio = screenAudio; self.microphone = microphone }
}
public enum PrivacyPane: Sendable { case screenRecording, microphone }

@MainActor @Observable public final class Recorder {
    public enum State: Equatable { case idle, starting, recording(since: Date), stopping, failed(String) }
    public private(set) var state: State = .idle
    public private(set) var systemLevel: Float = 0
    public private(set) var micLevel: Float = 0
    public private(set) var current: SessionManifest?
    public init(sessionsDir: URL) {}
    public func start(title: String?, projectSlug: String?, captureMic: Bool) async throws -> SessionManifest { fatalError("TODO") }
    public func stop() async throws -> SessionManifest { fatalError("TODO") }
    public func updateCurrent(title: String?, projectSlug: String?) { fatalError("TODO") }
    public static func permissions() async -> RecorderPermissions { fatalError("TODO") }
    public static func requestMicrophone() async -> Bool { fatalError("TODO") }
    public static func requestScreenCapture() async -> Bool { fatalError("TODO") }
    public static func openPrivacySettings(_ pane: PrivacyPane) { fatalError("TODO") }
    public static func recoverInterruptedSessions(in sessionsDir: URL) -> [SessionManifest] { fatalError("TODO") }
}
