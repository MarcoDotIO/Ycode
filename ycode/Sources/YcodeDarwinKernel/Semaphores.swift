import Foundation
import YcodeDarwinABI

// Mach semaphores with several threads (`specs/simulator/threads-and-events.md`
// §4.3, traps −33…−39). The semaphore object lives behind a port name in the
// task's space; agent I's `MachIPC` creates and destroys it
// (`semaphore_create`/`semaphore_destroy`, private traps 0x7963_2003/4) and
// hands it out through `MachIPCHandling.semaphore(named:)`.

/// A Mach semaphore. `count` is the number of free permits; threads wait only
/// while it is 0. A signal with a waiter hands its permit straight to that
/// waiter. Every method must be called with the kernel lock held.
public final class KernelSemaphore: @unchecked Sendable {
    public private(set) var count: Int32
    public private(set) var isDestroyed = false
    let waiters = WaitQueue()

    public init(value: Int32) {
        count = max(0, value)
    }

    /// The number of threads waiting.
    public var waiterCount: Int { waiters.count }

    /// `semaphore_signal`: wakes one waiter, or adds a permit.
    public func signal() {
        if waiters.wake(count: 1) == 0 { count &+= 1 }
    }

    /// `semaphore_signal_all`: wakes every waiter; the count does not change.
    public func signalAll() {
        waiters.wakeAll()
    }

    /// `semaphore_signal_thread` with a thread: true when it was waiting here.
    public func signal(thread: ThreadContext) -> Bool {
        waiters.wake(limit: 1) { c, _ in c === thread } == 1
    }

    /// `semaphore_destroy`: every waiter returns `KERN_TERMINATED`.
    public func destroy() {
        isDestroyed = true
        waiters.wakeAll()
    }

    /// Takes a permit or waits for one. `deadline` nil = forever; a deadline
    /// in the past polls. Returns a `kern_return_t`.
    func wait(lock: KernelLock, deadline: UInt64?, beforeSleeping: (() -> Void)? = nil) -> UInt64 {
        if isDestroyed { return DarwinKernel.KernReturn.terminated }
        if count > 0 {
            count -= 1
            beforeSleeping?()
            return DarwinKernel.KernReturn.success
        }
        if let deadline, deadline <= KernelClock.now() {
            beforeSleeping?()
            return DarwinKernel.KernReturn.operationTimedOut
        }
        switch waiters.wait(on: lock, deadline: deadline, tag: 0, beforeSleeping: beforeSleeping) {
        case .woken: return isDestroyed ? DarwinKernel.KernReturn.terminated : DarwinKernel.KernReturn.success
        case .timedOut: return DarwinKernel.KernReturn.operationTimedOut
        case .interrupted: return DarwinKernel.KernReturn.aborted
        }
    }
}

extension DarwinKernel {
    /// The semaphore behind the port name `name`.
    public func semaphore(named name: UInt32) -> KernelSemaphore? {
        machIPC?.semaphore(named: name)
    }

    /// The semaphore traps −33…−39. Returns nil for other numbers.
    func handleSemaphoreTrap(_ n: Int, _ frame: inout TrapFrame) -> Outcome? {
        guard (Mach.semaphoreTimedwaitSignal...Mach.semaphoreSignal).contains(n) else { return nil }
        let a = Array(frame.x[0..<8])
        func port(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: a[i]) }
        var call = ""
        func kr(_ value: UInt64, _ extra: String = "") -> Outcome {
            frame.x[0] = value
            trace("trap mach \(n) \(call) -> \(KernReturn.name(value))\(extra)")
            return .resume
        }
        func timeout(_ sec: UInt64, _ nsec: UInt64) -> UInt64 {
            let ns = UInt64(UInt32(truncatingIfNeeded: sec)) &* 1_000_000_000
                &+ UInt64(max(0, Int64(Int32(truncatingIfNeeded: nsec))))
            return KernelClock.deadline(afterNanoseconds: ns)
        }

        switch n {
        case Mach.semaphoreSignal, Mach.semaphoreSignalAll:
            call = "\(n == Mach.semaphoreSignal ? "semaphore_signal" : "semaphore_signal_all")(\(hx(port(0))))"
            guard let s = semaphore(named: port(0)) else { return kr(KernReturn.invalidName) }
            if s.isDestroyed { return kr(KernReturn.terminated) }
            let waiting = s.waiterCount
            if n == Mach.semaphoreSignal { s.signal() } else { s.signalAll() }
            return kr(KernReturn.success, " [count \(s.count), woke \(n == Mach.semaphoreSignal ? min(waiting, 1) : waiting)]")

        case Mach.semaphoreSignalThread:
            call = "semaphore_signal_thread(\(hx(port(0))), thread=\(hx(port(1))))"
            guard let s = semaphore(named: port(0)) else { return kr(KernReturn.invalidName) }
            if s.isDestroyed { return kr(KernReturn.terminated) }
            if port(1) == 0 {
                return kr(s.waiters.wake(count: 1) == 1 ? KernReturn.success : KernReturn.notWaiting)
            }
            guard let t = thread(port: port(1)) else { return kr(KernReturn.invalidArgument) }
            return kr(s.signal(thread: t) ? KernReturn.success : KernReturn.notWaiting)

        case Mach.semaphoreWait, Mach.semaphoreTimedwait:
            let timed = n == Mach.semaphoreTimedwait
            call = timed
                ? "semaphore_timedwait(\(hx(port(0))), sec=\(UInt32(truncatingIfNeeded: a[1])), nsec=\(Int32(truncatingIfNeeded: a[2])))"
                : "semaphore_wait(\(hx(port(0))))"
            guard let s = semaphore(named: port(0)) else { return kr(KernReturn.invalidName) }
            let r = s.wait(lock: lock, deadline: timed ? timeout(a[1], a[2]) : nil)
            return kr(r, " [count \(s.count)]")

        case Mach.semaphoreWaitSignal, Mach.semaphoreTimedwaitSignal:
            let timed = n == Mach.semaphoreTimedwaitSignal
            call = timed
                ? "semaphore_timedwait_signal(wait=\(hx(port(0))), signal=\(hx(port(1))), sec=\(UInt32(truncatingIfNeeded: a[2])), nsec=\(Int32(truncatingIfNeeded: a[3])))"
                : "semaphore_wait_signal(wait=\(hx(port(0))), signal=\(hx(port(1))))"
            guard let w = semaphore(named: port(0)), let s = semaphore(named: port(1)) else {
                return kr(KernReturn.invalidName)
            }
            if s.isDestroyed { return kr(KernReturn.terminated) }
            // Start waiting on w, then signal s (so w == s succeeds).
            let r = w.wait(lock: lock, deadline: timed ? timeout(a[2], a[3]) : nil, beforeSleeping: { s.signal() })
            return kr(r, " [count \(w.count)]")

        default:
            return nil
        }
    }
}
