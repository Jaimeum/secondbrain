import Foundation
import BrainCore

// MARK: v0.7.3 auto-updates — where an update can go, and when installing it would interrupt nothing.

@MainActor func testUpdatePolicy(_ t: Tester) {
    let home = "/Users/ana"
    let loc = { (path: String) in UpdatePolicy.location(bundlePath: path, home: home) }
    t.check(loc("/Applications/SecondBrain.app") == .applications, "/Applications is updatable in place")
    t.check(loc("/Users/ana/Applications/SecondBrain.app") == .applications, "~/Applications is updatable in place")
    t.check(loc("/Applications/../Applications/SecondBrain.app") == .applications, "path is standardized")
    t.check(loc("/private/var/folders/x/T/AppTranslocation/1234-ABCD/d/SecondBrain.app") == .translocated,
            "App Translocation is detected")
    t.check(loc("/Volumes/SecondBrain 0.7.3/SecondBrain.app") == .diskImage, "running from the DMG is detected")
    t.check(loc("/Users/ana/Downloads/SecondBrain.app") == .elsewhere, "Downloads is elsewhere")
    t.check(loc("/Applications Old/SecondBrain.app") == .elsewhere, "a sibling folder with the same prefix is not /Applications")
    t.check(loc("/Users/ana/ApplicationsBackup/SecondBrain.app") == .elsewhere, "~/ApplicationsBackup is not ~/Applications")

    func job(_ kind: JobKind, _ status: JobStatus) -> Job {
        var j = Job(kind: kind)
        j.status = status
        return j
    }
    let idle = [job(.transcribe, .queued), job(.transcribe, .done), job(.ingest, .running)]
    t.check(!UpdatePolicy.isTranscribing(idle), "queued/done transcriptions and other running jobs are not transcribing")
    t.check(UpdatePolicy.isTranscribing(idle + [job(.transcribe, .running)]), "a running transcription is detected")
    t.check(UpdatePolicy.canInstallNow(isRecording: false, recorderBusy: false, jobs: idle), "idle → install allowed")
    t.check(!UpdatePolicy.canInstallNow(isRecording: true, recorderBusy: false, jobs: idle), "recording → install waits")
    t.check(!UpdatePolicy.canInstallNow(isRecording: false, recorderBusy: true, jobs: idle), "recorder starting/stopping → waits")
    t.check(!UpdatePolicy.canInstallNow(isRecording: false, recorderBusy: false, jobs: idle + [job(.transcribe, .running)]),
            "transcribing → install waits")
}
