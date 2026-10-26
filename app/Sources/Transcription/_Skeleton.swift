import Foundation
import BrainCore

// TEMPORARY skeleton of docs/CONTRACT.md §5.1. Agent B replaces it (same public signatures) and deletes this file.

public final class WhisperTranscriber: Transcribing, @unchecked Sendable {
    public init(modelName: String, modelsDir: URL) {}
    public var isReady: Bool { false }
    public func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws { fatalError("TODO") }
    public func transcribe(sessionDir: URL, manifest: SessionManifest,
                           progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript { fatalError("TODO") }
}
