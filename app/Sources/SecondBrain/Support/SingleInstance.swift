import AppKit
import BrainCore
import Foundation

/// Keeps SecondBrain to one running copy per data folder. `LSMultipleInstancesProhibited` (Info.plist) covers most
/// launches; this also catches `open -n`, copies at another path (Gatekeeper translocation, a second download) and
/// bare `swift build` binaries, which have no bundle identifier.
@MainActor enum SingleInstance {
    /// Held for the life of the process; the kernel drops it when the process exits or crashes.
    private static var appLock: QueueLock?

    /// True when another SecondBrain is already running (it is brought to the front): the caller quits.
    static func activateOtherAndShouldQuit(dataURL: URL) -> Bool {
        let me = getpid()
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            Log.info("another SecondBrain is running (pid \(other.processIdentifier)); quitting pid \(me)")
            other.activate()
            return true
        }
        // Fallback for processes without a bundle identifier: one app per data folder (`data/app.lock`).
        let lock = QueueLock(url: dataURL.appendingPathComponent("app.lock"))
        if lock.tryLock() {
            appLock = lock
            return false
        }
        // Quit only when a live process really holds it (not when the lock file could not be opened).
        guard let pid = lock.holderPid(), pid != me, lock.holderName() != nil else { return false }
        Log.info("another SecondBrain holds \(lock.url.path) (pid \(pid)); quitting pid \(me)")
        NSRunningApplication(processIdentifier: pid)?.activate()
        return true
    }
}
