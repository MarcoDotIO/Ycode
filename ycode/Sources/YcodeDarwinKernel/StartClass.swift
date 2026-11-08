import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The host class of a thread start (`YCODE_START_CLASS`;
// `specs/simulator/scheduling-policy.md` §4.15, `boot-profile.md` §26).
//
// A vCPU's host thread runs one guest thread after another (a parked vCPU,
// a reused VM's spares), and §4.7 applies a host class only at the end of a
// locked trap. So a guest thread begins in the host priority of the last
// thread that ran there, until its first locked trap: a SpringBoard thread
// started on a host thread whose last thread was a darwin-bg one waits for a
// host CPU at class bg's weight. A new host thread begins in the cgroup of the
// thread that created it (a vCPU creator thread, itself in the cgroup of
// whichever thread first asked for a creation). xnu has no such state: a
// thread's priority comes from its own QoS and its task from the start.
//
// With the switch on:
// - a host thread that takes a guest thread applies that thread's host class
//   (its class raised to its image's pushes) before the thread's first
//   instruction, without the demotion delay;
// - a host thread whose guest thread ended (it parks) in a class below df
//   moves to df, so that the start that next wakes it is not left waiting
//   for a CPU at class bg's weight before it can apply the new class;
// - a vCPU creator thread runs at class ui (a host service thread, §4.4),
//   so the creations a start waits for, and the host threads they make, are
//   not throttled by the class of the thread that first asked for one.

extension HostSched {
    /// `YCODE_START_CLASS` (`1` on; default off until measured).
    nonisolated(unsafe) public static var startClassEnabled = getenv("YCODE_START_CLASS").map { String(cString: $0) == "1" } ?? false

    /// Moves made by the start class (diagnostics): at a start, at a park,
    /// on a creator thread.
    static let startClassMoves = Atomic<Int>(0)
    static let parkClassMoves = Atomic<Int>(0)
    static let creatorClassMoves = Atomic<Int>(0)

    /// The class a parked host thread waits in (df).
    static let parkClass = SchedClass.default

    @inline(__always) static var startClassActive: Bool {
        startClassEnabled && (backend != .none || moveHook != nil)
    }

    /// Gives the calling host thread class `cls` now, without the demotion
    /// delay; true when it moved.
    @discardableResult
    static func applyNow(_ cls: Int) -> Bool {
        pthread_setspecific(demoteKey, nil)
        guard appliedClass() != cls, let tid = currentTID() else { return false }
        move(tid, to: cls, isSelf: true)
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: cls + 1))
        return true
    }

    /// Starts by the host thread's applied class at the start (index 0: none
    /// applied yet, a new host thread; 1–4: classes bg…ui) and the new
    /// thread's host class (diagnostics, with any backend).
    static let startPairs = Mutex<[Int]>([Int](repeating: 0, count: (SchedClass.count + 1) * SchedClass.count))

    /// The calling host thread is about to run guest thread `context` (a
    /// `ThreadContext`): the start is counted, and with the switch on the
    /// host thread takes that thread's host class now.
    public static func applyAtStart(_ context: AnyObject?) {
        guard let thread = context as? ThreadContext else { return }
        let cls = thread.startHostClass
        let applied = appliedClass()
        if cls >= 0, cls < SchedClass.count, applied >= -1, applied < SchedClass.count {
            startPairs.withLock { $0[(applied + 1) * SchedClass.count + cls] += 1 }
        }
        guard startClassActive else { return }
        if applyNow(cls) { startClassMoves.wrappingAdd(1, ordering: .relaxed) }
    }

    /// "starts at a lower applied class N (new host threads N), higher N,
    /// the same N", over all classes (diagnostics).
    static var startPairsReport: String {
        let pairs = startPairs.withLock { $0 }
        var lower = 0, higher = 0, same = 0, fresh = 0
        for applied in -1..<SchedClass.count {
            for cls in 0..<SchedClass.count {
                let n = pairs[(applied + 1) * SchedClass.count + cls]
                if applied < 0 { fresh += n } else if applied < cls { lower += n } else if applied > cls { higher += n } else { same += n }
            }
        }
        guard lower + higher + same + fresh > 0 else { return "" }
        let bgToAbove = (1..<SchedClass.count).reduce(0) { $0 + pairs[1 * SchedClass.count + $1] }
        return "; thread starts by the host thread's class: below the thread's \(lower) (from bg \(bgToAbove)), above \(higher), "
            + "the same \(same), new host threads \(fresh)"
    }

    /// The calling host thread's guest thread ended and it parks: below df
    /// it moves to df.
    public static func applyAtPark() {
        guard startClassActive else { return }
        let current = appliedClass()
        guard current >= 0, current < parkClass else { return }
        if applyNow(parkClass) { parkClassMoves.wrappingAdd(1, ordering: .relaxed) }
    }

    /// The calling thread is a vCPU creator thread: class ui.
    public static func applyOnCreatorThread() {
        guard startClassActive else { return }
        if applyNow(SchedClass.interactive) { creatorClassMoves.wrappingAdd(1, ordering: .relaxed) }
    }

    /// The start class's part of the `sched:` report ("" when off).
    static var startClassReport: String {
        startPairsReport + (startClassEnabled
            ? "; start class: \(startClassMoves.load(ordering: .relaxed)) at starts, "
                + "\(parkClassMoves.load(ordering: .relaxed)) at parks, \(creatorClassMoves.load(ordering: .relaxed)) creator threads"
            : "")
    }
}

extension ThreadContext {
    /// The host class this thread starts at: its class raised to its image's
    /// send and sync-wait pushes (§4.7's host class).
    var startHostClass: Int {
        let c = schedClass
        guard let k = kernel else { return c }
        return max(c, k.sendPushClass, k.syncPushClass)
    }
}
