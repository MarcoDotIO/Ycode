import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The background band (`YCODE_BG_BAND`; `specs/simulator/scheduling-policy.md`
// §4.9, `boot-profile.md` §19.3, §20).
//
// On the reference a darwin-bg thread runs at priority 4 (MAXPRI_THROTTLE,
// §2.2) and gets no CPU while every CPU is busy with work of a higher
// priority: during a boot dasd's threads stay runnable at priority 4 with no
// CPU for 17–113 s, and run when the boot's burst eases (`boot-profile.md`
// §19.3). Ycode's guest threads are host threads, and the host's weights
// (the cgroup backend's class 0, §4.7) only make a background thread's share
// small, never zero.
//
// The band is a run gate in Ycode itself. Every guest thread is counted as
// runnable by its host class (§4.7: its class raised to its image's send
// push) from the end of a trap until it blocks in the kernel or ends.
// At the end of each trap (outside every kernel lock, before the thread
// returns to guest code) a thread of class bg goes on only when fewer than
// `YCODE_BG_BAND_CPUS` (default: the host's online CPUs) other guest threads
// are runnable; otherwise it waits, first in, first out, until one blocks.
// A waiting thread also leaves when its host class rises (an importance
// boost, an inheritance push, a send push), when its image ends or its gate
// closes (Mach suspension), or after `YCODE_BG_BAND_MAX_MS` (default 60 000;
// 0: no bound), the starvation guard. A thread in a long stretch of guest
// code with no trap is not stopped: the gate acts at trap ends only.

/// The background band's run gate (see the file comment).
public enum BackgroundBand {
    /// `YCODE_BG_BAND`: `1` on (with `YCODE_SCHED_QOS`), `0` off. Set by the
    /// VMM (`ExecHost`) before guest threads run.
    nonisolated(unsafe) public static var enabled = getenv("YCODE_BG_BAND").map { String(cString: $0) == "1" } ?? false
    /// True when the gate is in force (the band and thread classes on).
    @inline(__always) public static var active: Bool { enabled && SchedPolicy.qosEnabled }
    /// `YCODE_BG_BAND_CPUS`: the CPUs the guest's runnable threads may fill
    /// before a background thread waits (default: the host's online CPUs).
    nonisolated(unsafe) public static var cpus: Int = {
        if let v = getenv("YCODE_BG_BAND_CPUS").flatMap({ Int(String(cString: $0)) }), v > 0 { return v }
        return max(1, Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))))
    }()
    /// `YCODE_BG_BAND_BG_CPUS=N` (unset: no limit): at most N background
    /// threads run at once, as Apple silicon runs background work on its
    /// efficiency cores only (the reference Mac has 4 of its 14, `boot-
    /// profile.md` §19.1; Apple's public performance-tuning documentation).
    nonisolated(unsafe) public static var backgroundCPUs: Int = {
        if let v = getenv("YCODE_BG_BAND_BG_CPUS").flatMap({ Int(String(cString: $0)) }), v > 0 { return v }
        return Int.max
    }()
    /// `YCODE_BG_BAND_EASE_MS=N` (default 0: off): a background thread
    /// takes a free place only once the runnable threads above class bg
    /// have stayed below `cpus` for N ms, not at a momentary dip (§4.9: on the
    /// reference a priority-4 thread runs when the boot's CPU burst eases,
    /// `boot-profile.md` §19.3, §22).
    nonisolated(unsafe) public static var easeNanoseconds =
        UInt64(max(0, getenv("YCODE_BG_BAND_EASE_MS").flatMap { Double(String(cString: $0)) } ?? 0) * 1_000_000)
    /// When the runnable threads last filled the CPUs (host monotonic ns).
    static let lastSaturated = Atomic<UInt64>(0)
    /// `YCODE_BG_BAND_MAX_MS` (default 60 000; 0 none): the longest one wait.
    nonisolated(unsafe) public static var maxWaitNanoseconds =
        UInt64(max(0, getenv("YCODE_BG_BAND_MAX_MS").flatMap { Double(String(cString: $0)) } ?? 60_000) * 1_000_000)
    /// How long a waiter sleeps before it checks its exits again (a safety
    /// net: the events that end a wait also wake it).
    nonisolated(unsafe) static var pollNanoseconds: UInt64 = 100_000_000
    /// `YCODE_BG_BAND_TRACE=<program>[,<program>...]`: one line for each
    /// wait of 100 ms or more by a thread of a listed program.
    public static let tracedPrograms: Set<String> = {
        guard let v = getenv("YCODE_BG_BAND_TRACE").map({ String(cString: $0) }) else { return [] }
        return Set(v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }()

    // MARK: Runnable threads

    /// Runnable guest threads, 16 bits per class (class c at bit 16·c).
    static let runnable = Atomic<UInt64>(0)
    @inline(__always) static func unit(_ cls: Int) -> UInt64 { 1 << (16 * UInt64(cls)) }
    /// The number of threads a packed word counts.
    @inline(__always) static func total(_ w: UInt64) -> Int {
        Int(w & 0xFFFF) + Int((w >> 16) & 0xFFFF) + Int((w >> 32) & 0xFFFF) + Int(w >> 48)
    }
    /// The runnable threads above class bg in a packed word: the burst the
    /// ease window waits out (background threads filling the CPUs do not
    /// count, or they would keep each other out).
    @inline(__always) static func aboveBackground(_ w: UInt64) -> Int { total(w) - Int(w & 0xFFFF) }
    /// Runnable threads now, by class (bg, ut, df, ui).
    public static var runnableByClass: [Int] {
        let w = runnable.load(ordering: .relaxed)
        return (0..<SchedClass.count).map { Int((w >> (16 * UInt64($0))) & 0xFFFF) }
    }

    /// The class the calling host thread is counted under, plus one (0: not
    /// counted). Only the thread itself changes it.
    nonisolated(unsafe) static let countedKey: pthread_key_t = {
        var k = pthread_key_t()
        pthread_key_create(&k, nil)
        return k
    }()
    @inline(__always) static func counted() -> Int { Int(bitPattern: pthread_getspecific(countedKey)) - 1 }
    @inline(__always) static func setCounted(_ cls: Int) {
        pthread_setspecific(countedKey, UnsafeRawPointer(bitPattern: cls + 1))
    }

    /// Counts the calling thread as runnable in class `cls`.
    @inline(__always) static func count(_ cls: Int) {
        let old = counted()
        guard old != cls else { return }
        let now = runnable.wrappingAdd(unit(cls), ordering: .sequentiallyConsistent).newValue
        if easeNanoseconds > 0, aboveBackground(now) >= cpus { lastSaturated.store(KernelClock.now(), ordering: .relaxed) }
        setCounted(cls)
        if old >= 0 {
            runnable.wrappingSubtract(unit(old), ordering: .sequentiallyConsistent)
            releaseIfRoom()
        }
    }

    /// The calling host thread stopped being runnable: it blocks in the
    /// kernel, or its guest thread ended (the vCPU pool's run ended).
    @inline(__always) public static func stopped() {
        let old = counted()
        guard old >= 0 else { return }
        setCounted(-1)
        runnable.wrappingSubtract(unit(old), ordering: .sequentiallyConsistent)
        releaseIfRoom()
    }

    // MARK: The gate

    /// One waiting thread.
    final class Waiter {
        let cond: UnsafeMutablePointer<pthread_cond_t>
        unowned let context: ThreadContext
        /// Set (under the band's mutex) when a thread that blocked gave it
        /// its place: it was counted runnable for it.
        var released = false
        /// Set to make it check its exits now (a push, an ending image).
        var poked = false

        init(_ context: ThreadContext) {
            self.context = context
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
    }

    /// The waiters, oldest first, and the mutex that guards them (a leaf:
    /// nothing else is taken under it).
    nonisolated(unsafe) static var waiters: [Waiter] = []
    nonisolated(unsafe) static let mutex: UnsafeMutablePointer<pthread_mutex_t> = {
        let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(m, nil)
        return m
    }()
    /// `waiters.count`, readable without the mutex.
    static let waiterCount = Atomic<Int>(0)

    /// Gives the places of threads that stopped to waiters, oldest first,
    /// while fewer than `cpus` threads are runnable.
    @inline(__always) static func releaseIfRoom() {
        guard waiterCount.load(ordering: .sequentiallyConsistent) > 0,
              total(runnable.load(ordering: .sequentiallyConsistent)) < cpus else { return }
        pthread_mutex_lock(mutex)
        releaseLocked()
        pthread_mutex_unlock(mutex)
    }

    /// `releaseIfRoom` with the mutex held.
    static func releaseLocked() {
        while let w = waiters.first, tryCount() {
            waiters.removeFirst()
            waiterCount.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            w.released = true
            pthread_cond_signal(w.cond)
        }
    }

    /// Wakes `context` if it waits at the gate, to check its exits (its
    /// host class rose). Any lock may be held: the band's mutex is a leaf.
    static func poke(_ context: ThreadContext) {
        guard context.bandWaiting.load(ordering: .acquiring) else { return }
        pthread_mutex_lock(mutex)
        for w in waiters where w.context === context {
            w.poked = true
            pthread_cond_signal(w.cond)
        }
        pthread_mutex_unlock(mutex)
    }

    /// Wakes every waiting thread of `kernel` (a send push, the image ends,
    /// a gate closes).
    static func poke(kernel: DarwinKernel) {
        guard kernel.bandWaiters.load(ordering: .acquiring) > 0 else { return }
        pthread_mutex_lock(mutex)
        for w in waiters where w.context.kernel === kernel {
            w.poked = true
            pthread_cond_signal(w.cond)
        }
        pthread_mutex_unlock(mutex)
    }

    /// The end of a trap that resumes `context` (outside every kernel
    /// lock): counts it by its host class and, for class bg, waits while
    /// the other runnable threads fill the CPUs.
    public static func afterTrap(_ context: ThreadContext, kernel: DarwinKernel) {
        let cls = max(0, min(SchedClass.count - 1, context.hostClass))
        guard cls == SchedClass.background else { count(cls); return }
        // A running background thread is preempted at its trap ends too:
        // it leaves its place and asks again.
        if counted() >= 0 { stopped() }
        if waiterCount.load(ordering: .sequentiallyConsistent) == 0, tryCount() {
            setCounted(SchedClass.background)
            return
        }
        wait(context, kernel: kernel)
    }

    /// Counts one more runnable thread of class bg unless `cpus` threads
    /// already are; false when there was no free place.
    @inline(__always) static func tryCount() -> Bool {
        var w = runnable.load(ordering: .sequentiallyConsistent)
        if easeNanoseconds > 0 {
            let now = KernelClock.now()
            if aboveBackground(w) >= cpus {
                lastSaturated.store(now, ordering: .relaxed)
                return false
            }
            if now &- lastSaturated.load(ordering: .relaxed) < easeNanoseconds { return false }
        }
        while total(w) < cpus, Int(w & 0xFFFF) < backgroundCPUs {
            let (done, now) = runnable.compareExchange(expected: w, desired: w &+ unit(SchedClass.background),
                                                       ordering: .sequentiallyConsistent)
            if done { return true }
            w = now
        }
        return false
    }

    /// Why a wait ended (statistics and trace lines).
    enum Exit: Int { case room, raised, ended, bound }

    static func wait(_ context: ThreadContext, kernel: DarwinKernel) {
        let start = KernelClock.now()
        let w = Waiter(context)
        pthread_mutex_lock(mutex)
        waiters.append(w)
        waiterCount.wrappingAdd(1, ordering: .sequentiallyConsistent)
        // A thread that stopped before the count above found no waiter: the
        // place it left is given out here (oldest waiter first).
        releaseLocked()
        context.bandWaiting.store(true, ordering: .releasing)
        kernel.bandWaiters.wrappingAdd(1, ordering: .relaxed)
        var exit = Exit.room
        while !w.released {
            if context.hostClass > SchedClass.background { exit = .raised; break }
            if kernel.isTerminating || context.gate.isClosed { exit = .ended; break }
            let now = KernelClock.now()
            if maxWaitNanoseconds > 0, now &- start >= maxWaitNanoseconds { exit = .bound; break }
            w.poked = false
            var deadline = now &+ pollNanoseconds
            if maxWaitNanoseconds > 0 { deadline = min(deadline, start &+ maxWaitNanoseconds) }
            if !w.poked { _ = KernelLock.conditionWait(w.cond, mutex, deadline: deadline) }
            releaseLocked()
        }
        if !w.released {
            waiters.removeAll { $0 === w }
            waiterCount.wrappingSubtract(1, ordering: .sequentiallyConsistent)
        }
        context.bandWaiting.store(false, ordering: .releasing)
        kernel.bandWaiters.wrappingSubtract(1, ordering: .relaxed)
        pthread_mutex_unlock(mutex)
        if w.released {
            setCounted(SchedClass.background)
            if exit != .room { exit = .room }
        } else {
            // It goes on without a free place (raised, ending, bound).
            count(exit == .raised ? max(SchedClass.background, min(SchedClass.count - 1, context.hostClass)) : SchedClass.background)
        }
        let waited = KernelClock.now() &- start
        Stats.note(exit, waited)
        if !tracedPrograms.isEmpty, waited >= 100_000_000, let name = kernel.bandTraceName {
            stderrLine("ycode-simd: bg band: \(name) thread \(context.threadID) waited \(waited / 1_000_000) ms (\(exit))"
                       + " at \(String(format: "%.2f", Double(KernelClock.now() &- origin) / 1e9)) s")
        }
    }

    /// The start of the run (trace and sample times).
    nonisolated(unsafe) public static var origin = KernelClock.now()

    static func stderrLine(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    // MARK: Statistics

    enum Stats {
        static let waits = Atomic<Int>(0)
        static let waitNanoseconds = Atomic<UInt64>(0)
        static let longest = Atomic<UInt64>(0)
        static let room = Atomic<Int>(0)
        static let raised = Atomic<Int>(0)
        static let ended = Atomic<Int>(0)
        static let bound = Atomic<Int>(0)

        static func note(_ exit: Exit, _ ns: UInt64) {
            waits.wrappingAdd(1, ordering: .relaxed)
            waitNanoseconds.wrappingAdd(ns, ordering: .relaxed)
            var l = longest.load(ordering: .relaxed)
            while ns > l {
                let (done, now) = longest.compareExchange(expected: l, desired: ns, ordering: .relaxed)
                if done { break }
                l = now
            }
            switch exit {
            case .room: room.wrappingAdd(1, ordering: .relaxed)
            case .raised: raised.wrappingAdd(1, ordering: .relaxed)
            case .ended: ended.wrappingAdd(1, ordering: .relaxed)
            case .bound: bound.wrappingAdd(1, ordering: .relaxed)
            }
        }
    }

    /// The band's part of the scheduling report ("" when off).
    public static var report: String {
        guard active else { return "" }
        return "bg band on \(cpus) CPUs" + (backgroundCPUs == Int.max ? "" : " (background on \(backgroundCPUs))")
            + (easeNanoseconds == 0 ? "" : " (ease \(easeNanoseconds / 1_000_000) ms)") + ": \(Stats.waits.load(ordering: .relaxed)) waits, "
            + "\(Stats.waitNanoseconds.load(ordering: .relaxed) / 1_000_000) ms (longest \(Stats.longest.load(ordering: .relaxed) / 1_000_000) ms; "
            + "ended by room \(Stats.room.load(ordering: .relaxed)), raised \(Stats.raised.load(ordering: .relaxed)), "
            + "image end or suspension \(Stats.ended.load(ordering: .relaxed)), bound \(Stats.bound.load(ordering: .relaxed))); "
            + "now runnable \(runnableByClass.map(String.init).joined(separator: "/")), waiting \(waiterCount.load(ordering: .relaxed))"
    }

    // MARK: Sampling (diagnostics)

    /// `YCODE_BG_BAND_SAMPLE_MS=N`: one line every N ms with the runnable
    /// counts by class and the waiters (started by the VMM).
    public static func startSampler() {
        guard active, let ms = getenv("YCODE_BG_BAND_SAMPLE_MS").flatMap({ UInt32(String(cString: $0)) }), ms > 0 else { return }
        let thread = Thread {
            while true {
                usleep(ms * 1000)
                let t = Double(KernelClock.now() &- origin) / 1e9
                stderrLine("ycode-simd: bg band sample \(String(format: "%.2f", t)) s: runnable "
                           + runnableByClass.map(String.init).joined(separator: "/") + " waiting \(waiterCount.load(ordering: .relaxed))")
            }
        }
        thread.name = "ycode-bg-band-sample"
        thread.start()
    }
}
