import AVFAudio
import BrainCore
import CoreMedia
import Foundation
import os

/// One recording: owns the captures, the per-track chunk writers and the manifest. All audio
/// conversion, file I/O and manifest mutation happen on `queue` (serial, never the main thread).
final class RecordingSession: @unchecked Sendable {
    let directory: URL
    let startHost: Double
    let levels = LevelMeter()
    /// Called on `queue` whenever session.json is rewritten.
    var onManifestChange: ((SessionManifest) -> Void)?
    /// Called on `queue` for problems worth surfacing while still recording.
    var onWarning: ((RecorderWarning) -> Void)?
    /// Called on `queue` when the problem behind an earlier warning went away (e.g. the mic came back).
    var onWarningCleared: ((RecorderWarning) -> Void)?

    private let queue = DispatchQueue(label: "app.secondbrain.recorder.writer", qos: .userInitiated)
    private let log = Logger(subsystem: "app.secondbrain.mac", category: "Recorder")
    private var manifest: SessionManifest
    private let sampleRate: Int
    private var writers: [String: ChunkedTrackWriter] = [:]
    private var resamplers: [String: MonoResampler] = [:]
    private var system: SystemAudioCapture?
    private var mic: MicCapture?
    private var ticker: DispatchSourceTimer?
    private var systemRestarts = 0
    private var stopping = false

    /// How far behind "now" a silent track is zero-filled while recording. Must exceed the worst
    /// delivery latency of real buffers, or late audio would be dropped as overlap.
    private static let fillLag = 2.0

    init(sessionsDir: URL, title: String?, projectSlug: String?, captureMic: Bool,
         calendarEventId: String? = nil, attendees: [String]? = nil) throws {
        let startedAt = Date()
        startHost = AudioMath.hostSeconds()
        let id = SessionManifest.newId(at: startedAt)
        directory = sessionsDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var tracks = ["system": [String]()]
        if captureMic { tracks["mic"] = [] }
        manifest = SessionManifest(id: id, title: title, projectSlug: projectSlug, startedAt: startedAt,
                                   tracks: tracks, micCaptured: captureMic,
                                   calendarEventId: calendarEventId, attendees: attendees)
        sampleRate = manifest.sampleRate
        for track in tracks.keys { addTrack(track) }
        try manifest.save(to: directory)
    }

    var snapshot: SessionManifest { queue.sync { manifest } }

    func start() async throws {
        ActiveSessions.insert(manifest.id)
        startTicker()

        let system = SystemAudioCapture(queue: queue, onBuffer: { [weak self] in self?.handleSystem($0) },
                                        onStop: { [weak self] in self?.systemStopped($0) })
        do {
            try await system.start()
        } catch {
            ticker?.cancel()
            ActiveSessions.remove(manifest.id)
            try? FileManager.default.removeItem(at: directory)
            throw RecorderError.from(systemCaptureError: error)
        }
        self.system = system

        guard writers["mic"] != nil else { return }
        let mic = MicCapture { [weak self] buffer, time in self?.handleMic(buffer, time) }
        mic.onFailure = { [weak self] _ in self?.micLost() }
        mic.onRecovery = { [weak self] in self?.micRecovered() }
        do {
            try mic.start()
            self.mic = mic
        } catch {
            log.error("Mic unavailable, recording system audio only: \(error.localizedDescription, privacy: .public)")
            await onQueue {
                self.writers["mic"] = nil
                self.manifest.tracks["mic"] = nil
                self.manifest.micCaptured = false
                self.saveManifest()
                self.onWarning?(.microphoneUnavailable)
            }
        }
    }

    func update(title: String?, projectSlug: String?) {
        queue.async {
            self.manifest.title = title
            self.manifest.projectSlug = projectSlug
            self.saveManifest()
        }
    }

    /// Stops capture and closes every track at the same wall-clock instant so both have exactly the
    /// same length.
    func stop() async -> SessionManifest {
        let endSample = max(0, Int(((AudioMath.hostSeconds() - startHost) * Double(sampleRate)).rounded()))
        await onQueue {
            self.stopping = true
            for writer in self.writers.values { writer.limit = endSample }
        }
        ticker?.cancel()
        await system?.stop()
        mic?.stop()
        system = nil
        mic = nil
        let result = await onQueue { () -> SessionManifest in
            for writer in self.writers.values.sorted(by: { $0.name > $1.name }) {
                do { try writer.finish(at: endSample) } catch { self.log.error("Finishing \(writer.name) failed: \(error.localizedDescription, privacy: .public)") }
            }
            self.manifest.endedAt = self.manifest.startedAt.addingTimeInterval(Double(endSample) / Double(self.sampleRate))
            self.saveManifest()
            return self.manifest
        }
        ActiveSessions.remove(result.id)
        return result
    }

    // MARK: - Queue work

    private func addTrack(_ name: String) {
        let writer = ChunkedTrackWriter(name: name, directory: directory, sampleRate: sampleRate, chunkSeconds: manifest.chunkSeconds)
        writer.onChunkOpened = { [unowned self] file in
            manifest.tracks[name, default: []].append(file)
            saveManifest()
        }
        writers[name] = writer
        resamplers[name] = MonoResampler(mix: name == "system" ? .average : .firstChannel, sampleRate: sampleRate)
    }

    private func handleSystem(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = sampleBuffer.pcmBuffer() else { return }
        let pts = sampleBuffer.presentationTimeStamp
        write(track: "system", pcm, hostSeconds: pts.isValid ? pts.seconds : nil)
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let copy = buffer.copy() else { return }
        let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
        queue.async { self.write(track: "mic", copy, hostSeconds: host) }
    }

    private func write(track: String, _ pcm: AVAudioPCMBuffer, hostSeconds: Double?) {
        guard let writer = writers[track], let resampler = resamplers[track], !writer.isFinished else { return }
        let samples = resampler.process(pcm)
        guard !samples.isEmpty else { return }
        levels.report(track, AudioMath.level(samples))
        do {
            try writer.write(samples, at: timelinePosition(hostSeconds))
        } catch {
            log.error("Writing \(track) failed: \(error.localizedDescription, privacy: .public)")
            onWarning?(.diskWriteFailed)
        }
    }

    /// Seconds since the session start, or nil if the timestamp is missing or implausible (then
    /// the buffer is appended contiguously).
    private func timelinePosition(_ hostSeconds: Double?) -> Double? {
        guard let hostSeconds else { return nil }
        let position = hostSeconds - startHost
        let now = AudioMath.hostSeconds() - startHost
        return (position > -5 && position < now + 1) ? position : nil
    }

    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopping else { return }
            let target = Int((AudioMath.hostSeconds() - self.startHost - Self.fillLag) * Double(self.sampleRate))
            for writer in self.writers.values {
                do { try writer.fill(to: target) } catch { self.log.error("Zero-fill failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        timer.resume()
        ticker = timer
    }

    private func systemStopped(_ error: Error) {
        log.error("System audio stream stopped: \(error.localizedDescription, privacy: .public)")
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            guard self.systemRestarts < 5 else { self.onWarning?(.systemAudioLost); return }
            self.systemRestarts += 1
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let system = self.system else { return }
                do { try await system.start() } catch {
                    self.log.error("System audio restart failed: \(error.localizedDescription, privacy: .public)")
                    self.queue.async { self.onWarning?(.systemAudioLost) }
                }
            }
        }
    }

    /// The mic died mid-recording and can't be restarted for now: keep its track (zero-filled from here
    /// on, so both tracks stay the same length), record the outage in session.json and tell the user.
    private func micLost() {
        let at = max(0, AudioMath.hostSeconds() - startHost)
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            var outages = self.manifest.micOutages ?? []
            if outages.last.map({ $0.end != nil }) ?? true { outages.append(MicOutage(start: at)) }
            self.manifest.micOutages = outages
            self.saveManifest()
            self.onWarning?(.microphoneUnavailable)
        }
    }

    /// MicCapture brought the mic back after `micLost`: close the open outage.
    private func micRecovered() {
        let at = max(0, AudioMath.hostSeconds() - startHost)
        queue.async { [weak self] in
            guard let self, !self.stopping, var outages = self.manifest.micOutages,
                  let last = outages.indices.last, outages[last].end == nil else { return }
            outages[last].end = at
            self.manifest.micOutages = outages
            self.saveManifest()
            self.onWarningCleared?(.microphoneUnavailable)
            self.log.notice("Microphone recovered after \(at - outages[last].start, format: .fixed(precision: 1)) s")
        }
    }

    private func saveManifest() {
        do { try manifest.save(to: directory) } catch {
            log.error("Saving session.json failed: \(error.localizedDescription, privacy: .public)")
        }
        onManifestChange?(manifest)
    }

    private func onQueue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// Latest meter values, written from the audio queue and read (and reset) by the UI poller.
final class LevelMeter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String: Float]())

    func report(_ track: String, _ level: Float) {
        lock.withLock { $0[track] = max($0[track] ?? 0, level) }
    }

    /// Peak per track since the last call.
    func take() -> [String: Float] {
        lock.withLock { levels in
            defer { levels.removeAll() }
            return levels
        }
    }
}

/// Session ids currently being recorded in this process (skipped by crash recovery).
enum ActiveSessions {
    private static let ids = OSAllocatedUnfairLock(initialState: Set<String>())
    static func insert(_ id: String) { ids.withLock { _ = $0.insert(id) } }
    static func remove(_ id: String) { ids.withLock { _ = $0.remove(id) } }
    static func contains(_ id: String) -> Bool { ids.withLock { $0.contains(id) } }
}
