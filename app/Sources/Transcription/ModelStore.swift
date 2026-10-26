import Foundation
import SpeakerKit
import WhisperKit

/// Downloads (into `modelsDir`, Hub layout) and keeps the WhisperKit / SpeakerKit instances alive.
actor ModelStore {
    static let whisperRepo = "argmaxinc/whisperkit-coreml"

    nonisolated let modelName: String
    let modelsDir: URL
    private(set) var whisper: WhisperKit?
    private(set) var speaker: SpeakerKit?
    private var loading: Task<Void, Error>?

    /// WhisperKit/SpeakerKit are reference types without Sendable conformance; the transcription
    /// queue is serial, so handing them out of the actor is safe in practice.
    struct Loaded: @unchecked Sendable {
        let whisper: WhisperKit
        let speaker: SpeakerKit
    }

    func loadedModels() -> Loaded? {
        guard let whisper, let speaker else { return nil }
        return Loaded(whisper: whisper, speaker: speaker)
    }

    init(modelName: String, modelsDir: URL) {
        self.modelName = modelName
        self.modelsDir = modelsDir
    }

    var whisperVariant: String {
        modelName.hasPrefix("openai_whisper-") || modelName.hasPrefix("distil-whisper_") ? modelName : "openai_whisper-\(modelName)"
    }

    func ensureLoaded(_ report: @escaping @Sendable (Double, String) -> Void) async throws {
        if whisper != nil && speaker != nil { return }
        if let loading { return try await loading.value }
        let task = Task { try await self.load(report) }
        loading = task
        do {
            try await task.value
            loading = nil
        } catch {
            loading = nil
            throw error
        }
    }

    private func load(_ report: @escaping @Sendable (Double, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // 0.00–0.70 Whisper download, 0.70–0.75 SpeakerKit download, 0.75–1.00 compile/load.
        let whisperFolder = try await downloadWhisper { fraction in
            report(0.70 * fraction, Messages.downloadingWhisper(fraction))
        }

        // Build the diarizer ourselves so its download can report progress, then hand it to SpeakerKit.
        let pyannote = PyannoteConfig(downloadBase: modelsDir.path, download: true, load: false, verbose: false, logLevel: .none)
        let diarizer = SpeakerKitDiarizer.pyannote(config: pyannote)
        report(0.70, Messages.downloadingSpeakers(0))
        let throttle = Throttle()
        try await (diarizer as ModelManager).downloadModels { (progress: Progress) in
            let f = progress.fractionCompleted
            if throttle.shouldEmit(f) { report(0.70 + 0.05 * f, Messages.downloadingSpeakers(f)) }
        }
        pyannote.diarizer = diarizer
        pyannote.download = false
        let speakerKit = try await SpeakerKit(pyannote)

        // Core ML compiles for the Neural Engine on first load (~1–2 min) without progress: ease forward.
        let ticker = Task {
            var f = 0.75
            while !Task.isCancelled {
                report(f, Messages.optimizing)
                try? await Task.sleep(for: .seconds(1))
                f += (0.97 - f) * 0.02
            }
        }
        defer { ticker.cancel() }

        let config = WhisperKitConfig(
            modelFolder: whisperFolder.path,
            tokenizerFolder: modelsDir,
            verbose: false,
            logLevel: .none,
            load: true,
            download: false
        )
        let whisperKit = try await WhisperKit(config)
        try await speakerKit.ensureModelsLoaded()
        ticker.cancel()

        whisper = whisperKit
        speaker = speakerKit
        report(1, Messages.ready)
    }

    /// Uses the local copy when the Hub cache validates offline; otherwise downloads with progress.
    private func downloadWhisper(_ progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let variant = whisperVariant
        let downloader = ModelDownloader(config: ModelDownloadConfig(downloadBase: modelsDir.path, modelRepo: Self.whisperRepo))
        if let root = try? await downloader.resolveRepo(patterns: ["\(variant)/*"], download: false),
           Self.hasWhisperModels(root.appendingPathComponent(variant)) {
            progress(1)
            return root.appendingPathComponent(variant)
        }
        progress(0)
        let throttle = Throttle()
        let folder = try await WhisperKit.download(variant: variant, downloadBase: modelsDir, from: Self.whisperRepo) { p in
            if throttle.shouldEmit(p.fractionCompleted) { progress(p.fractionCompleted) }
        }
        guard Self.hasWhisperModels(folder) else {
            throw TranscriptionError.modelUnavailable(variant)
        }
        progress(1)
        return folder
    }

    static func hasWhisperModels(_ folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
            FileManager.default.fileExists(atPath: ModelUtilities.detectModelURL(inFolder: folder, named: $0).path)
        }
    }
}

/// Emits only when the integer percentage changes.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func shouldEmit(_ fraction: Double) -> Bool {
        let pct = Int((fraction * 100).rounded(.down))
        lock.lock(); defer { lock.unlock() }
        guard pct != last else { return false }
        last = pct
        return true
    }
}

public enum TranscriptionError: LocalizedError {
    case modelUnavailable(String)
    case noAudio

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let name): return Messages.modelUnavailable(name)
        case .noAudio: return Messages.noAudio
        }
    }
}
