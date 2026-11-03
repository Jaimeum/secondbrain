import Foundation
import Transcription

// MARK: v0.7.3 transcribe crash — TranscriptMerge.collapseLoops trapped on `1...0` once a collapse left fewer than
// minRepeats words ("y y y" → "y"), crashing every retry of the same transcribe job. Pure text, no models or audio.

@MainActor func testTranscriptMerge(_ t: Tester) {
    // Inputs that used to trap (SIGTRAP): the collapse leaves 1–2 words.
    t.eq(TranscriptMerge.collapseLoops("y y y"), "y", "\"y y y\" collapses to one word")
    t.eq(TranscriptMerge.collapseLoops("y y y y y y"), "y", "six repeats collapse to one word")
    t.eq(TranscriptMerge.collapseLoops("a a a b"), "a b", "loop then a tail word")
    t.eq(TranscriptMerge.collapseLoops("x a a a"), "x a", "head word then a loop")
    t.eq(TranscriptMerge.collapseLoops("hola hola hola"), "hola", "\"hola hola hola\"")
    t.eq(TranscriptMerge.collapseLoops("no sé no sé no sé"), "no sé", "two-word loop collapses to one copy")
    t.eq(TranscriptMerge.collapseLoops("Gracias. Gracias. Gracias."), "Gracias.", "punctuated loop")

    // Unchanged behaviour on inputs that never trapped.
    t.eq(TranscriptMerge.collapseLoops("no sé no sé no sé no sé y luego"), "no sé y luego", "loop inside a sentence")
    t.eq(TranscriptMerge.collapseLoops("a b c a b c a b c d e f g"), "a b c d e f g", "three-word loop")
    t.eq(TranscriptMerge.collapseLoops("hola que tal"), "hola que tal", "no loop → unchanged")
    t.eq(TranscriptMerge.collapseLoops("no sé no sé"), "no sé no sé", "two repeats are below minRepeats")

    // Short and empty strings.
    t.eq(TranscriptMerge.collapseLoops(""), "", "empty")
    t.eq(TranscriptMerge.collapseLoops("y"), "y", "one word")
    t.eq(TranscriptMerge.collapseLoops("y y"), "y y", "two words")

    // Long runaway loops (typical Whisper output on silence).
    t.eq(TranscriptMerge.collapseLoops(Array(repeating: "y", count: 500).joined(separator: " ")), "y", "500 × \"y\"")
    t.eq(TranscriptMerge.collapseLoops(Array(repeating: "no sé", count: 200).joined(separator: " ") + " fin"),
         "no sé fin", "200 × \"no sé\" then a word")
    let gracias = Array(repeating: "Gracias.", count: 9).joined(separator: " ")
    t.eq(TranscriptMerge.collapseLoops(gracias + " ok fin bien"), "Gracias. ok fin bien", "9 × \"Gracias.\" then words")

    // Degenerate minRepeats: 0 divided by zero, 1 never terminated.
    t.eq(TranscriptMerge.collapseLoops("x", minRepeats: 1), "x", "minRepeats 1 does not hang")
    t.eq(TranscriptMerge.collapseLoops("x x x", minRepeats: 0), "x x x", "minRepeats 0 does not divide by zero")

    // The real call path: merge() runs collapseLoops on every segment.
    let sys = [RawSegment(start: 0, end: 2, text: "y y y", track: "system", speaker: "S1"),
               RawSegment(start: 2, end: 4, text: "hola hola hola", track: "system", speaker: "S1")]
    let mic = [RawSegment(start: 5, end: 6, text: "no sé no sé no sé", track: "mic", speaker: "me")]
    let merged = TranscriptMerge.merge(system: sys, mic: mic)
    t.check(merged.allSatisfy { !$0.text.contains("hola hola") && !$0.text.contains("no sé no sé") },
            "merge() collapses loops without trapping")

    // A NaN/infinite timestamp must not trap the Int conversion when planning windows.
    let audio = [Float](repeating: 0.1, count: 16000)
    t.eq(Windowing.sampleRanges([SpeechTurn(start: .nan, end: 0.5)], audio: audio, maxLength: 480000), [0..<8000],
         "NaN start → clamped to 0")
    t.eq(Windowing.sampleRanges([SpeechTurn(start: 0.5, end: .infinity)], audio: audio, maxLength: 480000), [8000..<16000],
         "infinite end → clamped to the audio length")
    t.eq(Windowing.sampleRanges([SpeechTurn(start: -.infinity, end: .nan)], audio: audio, maxLength: 480000), [],
         "no finite bounds → no range")
}

// MARK: v0.7.3 transcribe crash — parallel decoding on one WhisperKit raced on its unlocked shared state and
// over-released an ObjC object (EXC_BAD_ACCESS in objc_autoreleasePoolPop). ModelGate must run model calls one at a time.

/// Counts how many bodies run at once.
private actor Overlap {
    var inside = 0, peak = 0, order: [Int] = []
    func enter(_ i: Int) { inside += 1; peak = max(peak, inside); order.append(i) }
    func leave() { inside -= 1 }
}

private struct GateTestError: Error {}

@MainActor func testModelGate(_ t: Tester) async {
    let gate = ModelGate()
    let overlap = Overlap()
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<16 {
            group.addTask {
                await gate.run {
                    await overlap.enter(i)
                    try? await Task.sleep(for: .milliseconds(2))
                    await overlap.leave()
                }
            }
        }
    }
    t.eq(await overlap.peak, 1, "16 concurrent callers never overlap inside the gate")
    t.eq(await overlap.order.count, 16, "every caller ran")

    // A throwing body releases the gate.
    let threw = await (try? gate.run { () async throws -> Int in throw GateTestError() }) == nil
    t.check(threw, "the error reaches the caller")
    t.eq(await gate.run { 42 }, 42, "the gate is free again after a throwing body")
}
