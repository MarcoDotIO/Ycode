import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#endif

// The port lock split (`specs/simulator/mach-ipc-locking.md` §4.12, C27;
// `YCODE_PORT_LOCK_SPLIT=1`, off by default).
//
// The port lock G guarded every space, port, port set and queued message of
// a system. With the switch on it is a reader-writer lock, and each space
// (`MachIPC`) has a lock of its own:
//
// | Lock | Taken by | Guards, among fine steps |
// |---|---|---|
// | G exclusive | every holder of G as before (`withLock`, waits, snapshots) | everything, as before |
// | G shared | fine steps only (`MachIPC.fineStep`) | nothing by itself: it keeps exclusive holders out |
// | S, one per space | fine steps, under G shared, in increasing space id | the space's names and the ports it receives |
//
// A fine step is a Mach operation that touches only state owned by the
// spaces whose locks it holds: their name tables, the ports whose receive
// right they hold (queue, counters, requests, port sets), and the importance
// count of the process whose space it is. It never blocks, never wakes a
// waiter, never takes another kernel lock, and changes nothing before it has
// checked that all of this holds; otherwise it declines and the trap runs
// under G exclusive, as before. What it cannot do under its locks (EVFILT_MACHPORT
// hooks, L0 work) is deferred work (§4.5) and runs after it lets go.
//
// Exclusive holders exclude fine steps (an exclusive holder that has the mutex
// waits for the shared holders in flight, and new shared acquisitions
// decline while it holds or waits), so state a fine step changes is guarded by G
// exclusive for every other code path and by the space locks among fine
// steps. Fine steps wait only for space locks, which are held by other fine
// steps that wait for nothing but higher space locks: no cycle.

/// The switch and the split's diagnostics.
public enum PortLockSplit {
    /// `YCODE_PORT_LOCK_SPLIT=1`: G becomes a reader-writer lock with space
    /// locks under it (read when a system's port lock is made).
    nonisolated(unsafe) public static var enabled = getenv("YCODE_PORT_LOCK_SPLIT").map { String(cString: $0) == "1" } ?? false

    /// `YCODE_PORT_LOCK_SHARED_SPIN_US` (default 20): how long a fine step
    /// waits for an exclusive holder to finish before it declines.
    nonisolated(unsafe) static var sharedSpinNanoseconds =
        UInt64(max(0, getenv("YCODE_PORT_LOCK_SHARED_SPIN_US").flatMap { Double(String(cString: $0)) } ?? 20) * 1000)

    /// `YCODE_PORT_LOCK_SPLIT_MIN_CLASS` (default 2, class df): a thread
    /// whose host thread runs below this class takes the exclusive path.
    /// A shared holder is not promoted by the exclusive holder that waits
    /// for it (an exclusive holder is, `HostSched.promoteHolders`), so a
    /// preempted background thread would hold every exclusive acquirer.
    nonisolated(unsafe) static var minimumClass =
        getenv("YCODE_PORT_LOCK_SPLIT_MIN_CLASS").flatMap { Int(String(cString: $0)) } ?? SchedClass.default

    /// Why a fine step declined (the trap then ran under G exclusive).
    enum Reason: Int, CaseIterable {
        case lowClass, writer, nested, combined, complex, header, destination, deadPort, kernelObject, hostSpace
        case disposition, nameRequest, reply, importance, replyPush, lookupHold, stats, msg2Options
        case queueLimit, waiters, wouldBlock, message, tooLarge, demandPush, sendWaiters, sendPossible
        case servicing, replyWait, nameTable, noSenders, sendOnce, portSet, retry, notSelf

        var label: String { "\(self)" }
    }

    /// Fine steps served, by kind.
    enum Kind: Int, CaseIterable { case send, receive, keventReceive, deallocate, query, servicing, threadState }

    final class Counter: @unchecked Sendable {
        let value = Atomic<UInt64>(0)
        @inline(__always) func add() { value.wrappingAdd(1, ordering: .relaxed) }
        var load: UInt64 { value.load(ordering: .relaxed) }
    }

    static let declines = Reason.allCases.map { _ in Counter() }
    static let served = Kind.allCases.map { _ in Counter() }
    /// Space-lock acquisitions, contended ones and their wait.
    static let spaceAcquisitions = Counter()
    static let spaceContended = Counter()
    static let spaceWaitNanoseconds = Atomic<UInt64>(0)
    /// Fine steps that took more space locks on top of those held, and
    /// that let go of theirs to take a lower one first.
    static let lockedOnTop = Counter()
    static let relocked = Counter()
    /// Exclusive acquisitions that waited for shared holders, and how long.
    static let drains = Counter()
    static let drainNanoseconds = Atomic<UInt64>(0)

    @inline(__always) static func decline(_ r: Reason) { declines[r.rawValue].add() }
    @inline(__always) static func serve(_ k: Kind) { served[k.rawValue].add() }

    /// One line for the exit report (empty when off).
    public static var report: String {
        guard enabled else { return "" }
        let s = Kind.allCases.map { "\($0) \(served[$0.rawValue].load)" }.joined(separator: ", ")
        let d = Reason.allCases.filter { declines[$0.rawValue].load > 0 }
            .sorted { declines[$0.rawValue].load > declines[$1.rawValue].load }
            .map { "\($0.label) \(declines[$0.rawValue].load)" }.joined(separator: ", ")
        return "port lock split: fine steps \(s); declined \(d); space locks \(spaceAcquisitions.load) acquisitions "
            + "(\(lockedOnTop.load) steps took more on top, \(relocked.load) took them again in order), "
            + "\(spaceContended.load) contended, \(spaceWaitNanoseconds.load(ordering: .relaxed) / 1_000_000) ms waited; "
            + "exclusive holders waited for shared ones \(drains.load) times, \(drainNanoseconds.load(ordering: .relaxed) / 1_000_000) ms"
    }

    /// Stops the process when a fine step changes state of a space whose
    /// lock it does not hold (`YCODE_LOCK_ORDER_CHECK=1`).
    @inline(__always) static func checkOwned(_ space: MachIPC?, _ what: @autoclosure () -> String) {
        guard KernelThreadLocks.checkOrder else { return }
        let tl = KernelThreadLocks.current
        guard tl.sharedPortHold > 0 else { return }
        guard let space, tl.heldSpaces.contains(where: { $0 === space.spaceLock }) else {
            FileHandle.standardError.write(Data(Thread.callStackSymbols.joined(separator: "\n").utf8))
            fatalError("\(what()) changed by a fine port step without its space lock (mach-ipc-locking.md §4.12)")
        }
    }

    /// True while the calling thread runs a fine step.
    static var inFineStep: Bool { KernelThreadLocks.current.sharedPortHold > 0 }
}

/// A space's lock (`mach-ipc-locking.md` §4.12): a mutex, taken only under
/// the port lock held shared, in increasing `order` (the space id).
final class SpaceLock: @unchecked Sendable {
    let mutex: UnsafeMutablePointer<pthread_mutex_t>
    let order: UInt64

    init(order: UInt64) {
        self.order = order
        mutex = .allocate(capacity: 1)
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        #if os(Linux)
        if KernelLock.fineLockSpin { pthread_mutexattr_settype(&attr, Int32(PTHREAD_MUTEX_ADAPTIVE_NP)) }
        #endif
        pthread_mutex_init(mutex, &attr)
        pthread_mutexattr_destroy(&attr)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    @inline(__always) func lock() {
        PortLockSplit.spaceAcquisitions.add()
        if pthread_mutex_trylock(mutex) == 0 { return }
        let start = KernelClock.now()
        var taken = false
        let spin = KernelLock.fineSpinNanoseconds
        if spin > 0 {
            var polls = 0
            while !taken {
                if pthread_mutex_trylock(mutex) == 0 { taken = true; break }
                polls &+= 1
                if polls & 15 == 0, KernelClock.now() &- start >= spin { break }
            }
        }
        if !taken { pthread_mutex_lock(mutex) }
        PortLockSplit.spaceContended.add()
        PortLockSplit.spaceWaitNanoseconds.wrappingAdd(KernelClock.now() &- start, ordering: .relaxed)
    }

    @inline(__always) func unlock() { pthread_mutex_unlock(mutex) }
}

extension KernelLock {
    /// A fine lock's totals (diagnostics, read without its lock).
    public var fineLockTotals: String {
        "port lock held \(totalHeldNanoseconds / 1_000_000) ms, \(acquisitions) acquisitions, "
            + "\(fineContendedCount) contended, \(fineWaitedNanoseconds / 1_000_000) ms waited"
    }

    /// A fine step's shared hold of the port lock: false (nothing held) when
    /// an exclusive holder has it, or waits for it, for longer than the
    /// shared spin.
    func tryAcquireShared() -> Bool {
        var deadline: UInt64 = 0
        while true {
            if writerPending.load(ordering: .sequentiallyConsistent) == 0 {
                sharedReaders.wrappingAdd(1, ordering: .sequentiallyConsistent)
                // Dekker with `drainSharedHolders`: the exclusive holder sets
                // its flag, then reads the count; this side adds itself, then
                // reads the flag. One of the two sees the other.
                if writerPending.load(ordering: .sequentiallyConsistent) == 0 { return true }
                sharedReaders.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            }
            let now = KernelClock.now()
            if deadline == 0 { deadline = now &+ PortLockSplit.sharedSpinNanoseconds }
            if now >= deadline { return false }
        }
    }

    /// Ends a shared hold (its changes are visible to the next exclusive holder).
    @inline(__always) func releaseShared() {
        sharedReaders.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    }

    /// An exclusive holder that has the mutex: marks itself, then waits
    /// until no shared holder is in flight (they hold for microseconds and
    /// wait for nothing but space locks).
    func drainSharedHolders() {
        writerPending.store(1, ordering: .sequentiallyConsistent)
        guard sharedReaders.load(ordering: .sequentiallyConsistent) != 0 else { return }
        let start = KernelClock.now()
        var polls = 0
        while sharedReaders.load(ordering: .sequentiallyConsistent) != 0 {
            polls &+= 1
            if polls > 256 { sched_yield() }
        }
        PortLockSplit.drains.add()
        PortLockSplit.drainNanoseconds.wrappingAdd(KernelClock.now() &- start, ordering: .relaxed)
    }
}

extension MachIPC {
    /// What a fine step's check decided.
    enum FineCheck {
        /// Decline: run the trap under G exclusive.
        case decline(PortLockSplit.Reason)
        /// Go, holding the locks of these spaces (the caller's included).
        case go([MachIPC])
    }

    /// Runs a fine step (`mach-ipc-locking.md` §4.12): G shared, this
    /// space's lock, then `check` (reads only) names the spaces the step
    /// touches; once all of their locks are held (in increasing space id;
    /// taking a lower one means letting go and checking again) `body` runs.
    /// `check` gets whether a space's lock is held: it reads another space's
    /// mutable state only once that space's lock is held (until then only
    /// what changes under G exclusive alone: a port's receiver, whether it
    /// is alive, a kernel object, a special reply port, its port sets), and
    /// answers `.go` with the spaces it needs as soon as one is missing.
    /// Nil when the step declined (nothing changed). Deferred work runs after
    /// the locks are released.
    func fineStep<T>(_ check: (_ held: (MachIPC) -> Bool) -> FineCheck, _ body: () -> T) -> T? {
        guard let g = system.portLock, g.sharesReaders else { return nil }
        let tl = KernelThreadLocks.current
        guard tl.sharedPortHold == 0, !g.isHeldByCurrentThread else {
            PortLockSplit.decline(.nested)
            return nil
        }
        let applied = HostSched.appliedClass()
        if applied >= 0, applied < PortLockSplit.minimumClass {
            PortLockSplit.decline(.lowClass)
            return nil
        }
        guard g.tryAcquireShared() else {
            PortLockSplit.decline(.writer)
            return nil
        }
        tl.sharedPortHold = 1
        var locked: [MachIPC] = [self]
        func take(_ s: MachIPC) {
            // Space locks in strictly increasing space id (§4.12).
            if KernelThreadLocks.checkOrder, let last = tl.heldSpaces.last, last.order >= s.spaceLock.order {
                fatalError("kernel lock order: space lock \(s.spaceLock.order) taken after \(last.order) (mach-ipc-locking.md §4.12)")
            }
            s.spaceLock.lock()
            tl.heldSpaces.append(s.spaceLock)
        }
        func lockAll() {
            for s in locked { take(s) }
        }
        func unlockAll() {
            for s in locked.reversed() { s.spaceLock.unlock() }
            tl.heldSpaces.removeAll()
        }
        lockAll()
        var result: T?
        var attempts = 0
        steps: while true {
            let lockedNow = locked
            switch check({ s in lockedNow.contains { $0 === s } }) {
            case let .decline(reason):
                PortLockSplit.decline(reason)
                break steps
            case let .go(spaces):
                let missing = spaces.filter { s in !locked.contains { $0 === s } }
                if missing.isEmpty {
                    result = body()
                    break steps
                }
                attempts += 1
                if attempts > 2 {
                    PortLockSplit.decline(.retry)
                    break steps
                }
                var unique: [MachIPC] = []
                for s in missing where !unique.contains(where: { $0 === s }) { unique.append(s) }
                let top = locked.map(\.spaceID).max() ?? 0
                if unique.allSatisfy({ $0.spaceID > top }) {
                    // Above every lock held: take them on top, in order.
                    let more = unique.sorted { $0.spaceID < $1.spaceID }
                    for s in more { take(s) }
                    locked += more
                    PortLockSplit.lockedOnTop.add()
                } else {
                    PortLockSplit.relocked.add()
                    unlockAll()
                    locked = (locked + unique).sorted { $0.spaceID < $1.spaceID }
                    lockAll()
                }
            }
        }
        unlockAll()
        tl.sharedPortHold = 0
        g.releaseShared()
        if !tl.deferred.isEmpty { tl.runDeferredWork() }
        return result
    }
}
