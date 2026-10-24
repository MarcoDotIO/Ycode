// The restore's thread starts (specs/simulator/snapshot.md §7 step 9): every
// restored thread gets its vCPU before any restored thread runs.
//
// Without the gate, a thread started early in the loop could run its pending
// trap (an `exit`, a fatal fault, a kill of another process) and end its
// process while the loop was still starting that process's other threads;
// those starts then found the process's vCPU pool ended and the whole restore
// failed with "no vCPU for thread N" (§12). With the gate the restored
// threads wait at their first trap until every start is done, and a start
// for a process that has already ended is skipped instead of failing.

import Foundation

public final class SnapshotRestoreStartGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    public init() {}

    /// Called by a restored thread at its first trap, before the trap runs:
    /// returns once `release` was called. No kernel lock may be held.
    public func waitForRelease() {
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    /// Lets every restored thread run (idempotent).
    public func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    public var isReleased: Bool {
        condition.lock()
        defer { condition.unlock() }
        return released
    }

    /// The outcome of `startAll`.
    public struct Starts<T> {
        /// Threads that have a vCPU, with its index.
        public var started: [(thread: T, vcpu: Int)] = []
        /// Threads not started because their process had already ended.
        public var skipped: [T] = []
    }

    /// Starts every thread with `start` (nil: no vCPU). A thread whose
    /// process has ended (`processEnded`, checked before and after a start
    /// that found no vCPU) is skipped: the process is gone and its threads
    /// with it. A start that finds no vCPU for a live process throws, with
    /// `describe`'s text: a pool too small for the threads it ran before
    /// the snapshot is a bug, not a state to paper over.
    public static func startAll<T>(_ threads: [T], start: (T) throws -> Int?, processEnded: (T) -> Bool,
                                   describe: (T) -> String) throws -> Starts<T> {
        var out = Starts<T>()
        for t in threads {
            if processEnded(t) {
                out.skipped.append(t)
                continue
            }
            if let index = try start(t) {
                out.started.append((t, index))
            } else if processEnded(t) {
                out.skipped.append(t)
            } else {
                throw SnapshotError(describe(t))
            }
        }
        return out
    }
}
