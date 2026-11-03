import Foundation

/// Async mutex: runs one body at a time, in arrival order.
///
/// WhisperKit and SpeakerKit are not safe to call concurrently on the same instance. WhisperKit 1.1.1
/// writes `progress` and the `TextDecoder.languageLogitsFilter` cache without locks. With parallel
/// decoding, those writes over-released an ObjC object and crashed the app (EXC_BAD_ACCESS in
/// objc_autoreleasePoolPop, 2026-11-03). Every model call goes through `ModelStore.gate`.
public final class ModelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let free = lock.withLock { () -> Bool in
                if busy { waiters.append(c); return false }
                busy = true
                return true
            }
            if free { c.resume() }
        }
    }

    private func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiters.isEmpty { busy = false; return nil }
            return waiters.removeFirst()   // stays busy: ownership passes to the next waiter
        }
        next?.resume()
    }
}
