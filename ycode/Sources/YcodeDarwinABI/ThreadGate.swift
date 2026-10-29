#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Synchronization

// The run gate of one guest thread: Mach suspension
// (`specs/simulator/threads-and-events.md` §1.6). The kernel closes it while
// the thread's suspend count or its task's is above zero; the vCPU host
// thread that runs the thread checks it before every guest entry and at the
// entry of every trap, and parks here, publishing the thread's user
// registers, until the kernel opens it again.
//
// The kernel and the VMM share this object (the thread's `ThreadContext`
// owns it; the vCPU pool holds it while it runs the thread). Its mutex is a
// leaf: nothing is taken while it is held.

/// Implemented by a guest-thread object that has a run gate (the kernel's
/// `ThreadContext`), so the vCPU pool finds the gate of the thread it runs.
public protocol GuestThreadGated: AnyObject {
    var gate: GuestThreadGate { get }
}

public final class GuestThreadGate: @unchecked Sendable {
    /// Where a stopped thread parked; the published registers mean:
    public enum ParkPoint: UInt8, Sendable, CustomStringConvertible {
        /// Before its first instruction: its start state.
        case start
        /// Stopped in guest code (the vCPU was kicked out at EL0): the
        /// registers at the next instruction.
        case guest
        /// At the entry of a trap, before the kernel handles it: the
        /// registers as the trap arrived (PC after the `svc`). The trap runs
        /// when the thread is resumed.
        case trapEntry
        /// After a trap, before returning to guest code: the registers the
        /// thread continues with (the trap's results in x0, x1 and carry).
        case afterTrap

        public var description: String {
            switch self {
            case .start: "start"
            case .guest: "guest"
            case .trapEntry: "trap entry"
            case .afterTrap: "after trap"
            }
        }
    }

    private static let closedBit: UInt8 = 1
    private static let replacementBit: UInt8 = 2

    /// Bit 0: closed (the thread must not run guest code). Bit 1: a register
    /// replacement waits for the end of the thread's trap. Read without a
    /// lock on every guest entry and trap entry; changed under `mutex`.
    private let flags = Atomic<UInt8>(0)
    /// True while a vCPU runs the thread, or is about to (set by the vCPU
    /// pool when it takes the thread, cleared when the thread's run ends).
    /// A thread that is not attached runs no guest code: it is stopped.
    public let attached = Atomic<Bool>(false)
    /// Statistics: how many times the thread parked.
    public let parkCount = Atomic<UInt64>(0)

    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private let cond: UnsafeMutablePointer<pthread_cond_t>
    // Guarded by `mutex`.
    private var parkedFrame: TrapFrame?
    private var parkedAt = ParkPoint.guest
    private var parkedChanged = false
    private var replacement: TrapFrame?
    private var released = false

    public init() {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
        cond = .allocate(capacity: 1)
        cond.initialize(to: pthread_cond_t())
        #if canImport(Glibc)
        var attr = pthread_condattr_t()
        pthread_condattr_init(&attr)
        pthread_condattr_setclock(&attr, CLOCK_MONOTONIC)
        pthread_cond_init(cond, &attr)
        pthread_condattr_destroy(&attr)
        #else
        pthread_cond_init(cond, nil)
        #endif
    }

    deinit {
        pthread_cond_destroy(cond)
        cond.deallocate()
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    @inline(__always) private func locked<T>(_ body: () throws -> T) rethrows -> T {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body()
    }

    // MARK: The fast check (vCPU thread)

    /// True when the thread must stop, or a register replacement is
    /// waiting: one relaxed load, on every guest entry.
    @inline(__always) public var needsAttention: Bool { flags.load(ordering: .relaxed) != 0 }

    /// True while the thread must not run guest code.
    @inline(__always) public var isClosed: Bool { flags.load(ordering: .acquiring) & Self.closedBit != 0 }

    // MARK: Kernel side

    /// The thread must stop (its suspend count, or its task's, became
    /// nonzero). The caller then makes its vCPU leave guest mode.
    public func close() {
        locked { _ = flags.bitwiseOr(Self.closedBit, ordering: .sequentiallyConsistent) }
    }

    /// The thread may run again (both counts are zero): a parked thread
    /// continues.
    public func open() {
        locked {
            _ = flags.bitwiseAnd(~Self.closedBit, ordering: .sequentiallyConsistent)
            pthread_cond_broadcast(cond)
        }
    }

    /// The thread's image is ending: a parked thread continues (and sees the
    /// end), and the thread never parks again.
    public func release() {
        locked {
            released = true
            pthread_cond_broadcast(cond)
        }
    }

    /// The registers of the parked thread and where it parked; nil when it
    /// is not parked.
    public var parked: (frame: TrapFrame, at: ParkPoint)? {
        locked { parkedFrame.map { ($0, parkedAt) } }
    }

    /// The register replacement waiting for the end of the thread's trap.
    public var pendingReplacement: TrapFrame? { locked { replacement } }

    /// Changes the registers of the parked thread (thread_set_state); it
    /// continues with them. False when the thread is not parked, or parked
    /// at the entry of a trap (use `setReplacement`: the trap runs first).
    public func modifyParked(_ body: (inout TrapFrame) -> Void) -> Bool {
        locked {
            guard var f = parkedFrame, parkedAt != .trapEntry else { return false }
            body(&f)
            parkedFrame = f
            parkedChanged = true
            return true
        }
    }

    /// thread_set_state for a thread that is in (or about to run) a trap:
    /// when its trap ends, the thread continues with `frame`'s user
    /// registers, except x0, x1 and carry, which keep the trap's results.
    public func setReplacement(_ frame: TrapFrame) {
        locked {
            replacement = frame
            _ = flags.bitwiseOr(Self.replacementBit, ordering: .sequentiallyConsistent)
        }
    }

    /// Waits until the thread is parked, at most until `deadline` (host
    /// monotonic ns). Returns true when it is parked. Call with no kernel
    /// lock held.
    public func waitUntilParked(deadline: UInt64) -> Bool {
        locked {
            while parkedFrame == nil {
                if Self.wait(cond, mutex, deadline: deadline) == ETIMEDOUT { break }
            }
            return parkedFrame != nil
        }
    }

    // MARK: vCPU side

    /// Parks the calling vCPU host thread while the gate is closed,
    /// publishing `frame` (the thread's user registers at `point`). Returns
    /// the registers to continue with when they were changed while it was
    /// parked (thread_set_state), else nil. Returns at once when the gate
    /// is open or the image is ending.
    public func park(_ frame: TrapFrame, at point: ParkPoint) -> TrapFrame? {
        locked {
            guard !released, flags.load(ordering: .relaxed) & Self.closedBit != 0 else { return nil }
            parkedFrame = frame
            parkedAt = point
            parkedChanged = false
            parkCount.wrappingAdd(1, ordering: .relaxed)
            pthread_cond_broadcast(cond)
            while !released, flags.load(ordering: .relaxed) & Self.closedBit != 0 {
                pthread_cond_wait(cond, mutex)
            }
            let changed = parkedChanged ? parkedFrame : nil
            parkedFrame = nil
            parkedChanged = false
            return changed
        }
    }

    /// Takes the register replacement waiting for the end of the thread's
    /// trap (nil: none).
    public func takeReplacement() -> TrapFrame? {
        guard flags.load(ordering: .acquiring) & Self.replacementBit != 0 else { return nil }
        return locked {
            _ = flags.bitwiseAnd(~Self.replacementBit, ordering: .sequentiallyConsistent)
            defer { replacement = nil }
            return replacement
        }
    }

    // MARK: Helpers

    /// One condition wait until `deadline` (host monotonic ns).
    private static func wait(_ cond: UnsafeMutablePointer<pthread_cond_t>, _ mutex: UnsafeMutablePointer<pthread_mutex_t>,
                             deadline: UInt64) -> Int32 {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        let nowNs = UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec)
        if nowNs >= deadline { return ETIMEDOUT }
        #if canImport(Darwin)
        let remaining = deadline - nowNs
        var ts = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
        return pthread_cond_timedwait_relative_np(cond, mutex, &ts)
        #else
        var ts = timespec(tv_sec: Int(deadline / 1_000_000_000), tv_nsec: Int(deadline % 1_000_000_000))
        return pthread_cond_timedwait(cond, mutex, &ts)
        #endif
    }

    /// The host monotonic clock (ns), the clock `waitUntilParked` takes.
    public static func now() -> UInt64 {
        var t = timespec()
        clock_gettime(CLOCK_MONOTONIC, &t)
        return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
    }
}

extension TrapFrame {
    /// Copies the user registers a thread state carries (x0–x30, SP, PC,
    /// the condition flags of PSTATE) from `other`; the mode bits of SPSR
    /// stay EL0t, and the trap fields (kind, ESR, FAR, resume flags) and
    /// TPIDR registers stay this frame's.
    public mutating func takeUserState(of other: TrapFrame) {
        x = other.x
        spEL0 = other.spEL0
        elr = other.elr
        // NZCV only: the thread stays in EL0 (AArch64), as xnu masks the
        // mode bits of a state it is given.
        spsr = (spsr & ~UInt64(0xF000_0000)) | (other.spsr & 0xF000_0000)
    }
}
