import Foundation

/// Keeps a track on the session's wall-clock timeline: given where a buffer *should* start
/// (seconds since the session's start) and how many samples were already written, decides how many
/// zeros to insert first or how many leading samples to drop. Small deviations (jitter, resampler
/// latency) are tolerated and the buffer is just appended, so audio stays gapless.
struct TimelineAligner {
    var sampleRate: Double
    var tolerance: Int

    init(sampleRate: Int, toleranceSeconds: Double = 0.08) {
        self.sampleRate = Double(sampleRate)
        self.tolerance = Int(Double(sampleRate) * toleranceSeconds)
    }

    func plan(written: Int, startSeconds: Double, count: Int) -> (pad: Int, skip: Int) {
        let target = Int((startSeconds * sampleRate).rounded())
        let diff = target - written
        if diff > tolerance { return (diff, 0) }
        if diff < -tolerance { return (0, min(-diff, count)) }
        return (0, 0)
    }
}

/// Writes one track as consecutive WAV chunks (`<name>_000.wav`, ...). Chunk k covers exactly
/// [k*chunkSeconds, (k+1)*chunkSeconds) of the timeline. Not thread-safe: use from one serial queue.
final class ChunkedTrackWriter {
    let name: String
    let directory: URL
    let sampleRate: Int
    let chunkSamples: Int
    /// Called after a new chunk file is created, with its file name.
    var onChunkOpened: ((String) -> Void)?
    /// Samples at or beyond this timeline index are discarded (set when stopping).
    var limit: Int?

    private(set) var totalSamples = 0
    private(set) var fileNames: [String] = []
    private(set) var isFinished = false
    private var file: WAVWriter?
    private let aligner: TimelineAligner

    init(name: String, directory: URL, sampleRate: Int, chunkSeconds: Int) {
        self.name = name
        self.directory = directory
        self.sampleRate = sampleRate
        self.chunkSamples = sampleRate * chunkSeconds
        self.aligner = TimelineAligner(sampleRate: sampleRate)
    }

    static func fileName(track: String, index: Int) -> String { String(format: "%@_%03d.wav", track, index) }

    /// Appends samples that started at `startSeconds` on the timeline (nil = trust contiguity).
    func write(_ samples: UnsafeBufferPointer<Int16>, at startSeconds: Double?) throws {
        guard !isFinished else { return }
        var src = samples
        if let startSeconds {
            let plan = aligner.plan(written: totalSamples, startSeconds: startSeconds, count: samples.count)
            if plan.pad > 0 { try appendSilence(plan.pad) }
            if plan.skip > 0 { src = UnsafeBufferPointer(rebasing: samples[plan.skip...]) }
        }
        try append(src)
    }

    func write(_ samples: [Int16], at startSeconds: Double?) throws {
        try samples.withUnsafeBufferPointer { try write($0, at: startSeconds) }
    }

    /// Zero-fills up to `sampleIndex` if the track is behind (no buffers arriving).
    func fill(to sampleIndex: Int) throws {
        guard !isFinished, sampleIndex > totalSamples else { return }
        try appendSilence(sampleIndex - totalSamples)
    }

    /// Pads the track to exactly `sampleIndex` samples and closes the current chunk.
    func finish(at sampleIndex: Int) throws {
        guard !isFinished else { return }
        limit = sampleIndex
        try fill(to: sampleIndex)
        if fileNames.isEmpty { try openChunk() }   // always leave at least one (possibly empty) file
        try file?.close()
        file = nil
        isFinished = true
    }

    private var room: Int {
        guard let limit else { return .max }
        return max(0, limit - totalSamples)
    }

    private func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        var offset = 0
        var remaining = min(samples.count, room)
        while remaining > 0 {
            let writer = try currentFile()
            let n = min(remaining, chunkSamples - writer.sampleCount)
            try writer.append(UnsafeBufferPointer(rebasing: samples[offset..<(offset + n)]))
            try advance(by: n)
            offset += n
            remaining -= n
        }
    }

    private func appendSilence(_ count: Int) throws {
        var remaining = min(count, room)
        while remaining > 0 {
            let writer = try currentFile()
            let n = min(remaining, chunkSamples - writer.sampleCount)
            try writer.appendSilence(n)
            try advance(by: n)
            remaining -= n
        }
    }

    private func advance(by n: Int) throws {
        totalSamples += n
        if let file, file.sampleCount >= chunkSamples {
            try file.close()
            self.file = nil
        }
    }

    private func currentFile() throws -> WAVWriter {
        if let file { return file }
        return try openChunk()
    }

    @discardableResult
    private func openChunk() throws -> WAVWriter {
        let fileName = Self.fileName(track: name, index: fileNames.count)
        let writer = try WAVWriter(url: directory.appendingPathComponent(fileName), sampleRate: sampleRate)
        file = writer
        fileNames.append(fileName)
        onChunkOpened?(fileName)
        return writer
    }
}
