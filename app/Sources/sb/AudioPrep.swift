import AVFoundation
import Foundation

/// Converts arbitrary audio files to the recorder's on-disk format (16 kHz mono Int16 WAV chunks, CONTRACT §3).
enum AudioPrep {
    static func loadMono16k(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 65_536) else {
            throw CLIError("Can't convert \(url.lastPathComponent)")
        }
        converter.downmix = true
        var samples: [Int16] = []
        samples.reserveCapacity(Int(Double(file.length) * 16_000 / inFormat.sampleRate) + 1)
        var finished = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 65_536) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do { try file.read(into: inBuffer, frameCount: 65_536) } catch { inBuffer.frameLength = 0 }
                if inBuffer.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let error { throw error }
            if let data = out.int16ChannelData, out.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return samples
    }

    /// Writes `prefix_000.wav`, `prefix_001.wav`… each `chunkSeconds` long (the last may be shorter).
    static func writeChunks(_ samples: [Int16], prefix: String, chunkSeconds: Int, sampleRate: Int, dir: URL) throws -> [String] {
        let perChunk = max(1, chunkSeconds * sampleRate)
        var names: [String] = []
        var offset = 0
        repeat {
            let end = min(samples.count, offset + perChunk)
            let name = String(format: "%@_%03d.wav", prefix, names.count)
            try writeWAV(samples[offset..<end], sampleRate: sampleRate, to: dir.appendingPathComponent(name))
            names.append(name)
            offset = end
        } while offset < samples.count
        return names
    }

    static func writeWAV(_ samples: ArraySlice<Int16>, sampleRate: Int, to url: URL) throws {
        let dataSize = UInt32(samples.count * 2)
        var header = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + dataSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); put(dataSize)
        var data = header
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }   // host is little-endian
        try data.write(to: url, options: .atomic)
    }
}
