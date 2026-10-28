import Foundation
import Recorder

// MARK: v0.7.2 mic restarts — when MicCapture rebuilds its engine after an audio configuration change. Pure policy, no
// audio hardware or mic permission needed.

@MainActor func testMicRestartPolicy(_ t: Tester) {
    // Only a real loss restarts: another app reconfiguring the shared mic must not make us reconfigure it again.
    t.check(!MicRestartPolicy.needsRestart(deviceChanged: false, engineRunning: true), "same device, still running → no restart")
    t.check(MicRestartPolicy.needsRestart(deviceChanged: true, engineRunning: true), "default input changed → restart")
    t.check(MicRestartPolicy.needsRestart(deviceChanged: false, engineRunning: false), "engine stopped → restart")
    t.check(MicRestartPolicy.debounce > 0 && MicRestartPolicy.debounce <= 1, "bursts are debounced by under a second")
    t.check(MicRestartPolicy.retryDelays.count >= 2 && MicRestartPolicy.retryDelays == MicRestartPolicy.retryDelays.sorted(),
            "a failed restart is retried with growing delays")

    // At most 5 restarts per sliding minute.
    var policy = MicRestartPolicy()
    let admitted = (0..<5).map { policy.admit(at: 100 + Double($0)) }
    t.eq(admitted, [true, true, true, true, true], "first five restarts allowed")
    t.check(!policy.admit(at: 110), "sixth within the minute refused")
    t.check(!policy.admit(at: 159.9), "still refused just before the first one ages out")
    t.check(policy.admit(at: 160), "allowed once the oldest is a minute old")
    t.check(!policy.admit(at: 160.5), "and the window is full again")
    t.check(policy.admit(at: 1000), "allowed after a long quiet period")

    // A refused restart backs off until the window frees up instead of giving up.
    var full = MicRestartPolicy()
    for i in 0..<5 { _ = full.admit(at: 100 + Double(i)) }
    t.check(!full.admit(at: 130), "budget full")
    t.check(abs(full.wait(at: 130) - 30) < 1e-9, "wait until the oldest restart is a minute old")
    t.check(full.admit(at: 130 + full.wait(at: 130)), "admitted after waiting")
    t.eq(MicRestartPolicy().wait(at: 0), 0, "empty budget → no wait")
    t.check(MicRestartPolicy.recheckInterval >= 10, "after failed retries the mic is re-tried slowly, not abandoned")

    // Debounce is trailing but capped: a burst can't postpone the check past maxDebounceWait.
    t.eq(MicRestartPolicy.debounceDelay(now: 0, burstStart: 0), MicRestartPolicy.debounce, "first change waits the debounce")
    t.check(abs(MicRestartPolicy.debounceDelay(now: 1.8, burstStart: 0) - 0.2) < 1e-9, "late in a burst only the cap remains")
    t.eq(MicRestartPolicy.debounceDelay(now: 5, burstStart: 0), 0, "past the cap → check now")

    var tight = MicRestartPolicy(limit: 1, window: 10)
    t.check(tight.admit(at: 0) && !tight.admit(at: 9) && tight.admit(at: 10), "custom limit/window")
}
