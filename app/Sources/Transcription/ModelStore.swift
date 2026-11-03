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

    /// Serializes every WhisperKit/SpeakerKit call on these instances (see `ModelGate`).
    nonisolated let gate = ModelGate()

    /// WhisperKit/SpeakerKit are reference types without Sendable conformance and are not safe to call
    /// concurrently. Handing them out of the actor is safe only because callers make every model call
    /// through `gate`, one at a time, and never ask WhisperKit to decode in parallel.
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

        // Already-downloaded models skip the download stages, so this is what a normal launch shows.
        report(0, Messages.loadingModels)
        // 0.00–0.70 Whisper download, 0.70–0.75 SpeakerKit download, 0.75–1.00 compile/load.
        let whisperFolder = try await downloadWhisper { fraction in
            report(0.70 * fraction, Messages.downloadingWhisper(fraction))
        }

        // Make sure every SpeakerKit file is on disk first (see `downloadSpeakerKit`), then let the
        // diarizer resolve them: with a complete cache its own resolve validates offline.
        try await downloadSpeakerKit { fraction in
            report(0.70 + 0.05 * fraction, Messages.downloadingSpeakers(fraction))
        }
        let pyannote = PyannoteConfig(downloadBase: modelsDir.path, download: true, load: false, verbose: false, logLevel: .none)
        let diarizer = SpeakerKitDiarizer.pyannote(config: pyannote)
        try await (diarizer as ModelManager).downloadModels()
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

    // MARK: - Downloads
    //
    // The Hub cache alone can't tell a complete model from an interrupted download: each file is moved
    // into place atomically, but files that never arrived simply aren't there, and the offline
    // validation (and `resolveRepo`) only checks the files that are. Core ML then crashes the whole
    // process (EXC_BAD_ACCESS, not an error) loading a `.mlmodelc` whose `weights/weight.bin` is
    // missing. So a model counts as downloaded only once a full online snapshot finished, recorded by
    // a marker in `<modelsDir>/.complete/`, and the `.mlmodelc` folders look whole.

    static let speakerRepo = "argmaxinc/speakerkit-coreml"

    private func markerURL(_ id: String) -> URL {
        modelsDir.appendingPathComponent(".complete", isDirectory: true).appendingPathComponent(id)
    }

    private func isMarkedComplete(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(id).path)
    }

    private func setMarked(_ id: String, _ complete: Bool) {
        let url = markerURL(id)
        if complete {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func repoRoot(_ repo: String) -> URL {
        HubApiWrapper(downloadBase: modelsDir).localRepoLocation(HubApiWrapper.Repo(id: repo, type: .models))
    }

    /// Uses the local copy when it is marked complete and still looks whole; otherwise downloads
    /// (resuming partial files, skipping the ones already there) with progress.
    private func downloadWhisper(_ progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let variant = whisperVariant
        let marker = "whisperkit-\(variant)"
        let local = repoRoot(Self.whisperRepo).appendingPathComponent(variant)
        let downloader = ModelDownloader(config: ModelDownloadConfig(downloadBase: modelsDir.path, modelRepo: Self.whisperRepo))
        let validatesOffline = { (try? await downloader.resolveRepo(patterns: ["\(variant)/*"], download: false)) != nil }

        if isMarkedComplete(marker), Self.hasWhisperModels(local), Self.modelsLookWhole(in: local), await validatesOffline() {
            return local
        }
        setMarked(marker, false)
        progress(0)
        let throttle = Throttle()
        do {
            let folder = try await WhisperKit.download(variant: variant, downloadBase: modelsDir, from: Self.whisperRepo) { p in
                if throttle.shouldEmit(p.fractionCompleted) { progress(p.fractionCompleted) }
            }
            guard Self.hasWhisperModels(folder), Self.modelsLookWhole(in: folder) else {
                throw TranscriptionError.modelUnavailable(variant)
            }
            setMarked(marker, true)
            progress(1)
            return folder
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Offline with a copy from before the markers existed: use it if it looks whole.
            if Self.hasWhisperModels(local), Self.modelsLookWhole(in: local), await validatesOffline() {
                return local
            }
            if error is TranscriptionError { throw error }
            throw TranscriptionError.modelUnavailable(variant)
        }
    }

    /// Same idea for the SpeakerKit (pyannote) models, which SpeakerKit itself would only resolve
    /// through the offline shortcut once any of their files exist.
    private func downloadSpeakerKit(_ progress: @escaping @Sendable (Double) -> Void) async throws {
        let marker = "speakerkit-pyannote"
        let local = repoRoot(Self.speakerRepo)
        if isMarkedComplete(marker), Self.modelsLookWhole(in: local, expecting: 4) {
            return
        }
        setMarked(marker, false)
        progress(0)
        let patterns = [ModelInfo.segmenter(), ModelInfo.embedder(), ModelInfo.plda()].map(\.downloadPattern)
        let throttle = Throttle()
        do {
            _ = try await HubApiWrapper(downloadBase: modelsDir).snapshot(
                from: HubApiWrapper.Repo(id: Self.speakerRepo, type: .models), matching: patterns
            ) { p in
                if throttle.shouldEmit(p.fractionCompleted) { progress(p.fractionCompleted) }
            }
            try Task.checkCancellation()
            // The Hub client silently validates offline when it thinks there's no network.
            guard Self.modelsLookWhole(in: local, expecting: 4) else { throw TranscriptionError.modelUnavailable("speakerkit") }
            setMarked(marker, true)
            progress(1)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.modelsLookWhole(in: local, expecting: 4) { return }
            if error is TranscriptionError { throw error }
            throw TranscriptionError.modelUnavailable("speakerkit")
        }
    }

    static func hasWhisperModels(_ folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
            FileManager.default.fileExists(atPath: ModelUtilities.detectModelURL(inFolder: folder, named: $0).path)
        }
    }

    /// Every compiled model under `folder` has the files Core ML needs (at least `expecting` of them).
    /// Catches the folders an interrupted download leaves half-filled.
    static func modelsLookWhole(in folder: URL, expecting minimum: Int = 1) -> Bool {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        var count = 0
        for case let url as URL in walker where url.pathExtension == "mlmodelc" {
            walker.skipDescendants()
            count += 1
            let has = { (name: String) in fm.fileExists(atPath: url.appendingPathComponent(name).path) }
            guard has("coremldata.bin"), has("metadata.json") else { return false }
            if has("model.mil") {
                let mil = (try? String(contentsOf: url.appendingPathComponent("model.mil"), encoding: .utf8)) ?? ""
                if mil.contains("weights/weight.bin"), !has("weights/weight.bin") { return false }
            } else if !has("model.espresso.net") {
                return false
            }
        }
        return count >= minimum
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
