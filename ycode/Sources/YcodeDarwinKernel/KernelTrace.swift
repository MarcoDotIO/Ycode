#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Hooks for the VMM's frame profile (specs/simulator/frame-profile.md;
// diagnostics, off by default). The VMM sets them only while a trace window
// is open; with them nil each site costs one load and a nil check.

/// Optional hooks for the VMM's frame profile (`specs/simulator/frame-profile.md`).
/// Each is nil unless a trace window is open.
public enum KernelTrace {
    /// A waiter is being woken: its guest thread (nil: a service waiter).
    /// Called on the waker's host thread, with or without kernel locks held;
    /// must not block or take kernel locks.
    nonisolated(unsafe) public static var wake: ((_ wakee: ThreadContext?) -> Void)?
    /// A guest thread starts (true) or stops (false) sleeping in a wait
    /// queue. Called on that thread's host thread; same rules as `wake`.
    nonisolated(unsafe) public static var blocking: ((_ context: ThreadContext, _ sleeping: Bool) -> Void)?
    /// A timer of image `pid` fired `late` ns after its deadline (`kind` 0: a
    /// Mach timer, 1: an EVFILT_TIMER knote). Called with the image's event
    /// lock held, on the thread that fires it; same rules as `wake`.
    nonisolated(unsafe) public static var timerFired: ((_ pid: Int32, _ late: UInt64, _ kind: Int32) -> Void)?
    /// A contended acquisition of a kernel lock (`level` 0: L0, 1: an event
    /// lock, 2: the port lock) waited `waited` ns. Called on the waiter's
    /// host thread with the lock just taken; same rules as `wake`.
    nonisolated(unsafe) public static var lockWaited: ((_ level: Int32, _ waited: UInt64) -> Void)?
}

extension DarwinKernel {
    /// `YCODE_TIMER_L0=1`: the timer thread runs under the kernel lock L0
    /// (the behaviour before frame-profile.md §5.3); otherwise, with the
    /// lock split, under the image's event lock.
    static let timerThreadL0 = getenv("YCODE_TIMER_L0").map { String(cString: $0) == "1" } ?? false

    /// True when this image's timer thread waits on its event lock.
    var timerThreadOnEventLock: Bool { eventLock != nil && !Self.timerThreadL0 }
}
