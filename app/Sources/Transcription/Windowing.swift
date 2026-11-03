import Accelerate
import Foundation

/// A span of speech, in seconds, optionally attributed to a diarizer speaker id.
public struct SpeechTurn: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: Int?
    public init(start: Double, end: Double, speaker: Int? = nil) {
        self.start = start; self.end = end; self.speaker = speaker
    }
}

/// Plans the audio windows sent to Whisper.
///
/// Whisper detects language once per window, so plain 30 s windows label a mixed es/en stretch
/// with a single language (and translate the minority one). Windows here follow speaker turns
/// (system track) or utterances (mic), so each language switch at a turn gets its own detection.
public enum Windowing {
    public static let sampleRate = 16000

    /// Joins consecutive turns of the same speaker (and sub-second blips) separated by < `joinGap`,
    /// never overlapping, padded by `pad` seconds, each at most `maxSeconds` long.
    public static func windows(for turns: [SpeechTurn], totalSeconds: Double, joinGap: Double = 1.5,
                               maxSeconds: Double = 28, pad: Double = 0.3) -> [SpeechTurn] {
        var out: [SpeechTurn] = []
        for t in turns.sorted(by: { $0.start < $1.start }) where t.end > t.start {
            var turn = t
            if let last = out.last {
                if turn.end <= last.end { continue }
                turn.start = max(turn.start, last.end)
                let gap = turn.start - last.end
                let blip = turn.end - turn.start < 1.0
                if (last.speaker == turn.speaker || blip), gap < joinGap, turn.end - last.start <= maxSeconds {
                    out[out.count - 1].end = turn.end
                    continue
                }
            }
            out.append(turn)
        }
        // Pad without crossing neighbours so words cut by the diarizer's boundaries survive.
        for i in out.indices {
            let lo = i > 0 ? (out[i - 1].end + out[i].start) / 2 : 0
            let hi = i < out.count - 1 ? (out[i].end + out[i + 1].start) / 2 : totalSeconds
            out[i].start = max(lo, out[i].start - pad)
            out[i].end = min(hi, out[i].end + pad)
        }
        return out
    }

    /// Speech regions by short-term energy (for the single-speaker mic track or as a fallback).
    public static func energyTurns(_ audio: [Float], threshold: Float = 0.004, frame: Double = 0.05,
                                   hangover: Double = 0.5, minLength: Double = 0.2) -> [SpeechTurn] {
        let n = Int(frame * Double(sampleRate))
        guard n > 0, !audio.isEmpty else { return [] }
        var turns: [SpeechTurn] = []
        audio.withUnsafeBufferPointer { buf in
            var i = 0
            var open: Double?
            var lastActive = 0.0
            while i < buf.count {
                let j = min(buf.count, i + n)
                let active = vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: buf[i..<j])) >= threshold
                let t = Double(i) / Double(sampleRate)
                if active {
                    if open == nil { open = t }
                    lastActive = Double(j) / Double(sampleRate)
                } else if let s = open, t - lastActive >= hangover {
                    if lastActive - s >= minLength { turns.append(SpeechTurn(start: s, end: lastActive)) }
                    open = nil
                }
                i = j
            }
            if let s = open, lastActive - s >= minLength { turns.append(SpeechTurn(start: s, end: lastActive)) }
        }
        return turns
    }

    /// Converts windows to sample ranges, splitting any longer than `maxLength` samples at the
    /// longest silence in its second half (same rule as WhisperKit's VADAudioChunker).
    public static func sampleRanges(_ windows: [SpeechTurn], audio: [Float], maxLength: Int) -> [Range<Int>] {
        windows.flatMap { w -> [Range<Int>] in
            let a = sampleIndex(w.start, count: audio.count)
            let b = max(a, sampleIndex(w.end, count: audio.count))
            return b > a ? split(audio, a..<b, maxLength: maxLength) : []
        }
    }

    /// Seconds → sample index in 0...count, clamped in Double space: `Int(_:)` traps on NaN, ±inf or values past
    /// Int.max, which a bad Whisper/SpeakerKit timestamp could produce.
    static func sampleIndex(_ seconds: Double, count: Int) -> Int {
        let x = seconds * Double(sampleRate)
        guard !x.isNaN, x > 0 else { return 0 }          // NaN, negatives and -inf → start of the audio
        return x >= Double(count) ? count : Int(x)        // +inf and anything past the end → end of the audio
    }

    static func split(_ audio: [Float], _ range: Range<Int>, maxLength: Int) -> [Range<Int>] {
        guard maxLength > 0, range.count > maxLength else { return [range] }   // maxLength 0 would never advance
        let frame = sampleRate / 10
        var ranges: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > maxLength {
            let limit = start + maxLength
            let mid = start + maxLength / 2
            var quietest = limit, quietestRMS = Float.infinity
            audio.withUnsafeBufferPointer { buf in
                var i = mid
                while i + frame <= limit {
                    let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: buf[i..<i + frame]))
                    if rms < quietestRMS { quietestRMS = rms; quietest = i + frame / 2 }
                    i += frame
                }
            }
            ranges.append(start..<quietest)
            start = quietest
        }
        ranges.append(start..<range.upperBound)
        return ranges
    }
}
