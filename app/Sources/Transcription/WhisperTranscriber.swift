import Foundation
import BrainCore
import SpeakerKit
import WhisperKit

/// CONTRACT §5.1: local transcription (WhisperKit) + diarization of the system track (SpeakerKit).
public final class WhisperTranscriber: Transcribing, @unchecked Sendable {
    private let store: ModelStore
    private let lock = NSLock()
    private var loaded = false

    public init(modelName: String, modelsDir: URL) {
        store = ModelStore(modelName: modelName, modelsDir: modelsDir)
    }

    /// Language of progress/error messages: "es" (default) or "en".
    public var messageLanguage: String {
        get { Messages.language }
        set { Messages.language = newValue }
    }

    public var isReady: Bool {
        lock.withLock { loaded }
    }

    public func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {
        try await store.ensureLoaded { progress(ModelPrepProgress(fraction: $0, message: $1)) }
        lock.withLock { loaded = true }
        progress(ModelPrepProgress(fraction: 1, message: Messages.ready))
    }

    public func transcribe(sessionDir: URL, manifest: SessionManifest,
                           progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        if !isReady {
            progress(0, Messages.loadingModels)
            try await prepare { _ in }
        }
        guard let models = await store.loadedModels() else {
            throw TranscriptionError.modelUnavailable(store.modelName)
        }
        let whisper = models.whisper, speakerKit = models.speaker

        let files = { (track: String) in (manifest.tracks[track] ?? []).map { sessionDir.appendingPathComponent($0) } }
        let systemFiles = files("system")
        let micFiles = files("mic")
        guard !systemFiles.isEmpty || !micFiles.isEmpty else { throw TranscriptionError.noAudio }

        let hasMic = !micFiles.isEmpty
        let stage = hasMic
            ? (diarize: 0.02...0.15, system: 0.15...0.55, mic: 0.55...0.96)
            : (diarize: 0.02...0.20, system: 0.20...0.96, mic: 0.96...0.96)
        func report(_ range: ClosedRange<Double>, _ f: Double, _ message: (Double) -> String) {
            progress(range.lowerBound + (range.upperBound - range.lowerBound) * min(max(f, 0), 1), message(f))
        }

        progress(0, Messages.readingAudio)
        var durationSamples = 0
        var system: [RawSegment] = []
        var systemLanguages: Set<String> = []
        if !systemFiles.isEmpty {
            let audio = try TrackLoader.load(chunks: systemFiles, chunkSeconds: manifest.chunkSeconds)
            durationSamples = audio.count
            (system, systemLanguages) = try await processSystem(audio, whisper: whisper, speakerKit: speakerKit, stage: (stage.diarize, stage.system), report: report)
        }
        try Task.checkCancellation()

        var mic: [RawSegment] = []
        if hasMic {
            let audio = try TrackLoader.load(chunks: micFiles, chunkSeconds: manifest.chunkSeconds)
            durationSamples = max(durationSamples, audio.count)
            let seconds = Double(audio.count) / Double(Windowing.sampleRate)
            let plan = Windowing.windows(for: Windowing.energyTurns(audio), totalSeconds: seconds)
            let windows = try await transcribeTrack(whisper, audio, plan, knownLanguages: systemLanguages) {
                report(stage.mic, $0, Messages.transcribingMic)
            }
            mic = windows.flatMap { w in
                w.segments.map { s in
                    RawSegment(start: Double(s.start), end: Double(s.end), text: s.text, track: "mic", speaker: "me",
                               language: w.language, avgLogprob: Double(s.avgLogprob), noSpeechProb: Double(s.noSpeechProb),
                               compressionRatio: Double(s.compressionRatio),
                               rms: TrackLoader.rms(audio, from: Double(s.start), to: Double(s.end)))
                }
            }
        }
        Self.debugDump(system + mic)

        progress(0.97, Messages.merging)
        let merged = TranscriptMerge.relabelSystemSpeakers(TranscriptMerge.merge(system: system, mic: mic))
        let transcript = TranscriptMerge.transcript(from: merged, durationSeconds: Double(durationSamples) / Double(TrackLoader.sampleRate))
        progress(1, Messages.done)
        return transcript
    }

    // MARK: - System track

    private func processSystem(_ audio: [Float], whisper: WhisperKit, speakerKit: SpeakerKit,
                               stage: (diarize: ClosedRange<Double>, system: ClosedRange<Double>),
                               report: @escaping (ClosedRange<Double>, Double, (Double) -> String) -> Void) async throws -> ([RawSegment], Set<String>) {
        // Nothing but silence (e.g. an in-person meeting recorded only by the mic): skip the models.
        guard !Windowing.energyTurns(audio, threshold: Float(TranscriptMerge.silenceRMS)).isEmpty else { return ([], []) }
        let seconds = Double(audio.count) / Double(Windowing.sampleRate)

        // Diarize first: speaker turns drive the Whisper windows (one language detection per turn).
        report(stage.diarize, 0, Messages.identifyingSpeakers)
        let diarization = try? await diarize(speakerKit, audio) { report(stage.diarize, $0, Messages.identifyingSpeakers) }
        var turns = diarization?.segments.map {
            SpeechTurn(start: Double($0.startTime), end: Double($0.endTime), speaker: $0.speaker.speakerIds.first)
        } ?? []
        if turns.isEmpty { turns = Windowing.energyTurns(audio) }

        let windows = try await transcribeTrack(whisper, audio, Windowing.windows(for: turns, totalSeconds: seconds)) {
            report(stage.system, $0, Messages.transcribingMeeting)
        }
        let speakerOf = diarization.map { Self.wordSpeakers($0, windows.flatMap(\.segments)) } ?? [:]
        return (Self.systemSegments(windows, speakerOf: speakerOf, audio: audio), Set(windows.compactMap(\.language)))
    }

    // MARK: - Whisper

    struct Window {
        var range: Range<Int>                  // samples within the track
        var language: String?
        var segments: [TranscriptionSegment]   // absolute times
    }

    private static let decodeOptions = DecodingOptions(
        verbose: false,
        task: .transcribe,
        language: nil,
        usePrefillPrompt: true,
        detectLanguage: true,          // per window: meetings mix es/en
        skipSpecialTokens: true,
        wordTimestamps: true,
        concurrentWorkerCount: 4
    )

    /// Transcribes the planned windows (skipping near-silent ones) in small batches so progress and
    /// cancellation stay responsive. Returned segment times are absolute from session start.
    private func transcribeTrack(_ whisper: WhisperKit, _ audio: [Float], _ plan: [SpeechTurn],
                                 knownLanguages: Set<String> = [],
                                 progress: (Double) -> Void) async throws -> [Window] {
        let windowSamples = whisper.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        let ranges = Windowing.sampleRanges(plan, audio: audio, maxLength: windowSamples).filter {
            TrackLoader.rms(audio, from: Double($0.lowerBound) / 16000, to: Double($0.upperBound) / 16000) >= TranscriptMerge.silenceRMS
        }
        progress(0)
        guard !ranges.isEmpty else { progress(1); return [] }

        let totalSamples = Double(ranges.reduce(0) { $0 + $1.count })
        var doneSamples = 0.0
        var windows: [Window] = []
        var firstError: Error?
        let batchSize = 4
        for batchStart in stride(from: 0, to: ranges.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(ranges[batchStart..<min(batchStart + batchSize, ranges.count)])
            let (done, error) = await run(whisper, audio, batch, options: batch.map { _ in Self.decodeOptions })
            windows += done
            firstError = firstError ?? error
            doneSamples += Double(batch.reduce(0) { $0 + $1.count })
            progress(0.95 * doneSamples / totalSamples)
        }
        if windows.isEmpty, let firstError { throw firstError }

        // Short windows sometimes get an exotic language ("w noviembre" as Polish). Re-decode those
        // with the most likely language among the ones the meeting is actually spoken in.
        let speech = windows.map { w in
            (w.language, w.segments.reduce(0.0) { sum, s in
                let rms = TrackLoader.rms(audio, from: Double(s.start), to: Double(s.end))
                return rms >= TranscriptMerge.speechRMS ? sum + Double(s.end - s.start) : sum
            })
        }
        let allowed = knownLanguages.union(TranscriptMerge.meetingLanguages(speech))
        let outliers = windows.indices.filter { windows[$0].language.map { !allowed.contains($0) } ?? false }
        if !allowed.isEmpty, !outliers.isEmpty {
            var options: [DecodingOptions] = []
            for i in outliers {
                let probs = (try? await whisper.detectLangauge(audioArray: Array(audio[windows[i].range])).langProbs) ?? [:]
                var o = Self.decodeOptions
                o.language = allowed.max { (probs[$0] ?? -.infinity) < (probs[$1] ?? -.infinity) }
                o.detectLanguage = false
                options.append(o)
            }
            let (redone, _) = await run(whisper, audio, outliers.map { windows[$0].range }, options: options)
            let byRange = Dictionary(redone.map { ($0.range, $0) }, uniquingKeysWith: { a, _ in a })
            for i in outliers { if let w = byRange[windows[i].range] { windows[i] = w } }
        }
        progress(1)
        return windows
    }

    private func run(_ whisper: WhisperKit, _ audio: [Float], _ ranges: [Range<Int>],
                     options: [DecodingOptions]) async -> (windows: [Window], error: Error?) {
        let results = await whisper.transcribeWithOptions(
            audioArrays: ranges.map { Array(audio[$0]) },
            decodeOptionsArray: options
        )
        var windows: [Window] = []
        var firstError: Error?
        for (range, result) in zip(ranges, results) {
            switch result {
            case .success(let parts):
                // Whisper pads every window to 30 s and may "hear" text past its end.
                let windowEnd = Float(range.count) / 16000
                let segments = parts.flatMap(\.segments).compactMap { s -> TranscriptionSegment? in
                    guard s.start < windowEnd else { return nil }
                    var s = s
                    s.end = min(s.end, windowEnd)
                    s.words = s.words?.filter { $0.start < windowEnd }
                    return TranscriptionUtilities.updateSegmentTimings(segment: s, seekOffsetIndex: range.lowerBound)
                }
                let language = parts.first.map(\.language).flatMap { $0.isEmpty ? nil : $0 }
                windows.append(Window(range: range, language: language, segments: segments))
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        return (windows, firstError)
    }

    // MARK: - Diarization

    /// Diarizes the whole track at once so speaker identities stay consistent across the meeting.
    private func diarize(_ speakerKit: SpeakerKit, _ audio: [Float],
                         progress: @escaping (Double) -> Void) async throws -> DiarizationResult {
        let box = ProgressBox(progress)
        let result = try await speakerKit.diarize(audioArray: audio, options: nil) { p in box.send(p.fractionCompleted) }
        progress(1)
        return result
    }

    /// Speaker of every word, via SpeakerKit's `addSpeakerInfo`.
    static func wordSpeakers(_ diarization: DiarizationResult, _ segments: [TranscriptionSegment]) -> [WordTiming: Int] {
        let result = TranscriptionResult(text: "", segments: segments, language: "", timings: TranscriptionTimings())
        var map: [WordTiming: Int] = [:]
        for group in diarization.addSpeakerInfo(to: [result], strategy: .subsegment) {
            for segment in group {
                for word in segment.speakerWords {
                    if let id = word.speaker.speakerIds.first { map[word.wordTiming] = id }
                }
            }
        }
        return map
    }

    static func debugDump(_ segments: [RawSegment]) {
        guard ProcessInfo.processInfo.environment["SB_TRANSCRIBE_DEBUG"] != nil else { return }
        for s in segments.sorted(by: { $0.start < $1.start }) {
            FileHandle.standardError.write(Data(String(
                format: "[raw %6.2f–%6.2f] %@ %@ lang=%@ lp=%.2f nsp=%.2f cr=%.2f rms=%.4f %@\n",
                s.start, s.end, s.track, s.speaker, s.language ?? "-", s.avgLogprob, s.noSpeechProb,
                s.compressionRatio, s.rms, s.text).utf8))
        }
    }

    static func systemSegments(_ windows: [Window], speakerOf: [WordTiming: Int], audio: [Float]) -> [RawSegment] {
        var out: [RawSegment] = []
        for window in windows {
            for s in window.segments {
                let make = { (start: Float, end: Float, text: String, id: Int?) in
                    RawSegment(start: Double(start), end: Double(end), text: text, track: "system",
                               speaker: id.map(String.init) ?? "S?", language: window.language,
                               avgLogprob: Double(s.avgLogprob), noSpeechProb: Double(s.noSpeechProb),
                               compressionRatio: Double(s.compressionRatio),
                               rms: TrackLoader.rms(audio, from: Double(start), to: Double(end)))
                }
                guard let words = s.words, !words.isEmpty else {
                    out.append(make(s.start, s.end, s.text, nil))
                    continue
                }
                for run in TranscriptMerge.absorbShortRuns(TranscriptMerge.splitBySpeaker(words, speaker: { speakerOf[$0] })) {
                    out.append(make(run.words.first!.start, max(run.words.last!.end, run.words.first!.start),
                                    run.words.map(\.word).joined(), run.speaker))
                }
            }
        }
        return out
    }
}

/// Lets a non-Sendable progress closure be called from SpeakerKit's @Sendable callback.
private final class ProgressBox: @unchecked Sendable {
    private let fn: (Double) -> Void
    private let throttle = Throttle()
    init(_ fn: @escaping (Double) -> Void) { self.fn = fn }
    func send(_ f: Double) { if throttle.shouldEmit(f) { fn(f) } }
}
