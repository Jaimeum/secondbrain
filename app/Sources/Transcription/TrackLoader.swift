import Accelerate
import Foundation
import WhisperKit

/// Loads a session track (CONTRACT §3) as one contiguous 16 kHz float timeline.
enum TrackLoader {
    static let sampleRate = 16000

    /// Chunk k is placed at exactly k * chunkSeconds; short or missing non-final chunks are zero-padded
    /// so timestamps stay absolute from session start.
    static func load(chunks: [URL], chunkSeconds: Int) throws -> [Float] {
        let chunkSamples = max(1, chunkSeconds) * sampleRate
        var out = [Float]()
        out.reserveCapacity(chunks.count * chunkSamples)
        for (k, url) in chunks.enumerated() {
            let isLast = k == chunks.count - 1
            var samples = FileManager.default.fileExists(atPath: url.path) ? try readWAV(url) : []
            if !isLast {
                if samples.count > chunkSamples { samples.removeLast(samples.count - chunkSamples) }
                if samples.count < chunkSamples { samples.append(contentsOf: repeatElement(0, count: chunkSamples - samples.count)) }
            }
            out.append(contentsOf: samples)
        }
        return out
    }

    /// Fast path for 16 kHz mono PCM16 (tolerates a crash-truncated header);
    /// anything else goes through WhisperKit's resampling loader.
    static func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let samples = pcm16Mono16k(data) { return samples }
        return try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    }

    private static func pcm16Mono16k(_ data: Data) -> [Float]? {
        guard data.count >= 12 else { return nil }
        func u32(_ o: Int) -> Int { data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) } }
        func u16(_ o: Int) -> Int { data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) } }
        guard data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { return nil }

        var offset = 12
        var formatOK = false
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                guard body + 16 <= data.count else { return nil }
                let format = u16(body), channels = u16(body + 2), rate = u32(body + 4), bits = u16(body + 14)
                formatOK = (format == 1 || format == 0xFFFE) && channels == 1 && rate == sampleRate && bits == 16
                if !formatOK { return nil }
            } else if id == "data" {
                guard formatOK else { return nil }
                // A header left at 0 / 0xFFFFFFFF by an interrupted recording: use what is on disk.
                let available = data.count - body
                let length = (size == 0 || size > available) ? available : size
                let count = length / 2
                guard count > 0 else { return [] }
                var out = [Float](repeating: 0, count: count)
                data.withUnsafeBytes { raw in
                    let base = raw.baseAddress!.advanced(by: body)
                    if Int(bitPattern: base) % MemoryLayout<Int16>.alignment == 0 {
                        let src = UnsafeBufferPointer(start: base.assumingMemoryBound(to: Int16.self), count: count)
                        vDSP.convertElements(of: src, to: &out)
                    } else {
                        let copy = [Int16](unsafeUninitializedCapacity: count) { buf, n in
                            memcpy(buf.baseAddress!, base, count * 2); n = count
                        }
                        vDSP.convertElements(of: copy, to: &out)
                    }
                }
                vDSP.multiply(1.0 / 32768.0, out, result: &out)
                return out
            }
            offset = body + size + (size & 1)
        }
        return nil
    }

    static func rms(_ audio: [Float], from start: Double, to end: Double) -> Double {
        let a = Windowing.sampleIndex(start, count: audio.count)
        let b = max(a, Windowing.sampleIndex(end, count: audio.count))
        guard b > a else { return 0 }
        return audio.withUnsafeBufferPointer { Double(vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: $0[a..<b]))) }
    }
}
