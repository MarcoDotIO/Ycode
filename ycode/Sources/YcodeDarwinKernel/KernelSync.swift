import Foundation
import Synchronization
import YcodeDarwinABI
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The kernel lock and the blocking primitive of stage 4a
// (`specs/simulator/stage4a-contract.md` §2, §8).
//
// One Darwin process = one VM = one `DarwinKernel`. Every vCPU has its own
// host thread, and every one of them calls `DarwinKernel.handle` for its own
// traps. The kernel's shared state is protected by ONE `KernelLock`, held for
// the whole trap. A trap that must block waits on a `WaitQueue`, which
// releases the lock while the host thread sleeps and takes it again before
// it returns. Every `WaitQueue` operation must be made with the lock held.
//
// Deadlines are absolute host monotonic nanoseconds (`KernelClock.now()`,
// which is `MachTimebase.hostMonotonicNanoseconds()`).

/// What a trap handler returns to the VMM. Agent I's `MachIPC.handleTrap`
/// returns `TrapOutcome?` (nil = "not my trap").
public typealias TrapOutcome = DarwinKernel.Outcome

/// The host monotonic clock that kernel deadlines use.
public enum KernelClock {
    /// Now, in host monotonic nanoseconds.
    public static func now() -> UInt64 { MachTimebase.hostMonotonicNanoseconds() }

    /// `now() + nanoseconds`, saturating.
    public static func deadline(afterNanoseconds ns: UInt64) -> UInt64 {
        let (d, overflow) = now().addingReportingOverflow(ns)
        return overflow ? UInt64.max : d
    }
}

/// How a `WaitQueue.wait` ended.
public enum WaitResult: Equatable, Sendable {
    /// `wake` chose this waiter.
    case woken
    /// The deadline passed first.
    case timedOut
    /// The thread was interrupted (`KernelLock.interrupt`), or the process
    /// is terminating (`KernelLock.terminate`). Signals map this to EINTR,
    /// Mach waits to `KERN_ABORTED`.
    case interrupted
}

/// The one kernel lock of a VM. Re-entrant on the owning host thread (a
/// nested `withLock` just runs its body), but a `WaitQueue.wait` must be
/// made at nesting depth 1.
public final class KernelLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    /// The holding host thread (`threadToken`), 0 when free. Atomic: other
    /// threads read it (`isHeldByCurrentThread`) without the mutex.
    private let owner = Atomic<UInt>(0)
    @inline(__always) private static var threadToken: UInt {
        #if canImport(Darwin)
        UInt(bitPattern: pthread_self())
        #else
        UInt(pthread_self())
        #endif
    }
    private var depth = 0
    /// Every thread blocked in a `WaitQueue` of this lock.
    private var waiters: [ObjectIdentifier: WaitQueue.Waiter] = [:]

    /// The context of the guest thread whose trap holds the lock (nil for a
    /// kernel service thread, such as the timer thread). Restored after a
    /// wait.
    public internal(set) var currentContext: ThreadContext?
    /// Set by `terminate()`: every wait returns `.interrupted` at once.
    public private(set) var isTerminated = false
    /// Told when a guest thread starts and stops blocking in a wait (the
    /// workqueue's "a blocked worker frees its slot" rule). Stage 4b: the
    /// `DarwinSystem` that owns the lock sets it once and forwards to the
    /// thread's own kernel (`ThreadContext.kernel`).
    var blockingObserver: ((_ context: ThreadContext, _ blocking: Bool) -> Void)?

    /// Diagnostics: total time held (ns), acquisitions, and a reporter for
    /// holds longer than `slowHoldNanoseconds` (context, duration).
    public private(set) var totalHeldNanoseconds: UInt64 = 0
    public private(set) var acquisitions: UInt64 = 0
    public var slowHoldNanoseconds: UInt64 = 0
    public var slowHoldReporter: ((_ context: ThreadContext?, _ nanoseconds: UInt64) -> Void)?
    private var holdStart: UInt64 = 0
    /// Diagnostics (when `profileHolds`): total hold time and count per trap
    /// number of the holding thread (Int64.min = no guest thread).
    public var profileHolds = false
    public private(set) var holdProfile: [Int64: (ns: UInt64, count: UInt64)] = [:]

    private func noteAcquired() {
        holdStart = KernelClock.now()
        acquisitions &+= 1
    }

    private func noteReleasing() {
        let held = KernelClock.now() &- holdStart
        totalHeldNanoseconds &+= held
        if profileHolds {
            let key = currentContext?.trapInProgress.map { Int64(bitPattern: $0.x16) } ?? Int64.min
            let old = holdProfile[key] ?? (0, 0)
            holdProfile[key] = (old.ns &+ held, old.count &+ 1)
        }
        if slowHoldNanoseconds > 0, held >= slowHoldNanoseconds, let r = slowHoldReporter { r(currentContext, held) }
    }

    public init() {
        mutex = .allocate(capacity: 1)
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        pthread_mutex_init(mutex, &attr)
        pthread_mutexattr_destroy(&attr)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    /// True when the calling host thread holds the lock.
    public var isHeldByCurrentThread: Bool {
        owner.load(ordering: .relaxed) == Self.threadToken
    }

    /// Runs `body` with the lock held, without a guest-thread context.
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try withLock(context: nil, body)
    }

    /// Runs `body` with the lock held on behalf of `context`'s trap. When the
    /// calling host thread already holds the lock, `body` runs nested and the
    /// current context is kept.
    public func withLock<T>(context: ThreadContext?, _ body: () throws -> T) rethrows -> T {
        if isHeldByCurrentThread {
            depth += 1
            defer { depth -= 1 }
            return try body()
        }
        pthread_mutex_lock(mutex)
        owner.store(Self.threadToken, ordering: .relaxed)
        depth = 1
        currentContext = context
        noteAcquired()
        defer {
            noteReleasing()
            currentContext = nil
            depth = 0
            owner.store(0, ordering: .relaxed)
            pthread_mutex_unlock(mutex)
        }
        return try body()
    }

    /// Ends every current and future wait with `.interrupted` (process exit).
    /// Call with the lock held.
    public func terminate() {
        precondition(isHeldByCurrentThread, "KernelLock.terminate needs the kernel lock")
        isTerminated = true
        for w in waiters.values { w.finish(.interrupted) }
        waiters.removeAll()
    }

    /// Ends every current and future wait of the guest threads of one
    /// process image (`kernel`), and of no other (stage 4b: several processes
    /// share this lock). Waits without a thread context are not touched (the
    /// image's timer thread watches `DarwinKernel.isTerminating`). Call with
    /// the lock held, after `kernel.isTerminating` became true.
    public func terminate(kernel: DarwinKernel) {
        precondition(isHeldByCurrentThread, "KernelLock.terminate needs the kernel lock")
        for (key, w) in waiters where w.context?.kernel === kernel {
            w.finish(.interrupted)
            waiters[key] = nil
        }
    }

    /// Interrupts the waits of one guest thread (signal delivery). Returns
    /// true when it was waiting. Call with the lock held.
    @discardableResult
    public func interrupt(_ context: ThreadContext) -> Bool {
        precondition(isHeldByCurrentThread, "KernelLock.interrupt needs the kernel lock")
        var any = false
        for (key, w) in waiters where w.context === context {
            w.finish(.interrupted)
            waiters[key] = nil
            any = true
        }
        return any
    }

    /// Releases the lock, yields the host CPU, and takes the lock again
    /// (`thread_switch`). Call at nesting depth 1.
    public func yield() {
        precondition(isHeldByCurrentThread && depth == 1, "KernelLock.yield needs the lock at depth 1")
        let saved = currentContext
        noteReleasing()
        owner.store(0, ordering: .relaxed)
        depth = 0
        currentContext = nil
        pthread_mutex_unlock(mutex)
        sched_yield()
        pthread_mutex_lock(mutex)
        owner.store(Self.threadToken, ordering: .relaxed)
        depth = 1
        currentContext = saved
        noteAcquired()
    }

    /// Runs `body` with the lock released (stage 6, `stage6-contract.md`
    /// §5.1, first step: host file-system I/O outside the global lock) and
    /// takes it again before returning. `body` must touch no state the lock
    /// protects. At nesting depth > 1 (a caller that cannot give the lock
    /// up) `body` runs with the lock held.
    public func unlocked<T>(_ body: () throws -> T) rethrows -> T {
        guard isHeldByCurrentThread, depth == 1 else { return try body() }
        let saved = currentContext
        noteReleasing()
        owner.store(0, ordering: .relaxed)
        depth = 0
        currentContext = nil
        pthread_mutex_unlock(mutex)
        defer {
            pthread_mutex_lock(mutex)
            owner.store(Self.threadToken, ordering: .relaxed)
            depth = 1
            currentContext = saved
            noteAcquired()
        }
        return try body()
    }

    // MARK: Used by WaitQueue

    fileprivate func register(_ w: WaitQueue.Waiter) { waiters[ObjectIdentifier(w)] = w }
    fileprivate func unregister(_ w: WaitQueue.Waiter) { waiters[ObjectIdentifier(w)] = nil }

    /// Sleeps on `cond` until signalled or `deadline`, releasing the mutex.
    /// Returns false on timeout.
    fileprivate func sleep(on cond: UnsafeMutablePointer<pthread_cond_t>, deadline: UInt64?) -> Bool {
        precondition(depth == 1, "WaitQueue.wait inside a nested withLock")
        let saved = currentContext
        noteReleasing()
        owner.store(0, ordering: .relaxed)
        depth = 0
        currentContext = nil
        var rc: Int32 = 0
        if let deadline {
            let now = KernelClock.now()
            if now >= deadline {
                rc = ETIMEDOUT
            } else {
                #if canImport(Darwin)
                let remaining = deadline - now
                var ts = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
                rc = pthread_cond_timedwait_relative_np(cond, mutex, &ts)
                #else
                var ts = timespec(tv_sec: Int(deadline / 1_000_000_000), tv_nsec: Int(deadline % 1_000_000_000))
                rc = pthread_cond_timedwait(cond, mutex, &ts)
                #endif
            }
        } else {
            rc = pthread_cond_wait(cond, mutex)
        }
        owner.store(Self.threadToken, ordering: .relaxed)
        depth = 1
        currentContext = saved
        noteAcquired()
        return rc != ETIMEDOUT
    }
}

/// A queue of blocked host threads. It has reference semantics: copies share
/// the same waiters. Every call must be made with the kernel lock held.
public struct WaitQueue: @unchecked Sendable {
    /// One blocked host thread.
    final class Waiter {
        let cond: UnsafeMutablePointer<pthread_cond_t>
        let context: ThreadContext?
        let tag: UInt64
        var result: WaitResult?
        weak var storage: Storage?

        init(context: ThreadContext?, tag: UInt64) {
            self.context = context
            self.tag = tag
            cond = .allocate(capacity: 1)
            var attr = pthread_condattr_t()
            pthread_condattr_init(&attr)
            #if !canImport(Darwin)
            pthread_condattr_setclock(&attr, CLOCK_MONOTONIC)
            #endif
            pthread_cond_init(cond, &attr)
            pthread_condattr_destroy(&attr)
        }

        deinit {
            pthread_cond_destroy(cond)
            cond.deallocate()
        }

        /// Records the result, leaves the queue, and wakes the host thread.
        func finish(_ r: WaitResult) {
            guard result == nil else { return }
            result = r
            storage?.remove(self)
            pthread_cond_signal(cond)
        }
    }

    final class Storage {
        var waiters: [Waiter] = []
        func remove(_ w: Waiter) { waiters.removeAll { $0 === w } }
    }

    private let storage = Storage()

    public init() {}

    /// The number of threads waiting.
    public var count: Int { storage.waiters.count }
    public var isEmpty: Bool { storage.waiters.isEmpty }

    /// The contexts of the waiting threads, oldest first.
    public var waitingContexts: [ThreadContext] { storage.waiters.compactMap(\.context) }

    /// Blocks the calling thread until `wake` picks it, `deadline` (absolute
    /// host monotonic ns; nil = forever) passes, or it is interrupted. The
    /// kernel lock is released while it sleeps and held again on return.
    public func wait(on lock: KernelLock, deadline: UInt64?) -> WaitResult {
        wait(on: lock, deadline: deadline, tag: 0, beforeSleeping: nil)
    }

    /// As `wait(on:deadline:)`. `tag` is a value `wake(where:)` can match.
    /// `beforeSleeping` runs once the thread is queued and before the lock is
    /// released (so a wake it causes is not lost; it may wake this waiter).
    public func wait(on lock: KernelLock, deadline: UInt64?, tag: UInt64,
                     beforeSleeping: (() -> Void)?) -> WaitResult {
        precondition(lock.isHeldByCurrentThread, "WaitQueue.wait needs the kernel lock")
        let context = lock.currentContext
        let w = Waiter(context: context, tag: tag)
        w.storage = storage
        if lock.isTerminated { return .interrupted }
        // A thread of an image that is ending never sleeps again (stage 4b).
        if let k = context?.kernel, k.isTerminating { return .interrupted }
        storage.waiters.append(w)
        lock.register(w)
        beforeSleeping?()
        if w.result == nil, let context {
            context.blockedInKernel = true
            lock.blockingObserver?(context, true)
        }
        while w.result == nil {
            if !lock.sleep(on: w.cond, deadline: deadline), w.result == nil {
                // Timed out and nobody woke it in the meantime.
                w.result = .timedOut
                storage.remove(w)
            }
        }
        lock.unregister(w)
        if let context, context.blockedInKernel {
            context.blockedInKernel = false
            lock.blockingObserver?(context, false)
        }
        return w.result!
    }

    /// Wakes up to `count` waiters, oldest first. Returns how many it woke.
    @discardableResult
    public func wake(count: Int) -> Int {
        var n = 0
        while n < count, let w = storage.waiters.first {
            w.finish(.woken)
            n += 1
        }
        return n
    }

    /// Wakes every waiter. Returns how many it woke.
    @discardableResult
    public func wakeAll() -> Int { wake(count: Int.max) }

    /// Wakes up to `limit` waiters for which `match(context, tag)` holds.
    @discardableResult
    public func wake(limit: Int = Int.max, where match: (ThreadContext?, UInt64) -> Bool) -> Int {
        var n = 0
        for w in storage.waiters where n < limit && match(w.context, w.tag) {
            w.finish(.woken)
            n += 1
        }
        return n
    }

    /// True when `context` waits here.
    public func contains(_ context: ThreadContext) -> Bool {
        storage.waiters.contains { $0.context === context }
    }
}
