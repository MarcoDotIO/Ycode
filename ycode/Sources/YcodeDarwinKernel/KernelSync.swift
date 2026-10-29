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
    fileprivate let mutex: UnsafeMutablePointer<pthread_mutex_t>
    /// The holding host thread (`threadToken`), 0 when free. Atomic: other
    /// threads read it (`isHeldByCurrentThread`) without the mutex.
    fileprivate let owner = Atomic<UInt>(0)
    /// The lock split (`mach-ipc-locking.md` §4) is on for the system of
    /// this kernel lock L0: IPC state has fine locks of its own.
    public let splitEnabled: Bool
    /// For a fine lock (level 1: an image's event lock L_P; level 2: the port
    /// lock G): the system's kernel lock L0. Nil for L0 itself.
    public let root: KernelLock?
    /// The lock's level in the order of `mach-ipc-locking.md` §4.1.
    public let level: Int
    /// The lock split is on for this lock (L0 of a split system, or a fine lock).
    @inline(__always) var isSplit: Bool { splitEnabled || root != nil }
    /// The L0 of the split this lock belongs to (itself for L0).
    @inline(__always) var splitRoot: KernelLock? { root ?? (splitEnabled ? self : nil) }
    /// L0 only: the fine locks of this system, for `interrupt`, `terminate`
    /// and the snapshot census (weak; guarded by `fineLocksMutex`).
    private var fineLocks: [WeakKernelLock] = []
    private let fineLocksMutex = NSLock()
    @inline(__always) fileprivate static var threadToken: UInt {
        #if canImport(Darwin)
        UInt(bitPattern: pthread_self())
        #else
        UInt(pthread_self())
        #endif
    }
    fileprivate var depth = 0
    /// Every thread blocked in a `WaitQueue` of this lock.
    fileprivate var waiters: [ObjectIdentifier: WaitQueue.Waiter] = [:]
    /// Waiters woken while the lock is held, signalled once it is released
    /// (`mach-ipc-locking.md` §3.2): a woken thread's first act is to take
    /// this lock, so signalling it while the lock is still held only makes
    /// it block on the mutex (and the futex wake would lengthen the hold).
    private var deferredWakes: [WaitQueue.Waiter] = []
    /// `YCODE_WAKE_AFTER_UNLOCK=0` (also the older `YCODE_DEFERRED_WAKE=0`)
    /// signals at once, under the lock (thread-latency.md §4; one mechanism
    /// for the kernel lock and the lock split's fine locks).
    nonisolated(unsafe) public static var wakeAfterUnlock: Bool = {
        for name in ["YCODE_WAKE_AFTER_UNLOCK", "YCODE_DEFERRED_WAKE"] {
            if let v = getenv(name) { return String(cString: v) != "0" }
        }
        return true
    }()

    /// Queues the signal of a woken waiter until the lock is released.
    /// Called by the holder.
    fileprivate func deferSignal(_ w: WaitQueue.Waiter) { deferredWakes.append(w) }

    /// Takes the deferred signals (lock held); signal them after unlocking.
    @inline(__always) fileprivate func takeDeferredWakes() -> [WaitQueue.Waiter]? {
        guard !deferredWakes.isEmpty else { return nil }
        let wakes = deferredWakes
        deferredWakes = []
        return wakes
    }

    @inline(__always) fileprivate static func signal(_ wakes: [WaitQueue.Waiter]?) {
        guard let wakes else { return }
        for w in wakes { pthread_cond_signal(w.cond) }
    }

    /// Profiling (`profileProcesses`): from a waiter's wakeup (`finish`) to
    /// its thread holding the lock again, process-wide.
    public static let wakeLatency = LatencyHistogram("wake")

    /// The context of the guest thread whose trap holds the lock (nil for a
    /// kernel service thread, such as the timer thread). Restored after a
    /// wait.
    public internal(set) var currentContext: ThreadContext?
    /// Set by `terminate()`: every wait returns `.interrupted` at once.
    public fileprivate(set) var isTerminated = false
    /// Told when a guest thread starts and stops blocking in a wait (the
    /// workqueue's "a blocked worker frees its slot" rule). Stage 4b: the
    /// `DarwinSystem` that owns the lock sets it once and forwards to the
    /// thread's own kernel (`ThreadContext.kernel`).
    var blockingObserver: ((_ context: ThreadContext, _ blocking: Bool) -> Void)?

    /// Diagnostics: total time held (ns), acquisitions, and a reporter for
    /// holds longer than `slowHoldNanoseconds` (context, duration).
    public private(set) var totalHeldNanoseconds: UInt64 = 0
    public private(set) var acquisitions: UInt64 = 0
    /// A fine lock's posted work (`runOrPost`): run by whoever holds the lock
    /// next, before it lets go. Guarded by `postedMutex` (a leaf).
    fileprivate var posted: [() -> Void] = []
    fileprivate let postedCount = Atomic<Int>(0)
    fileprivate let postedMutex = NSLock()
    /// A fine lock's contended acquisitions and their wait (split only).
    fileprivate var fineContended: UInt64 = 0
    fileprivate var fineWaitNanoseconds: UInt64 = 0
    public var slowHoldNanoseconds: UInt64 = 0
    public var slowHoldReporter: ((_ context: ThreadContext?, _ nanoseconds: UInt64) -> Void)?
    private var holdStart: UInt64 = 0
    /// Diagnostics (when `profileHolds`): total hold time and count per trap
    /// number of the holding thread (Int64.min = no guest thread).
    public var profileHolds = false
    public private(set) var holdProfile: [Int64: (ns: UInt64, count: UInt64)] = [:]
    /// Diagnostics (`YCODE_TRAP_PROFILE`, `TrapProfile.swift`): acquisitions,
    /// hold and wait time per trap. Nil (and free) unless the variable is set.
    let trapProfile: TrapProfile?

    /// Takes the mutex for `context` (profiled: the wait, and whether the
    /// mutex was taken). With the admission gate (`scheduling-policy.md`
    /// §4.5) a thread first yields to waiters of higher classes, for at most
    /// its class's bound; a contended wait is counted per class while it lasts.
    @inline(__always) fileprivate func lockMutex(for context: ThreadContext?) {
        let gate = admission
        let tracking = gate || tracksContention
        let traced = KernelTrace.lockWaited
        let timed = trapProfile != nil || (Self.profileProcesses && root == nil) || traced != nil
        let promoting = HostSched.promoting
        guard timed || tracking || promoting else {
            pthread_mutex_lock(mutex)
            return
        }
        let cls = gate ? (context?.schedClass ?? SchedClass.interactive) : SchedClass.default
        let start = timed ? KernelClock.now() : 0
        if gate, cls < SchedClass.interactive { admit(cls) }
        var contended = false
        if pthread_mutex_trylock(mutex) != 0 {
            contended = true
            if tracking {
                if cls >= SchedClass.default, context != nil { lastHighContentionStore.store(KernelClock.now(), ordering: .relaxed) }
                contending.wrappingAdd(Self.unit(cls), ordering: .sequentiallyConsistent)
            }
            if promoting { lockPromoting(context) } else { pthread_mutex_lock(mutex) }
            if tracking {
                contending.wrappingSubtract(Self.unit(cls), ordering: .sequentiallyConsistent)
                if gateWaiters.load(ordering: .sequentiallyConsistent) > 0 { wakeGate() }
            }
        }
        if timed {
            let waited = KernelClock.now() &- start
            trapProfile?.noteWait(TrapProfile.key(for: context), waited, contended: contended)
            if contended, let traced { traced(Int32(level), waited) }
            // The mutex is held: the image's counters may change.
            if Self.profileProcesses, let kernel = context?.kernel { kernel.profileLockWaitNanoseconds &+= waited }
        }
    }

    // MARK: Admission by class (scheduling-policy.md §4.5)

    /// The admission gate is on for this lock (from the switches when the
    /// lock is made; tests set it per lock).
    public var admission = SchedPolicy.gateActive
    /// Contended acquisitions are tracked (the gate, or the start hold's quiet test).
    public var tracksContention = SchedPolicy.holdEnabled

    /// Threads blocked on the mutex, 16 bits per class (class c at bit 16·c).
    private let contending = Atomic<UInt64>(0)
    /// Threads waiting at the admission gate.
    private let gateWaiters = Atomic<Int>(0)
    private let gateMutex: UnsafeMutablePointer<pthread_mutex_t>
    private let gateCond: UnsafeMutablePointer<pthread_cond_t>
    /// Host monotonic ns of the last contended acquisition by a guest thread
    /// of class ≥ default (the start hold's "quiet" test, §4.2).
    private let lastHighContentionStore = Atomic<UInt64>(0)
    public var lastHighContention: UInt64 { lastHighContentionStore.load(ordering: .relaxed) }
    /// Diagnostics: gate waits per class, their time, and bound expiries.
    private let gateWaits = Atomic<UInt64>(0)
    private let gateWaitNanoseconds = Atomic<UInt64>(0)
    private let gateBoundHits = Atomic<UInt64>(0)

    @inline(__always) static func unit(_ cls: Int) -> UInt64 { 1 << (16 * UInt64(cls)) }

    /// The number of threads of class `cls` that wait for the mutex.
    func contendingCount(_ cls: Int) -> UInt64 {
        (contending.load(ordering: .sequentiallyConsistent) >> (16 * UInt64(cls))) & 0xFFFF
    }

    /// The number of threads of classes above `cls` that wait for the mutex.
    func higherContending(_ cls: Int) -> UInt64 {
        contending.load(ordering: .sequentiallyConsistent) >> (16 * UInt64(cls + 1))
    }

    /// Waits while a thread of a higher class waits for the mutex, at most
    /// the class's bound. Holds no lock of the caller (the kernel lock is
    /// not held here), so it cannot deadlock; the bound keeps it from
    /// starving. A wakeup is not lost: a waiter counts itself in
    /// `gateWaiters` before it reads `contending` under `gateMutex`, and the
    /// thread that lowers `contending` reads `gateWaiters` after it (both
    /// sequentially consistent) and then signals under `gateMutex`; every
    /// wait is also cut into slices of at most 1 ms.
    private func admit(_ cls: Int) {
        guard higherContending(cls) != 0 else { return }
        let bounds = SchedPolicy.admissionBoundNanoseconds
        let bound = cls < bounds.count ? bounds[cls] : 0
        guard bound > 0 else { return }
        let start = KernelClock.now()
        let deadline = start &+ bound
        gateWaiters.wrappingAdd(1, ordering: .sequentiallyConsistent)
        pthread_mutex_lock(gateMutex)
        var hitBound = false
        while higherContending(cls) != 0 {
            let now = KernelClock.now()
            if now >= deadline {
                hitBound = true
                break
            }
            let slice = min(deadline - now, 1_000_000)
            #if canImport(Darwin)
            var ts = timespec(tv_sec: 0, tv_nsec: Int(slice))
            _ = pthread_cond_timedwait_relative_np(gateCond, gateMutex, &ts)
            #else
            let until = now + slice
            var ts = timespec(tv_sec: Int(until / 1_000_000_000), tv_nsec: Int(until % 1_000_000_000))
            _ = pthread_cond_timedwait(gateCond, gateMutex, &ts)
            #endif
        }
        pthread_mutex_unlock(gateMutex)
        gateWaiters.wrappingSubtract(1, ordering: .sequentiallyConsistent)
        gateWaits.wrappingAdd(1, ordering: .relaxed)
        gateWaitNanoseconds.wrappingAdd(KernelClock.now() &- start, ordering: .relaxed)
        if hitBound { gateBoundHits.wrappingAdd(1, ordering: .relaxed) }
    }

    private func wakeGate() {
        pthread_mutex_lock(gateMutex)
        pthread_cond_broadcast(gateCond)
        pthread_mutex_unlock(gateMutex)
    }

    /// Diagnostics: the gate's counters.
    public var admissionReport: String {
        "lock admission: \(gateWaits.load(ordering: .relaxed)) gate waits, "
            + "\(gateWaitNanoseconds.load(ordering: .relaxed) / 1_000_000) ms, "
            + "\(gateBoundHits.load(ordering: .relaxed)) at the bound"
    }

    /// Diagnostics (`YCODE_BOOT_PROFILE`; set once by the VMM before the
    /// first image): every hold and lock wait is also counted on the
    /// holding thread's image (`DarwinKernel.profileLock*`).
    nonisolated(unsafe) public static var profileProcesses = false

    /// The holder's counters at acquisition (`TrapProfile.threadUsage`).
    private var holdUsage: TrapProfile.ThreadUsage?
    /// Diagnostics (profiling only): the Linux thread id of the holder, 0
    /// when the lock is free (`TrapProfile.startHolderSampler`).
    private let holderTID = Atomic<Int>(0)
    public var holderThreadID: Int { holderTID.load(ordering: .relaxed) }
    /// Diagnostics (profiling only): the trap key of the holder.
    private let holderKey = Atomic<Int64>(0)
    public var holderTrapKey: Int64 { holderKey.load(ordering: .relaxed) }
    /// Diagnostics (profiling only): counts acquisitions, so the sampler
    /// can drop a sample whose holder let go while it was being read.
    private let holderSequence = Atomic<UInt64>(0)
    public var holdSequence: UInt64 { holderSequence.load(ordering: .acquiring) }

    // MARK: Holder promotion (scheduling-policy.md §4.7)

    /// The holder, for waiters that raise its host priority: bits 0–31 its
    /// Linux thread id, 32–35 its applied host class + 1 (0: none applied,
    /// never raised), 36–39 the class a waiter raised it to + 1 (0: not
    /// raised), 40–63 a generation that changes at every acquisition (so a
    /// waiter cannot raise a later holder by mistake). 0 while free.
    private let holderWord = Atomic<UInt64>(0)
    /// Waiters between their compare-exchange on `holderWord` and the end
    /// of their move of the holder.
    private let promotersInFlight = Atomic<Int>(0)
    /// Changed only by the holder.
    private var holderGeneration: UInt64 = 0

    @inline(__always) private func publishHolder() {
        guard let tid = HostSched.currentTID() else { return }
        holderGeneration &+= 1
        let applied = UInt64(max(-1, min(SchedClass.interactive, HostSched.appliedClass())) + 1)
        let word = UInt64(UInt32(bitPattern: tid)) | applied << 32 | (holderGeneration & 0xFF_FFFF) << 40
        holderWord.store(word, ordering: .sequentiallyConsistent)
    }

    /// The holder lets go. When a waiter raised it, it waits for every
    /// waiter still moving it and records the raised class as its applied
    /// one: `HostSched.apply` (at the end of its trap) moves it back to its
    /// own class, after the demotion delay.
    @inline(__always) private func withdrawHolder() {
        let old = holderWord.exchange(0, ordering: .sequentiallyConsistent)
        let raised = Int((old >> 36) & 0xF) - 1
        guard raised >= 0 else { return }
        var spins = 0
        while promotersInFlight.load(ordering: .sequentiallyConsistent) > 0 {
            spins += 1
            if spins > 64 { sched_yield() }
        }
        let applied = Int((old >> 32) & 0xF) - 1
        if HostSched.raisesGroup(applied) {
            HostSched.lowerGroup(applied)
        } else {
            HostSched.setAppliedClass(raised)
        }
        HostSched.promotionRestores.wrappingAdd(1, ordering: .relaxed)
    }

    /// `YCODE_LOCK_PROMOTION_DELAY_US` (default 200): a waiter raises the
    /// holder only after waiting this long. Holds are microseconds; a
    /// holder that keeps the lock this long is one the host does not run
    /// (scheduling-policy.md §4.7, §7.5: 200 µs boots were steadier than
    /// 1000 µs ones).
    nonisolated(unsafe) static var promotionDelayNanoseconds: UInt64 =
        UInt64(getenv("YCODE_LOCK_PROMOTION_DELAY_US").flatMap { Double(String(cString: $0)) } ?? 200) * 1000

    /// Takes the contended mutex: waits up to the promotion delay, then
    /// raises the holder (`promoteHolder`) and waits on.
    private func lockPromoting(_ context: ThreadContext?) {
        let delay = Self.promotionDelayNanoseconds
        if delay > 0 {
            #if os(Linux)
            var now = timespec()
            clock_gettime(CLOCK_REALTIME, &now)
            let total = UInt64(now.tv_nsec) + delay
            var until = timespec(tv_sec: now.tv_sec + Int(total / 1_000_000_000), tv_nsec: Int(total % 1_000_000_000))
            if pthread_mutex_timedlock(mutex, &until) == 0 { return }
            #else
            // No timed lock: poll (the promotion has a backend on Linux only;
            // the tests' move hook runs everywhere).
            let deadline = KernelClock.now() &+ delay
            while KernelClock.now() < deadline {
                if pthread_mutex_trylock(mutex) == 0 { return }
                usleep(50)
            }
            #endif
            HostSched.promotionWaits.wrappingAdd(1, ordering: .relaxed)
        }
        promoteHolder(to: context?.hostClass ?? SchedClass.interactive)
        pthread_mutex_lock(mutex)
    }

    /// A waiter of class `cls` found the lock taken: raise the holder's
    /// host thread to `cls` while it holds the lock (xnu's turnstile push
    /// onto a lock owner, §2.4). Holders that applied no class (host
    /// service threads, a guest thread before its first trap returned) are
    /// left alone; so is a holder already at `cls` or above.
    private func promoteHolder(to cls: Int) {
        guard cls > SchedClass.background else { return }
        promotersInFlight.wrappingAdd(1, ordering: .sequentiallyConsistent)
        defer { promotersInFlight.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
        var word = holderWord.load(ordering: .sequentiallyConsistent)
        while word != 0 {
            let applied = Int((word >> 32) & 0xF) - 1
            let raised = Int((word >> 36) & 0xF) - 1
            guard applied >= 0, cls > max(applied, raised) else { return }
            let new = (word & ~(UInt64(0xF) << 36)) | UInt64(cls + 1) << 36
            let (exchanged, original) = holderWord.compareExchange(expected: word, desired: new, ordering: .sequentiallyConsistent)
            if exchanged {
                if HostSched.raisesGroup(applied) {
                    // Counted once per holder: a second raise of the same
                    // holder only lifts the weight further.
                    if raised < 0 { HostSched.raiseGroup(applied, to: cls) } else { HostSched.raiseGroup(applied, to: cls); HostSched.lowerGroup(applied) }
                } else {
                    HostSched.move(Int32(truncatingIfNeeded: word & 0xFFFF_FFFF), to: cls)
                }
                HostSched.promotions.wrappingAdd(1, ordering: .relaxed)
                return
            }
            word = original
        }
    }

    /// `YCODE_FINE_LOCK_SPIN=0`: fine locks are plain mutexes.
    nonisolated(unsafe) public static var fineLockSpin = getenv("YCODE_FINE_LOCK_SPIN").map { String(cString: $0) != "0" } ?? true

    /// Diagnostics: a fine lock records its holder like L0 does when
    /// profiling (`LockStackSampler`).
    public var tracksHolder = false

    fileprivate func noteAcquired() {
        if trapProfile != nil || tracksHolder {
            if root == nil, let probe = TrapProfile.threadUsage { holdUsage = probe() }
            holderKey.store(TrapProfile.key(for: currentContext), ordering: .relaxed)
            if let tid = TrapProfile.currentThreadID { holderTID.store(tid(), ordering: .relaxed) }
            holderSequence.wrappingAdd(1, ordering: .releasing)
        }
        holdStart = KernelClock.now()
        acquisitions &+= 1
        if HostSched.promoting { publishHolder() }
    }

    fileprivate func noteReleasing() {
        if HostSched.promoting { withdrawHolder() }
        let held = KernelClock.now() &- holdStart
        if trapProfile != nil || tracksHolder {
            holderTID.store(0, ordering: .relaxed)
            holderSequence.wrappingAdd(1, ordering: .releasing)
        }
        totalHeldNanoseconds &+= held
        if Self.profileProcesses, root == nil, let kernel = currentContext?.kernel {
            kernel.profileLockHeldNanoseconds &+= held
            kernel.profileLockAcquisitions &+= 1
        }
        if profileHolds {
            let key = currentContext?.trapInProgress.map { Int64(bitPattern: $0.x16) } ?? Int64.min
            let old = holdProfile[key] ?? (0, 0)
            holdProfile[key] = (old.ns &+ held, old.count &+ 1)
        }
        if let trapProfile {
            var usage: TrapProfile.ThreadUsage?
            if let start = holdUsage, let probe = TrapProfile.threadUsage {
                let end = probe()
                usage = .init(faults: end.faults &- start.faults,
                              voluntarySwitches: end.voluntarySwitches &- start.voluntarySwitches,
                              involuntarySwitches: end.involuntarySwitches &- start.involuntarySwitches)
            }
            trapProfile.noteHold(TrapProfile.key(for: currentContext), held, usage: usage)
        }
        if slowHoldNanoseconds > 0, held >= slowHoldNanoseconds, let r = slowHoldReporter { r(currentContext, held) }
    }

    public convenience init() {
        self.init(ipcLocks: false)
    }

    /// The kernel lock L0; with `ipcLocks`, of a system with the lock split
    /// (`mach-ipc-locking.md` §4): it gets the IPC gate.
    public convenience init(ipcLocks: Bool) {
        self.init(split: ipcLocks, root: nil, level: 0, name: "kernel lock (L0)")
    }

    /// A fine lock of the split: level 1 (an image's event lock) or 2 (the
    /// port lock), under `root` (L0 of a split system).
    public convenience init(fineLockOf root: KernelLock, level: Int, name: String) {
        precondition(root.splitEnabled && (level == 1 || level == 2))
        self.init(split: false, root: root, level: level, name: name)
        admission = false
        tracksContention = false
        root.fineLocksMutex.lock()
        root.fineLocks.removeAll { $0.lock == nil }
        root.fineLocks.append(WeakKernelLock(self))
        root.fineLocksMutex.unlock()
    }

    private init(split: Bool, root: KernelLock?, level: Int, name: String) {
        splitEnabled = split
        self.root = root
        self.level = level
        trapProfile = root == nil ? TrapProfile.shared : (level == 2 ? TrapProfile.portLock : TrapProfile.eventLocks)
        mutex = .allocate(capacity: 1)
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        #if os(Linux)
        // Fine locks are held for microseconds: a contender spins briefly
        // before it sleeps (glibc adaptive mutex), instead of paying a futex
        // sleep and wakeup per handoff. `YCODE_FINE_LOCK_SPIN=0` turns it off.
        if root != nil, Self.fineLockSpin {
            pthread_mutexattr_settype(&attr, Int32(PTHREAD_MUTEX_ADAPTIVE_NP))
        }
        #endif
        pthread_mutex_init(mutex, &attr)
        pthread_mutexattr_destroy(&attr)
        TrapProfile.nameLock(UnsafeMutableRawPointer(mutex), name)
        gateMutex = .allocate(capacity: 1)
        pthread_mutex_init(gateMutex, nil)
        gateCond = .allocate(capacity: 1)
        var cattr = pthread_condattr_t()
        pthread_condattr_init(&cattr)
        #if !canImport(Darwin)
        pthread_condattr_setclock(&cattr, CLOCK_MONOTONIC)
        #endif
        pthread_cond_init(gateCond, &cattr)
        pthread_condattr_destroy(&cattr)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
        pthread_cond_destroy(gateCond)
        gateCond.deallocate()
        pthread_mutex_destroy(gateMutex)
        gateMutex.deallocate()
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
        if isSplit { return try withSplitLock(context: context, body) }
        KernelThreadLocks.checkNoLeaf(self)
        lockMutex(for: context)
        owner.store(Self.threadToken, ordering: .relaxed)
        depth = 1
        currentContext = context
        noteAcquired()
        defer {
            noteReleasing()
            currentContext = nil
            depth = 0
            owner.store(0, ordering: .relaxed)
            let wakes = takeDeferredWakes()
            pthread_mutex_unlock(mutex)
            Self.signal(wakes)
        }
        return try body()
    }

    /// Ends every current and future wait with `.interrupted` (process exit).
    /// Call with the lock held.
    public func terminate() {
        precondition(isHeldByCurrentThread, "KernelLock.terminate needs the kernel lock")
        isTerminated = true
        forEachRegistry { lock in
            for w in lock.waiters.values { w.finish(.interrupted) }
            lock.waiters.removeAll()
        }
    }

    /// Runs `body` on this lock and, with the split, on each live fine lock
    /// while holding it (each registry is that lock's state).
    private func forEachRegistry(_ body: (KernelLock) -> Void) {
        body(self)
        for lock in liveFineLocks {
            if lock.isHeldByCurrentThread { body(lock) } else { lock.withLock { body(lock) } }
        }
    }

    /// Ends every current and future wait of the guest threads of one
    /// process image (`kernel`), and of no other (stage 4b: several processes
    /// share this lock). Waits without a thread context are not touched (the
    /// image's timer thread watches `DarwinKernel.isTerminating`). Call with
    /// the lock held, after `kernel.isTerminating` became true.
    public func terminate(kernel: DarwinKernel) {
        precondition(isHeldByCurrentThread, "KernelLock.terminate needs the kernel lock")
        forEachRegistry { lock in
            for (key, w) in lock.waiters where w.context?.kernel === kernel {
                w.finish(.interrupted)
                lock.waiters[key] = nil
            }
        }
    }

    /// Interrupts the waits of one guest thread (signal delivery). Returns
    /// true when it was waiting. Call with the lock held.
    @discardableResult
    public func interrupt(_ context: ThreadContext) -> Bool {
        precondition(isHeldByCurrentThread, "KernelLock.interrupt needs the kernel lock")
        var any = false
        forEachRegistry { lock in
            for (key, w) in lock.waiters where w.context === context {
                w.finish(.interrupted)
                lock.waiters[key] = nil
                any = true
            }
        }
        return any
    }

    /// L0 of a split, held: runs `body` holding every live fine lock too (the
    /// event locks, then the port lock), so that no fast path changes IPC
    /// state while a quiesced system is classified and captured
    /// (`mach-ipc-locking.md` §4.6, snapshots). Only this caller holds more
    /// than one event lock; the others never wait for L0 while holding one,
    /// so this cannot deadlock.
    public func withAllFineLocks<T>(_ body: () throws -> T) rethrows -> T {
        guard splitEnabled else { return try body() }
        precondition(isHeldByCurrentThread, "withAllFineLocks needs the kernel lock")
        let locks = liveFineLocks.sorted { ($0.level, ObjectIdentifier($0)) < ($1.level, ObjectIdentifier($1)) }
            .filter { !$0.isHeldByCurrentThread }
        let threadLocks = KernelThreadLocks.current
        let wasQuiesced = threadLocks.quiesced
        threadLocks.quiesced = true
        for lock in locks {
            lock.acquireRaw(depth: 1, context: currentContext)
            threadLocks.held.append(lock)
        }
        defer {
            for lock in locks.reversed() {
                threadLocks.held.removeAll { $0 === lock }
                lock.releaseRaw()
            }
            threadLocks.quiesced = wasQuiesced
            if !threadLocks.deferred.isEmpty { threadLocks.runDeferredWork() }
        }
        return try body()
    }

    /// L0 of a split: its live fine locks (empty otherwise).
    var liveFineLocks: [KernelLock] {
        guard splitEnabled else { return [] }
        fineLocksMutex.lock()
        defer { fineLocksMutex.unlock() }
        return fineLocks.compactMap(\.lock)
    }

    /// Releases the lock, yields the host CPU, and takes the lock again
    /// (`thread_switch`). Call at nesting depth 1.
    public func yield() {
        precondition(isHeldByCurrentThread && depth == 1, "KernelLock.yield needs the lock at depth 1")
        // Split: only when nothing is held above L0 (a fine lock may not be
        // held without the gate).
        if isSplit {
            // Only when nothing is held above L0.
            guard root == nil, KernelThreadLocks.current.held.last === self else { sched_yield(); return }
            KernelThreadLocks.current.held.removeLast()
            defer { KernelThreadLocks.current.held.append(self) }
        }
        let saved = currentContext
        noteReleasing()
        owner.store(0, ordering: .relaxed)
        depth = 0
        currentContext = nil
        let wakes = takeDeferredWakes()
        pthread_mutex_unlock(mutex)
        Self.signal(wakes)
        sched_yield()
        lockMutex(for: saved)
        owner.store(Self.threadToken, ordering: .relaxed)
        depth = 1
        currentContext = saved
        noteAcquired()
    }

    /// Diagnostics (`YCODE_DEBUG_NO_UNLOCK=1`): `unlocked` keeps the lock.
    static let neverUnlock = getenv("YCODE_DEBUG_NO_UNLOCK").map { String(cString: $0) == "1" } ?? false

    /// Runs `body` with the lock released (stage 6, `stage6-contract.md`
    /// §5.1, first step: host file-system I/O outside the global lock) and
    /// takes it again before returning. `body` must touch no state the lock
    /// protects. At nesting depth > 1 (a caller that cannot give the lock
    /// up) `body` runs with the lock held.
    public func unlocked<T>(_ body: () throws -> T) rethrows -> T {
        guard isHeldByCurrentThread, depth == 1, !Self.neverUnlock else { return try body() }
        if isSplit {
            guard root == nil, KernelThreadLocks.current.held.last === self else { return try body() }
            KernelThreadLocks.current.held.removeLast()
        }
        defer { if isSplit { KernelThreadLocks.current.held.append(self) } }
        let saved = currentContext
        noteReleasing()
        owner.store(0, ordering: .relaxed)
        depth = 0
        currentContext = nil
        let wakes = takeDeferredWakes()
        pthread_mutex_unlock(mutex)
        Self.signal(wakes)
        defer {
            lockMutex(for: saved)
            owner.store(Self.threadToken, ordering: .relaxed)
            depth = 1
            currentContext = saved
            noteAcquired()
        }
        return try body()
    }

    /// SNAPSHOT hook (agent SNAP, specs/simulator/snapshot.md §3.1 step 3):
    /// every registered waiter's thread and whether it was already woken
    /// (a result is set, the thread has not returned from `wait` yet). Lock held.
    var snapshotWaiterStates: [(context: ThreadContext?, woken: Bool)] {
        var states: [(context: ThreadContext?, woken: Bool)] = []
        forEachRegistry { lock in
            states += lock.waiters.values.map { ($0.context, $0.result != nil) }
            if WaitQueue.Waiter.recordStacks {
                for w in lock.waiters.values where w.result == nil && w.context?.trapInProgress == nil {
                    FileHandle.standardError.write(Data(("wait without a trap on \(lock.name), thread \(w.context?.threadID ?? 0):\n"
                        + (w.debugStack ?? []).prefix(14).joined(separator: "\n") + "\n").utf8))
                }
            }
        }
        return states
    }

    // MARK: Used by WaitQueue

    fileprivate func register(_ w: WaitQueue.Waiter) { waiters[ObjectIdentifier(w)] = w }

    fileprivate func unregister(_ w: WaitQueue.Waiter) { waiters[ObjectIdentifier(w)] = nil }

    /// Sleeps on `cond` until signalled or `deadline`, releasing the mutex.
    /// Returns false on timeout.
    fileprivate func sleep(on cond: UnsafeMutablePointer<pthread_cond_t>, deadline: UInt64?) -> Bool {
        precondition(depth == 1, "WaitQueue.wait inside a nested withLock")
        // The condition wait releases the mutex atomically: deferred
        // signals go out first, still under the lock.
        Self.signal(takeDeferredWakes())
        let saved = currentContext
        noteReleasing()
        owner.store(0, ordering: .relaxed)
        depth = 0
        currentContext = nil
        let rc = Self.conditionWait(cond, mutex, deadline: deadline)
        owner.store(Self.threadToken, ordering: .relaxed)
        depth = 1
        currentContext = saved
        noteAcquired()
        return rc != ETIMEDOUT
    }

    /// One condition wait on `mutex` (held), until signalled or `deadline`
    /// (absolute host monotonic ns). Returns the pthread result (ETIMEDOUT
    /// at the deadline).
    fileprivate static func conditionWait(_ cond: UnsafeMutablePointer<pthread_cond_t>,
                                          _ mutex: UnsafeMutablePointer<pthread_mutex_t>, deadline: UInt64?) -> Int32 {
        guard let deadline else { return pthread_cond_wait(cond, mutex) }
        let now = KernelClock.now()
        if now >= deadline { return ETIMEDOUT }
        #if canImport(Darwin)
        let remaining = deadline - now
        var ts = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
        return pthread_cond_timedwait_relative_np(cond, mutex, &ts)
        #else
        var ts = timespec(tv_sec: Int(deadline / 1_000_000_000), tv_nsec: Int(deadline % 1_000_000_000))
        return pthread_cond_timedwait(cond, mutex, &ts)
        #endif
    }
}

/// A queue of blocked host threads. It has reference semantics: copies share
/// the same waiters. Every call must be made with the kernel lock held.
public struct WaitQueue: @unchecked Sendable {
    /// One blocked host thread.
    final class Waiter {
        let cond: UnsafeMutablePointer<pthread_cond_t>
        /// The lock the waiter sleeps on (it outlives every wait on it).
        unowned let lock: KernelLock
        let context: ThreadContext?
        let tag: UInt64
        var result: WaitResult?
        weak var storage: Storage?
        /// Diagnostics (`YCODE_DEBUG_WAIT_STACKS=1`): where the wait began.
        var debugStack: [String]?
        static let recordStacks = getenv("YCODE_DEBUG_WAIT_STACKS").map { String(cString: $0) == "1" } ?? false
        /// Profiling: when `finish` woke it (monotonic ns).
        var wokenAt: UInt64 = 0

        init(lock: KernelLock, context: ThreadContext?, tag: UInt64) {
            self.lock = lock
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
            if r == .woken, let hook = KernelTrace.wake { hook(context) }
            if lock.isSplit, !lock.isHeldByCurrentThread {
                // A waker without the waiter's lock (`mach-ipc-locking.md`
                // §4.4, I2): the waiter reads `result` only under its lock.
                pthread_mutex_lock(lock.mutex)
                result = r
                storage?.remove(self)
                pthread_cond_signal(cond)
                pthread_mutex_unlock(lock.mutex)
                return
            }
            result = r
            storage?.remove(self)
            if KernelLock.profileProcesses { wokenAt = KernelClock.now() }
            // A holder of the lock signals once it lets go; the waiter cannot
            // miss it: it sleeps until signalled and checks `result` under
            // the lock, and the deferred list keeps it (and its condition)
            // alive until the signal is sent (thread-latency.md §4,
            // mach-ipc-locking.md §3.2).
            if KernelLock.wakeAfterUnlock, lock.isHeldByCurrentThread {
                lock.deferSignal(self)
            } else {
                pthread_cond_signal(cond)
            }
        }
    }

    final class Storage {
        var waiters: [Waiter] = []
        /// The lock the queue's waiters sleep on (split only; set by the
        /// first wait): the queue's state is guarded by it.
        var bound: KernelLock?
        func remove(_ w: Waiter) { waiters.removeAll { $0 === w } }
    }

    fileprivate let storage = Storage()

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
        if lock.isSplit { return splitWait(on: lock, deadline: deadline, tag: tag, beforeSleeping: beforeSleeping) }
        precondition(lock.isHeldByCurrentThread, "WaitQueue.wait needs the kernel lock")
        let context = lock.currentContext
        let w = Waiter(lock: lock, context: context, tag: tag)
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
            KernelTrace.blocking?(context, true)
        }
        while w.result == nil {
            if !lock.sleep(on: w.cond, deadline: deadline), w.result == nil {
                // Timed out and nobody woke it in the meantime.
                w.result = .timedOut
                storage.remove(w)
            }
        }
        lock.unregister(w)
        if w.wokenAt != 0, w.result == .woken { KernelLock.wakeLatency.add(KernelClock.now() &- w.wokenAt) }
        if let context, context.blockedInKernel {
            context.blockedInKernel = false
            lock.blockingObserver?(context, false)
            KernelTrace.blocking?(context, false)
        }
        return w.result!
    }

    /// Wakes up to `count` waiters, oldest first. Returns how many it woke.
    /// With the split check on: the queue's lock must be held (I2, I3).
    @inline(__always) private func checkBound() {
        if KernelThreadLocks.checkOrder, let bound = storage.bound { bound.checkHeld("a wait queue") }
    }

    @discardableResult
    public func wake(count: Int) -> Int {
        checkBound()
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
        checkBound()
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

// MARK: - The lock split (`specs/simulator/mach-ipc-locking.md` §4)

struct WeakKernelLock {
    weak var lock: KernelLock?
    init(_ lock: KernelLock) { self.lock = lock }
}

/// Work a thread cannot do with the locks it holds (`mach-ipc-locking.md`
/// §4.5); it runs as soon as the thread's locks allow taking what it needs.
public struct DeferredKernelWork {
    enum Need {
        /// The kernel mutex M0 (`lock` is the system's L0).
        case kernelLock(KernelLock)
        /// A fine lock (an image's event lock).
        case fineLock(KernelLock)
    }

    let need: Need
    let run: () -> Void
}

/// Per host thread: the kernel locks of a split it holds (in acquisition
/// order), whether it runs a fast path and for which guest thread, and its
/// deferred work. Used only when the split is on.
public final class KernelThreadLocks {
    /// Locks held, in acquisition order (each once; nesting is the lock's depth).
    var held: [KernelLock] = []
    /// Nesting of fast paths (`KernelLock.withFastPath`).
    fileprivate var fastDepth = 0
    /// True while the thread runs a BSD fast path (`bsd-locking.md`; no
    /// kernel lock, no trace text).
    var bsdFast = false
    /// The guest thread whose trap runs on this host thread's fast path.
    var context: ThreadContext?
    /// Work for when this thread's locks allow it.
    var deferred: [DeferredKernelWork] = []
    /// A fast `mach_msg` (`mach-ipc-locking.md` §4.3): its send bytes read
    /// from guest memory before the port lock was taken, and the received
    /// message written to guest memory after it is released.
    var prefetchedSend: (va: UInt64, bytes: [UInt8])?
    var deferReceiveWrite = false
    var pendingReceiveWrite: (memory: any GuestVirtualMemory, va: UInt64, bytes: [UInt8])?
    /// Set while a quiesced system is captured or restored (no other thread
    /// runs): the lock checks are off.
    var quiesced = false
    /// True while the thread is running deferred work (no nested drain).
    private var draining = false

    /// True while the thread runs a fast path (no kernel mutex).
    var isFast: Bool { fastDepth > 0 }

    /// `YCODE_LOCK_ORDER_CHECK=1`: every acquisition is checked against the
    /// order, and guarded state against its lock (tests turn it on).
    nonisolated(unsafe) public static var checkOrder = getenv("YCODE_LOCK_ORDER_CHECK").map { String(cString: $0) == "1" } ?? false {
        didSet { LeafLockCheck.enabled = checkOrder }
    }

    /// Stops the process when the calling thread holds a leaf lock (a
    /// descriptor table's, `bsd-locking.md` §3) while it takes `lock`.
    @inline(__always) static func checkNoLeaf(_ lock: KernelLock) {
        guard LeafLockCheck.enabled, LeafLockCheck.depth > 0 else { return }
        FileHandle.standardError.write(Data(Thread.callStackSymbols.joined(separator: "\n").utf8))
        fatalError("kernel lock order: taking \(lock.name) while holding a leaf lock (bsd-locking.md §3)")
    }

    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key) { raw in
            #if canImport(Darwin)
            Unmanaged<KernelThreadLocks>.fromOpaque(raw).release()
            #else
            if let raw { Unmanaged<KernelThreadLocks>.fromOpaque(raw).release() }
            #endif
        }
        return key
    }()

    /// The calling host thread's record.
    public static var current: KernelThreadLocks {
        if let raw = pthread_getspecific(key) { return Unmanaged<KernelThreadLocks>.fromOpaque(raw).takeUnretainedValue() }
        let record = KernelThreadLocks()
        pthread_setspecific(key, Unmanaged.passRetained(record).toOpaque())
        return record
    }

    /// The highest level held (−1: none).
    var highestLevel: Int { held.last?.level ?? -1 }

    /// True when `lock` may be taken now: every lock held is of a lower level.
    func canAcquire(_ lock: KernelLock) -> Bool { highestLevel < lock.level }

    /// Stops the process when `lock` may not be taken now (with the check on).
    @inline(__always) func checkAcquire(_ lock: KernelLock) {
        Self.checkNoLeaf(lock)
        guard Self.checkOrder, !quiesced, !canAcquire(lock) else { return }
        FileHandle.standardError.write(Data(Thread.callStackSymbols.joined(separator: "\n").utf8))
        fatalError("kernel lock order: taking \(lock.name) (level \(lock.level)) while holding "
            + held.map { "\($0.name) (\($0.level))" }.joined(separator: ", ") + " (mach-ipc-locking.md §4.1)")
    }

    /// The context a lock taken now inherits: the trap's guest thread.
    var inheritedContext: ThreadContext? {
        for lock in held.reversed() { if let c = lock.currentContext { return c } }
        return context
    }

    /// What `releaseAll` gave up.
    struct Saved {
        var locks: [(lock: KernelLock, depth: Int, context: ThreadContext?)] = []
    }

    /// Releases every lock this thread holds (a wait, `mach-ipc-locking.md` §4.4 step 2).
    func releaseAll() -> Saved { releaseAbove(nil) }

    /// Releases the locks held above `lock` (all with nil).
    func releaseAbove(_ lock: KernelLock?) -> Saved {
        var saved = Saved()
        while let top = held.last, top !== lock {
            saved.locks.append((top, top.depth, top.currentContext))
            top.releaseRaw()
            held.removeLast()
            if top.postedCount.load(ordering: .sequentiallyConsistent) > 0 { top.drainPosted(self) }
        }
        saved.locks.reverse()
        return saved
    }

    /// Takes back what `releaseAll`/`releaseAbove` gave up, in the original order.
    func reacquireAll(_ saved: Saved) {
        for entry in saved.locks {
            entry.lock.acquireRaw(depth: entry.depth, context: entry.context)
            held.append(entry.lock)
        }
    }

    /// True when `need` can be met now (in order, or already held).
    private func satisfiable(_ need: DeferredKernelWork.Need) -> Bool {
        switch need {
        case let .kernelLock(l0): return l0.isHeldByCurrentThread ? held.last === l0 : held.isEmpty
        case let .fineLock(fine): return fine.isHeldByCurrentThread ? held.last === fine : canAcquire(fine)
        }
    }

    /// Runs the deferred work this thread's locks now allow, until none of
    /// what is left can run.
    func runDeferredWork() {
        guard !draining, !deferred.isEmpty else { return }
        draining = true
        // Deferred work is not part of the trap's own receive.
        let savedDefer = deferReceiveWrite
        deferReceiveWrite = false
        defer {
            draining = false
            deferReceiveWrite = savedDefer
        }
        var progress = true
        while progress, !deferred.isEmpty {
            progress = false
            var keep: [DeferredKernelWork] = []
            let batch = deferred
            deferred = []
            for item in batch {
                guard satisfiable(item.need) else { keep.append(item); continue }
                progress = true
                switch item.need {
                case let .kernelLock(l0): l0.withLock { item.run() }
                case let .fineLock(fine): fine.runOrPost(item.run)
                }
            }
            deferred = keep + deferred
        }
    }
}

extension KernelLock {
    /// The lock's name (diagnostics).
    var name: String { root == nil ? "kernel lock (L0)" : (level == 2 ? "port lock (G)" : "event lock (L_P)") }

    /// A lock of a split system taken by a thread that does not hold it.
    func withSplitLock<T>(context: ThreadContext?, _ body: () throws -> T) rethrows -> T {
        let threadLocks = KernelThreadLocks.current
        threadLocks.checkAcquire(self)
        acquireRaw(depth: 1, context: context ?? threadLocks.inheritedContext)
        threadLocks.held.append(self)
        defer {
            if threadLocks.held.last === self { threadLocks.held.removeLast() } else {
                threadLocks.held.removeAll { $0 === self }
            }
            releaseRaw()
            if postedCount.load(ordering: .sequentiallyConsistent) > 0 { drainPosted(threadLocks) }
            if !threadLocks.deferred.isEmpty { threadLocks.runDeferredWork() }
        }
        return try body()
    }

    /// Runs `work` under this fine lock: now if the lock is free (or held by
    /// this thread), else hands it to the thread that holds it, which runs
    /// it before it lets go (`mach-ipc-locking.md` §4.5). The caller's locks
    /// must allow taking this one. No posted work is left behind: a poster
    /// tries the lock again after posting, and every release looks for
    /// posted work after unlocking.
    func runOrPost(_ work: @escaping () -> Void) {
        if isHeldByCurrentThread { work(); return }
        let threadLocks = KernelThreadLocks.current
        if tryWithLock(threadLocks, work) { return }
        postedMutex.lock()
        posted.append(work)
        postedCount.wrappingAdd(1, ordering: .sequentiallyConsistent)
        postedMutex.unlock()
        drainPosted(threadLocks)
    }

    /// Takes the lock if it is free and runs `body`; false when it is taken.
    private func tryWithLock(_ threadLocks: KernelThreadLocks, _ body: () -> Void) -> Bool {
        guard threadLocks.canAcquire(self), pthread_mutex_trylock(mutex) == 0 else { return false }
        owner.store(Self.threadToken, ordering: .relaxed)
        depth = 1
        currentContext = threadLocks.inheritedContext
        noteAcquired()
        threadLocks.held.append(self)
        body()
        threadLocks.held.removeLast()
        releaseRaw()
        if postedCount.load(ordering: .sequentiallyConsistent) > 0 { drainPosted(threadLocks) }
        if !threadLocks.deferred.isEmpty { threadLocks.runDeferredWork() }
        return true
    }

    /// Runs the posted work if the lock is free now (after an unlock).
    fileprivate func drainPosted(_ threadLocks: KernelThreadLocks) {
        while postedCount.load(ordering: .sequentiallyConsistent) > 0 {
            guard threadLocks.canAcquire(self), pthread_mutex_trylock(mutex) == 0 else { return }
            owner.store(Self.threadToken, ordering: .relaxed)
            depth = 1
            currentContext = nil
            noteAcquired()
            threadLocks.held.append(self)
            while true {
                postedMutex.lock()
                let batch = posted
                posted = []
                postedCount.wrappingSubtract(batch.count, ordering: .sequentiallyConsistent)
                postedMutex.unlock()
                if batch.isEmpty { break }
                for work in batch { work() }
            }
            threadLocks.held.removeLast()
            releaseRaw()
        }
    }

    /// Takes the mutex and becomes the owner.
    fileprivate func acquireRaw(depth newDepth: Int, context: ThreadContext?) {
        if root == nil {
            lockMutex(for: context)
        } else if pthread_mutex_trylock(mutex) != 0 {
            let start = KernelClock.now()
            if HostSched.promoting { lockPromoting(context) } else { pthread_mutex_lock(mutex) }
            let waited = KernelClock.now() &- start
            fineContended &+= 1
            fineWaitNanoseconds &+= waited
            trapProfile?.noteWait(TrapProfile.key(for: context), waited, contended: true)
            if let traced = KernelTrace.lockWaited { traced(Int32(level), waited) }
        } else if let trapProfile {
            trapProfile.noteWait(TrapProfile.key(for: context), 0, contended: false)
        }
        owner.store(Self.threadToken, ordering: .relaxed)
        depth = newDepth
        currentContext = context
        noteAcquired()
    }

    /// Gives up ownership and the mutex, then sends the deferred wakeups.
    fileprivate func releaseRaw() {
        noteReleasing()
        currentContext = nil
        depth = 0
        owner.store(0, ordering: .relaxed)
        let wakes = takeDeferredWakes()
        pthread_mutex_unlock(mutex)
        Self.signal(wakes)
    }

    /// A fine lock held once, as the thread's last lock: runs `body` with it
    /// released and takes it back (VM work inside a Mach routine that needs
    /// no Mach state, `mach-ipc-locking.md` §4.2). Otherwise runs `body` as is.
    public func withoutFineLock<T>(_ body: () throws -> T) rethrows -> T {
        guard root != nil, isHeldByCurrentThread, depth == 1 else { return try body() }
        let threadLocks = KernelThreadLocks.current
        guard threadLocks.held.last === self else { return try body() }
        let context = currentContext
        threadLocks.held.removeLast()
        releaseRaw()
        defer {
            threadLocks.checkAcquire(self)
            acquireRaw(depth: 1, context: context)
            threadLocks.held.append(self)
        }
        return try body()
    }

    /// Runs `body` as a fast path for `context`'s trap: no lock is taken here
    /// (the body takes the fine locks it needs); deferred work runs before
    /// this returns. Without the split, runs `body` under L0.
    public func withFastPath<T>(context: ThreadContext?, _ body: () throws -> T) rethrows -> T {
        guard splitEnabled else { return try withLock(context: context, body) }
        let threadLocks = KernelThreadLocks.current
        precondition(threadLocks.held.isEmpty && threadLocks.fastDepth == 0,
                     "a fast path starts with no kernel lock held (mach-ipc-locking.md §4.3)")
        let savedContext = threadLocks.context
        threadLocks.fastDepth = 1
        threadLocks.context = context
        defer {
            threadLocks.runDeferredWork()
            threadLocks.fastDepth = 0
            threadLocks.context = savedContext
        }
        return try body()
    }

    /// A fast path holding exactly this fine lock (an image's event lock)
    /// that must read L0 state (descriptor readiness, `mach-ipc-locking.md`
    /// §4.11): gives the lock up, takes L0, takes the lock back (in order),
    /// runs `body` under both, then gives L0 up and keeps this lock. The
    /// lock is not held for a moment, as in a wait. Nil (nothing done) when
    /// the thread holds anything else.
    func escalateToKernelLock<T>(_ body: () throws -> T) rethrows -> T? {
        guard let l0 = root, level == 1, !l0.isHeldByCurrentThread else { return nil }
        let threadLocks = KernelThreadLocks.current
        guard threadLocks.held.count == 1, threadLocks.held[0] === self else { return nil }
        let context = currentContext
        let saved = threadLocks.releaseAll()
        if !threadLocks.deferred.isEmpty { threadLocks.runDeferredWork() }
        defer { threadLocks.reacquireAll(saved) }
        KernelLock.escalations.wrappingAdd(1, ordering: .relaxed)
        return try l0.withLock(context: context) { () throws -> T in
            threadLocks.reacquireAll(saved)
            defer { _ = threadLocks.releaseAbove(l0) }
            return try body()
        }
    }

    /// Diagnostics: escalations from an event lock to L0.
    static let escalations = Atomic<UInt64>(0)

    /// Runs `work` now if the calling thread's locks allow taking what it
    /// needs (or hold it), else queues it for when they do. Without the
    /// split, runs it now (L0 is held).
    func deferIfFast(_ need: DeferredKernelWork.Need, tag: StaticString = "other", _ work: @escaping () -> Void) {
        guard isSplit else { work(); return }
        let threadLocks = KernelThreadLocks.current
        switch need {
        case let .kernelLock(l0):
            if l0.isHeldByCurrentThread { work(); return }
        case let .fineLock(fine):
            if fine.isHeldByCurrentThread { work(); return }
            if threadLocks.canAcquire(fine) { fine.runOrPost(work); return }
        }
        if case .kernelLock = need { Self.countDeferredL0(tag) }
        threadLocks.deferred.append(DeferredKernelWork(need: need, run: work))
    }

    /// Diagnostics: work deferred to L0 from a fast path, by kind.
    static let deferredL0 = Mutex<[String: UInt64]>([:])
    static func countDeferredL0(_ tag: StaticString) {
        deferredL0.withLock { $0["\(tag)", default: 0] &+= 1 }
    }

    /// The guest thread whose trap the calling host thread runs: this lock's
    /// context when the caller holds it (or without the split), else the
    /// context of the caller's fast path or of the fine lock it holds.
    var callerContext: ThreadContext? {
        if !isSplit || isHeldByCurrentThread { return currentContext }
        return KernelThreadLocks.current.inheritedContext
    }

    /// True when the calling thread does not hold the kernel mutex of this
    /// lock's split (a fast path, or deferred work run without it).
    var callerIsFast: Bool {
        guard let l0 = splitRoot else { return false }
        return !l0.isHeldByCurrentThread
    }

    /// Stops the process when the calling thread does not hold this lock
    /// (with `YCODE_LOCK_ORDER_CHECK=1`; state guarded by a fine lock).
    @inline(__always) func checkHeld(_ what: @autoclosure () -> String) {
        guard KernelThreadLocks.checkOrder, isSplit, !isHeldByCurrentThread else { return }
        if KernelThreadLocks.current.quiesced { return }
        FileHandle.standardError.write(Data(Thread.callStackSymbols.joined(separator: "\n").utf8))
        fatalError("\(what()) touched without \(name) (mach-ipc-locking.md §4.2)")
    }

    /// Diagnostics: the split's lock statistics (one line).
    public var splitReport: String {
        guard splitEnabled else { return "" }
        var parts = ["IPC fast traps: \(DarwinKernel.ipcFastServed.load(ordering: .relaxed)) served, "
            + "\(DarwinKernel.ipcFastDeclined.load(ordering: .relaxed)) fell back (descriptor knotes "
            + "\(DarwinKernel.ipcFastDeclinedDescriptors.load(ordering: .relaxed)), call "
            + "\(DarwinKernel.ipcFastDeclinedCall.load(ordering: .relaxed)), kernel object "
            + "\(DarwinKernel.ipcFastDeclinedKernelObject.load(ordering: .relaxed))); port routines without L0 "
            + "\(DarwinKernel.portRoutineFastServed.load(ordering: .relaxed)); proc_info reads without L0 "
            + "\(DarwinKernel.procInfoReadFast.load(ordering: .relaxed))"]
        var events = (held: UInt64(0), acq: UInt64(0), cont: UInt64(0), wait: UInt64(0), n: 0)
        for lock in liveFineLocks {
            if lock.level == 2 {
                parts.append("port lock: held \(lock.totalHeldNanoseconds / 1_000_000) ms, \(lock.acquisitions) acquisitions, "
                    + "\(lock.fineContended) contended, \(lock.fineWaitNanoseconds / 1_000_000) ms waited")
            } else {
                events.held &+= lock.totalHeldNanoseconds
                events.acq &+= lock.acquisitions
                events.cont &+= lock.fineContended
                events.wait &+= lock.fineWaitNanoseconds
                events.n += 1
            }
        }
        parts.append("BSD fast traps: \(DarwinKernel.bsdFastServed.load(ordering: .relaxed)) served, "
            + "\(DarwinKernel.bsdFastDeclined.load(ordering: .relaxed)) fell back, "
            + "\(DarwinKernel.bsdFastCloseHooks.load(ordering: .relaxed)) closes ran the hook under L0 ("
            + "\(DarwinKernel.bsdFastCloseHooksWatched.load(ordering: .relaxed)) for knotes)")
        parts.append(DarwinKernel.bsdDeclineReport)
        parts.append("escalations from an event lock to L0 (descriptor readiness): \(KernelLock.escalations.load(ordering: .relaxed))")
        if DarwinKernel.debugDescriptorCandidates { parts.append(DarwinKernel.descriptorDeclineReport) }
        parts.append("work deferred to L0: " + KernelLock.deferredL0.withLock { $0 }.sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        parts.append("event locks (\(events.n) live): held \(events.held / 1_000_000) ms, \(events.acq) acquisitions, "
            + "\(events.cont) contended, \(events.wait / 1_000_000) ms waited")
        return parts.joined(separator: "; ")
    }
}

extension WaitQueue {
    /// `wait` under the lock split (`mach-ipc-locking.md` §4.4).
    fileprivate func splitWait(on lock: KernelLock, deadline: UInt64?, tag: UInt64,
                               beforeSleeping: (() -> Void)?) -> WaitResult {
        let threadLocks = KernelThreadLocks.current
        let root = lock.splitRoot!
        var took = false
        if !lock.isHeldByCurrentThread {
            precondition(lock.root != nil, "WaitQueue.wait needs the kernel lock")
            threadLocks.checkAcquire(lock)
            lock.acquireRaw(depth: 1, context: threadLocks.inheritedContext)
            threadLocks.held.append(lock)
            took = true
        }
        defer {
            if took {
                threadLocks.held.removeAll { $0 === lock }
                lock.releaseRaw()
            }
        }
        precondition(lock.depth == 1, "WaitQueue.wait inside a nested withLock")
        storage.bound = lock
        let context = lock.currentContext
        let w = Waiter(lock: lock, context: context, tag: tag)
        w.storage = storage
        if Waiter.recordStacks { w.debugStack = Thread.callStackSymbols }
        if root.isTerminated { return .interrupted }
        if let k = context?.kernel, k.isTerminating { return .interrupted }
        storage.waiters.append(w)
        lock.register(w)
        beforeSleeping?()
        if w.result == nil, let context {
            context.blockedInKernel = true
            root.blockingObserver?(context, true)
            KernelTrace.blocking?(context, true)
        }
        if lock === root {
            // An L0 queue: M0 stays the condition's mutex; fine locks held
            // above it are given up for the sleep.
            let above = threadLocks.releaseAbove(lock)
            while w.result == nil {
                if !lock.sleep(on: w.cond, deadline: deadline) { break }
            }
            threadLocks.reacquireAll(above)
        } else {
            let saved = threadLocks.releaseAll()
            if !threadLocks.deferred.isEmpty { threadLocks.runDeferredWork() }
            pthread_mutex_lock(lock.mutex)
            while w.result == nil {
                if KernelLock.conditionWait(w.cond, lock.mutex, deadline: deadline) == ETIMEDOUT { break }
            }
            pthread_mutex_unlock(lock.mutex)
            threadLocks.reacquireAll(saved)
        }
        // The queue's lock is held again: its waiters may change.
        if w.result == nil {
            w.result = .timedOut
            storage.remove(w)
        }
        lock.unregister(w)
        if w.wokenAt != 0, w.result == .woken { KernelLock.wakeLatency.add(KernelClock.now() &- w.wokenAt) }
        if let context, context.blockedInKernel {
            context.blockedInKernel = false
            root.blockingObserver?(context, false)
            KernelTrace.blocking?(context, false)
        }
        return w.result!
    }
}
