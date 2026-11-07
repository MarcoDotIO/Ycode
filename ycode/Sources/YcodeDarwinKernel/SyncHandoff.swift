import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// A direct hand-off for workloop sync wakes (`YCODE_SYNC_HANDOFF=1`, off by
// default; `specs/simulator/boot-profile.md` §16).
//
// libdispatch hands a workloop from one thread to another with a sync wait
// and a sync wake (EVFILT_WORKLOOP, NOTE_WL_SYNC_WAIT / NOTE_WL_SYNC_WAKE).
// On xnu the woken thread runs at once on the waker's processor when the
// waker is about to block. Ycode's waiter is a host thread asleep on a
// condition variable: the futex wake puts it on whatever run queue the host
// picks, and on a saturated host it waits there behind other programs'
// threads while the waker goes on or parks (diagnosticd's threads spent 56 %
// of their time waiting for each other, §14.5).
//
// With the switch on, the waker restricts the woken host thread to the CPU
// the waker runs on before it signals, so the host enqueues it there and its
// wake-up preemption decides between the two; the woken thread gives its
// CPUs back (the process's mask, or its placement side) as soon as its wait
// returns. `YCODE_SYNC_HANDOFF=2` does the same when a thread gives a
// parked workqueue thread of its own image work (diagnosticd's other
// hand-off). The state word keeps the two sides from crossing: the waker pins
// and then marks (0 → 1); the waiter marks (0 → 2) or, finding 1, restores
// itself; a waker that finds 2 (the waiter already returned) restores it.

enum SyncHandoff {
    /// `YCODE_SYNC_HANDOFF`: `1` workloop sync wakes; `2` also a parked
    /// workqueue thread given work by a thread of its own image (the
    /// thread request a sync wait or a workloop enqueue makes). Linux only.
    nonisolated(unsafe) static var level: Int = {
        #if os(Linux)
        return getenv("YCODE_SYNC_HANDOFF").flatMap { Int(String(cString: $0)) } ?? 0
        #else
        return 0
        #endif
    }()
    static var enabled: Bool { level > 0 }
    static var parkWakes: Bool { level >= 2 }

    /// Tests: replaces the affinity calls (tid, nil = restore / CPU).
    nonisolated(unsafe) static var pinHook: ((Int32, Int32?) -> Void)?

    static let handoffs = Atomic<Int>(0)
    static let lateHandoffs = Atomic<Int>(0)
    static let restores = Atomic<Int>(0)
    static let nanoseconds = Atomic<UInt64>(0)

    static let notPinned = 0, pinned = 1, waiterReturned = 2

    /// The calling host thread's Linux id (0 off Linux or when off).
    static func currentTID() -> Int32 {
        guard enabled || pinHook != nil else { return 0 }
        #if os(Linux)
        if let threadID = HostSched.threadID { return Int32(truncatingIfNeeded: threadID()) }
        return glibcGettid?() ?? 0
        #else
        // Tests on macOS (pinHook): the Mach thread port names the thread.
        return Int32(bitPattern: pthread_mach_thread_np(pthread_self()))
        #endif
    }

    /// The process's CPU mask at start, which a woken thread gets back.
    static let processMask: [UInt64] = {
        #if os(Linux)
        typealias GetAffinity = @convention(c) (Int32, Int, UnsafeMutableRawPointer) -> Int32
        var mask = [UInt64](repeating: 0, count: 16)
        if let f = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "sched_getaffinity") {
            let call = unsafeBitCast(f, to: GetAffinity.self)
            if mask.withUnsafeMutableBytes({ call(getpid(), $0.count, $0.baseAddress!) }) == 0 { return mask }
        }
        let online = Int(sysconf(Int32(_SC_NPROCESSORS_ONLN)))
        mask = [UInt64](repeating: 0, count: max(1, (online + 63) / 64))
        for cpu in 0..<online { mask[cpu / 64] |= 1 << UInt64(cpu % 64) }
        return mask
        #else
        return []
        #endif
    }()

    #if os(Linux)
    nonisolated(unsafe) static let glibcGettid: (@convention(c) () -> Int32)? = {
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "gettid") else { return nil }
        return unsafeBitCast(f, to: (@convention(c) () -> Int32).self)
    }()
    nonisolated(unsafe) static let getCPU: (@convention(c) () -> Int32)? = {
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "sched_getcpu") else { return nil }
        return unsafeBitCast(f, to: (@convention(c) () -> Int32).self)
    }()
    #endif

    /// The CPU the calling host thread runs on (-1 unknown).
    static func currentCPU() -> Int32 {
        #if os(Linux)
        return getCPU?() ?? -1
        #else
        return -1
        #endif
    }

    /// One CPU as a mask.
    static func mask(cpu: Int32) -> [UInt64] {
        var m = [UInt64](repeating: 0, count: max(processMask.count, Int(cpu) / 64 + 1))
        m[Int(cpu) / 64] |= 1 << UInt64(cpu % 64)
        return m
    }

    /// Waker side, just before the condition is signalled: the waiting host
    /// thread `tid` may run only on the waker's CPU until its wait returns.
    static func pin(tid: Int32, state: borrowing Atomic<Int>) {
        guard tid > 0, state.load(ordering: .acquiring) == notPinned else { return }
        let cpu = currentCPU()
        guard cpu >= 0 || pinHook != nil else { return }
        let start = KernelClock.now()
        if let pinHook { pinHook(tid, cpu) } else { _ = HostSched.setAffinity(tid, mask(cpu: cpu)) }
        if state.compareExchange(expected: notPinned, desired: pinned, ordering: .acquiringAndReleasing).exchanged {
            handoffs.wrappingAdd(1, ordering: .relaxed)
        } else {
            // The waiter's wait already returned: give its CPUs back.
            restore(tid: tid)
            lateHandoffs.wrappingAdd(1, ordering: .relaxed)
        }
        nanoseconds.wrappingAdd(KernelClock.now() &- start, ordering: .relaxed)
    }

    /// Waiter side, when its wait returns (the calling thread is `tid`).
    static func waitReturned(tid: Int32, state: borrowing Atomic<Int>) {
        guard !state.compareExchange(expected: notPinned, desired: waiterReturned, ordering: .acquiringAndReleasing).exchanged
        else { return }
        restore(tid: tid)
    }

    private static func restore(tid: Int32) {
        restores.wrappingAdd(1, ordering: .relaxed)
        if let pinHook { pinHook(tid, nil); return }
        _ = HostSched.setAffinity(tid, processMask)
        // A placed thread (`YCODE_HOST_SCHED_UI_CPUS`) gets its side again
        // at its next trap end.
        if tid == currentTID() { pthread_setspecific(HostSched.placeKey, nil) }
    }

    /// The end-of-run line ("" when off).
    static var report: String {
        guard enabled else { return "" }
        return "sync hand-offs \(handoffs.load(ordering: .relaxed)) (late \(lateHandoffs.load(ordering: .relaxed)), "
            + "restores \(restores.load(ordering: .relaxed)), \(nanoseconds.load(ordering: .relaxed) / 1_000_000) ms pinning)"
    }
}
