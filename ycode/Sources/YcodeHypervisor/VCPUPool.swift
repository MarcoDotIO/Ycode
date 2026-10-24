// The per-VM vCPU pool: one Darwin thread = one vCPU, each vCPU driven by
// its own host thread running that vCPU's KVM_RUN loop.
// Contracts: specs/simulator/stage4a-contract.md §2 and §4 (threads),
// specs/simulator/stage4b-contract.md §3.4 and §7 (stopping, teardown).
//
// - vCPUs are created lazily, up to min(KVM_CAP_MAX_VCPUS, 64). KVM cannot
//   destroy one vCPU, so a vCPU whose guest thread ended is parked with its
//   host thread and reused for the next thread.
// - Each vCPU owns slot i of the vCPU-slot region (boot info, trap frame, EL1
//   stack). A fresh vCPU enters the shim at its reset entry with x0 = its
//   boot-info block. A parked vCPU stays stopped at the doorbell store of the
//   trap that parked it; it is reused by writing the new thread's complete
//   EL0 state into its frame and resuming, so the shim's ordinary trap return
//   starts the new thread.
// - The pool ends once: when a thread ends the image (exit, a fatal trap, an
//   unexpected VM exit: `.terminate`; exec: `.end`), when the owner stops it
//   (`requestStop`, the kernel's `stopAllThreads`), or when `shouldStop`
//   says so before a vCPU re-enters the guest. Ending sets `immediate_exit`
//   on every vCPU and kicks the running ones out of KVM_RUN with a signal;
//   every host thread then returns from its loop and exits. The last one
//   calls `onFinished`; the owner then joins the threads (`joinThreads`) and
//   may destroy the VM. A pool never starts threads again once it has ended.

import YcodeDarwinABI

/// The vCPU-slot region (stage4a-contract.md §4): 64 slots of 64 KiB at GPA
/// `0x4100_0000`, identity-mapped EL1 RW, UXN, PXN.
public enum VCPUSlots {
    public static let baseGPA: UInt64 = 0x4100_0000
    public static let slotSize: UInt64 = 0x1_0000
    public static let count = 64
    public static let regionSize: UInt64 = slotSize * UInt64(count)
    public static let bootInfoOffset: UInt64 = 0x0000
    public static let frameOffset: UInt64 = 0x4000
    public static let stackOffset: UInt64 = 0x8000

    public static func slotGPA(_ index: Int) -> UInt64 { baseGPA + UInt64(index) * slotSize }
    public static func bootInfoGPA(_ index: Int) -> UInt64 { slotGPA(index) + bootInfoOffset }
    public static func frameGPA(_ index: Int) -> UInt64 { slotGPA(index) + frameOffset }
    public static func stackTop(_ index: Int) -> UInt64 { slotGPA(index) + slotSize }

    /// The identity mapping of the whole region.
    public static let region = VMLayout.Region(name: "vcpu-slots", va: baseGPA, size: regionSize,
                                               attributes: PageAttributes(access: .el1ReadWrite))
}

/// The EL0 register state a new guest thread starts with (on a fresh vCPU
/// only x0…x7 can be nonzero: the shim's boot path loads those and zeroes
/// the rest).
public struct VCPUStartState: Sendable, Equatable, CustomStringConvertible {
    public var pc: UInt64
    public var sp: UInt64
    /// x0…x30. Missing entries are 0.
    public var registers: [UInt64]
    public var tpidrro: UInt64
    public var tpidr: UInt64

    public init(pc: UInt64, sp: UInt64, registers: [UInt64] = [], tpidrro: UInt64 = 0, tpidr: UInt64 = 0) {
        self.pc = pc
        self.sp = sp
        self.registers = registers
        self.tpidrro = tpidrro
        self.tpidr = tpidr
    }

    public var description: String {
        func h(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }
        let used = (registers.lastIndex { $0 != 0 } ?? -1) + 1
        return "pc \(h(pc)) sp \(h(sp)) x0-x\(max(0, used - 1)) [\(registers.prefix(used).map(h).joined(separator: " "))] tpidrro \(h(tpidrro))"
    }
}

#if os(Linux) && arch(arm64)
import CKVM
import Glibc
import Synchronization

public final class VCPUPool: @unchecked Sendable {
    /// What the run loop does after a trap or an unexpected exit.
    public enum Disposition: Sendable {
        /// Write the frame back and resume the thread.
        case resume
        /// The guest thread ended: keep the vCPU stopped and return it to the pool.
        case park
        /// End the image with this status (exit, fatal trap, ...): every vCPU stops.
        case terminate(status: Int32, message: String)
        /// End the image quietly (it was replaced by exec, or it is already
        /// ending): every vCPU stops; not an error.
        case end(message: String)
    }

    /// Why the pool ended.
    public struct Termination: Sendable {
        public enum Kind: Sendable, Equatable {
            /// A thread ended the image (`.terminate`).
            case terminated
            /// A thread ended the image quietly (`.end`).
            case ended
            /// The owner stopped the image (`requestStop`, `shouldStop`, `stopAll`).
            case stopped
        }
        public var kind: Kind
        public var status: Int32
        public var message: String
        /// The vCPU that ended the image, or nil.
        public var vcpuIndex: Int?
    }

    /// One vCPU with its host thread and slot.
    public final class Worker: @unchecked Sendable {
        public let index: Int
        public let vcpu: VCPU
        public var bootInfoGPA: UInt64 { VCPUSlots.bootInfoGPA(index) }
        public var frameGPA: UInt64 { VCPUSlots.frameGPA(index) }
        /// What the owner attached to the current guest thread (for
        /// ycode-simd: the kernel's per-thread context). Set before the
        /// thread first runs; read only on this worker's host thread.
        public internal(set) var context: AnyObject?
        /// The host thread's CPU time (ns) when its current guest thread
        /// started (set on the host thread; per-thread CPU accounting).
        public internal(set) var threadCPUBaseNanoseconds: UInt64 = 0
        /// How many guest threads this vCPU has run.
        public internal(set) var threadCount = 0
        /// The x16 and ELR of the trap being handled (diagnostics).
        public let lastTrapX16 = Atomic<UInt64>(0)
        public let lastTrapELR = Atomic<UInt64>(0)
        /// True while the host thread is inside the trap handler.
        public let inHandler = Atomic<Bool>(false)
        /// Diagnostics: when the current handler call began (monotonic ms),
        /// and the trap frame's kind (svc or a fault) and ESR.
        public let handlerSince = Atomic<UInt64>(0)
        public let lastTrapKind = Atomic<UInt64>(0)
        public let lastTrapESR = Atomic<UInt64>(0)
        /// Diagnostics: the last VM exit (monotonic ms); a sample of the
        /// guest state taken at a diagnostic kick (pc, pstate, ELR_EL1, ESR_EL1).
        public let lastExitMs = Atomic<UInt64>(0)
        public let sampleRequested = Atomic<Bool>(false)
        public let samplePC = Atomic<UInt64>(0)
        public let sampleLR = Atomic<UInt64>(0)
        public let sampleFP = Atomic<UInt64>(0)
        /// The sampled return addresses (written before `sampleCount`
        /// changes, released by it).
        public var sampleStack: [UInt64] = []
        public let samplePSTATE = Atomic<UInt64>(0)
        public let sampleELR1 = Atomic<UInt64>(0)
        public let sampleESR1 = Atomic<UInt64>(0)
        public let sampleCount = Atomic<UInt64>(0)
        /// The host (Linux) thread id of this vCPU's thread.
        public let hostTID = Atomic<UInt64>(0)

        fileprivate unowned let pool: VCPUPool
        /// Profiling (`VCPUPool.profiling`; this worker's host thread only):
        /// wall time inside KVM_RUN and inside the trap handler, and when
        /// the pending thread start was asked for (0: none).
        public fileprivate(set) var runNanoseconds: UInt64 = 0
        public fileprivate(set) var handlerNanoseconds: UInt64 = 0
        fileprivate var startRequestedAt: UInt64 = 0
        /// Profiling: how the pending start found this vCPU.
        fileprivate var startKind = StartKind.parked
        fileprivate var pending: VCPUStartState?
        fileprivate var running = false
        fileprivate var started = false
        fileprivate var hostThread = pthread_t()
        fileprivate var joined = false
        fileprivate let wakeup = HostCondition()

        fileprivate init(index: Int, vcpu: VCPU, pool: VCPUPool) {
            self.index = index
            self.vcpu = vcpu
            self.pool = pool
        }
    }

    public typealias TrapHandler = (Worker, inout TrapFrame) -> Disposition
    public typealias ExitHandler = (Worker, VCPUExit) -> Disposition

    public let vm: VirtualMachine
    /// min(KVM_CAP_MAX_VCPUS, 64): the most vCPUs (and guest threads) this process gets.
    public let capacity: Int
    /// The boot info every fresh vCPU starts from (TTBR0, TCR, MAIR, SCTLR, doorbell).
    public let bootTemplate: BootInfo
    /// Per-vCPU limit on VM exits (0 = none).
    public let maxExitsPerVCPU: Int
    /// The doorbell-trap handler, called on the trapping vCPU's host thread.
    public var trapHandler: TrapHandler = { _, _ in .terminate(status: 71, message: "no trap handler") }
    /// Called for every exit that is not a doorbell write from the vCPU's own frame.
    public var exitHandler: ExitHandler = { _, exit in .terminate(status: 71, message: "unexpected VM exit: \(exit)") }
    /// Checked (without any lock) before a vCPU enters the guest; true ends
    /// the pool (stage 4b: the kernel's `isTerminating`).
    public var shouldStop: () -> Bool = { false }
    /// Called when the pool ends and whenever a stronger reason replaces a
    /// `.stopped` one (a thread's exit status after a kick), with the
    /// recorded termination. Any host thread; no pool lock is held (the
    /// kernel lock may be).
    public var onEnd: (Termination) -> Void = { _ in }
    /// Called once, on the last host thread of the pool, after the pool ended
    /// and every other host thread returned. The vCPUs and the VM are no
    /// longer used by the pool. No lock is held.
    public var onFinished: () -> Void = {}
    /// Guest-physical ranges (besides the vCPU's own slot) to clean to the
    /// point of coherency before a fresh vCPU starts with its MMU off: the
    /// shim image and the page tables.
    public var preBootCleanRanges: () -> [(gpa: UInt64, count: Int)] = { [] }
    /// Diagnostics (the boot profile's PC samples): reads the return
    /// addresses of the frame-pointer chain from a frame pointer, on the
    /// sampled vCPU's own thread while its guest is stopped.
    public var sampleStackReader: ((UInt64) -> [UInt64])?
    /// Diagnostics (one line each).
    public var log: (String) -> Void = { _ in }

    /// The signal that kicks a vCPU host thread out of KVM_RUN.
    public static let kickSignal = SIGUSR2
    /// Diagnostics (`YCODE_DEBUG_NO_KICK=1`): never signal a vCPU thread;
    /// `immediate_exit` alone ends its next KVM_RUN.
    /// `resumeFlags` bit 1: the shim reads FPCR before it resumes the guest,
    /// so each run that returns from a trap uses FP/SIMD once and the host
    /// kernel switches FP/SIMD state to the vCPU. On Linux KVM hosts without
    /// upstream commit fbc7e61195e2 ("KVM: arm64: Unconditionally save+flush
    /// host FPSIMD/SVE/SME state"), a run in which the guest never touches
    /// FP leaves the VMM thread able to use SVE while the kernel tracks its
    /// state as FPSIMD-only, and its SVE predicates are lost at the next
    /// context switch (lost writes in glibc's SVE memcpy). On by default;
    /// `YCODE_SHIM_FP_TOUCH=0` turns it off. See also Sources/CKVM/hostcopy.c.
    static let resumeFPTouch: UInt64 = 1 << 1
    /// `YCODE_TRAP_FRAME_COPY=1`: decode and encode the trap frame through
    /// byte arrays (the old path; frame-profile.md §7 item 6).
    static let trapFrameCopy = getenv("YCODE_TRAP_FRAME_COPY").map { String(cString: $0) == "1" } ?? false
    static let shimFPTouch = getenv("YCODE_SHIM_FP_TOUCH").map { String(cString: $0) != "0" } ?? true

    /// `YCODE_KICK_ONLY_IN_RUN=1`: the kick signal is blocked on vCPU
    /// threads except inside KVM_RUN (see `ckvm_kick_mask_outside_run`).
    static let kickOnlyInRun = getenv("YCODE_KICK_ONLY_IN_RUN").map { String(cString: $0) == "1" } ?? false
    static let debugNoKick = getenv("YCODE_DEBUG_NO_KICK").map { String(cString: $0) == "1" } ?? false

    private let lock = HostMutex(name: "vCPU pool")
    private let terminated = HostCondition()
    private var workers: [Worker] = []
    private var idle: [Worker] = []
    /// The index of the next vCPU (and its KVM vCPU id). Assigned when a
    /// start reserves a new vCPU, so a creation finished later keeps it.
    private var nextIndex = 0
    /// vCPUs whose creation (on a `VCPUCreator` thread) has not finished.
    /// Each counts as a live host thread; a claimed one also as an active
    /// thread.
    private var creating = 0
    /// Creations made ahead (`warmTarget`) that no thread start has claimed
    /// yet, oldest first.
    private var warming: [InFlight] = []
    private var termination: Termination?
    /// Set once; read without the lock by the run loops.
    private let ending = Atomic<Bool>(false)
    /// `stopAll`: stopped threads record where they were.
    private var reportStops = false
    private var stopReports: [Int: String] = [:]
    private var activeThreads = 0
    /// Host threads created and not yet returned.
    private var liveHostThreads = 0
    private var finished = false
    /// The most threads alive at once (statistics).
    public private(set) var peakThreads = 0
    /// Every host thread the pool created (statistics).
    public private(set) var hostThreadsCreated = 0

    // MARK: Profiling (diagnostics)

    /// `YCODE_BOOT_PROFILE` (set by the VMM before the first pool): every
    /// vCPU host thread times its KVM_RUN and trap-handler calls and, when it
    /// returns, adds its host counters to `hostStats`.
    nonisolated(unsafe) public static var profiling = false

    /// The host cost of a pool's vCPU threads (summed over threads that
    /// returned). CPU times from the host kernel's per-thread accounting:
    /// `guest` is time in guest mode (part of `user`), `system` is host
    /// kernel time (KVM exits handled in the kernel: stage-2 faults, ...;
    /// the VMM's system calls), `user − guest` is the VMM's own code.
    public struct HostStats: Sendable {
        public var threads = 0
        public var userTicks: UInt64 = 0
        public var systemTicks: UInt64 = 0
        public var guestTicks: UInt64 = 0
        public var minorFaults: UInt64 = 0
        public var majorFaults: UInt64 = 0
        /// Scheduler CPU time and run-queue wait (ns, /proc schedstat).
        public var cpuNanoseconds: UInt64 = 0
        public var runQueueNanoseconds: UInt64 = 0
        /// Wall time inside KVM_RUN and inside the trap handler.
        public var runNanoseconds: UInt64 = 0
        public var handlerNanoseconds: UInt64 = 0
        /// VM exits to user space, and all exits counted by KVM (KVM's
        /// "exits" statistic: user-space exits plus those KVM handled itself,
        /// such as stage-2 faults and interrupts), WFI/WFE exits.
        public var userExits: UInt64 = 0
        public var kvmExits: UInt64 = 0
        public var wfxExits: UInt64 = 0
        /// Thread starts, and the time from the start request to the
        /// thread's first instruction (vCPU creation for a new vCPU, the
        /// wakeup for a parked one).
        public var starts: UInt64 = 0
        public var startWaitNanoseconds: UInt64 = 0
        public var maxStartWaitNanoseconds: UInt64 = 0

        public init() {}

        public mutating func add(_ o: HostStats) {
            threads += o.threads
            userTicks &+= o.userTicks; systemTicks &+= o.systemTicks; guestTicks &+= o.guestTicks
            minorFaults &+= o.minorFaults; majorFaults &+= o.majorFaults
            cpuNanoseconds &+= o.cpuNanoseconds; runQueueNanoseconds &+= o.runQueueNanoseconds
            runNanoseconds &+= o.runNanoseconds; handlerNanoseconds &+= o.handlerNanoseconds
            userExits &+= o.userExits; kvmExits &+= o.kvmExits; wfxExits &+= o.wfxExits
            starts &+= o.starts; startWaitNanoseconds &+= o.startWaitNanoseconds
            maxStartWaitNanoseconds = max(maxStartWaitNanoseconds, o.maxStartWaitNanoseconds)
        }
    }
    private var stats = HostStats()
    /// The counters of the pool's returned host threads.
    public var hostStats: HostStats { lock.withLock { stats } }
    /// When a vCPU of the pool first entered the guest (monotonic ns; 0: never).
    public let firstRunNanoseconds = Atomic<UInt64>(0)
    /// Diagnostics (the boot profile's guest-PC sampler): kicks every vCPU
    /// that runs guest code so that it records its PC (`samplePC`,
    /// `sampleCount`); returns those workers.
    public func kickForPCSamples() -> [Worker] {
        let list = lock.withLock { workers.filter { $0.running && $0.context != nil } }
        var kicked: [Worker] = []
        for w in list where !w.inHandler.load(ordering: .relaxed) {
            w.sampleRequested.store(true, ordering: .relaxed)
            _ = ckvm_kick_thread(UInt(w.hostThread), Self.kickSignal)
            kicked.append(w)
        }
        return kicked
    }

    /// The host thread ids of the pool's live vCPU threads (the sampler).
    public var hostThreadIDs: [Int] {
        lock.withLock { workers.map { Int($0.hostTID.load(ordering: .relaxed)) }.filter { $0 != 0 } }
    }

    private static let kvmStatNames = ["exits", "wfe_exit_stat", "wfi_exit_stat"]

    /// Adds the calling vCPU host thread's counters (its end; profiling only).
    private func recordThreadEnd(_ worker: Worker) {
        var t = [UInt64](repeating: 0, count: 8)
        _ = ckvm_task_stats(ckvm_gettid(), &t)
        var k = [UInt64](repeating: 0, count: Self.kvmStatNames.count)
        let names = Self.kvmStatNames.map { strdup($0) }
        defer { names.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = names.map { UnsafePointer($0) }
        _ = ckvm_vcpu_stats(worker.vcpu.fd, &pointers, Int32(k.count), &k)
        var s = HostStats()
        s.threads = 1
        s.userTicks = t[0]; s.systemTicks = t[1]; s.guestTicks = t[2]
        s.minorFaults = t[3]; s.majorFaults = t[4]
        s.cpuNanoseconds = t[5]; s.runQueueNanoseconds = t[6]
        s.runNanoseconds = worker.runNanoseconds; s.handlerNanoseconds = worker.handlerNanoseconds
        s.userExits = UInt64(worker.vcpu.exitCount); s.kvmExits = k[0]; s.wfxExits = k[1] &+ k[2]
        lock.withLock { stats.add(s) }
    }

    /// A thread start reached its first instruction (profiling only).
    private func noteStarted(_ worker: Worker) {
        guard worker.startRequestedAt != 0 else { return }
        let waited = monotonicNanoseconds() &- worker.startRequestedAt
        worker.startRequestedAt = 0
        Self.startLatency[worker.startKind.rawValue].add(waited)
        lock.withLock {
            stats.starts &+= 1
            stats.startWaitNanoseconds &+= waited
            stats.maxStartWaitNanoseconds = max(stats.maxStartWaitNanoseconds, waited)
        }
    }

    public init(vm: VirtualMachine, bootTemplate: BootInfo, limit: Int = VCPUSlots.count, maxExitsPerVCPU: Int = 0) throws {
        self.vm = vm
        self.capacity = max(1, min(vm.maxVCPUs, limit, VCPUSlots.count))
        vm.vcpuIDLimit = capacity
        self.bootTemplate = bootTemplate
        self.maxExitsPerVCPU = maxExitsPerVCPU
        try kvmCheck(ckvm_kick_install(Self.kickSignal), "sigaction (vCPU kick signal)")
    }

    /// SNAPSHOT hook (agent SNAP, specs/simulator/snapshot.md §3.1): every
    /// worker created so far, and how many vCPU creations are still pending.
    public var snapshotWorkers: (workers: [Worker], pendingCreations: Int) { lock.withLock { (workers, creating) } }

    /// The number of vCPUs created so far.
    public var vcpuCount: Int { lock.withLock { workers.count } }
    /// The number of created vCPUs with no guest thread.
    public var parkedCount: Int { lock.withLock { idle.count } }
    /// Diagnostics: the guest-thread contexts of the created vCPUs (nil for
    /// one without a thread), and the counts behind `hasRoom`.
    public var debugState: (contexts: [AnyObject?], creating: Int, warming: Int, nextIndex: Int, active: Int) {
        lock.withLock { (workers.map(\.context), creating, warming.count, nextIndex, activeThreads) }
    }
    /// The termination, once the pool has ended.
    public var currentTermination: Termination? { lock.withLock { termination } }
    /// True once the pool has ended (threads may still be returning).
    public var isEnding: Bool { ending.load(ordering: .acquiring) }
    /// True once the pool has ended and every host thread returned.
    public var isFinished: Bool { lock.withLock { finished || (ending.load(ordering: .relaxed) && liveHostThreads == 0) } }
    /// Host threads that have not returned yet.
    public var liveHostThreadCount: Int { lock.withLock { liveHostThreads } }
    /// The total VM exits of every vCPU.
    public var exitCount: Int { lock.withLock { workers.reduce(0) { $0 + $1.vcpu.exitCount } } }

    /// Creates the next vCPU and its host thread without starting a guest
    /// thread on it (it is parked until `start`). Lets the VMM read vCPU
    /// state (the counter, its frequency) before the first thread runs.
    public func createWorker() throws -> Worker {
        var warm: [InFlight] = []
        let worker: Worker = try lock.withLock {
            guard !ending.load(ordering: .relaxed) else { throw KVMError("vCPU pool", detail: "the pool has ended") }
            guard nextIndex < capacity else { throw KVMError("vCPU pool", detail: "all \(capacity) vCPUs exist") }
            let worker = try makeWorkerLocked()
            idle.insert(worker, at: 0)
            // Warm vCPUs for the threads after the first (thread-latency.md §3).
            warm = refillLocked(extra: idle.count)
            return worker
        }
        submit(warm)
        return worker
    }

    /// Creates the next vCPU and its host thread inline (pool lock held).
    private func makeWorkerLocked() throws -> Worker {
        let vcpu = try vm.makeVCPU(id: nextIndex)
        let worker = Worker(index: nextIndex, vcpu: vcpu, pool: self)
        try spawn(worker)
        nextIndex += 1
        workers.append(worker)
        return worker
    }

    // MARK: Starting threads

    /// Starts a guest thread on a parked vCPU, or on a new vCPU when none is
    /// parked, and returns the vCPU's index. Returns nil when the pool is
    /// exhausted or has ended (EAGAIN for the caller). `context` is attached
    /// to the worker before the thread runs. Safe to call from any host
    /// thread, including from inside a trap handler (with the kernel lock
    /// held).
    ///
    /// A new vCPU is not created here: the start reserves its index and
    /// hands the creation (KVM_CREATE_VCPU, KVM_ARM_VCPU_INIT, the kvm_run
    /// mapping, the host thread: milliseconds under load) to a
    /// `VCPUCreator` thread, so a caller that holds the kernel lock never
    /// waits for it. The thread runs as soon as its vCPU exists. A creation
    /// that fails ends the pool (status 1), as any vCPU failure does.
    /// `YCODE_VCPU_CREATORS=0` creates inline, as before.
    @discardableResult
    public func start(_ state: VCPUStartState, context: AnyObject?) throws -> Int? {
        var toSubmit: [InFlight] = []
        let index: Int? = try lock.withLock {
            if ending.load(ordering: .relaxed) { return nil }
            let requestedAt = Self.profiling ? monotonicNanoseconds() : 0
            if !idle.isEmpty {
                // Prefer the lowest-numbered idle vCPU (vCPU 0 for the main thread).
                let i = idle.indices.min { idle[$0].index < idle[$1].index }!
                let worker = idle.remove(at: i)
                worker.startKind = worker.threadCount > 0 ? .parked : worker.index == 0 ? .main : .warm
                activateLocked(worker, state, context: context)
                toSubmit = refillLocked()
                return worker.index
            }
            if !warming.isEmpty {
                // A creation made ahead is still running: the thread takes
                // it and runs as soon as its vCPU exists.
                let f = warming.removeFirst()
                f.claim = Claim(state: state, context: context, requestedAt: requestedAt, kind: .claimedWarm)
                f.urgent.store(true, ordering: .relaxed)
                activeThreads += 1
                peakThreads = max(peakThreads, activeThreads)
                toSubmit = refillLocked()
                return f.index
            }
            guard nextIndex < capacity else { return nil }
            guard VCPUCreator.shared != nil else {
                let worker = try makeWorkerLocked()
                worker.startKind = .created
                activateLocked(worker, state, context: context)
                return worker.index
            }
            // Reserve: the index, a live host thread (the pool cannot finish
            // before the creation ends), and an active thread.
            let f = newCreationLocked()
            f.claim = Claim(state: state, context: context, requestedAt: requestedAt, kind: .created)
            f.urgent.store(true, ordering: .relaxed)
            activeThreads += 1
            peakThreads = max(peakThreads, activeThreads)
            toSubmit = [f] + refillLocked()
            return f.index
        }
        // Handed over after the pool lock is released (the creator's queue
        // lock is a leaf).
        submit(toSubmit)
        return index
    }

    /// Gives `worker` (parked, not running) its next guest thread. Pool lock held.
    private func activateLocked(_ worker: Worker, _ state: VCPUStartState, context: AnyObject?) {
        worker.context = context
        worker.pending = state
        worker.threadCount += 1
        if Self.profiling { worker.startRequestedAt = max(1, monotonicNanoseconds()) }
        activeThreads += 1
        peakThreads = max(peakThreads, activeThreads)
        worker.wakeup.signal()
    }

    /// True when `start` would find a vCPU now (an idle one, or room for a new one).
    public var hasRoom: Bool {
        lock.withLock { !ending.load(ordering: .relaxed) && (!idle.isEmpty || !warming.isEmpty || nextIndex < capacity) }
    }

    // MARK: Deferred creation

    /// How a thread start found its vCPU (profiling).
    public enum StartKind: Int, Sendable, CaseIterable {
        /// A parked vCPU whose host thread had run a thread before.
        case parked
        /// A vCPU made ahead whose host thread was waiting (`warmTarget`).
        case warm
        /// A creation made ahead that had not finished yet.
        case claimedWarm
        /// A new vCPU created for this start.
        case created
        /// vCPU 0's first thread (the main thread; its vCPU is made with the image).
        case main
    }

    /// Process-wide start-latency distributions by `StartKind`
    /// (profiling): from the start request to the thread's first
    /// instruction being handed to its vCPU.
    public static let startLatency: [LatencyHistogram] = StartKind.allCases.map { LatencyHistogram("start.\($0)") }
    /// The phases of a creation on a `VCPUCreator` thread (profiling):
    /// queue wait, KVM_CREATE_VCPU, KVM_ARM_VCPU_INIT + kvm_run mapping
    /// (both 0 for a vCPU made ahead by a batch), pthread_create.
    public static let creationPhases: [LatencyHistogram] = ["queue", "create_vcpu", "vcpu_init", "pthread"].map { LatencyHistogram("creation.\($0)") }

    /// A thread start waiting for a vCPU being created.
    final class Claim {
        let state: VCPUStartState
        let context: AnyObject?
        /// Profiling: when the start was asked for (monotonic ns; 0 = not profiled).
        let requestedAt: UInt64
        let kind: StartKind
        init(state: VCPUStartState, context: AnyObject?, requestedAt: UInt64, kind: StartKind) {
            self.state = state
            self.context = context
            self.requestedAt = requestedAt
            self.kind = kind
        }
    }

    /// One vCPU creation handed to a `VCPUCreator` thread. `claim` (pool
    /// lock) is the thread that runs on it, or nil for a creation made
    /// ahead that no start has taken yet (its vCPU is then parked).
    final class InFlight: @unchecked Sendable {
        let index: Int
        var claim: Claim?
        /// Profiling: when it was queued.
        var queuedAt: UInt64 = 0
        /// Set when a start claims it: the creator threads take it first.
        let urgent = Atomic<Bool>(false)
        init(index: Int) { self.index = index }
    }

    /// `YCODE_VCPU_WARM=<n>` (thread-latency.md §3): each pool keeps up to
    /// `n` vCPUs with their host threads created ahead and parked, beyond
    /// the threads running, so a thread start finds one ready instead of
    /// waiting for KVM_CREATE_VCPU and pthread_create. 0 turns it off.
    public static let warmTarget = getenv("YCODE_VCPU_WARM").flatMap { Int(String(cString: $0)) }.map { max(0, min($0, 16)) } ?? 0

    /// Reserves the next index for a creation. Pool lock held.
    private func newCreationLocked() -> InFlight {
        let f = InFlight(index: nextIndex)
        nextIndex += 1
        creating += 1
        liveHostThreads += 1
        return f
    }

    /// The creations needed to bring the ready vCPUs (idle, plus made ahead
    /// and unclaimed) back to `warmTarget + extra`. Pool lock held; the
    /// caller submits them after releasing it.
    private func refillLocked(extra: Int = 0) -> [InFlight] {
        guard Self.warmTarget > 0, VCPUCreator.shared != nil, !ending.load(ordering: .relaxed) else { return [] }
        var out: [InFlight] = []
        while idle.count + warming.count < Self.warmTarget + extra, nextIndex < capacity {
            let f = newCreationLocked()
            warming.append(f)
            out.append(f)
        }
        return out
    }

    private func submit(_ creations: [InFlight]) {
        guard !creations.isEmpty, let creator = VCPUCreator.shared else { return }
        for f in creations {
            if Self.profiling { f.queuedAt = monotonicNanoseconds() }
            creator.submit(self, f)
        }
    }

    /// Statistics (process-wide): vCPUs created off the kernel lock, and
    /// their total creation time.
    public static let deferredCreations = Atomic<UInt64>(0)
    public static let deferredCreationNanoseconds = Atomic<UInt64>(0)
    /// Their phases: KVM_CREATE_VCPU, KVM_ARM_VCPU_INIT (+ the kvm_run
    /// mapping), and pthread_create of the vCPU's host thread.
    public static let deferredCreateVCPUNanoseconds = Atomic<UInt64>(0)
    public static let deferredInitNanoseconds = Atomic<UInt64>(0)
    public static let deferredThreadNanoseconds = Atomic<UInt64>(0)

    /// Runs on a `VCPUCreator` thread, with no lock held: creates the vCPU
    /// and starts its host thread, then gives it the claiming thread start
    /// or parks it. When the pool ended meanwhile, or the creation fails,
    /// the creation is dropped (a failure of a claimed one ends the pool).
    fileprivate func createReserved(_ f: InFlight) {
        var failure: Error?
        var worker: Worker?
        if !ending.load(ordering: .acquiring) {
            let began = monotonicNanoseconds()
            if Self.profiling, f.queuedAt != 0 { Self.creationPhases[0].add(began &- f.queuedAt) }
            do {
                // Both system calls run without the pool lock. The new host
                // thread waits for the pool lock and its pending state.
                let created = Worker(index: f.index, vcpu: try vm.makeVCPU(id: f.index), pool: self)
                let threadBegan = monotonicNanoseconds()
                try startHostThread(created)
                Self.deferredThreadNanoseconds.wrappingAdd(monotonicNanoseconds() &- threadBegan, ordering: .relaxed)
                if Self.profiling { Self.creationPhases[3].add(monotonicNanoseconds() &- threadBegan) }
                worker = created
            } catch {
                failure = error
            }
            Self.deferredCreations.wrappingAdd(1, ordering: .relaxed)
            Self.deferredCreationNanoseconds.wrappingAdd(monotonicNanoseconds() &- began, ordering: .relaxed)
        }
        lock.lock()
        creating -= 1
        if let i = warming.firstIndex(where: { $0 === f }) { warming.remove(at: i) }
        let claim = f.claim
        if let worker {
            // The host thread exists and is counted live (by the
            // reservation); `joinThreads` joins it even if the pool ended.
            workers.append(worker)
            hostThreadsCreated += 1
            var parkedNow = false
            if ending.load(ordering: .relaxed) {
                // It sees the end and returns without running a thread.
                if claim != nil { activeThreads -= 1 }
            } else if let claim {
                worker.context = claim.context
                worker.pending = claim.state
                worker.threadCount = 1
                worker.startRequestedAt = claim.requestedAt
                worker.startKind = claim.kind
            } else {
                // Made ahead and not claimed: parked until a start takes it.
                idle.append(worker)
                parkedNow = true
            }
            worker.wakeup.signal()
            let parked = parkedNow ? parkedHandler : nil
            lock.unlock()
            parked?()
            return
        }
        lock.unlock()
        // No host thread. A failure of a claimed creation ends the pool;
        // then the reservation's counts go, which may make this the pool's
        // last host thread. (A vCPU created without a thread closes with
        // the VM.)
        if let failure {
            log("vCPU \(f.index): cannot create: \(failure)")
            if claim != nil {
                terminate(status: 1, message: "vCPU \(f.index): cannot create: \(failure)", vcpuIndex: f.index)
            }
        }
        lock.lock()
        if claim != nil { activeThreads -= 1 }
        hostThreadReturnedLocked()
    }

    /// Called on a vCPU's host thread (no lock held) each time a thread ends
    /// and its vCPU returns to the idle list.
    public var onParked: (() -> Void)? {
        get { lock.withLock { parkedHandler } }
        set { lock.withLock { parkedHandler = newValue } }
    }
    private var parkedHandler: (() -> Void)?

    /// Diagnostics: `YCODE_DEBUG_STACK_GUARD_MB=N` puts an N MiB guard below
    /// each vCPU thread's stack (default: one page).
    static let debugStackGuardMB = getenv("YCODE_DEBUG_STACK_GUARD_MB").flatMap { Int(String(cString: $0)) }.flatMap { $0 > 0 ? $0 : nil }

    /// Starts `worker`'s host thread and counts it. Pool lock held.
    private func spawn(_ worker: Worker) throws {
        try startHostThread(worker)
        liveHostThreads += 1
        hostThreadsCreated += 1
    }

    /// Creates `worker`'s host thread (with or without the pool lock; the
    /// thread's first step takes it).
    private func startHostThread(_ worker: Worker) throws {
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setstacksize(&attributes, 16 << 20)
        if let mb = Self.debugStackGuardMB { pthread_attr_setguardsize(&attributes, mb << 20) }
        let box = Unmanaged.passRetained(worker).toOpaque()
        let result = pthread_create(&worker.hostThread, &attributes, { argument in
            let worker = Unmanaged<VCPUPool.Worker>.fromOpaque(argument!).takeRetainedValue()
            worker.pool.threadMain(worker)
            return nil
        }, box)
        if result != 0 {
            Unmanaged<Worker>.fromOpaque(box).release()
            throw KVMError("pthread_create (vCPU \(worker.index))", errno: result)
        }
    }

    /// A host thread returned, or a reservation was dropped (the pool has
    /// ended). The last one marks the pool finished and calls `onFinished`.
    /// Call with the pool lock held; returns with it released.
    private func hostThreadReturnedLocked() {
        liveHostThreads -= 1
        let last = liveHostThreads == 0
        if last { finished = true }
        terminated.broadcast()
        lock.unlock()
        if last { onFinished() }
    }

    // MARK: The host thread of one vCPU

    private enum RunEnd { case parked, ended }

    private func threadMain(_ worker: Worker) {
        worker.hostTID.store(UInt64(ckvm_gettid()), ordering: .relaxed)
        PostTrapWork.setCurrentVM(vm)
        if Self.kickOnlyInRun {
            let r = ckvm_kick_mask_outside_run(worker.vcpu.fd, Self.kickSignal)
            if r != 0 { var t = "ycode-simd: KVM_SET_SIGNAL_MASK failed (\(r))\n"; _ = t.withUTF8 { write(2, $0.baseAddress, $0.count) } }
        }
        while true {
            lock.lock()
            while worker.pending == nil && !ending.load(ordering: .relaxed) { worker.wakeup.wait(lock) }
            if ending.load(ordering: .relaxed) {
                if worker.pending != nil {
                    // Started but never ran: drop it.
                    worker.pending = nil
                    activeThreads -= 1
                }
                lock.unlock()
                break
            }
            let state = worker.pending!
            worker.pending = nil
            worker.running = true
            lock.unlock()
            worker.threadCPUBaseNanoseconds = hostThreadCPUNanoseconds()
            if Self.profiling { noteStarted(worker) }

            var end = RunEnd.ended
            do {
                try begin(worker, state)
                end = try runLoop(worker)
            } catch {
                terminate(status: 1, message: "vCPU \(worker.index): \(error)", vcpuIndex: worker.index)
            }

            lock.lock()
            worker.running = false
            worker.context = nil
            activeThreads -= 1
            if case .parked = end, !ending.load(ordering: .relaxed) {
                idle.append(worker)
                let parked = parkedHandler
                lock.unlock()
                parked?()
                continue
            }
            lock.unlock()
            break
        }
        // The pool has ended: this host thread returns.
        if Self.profiling { recordThreadEnd(worker) }
        lock.lock()
        worker.context = nil
        hostThreadReturnedLocked()
    }

    /// The guest's CPU count (`GuestCPUs`; set by the VMM before the first
    /// image). A thread's TPIDR_EL0, which Darwin user code reads as its CPU
    /// number, is its vCPU index modulo this count, so every CPU number the
    /// guest sees is below the CPU count it is told.
    nonisolated(unsafe) public static var guestCPUCount = 1

    /// The CPU number (TPIDR_EL0) of a thread on `worker`: the state's own
    /// when it has one, else the vCPU index modulo the guest CPU count.
    private func cpuNumber(_ worker: Worker, _ state: VCPUStartState) -> UInt64 {
        state.tpidr != 0 ? state.tpidr : UInt64(worker.index % max(1, Self.guestCPUCount))
    }

    /// Puts the new thread's state into the vCPU.
    private func begin(_ worker: Worker, _ state: VCPUStartState) throws {
        if !worker.started {
            // A fresh vCPU: the shim's reset entry with this slot's boot info.
            worker.started = true
            var info = bootTemplate
            info.el0EntryPC = state.pc
            info.el0InitialSP = state.sp
            info.trapFrameAddress = worker.frameGPA
            info.tpidrroEL0 = state.tpidrro
            info.tpidrEL0 = cpuNumber(worker, state)
            if state.registers.dropFirst(8).contains(where: { $0 != 0 }) {
                throw KVMError("vCPU \(worker.index) start", detail: "a fresh vCPU can start only with x0-x7 set: \(state)")
            }
            info.el0Registers = Array(state.registers.prefix(8))
            info.el1StackTop = VCPUSlots.stackTop(worker.index)
            try vm.zero(gpa: worker.frameGPA, count: TrapFrame.byteCount)
            try vm.write(gpa: worker.bootInfoGPA, bytes: info.encoded())
            // The shim reads the boot info with its MMU off (non-cacheable):
            // push the VMM's cacheable writes to the point of coherency.
            try vm.cleanDataCache(gpa: worker.bootInfoGPA, count: Int(VCPUSlots.stackOffset))
            for range in preBootCleanRanges() { try vm.cleanDataCache(gpa: range.gpa, count: range.count) }
            try worker.vcpu.set(.pc, VMLayout.shimEntryGPA)
            try worker.vcpu.set(.pstate, VMLayout.el1BootPSTATE)
            try worker.vcpu.set(.x(0), worker.bootInfoGPA)
            log("vCPU \(worker.index): first thread, \(state)")
        } else {
            // A parked vCPU, stopped at its doorbell store: the shim's trap
            // return restores this frame and enters the new thread.
            var frame = TrapFrame()
            for (i, value) in state.registers.prefix(TrapFrame.registerCount).enumerated() { frame.x[i] = value }
            frame.spEL0 = state.sp
            frame.elr = state.pc
            frame.spsr = VMLayout.el0InitialSPSR
            frame.tpidrro = state.tpidrro
            frame.tpidr = cpuNumber(worker, state)
            frame.flushTLB = true
            if Self.shimFPTouch { frame.resumeFlags |= Self.resumeFPTouch }
            try vm.write(gpa: worker.frameGPA, bytes: frame.encoded())
            log("vCPU \(worker.index): thread #\(worker.threadCount), \(state)")
        }
    }

    /// Runs the vCPU until its guest thread ends (`.parked`) or the pool ends (`.ended`).
    private func runLoop(_ worker: Worker) throws -> RunEnd {
        let vcpu = worker.vcpu
        while true {
            if ending.load(ordering: .acquiring) {
                acknowledgeStop(worker, .interrupted)
                return .ended
            }
            if shouldStop() {
                endPool(Termination(kind: .stopped, status: 0, message: "stopped", vcpuIndex: nil))
                return .ended
            }
            if maxExitsPerVCPU > 0, vcpu.exitCount >= maxExitsPerVCPU {
                terminate(status: 71, message: "vCPU \(worker.index) exceeded \(maxExitsPerVCPU) VM exits", vcpuIndex: worker.index)
                return .ended
            }
            let exit: VCPUExit
            if Self.profiling {
                let began = monotonicNanoseconds()
                if firstRunNanoseconds.load(ordering: .relaxed) == 0 {
                    _ = firstRunNanoseconds.compareExchange(expected: 0, desired: began, ordering: .relaxed)
                }
                exit = try vcpu.runOnce()
                worker.runNanoseconds &+= monotonicNanoseconds() &- began
            } else {
                exit = try vcpu.runOnce()
            }
            worker.lastExitMs.store(monotonicMilliseconds(), ordering: .relaxed)
            if case .interrupted = exit {
                if worker.sampleRequested.exchange(false, ordering: .relaxed) {
                    worker.samplePC.store((try? vcpu.get(.pc)) ?? 0, ordering: .relaxed)
                    worker.sampleLR.store((try? vcpu.get(.x(30))) ?? 0, ordering: .relaxed)
                    worker.sampleFP.store((try? vcpu.get(.x(29))) ?? 0, ordering: .relaxed)
                    worker.samplePSTATE.store((try? vcpu.get(.pstate)) ?? 0, ordering: .relaxed)
                    worker.sampleELR1.store((try? vcpu.get(.elrEL1)) ?? 0, ordering: .relaxed)
                    worker.sampleESR1.store((try? vcpu.get(SystemRegister.esrEL1)) ?? 0, ordering: .relaxed)
                    // The guest is stopped here: the owner may read its stack.
                    if let reader = sampleStackReader {
                        worker.sampleStack = reader(worker.sampleFP.load(ordering: .relaxed))
                    }
                    worker.sampleCount.wrappingAdd(1, ordering: .releasing)
                }
                continue
            }
            if ending.load(ordering: .acquiring) {
                // The pool ended while this vCPU ran: drop the exit.
                acknowledgeStop(worker, exit)
                return .ended
            }
            let disposition: Disposition
            let doorbellFrame: UInt64?
            switch exit {
            case let .mmio(.write, address, frameAddress, 8) where address == VMLayout.doorbellGPA && frameAddress == worker.frameGPA:
                doorbellFrame = frameAddress
            case let .hypercall(function, flags)
                where function == UInt64(VirtualMachine.hvcDoorbellFunction) && flags & 1 == 0 && bootTemplate.doorbellAddress == 0:
                // vm-shim-protocol.md §5.1: the HVC doorbell carries no
                // address; the frame is this vCPU's own.
                doorbellFrame = worker.frameGPA
            default:
                doorbellFrame = nil
            }
            switch doorbellFrame {
            case let frameAddress?:
                // The frame is read and written in place (one slot lookup, no
                // byte arrays); `YCODE_TRAP_FRAME_COPY=1` copies it as before.
                let framePointer = Self.trapFrameCopy ? nil : try vm.writableHostPointer(gpa: frameAddress, count: TrapFrame.byteCount)
                var frame = try framePointer.map { TrapFrame(decodingFrameAt: $0) }
                    ?? TrapFrame(decoding: vm.read(gpa: frameAddress, count: TrapFrame.byteCount))
                worker.lastTrapX16.store(frame.x[16], ordering: .relaxed)
                worker.lastTrapELR.store(frame.elr, ordering: .relaxed)
                worker.lastTrapKind.store(UInt64(frame.kind), ordering: .relaxed)
                worker.lastTrapESR.store(frame.esr, ordering: .relaxed)
                worker.handlerSince.store(monotonicMilliseconds(), ordering: .relaxed)
                worker.inHandler.store(true, ordering: .relaxed)
                if Self.profiling {
                    let began = monotonicNanoseconds()
                    disposition = trapHandler(worker, &frame)
                    worker.handlerNanoseconds &+= monotonicNanoseconds() &- began
                } else {
                    disposition = trapHandler(worker, &frame)
                }
                worker.inHandler.store(false, ordering: .relaxed)
                // Host work the trap left for after the kernel lock (C17).
                PostTrapWork.drain()
                if case .resume = disposition {
                    if Self.shimFPTouch { frame.resumeFlags |= Self.resumeFPTouch }
                    // (Looked up again: the handler may have changed the VM's slots.)
                    if framePointer != nil {
                        frame.encode(into: try vm.writableHostPointer(gpa: frameAddress, count: TrapFrame.byteCount))
                    } else { try vm.write(gpa: frameAddress, bytes: frame.encoded()) }
                }
            default:
                disposition = exitHandler(worker, exit)
            }
            switch disposition {
            case .resume:
                continue
            case .park:
                return .parked
            case let .terminate(status, message):
                terminate(status: status, message: message, vcpuIndex: worker.index)
                return .ended
            case let .end(message):
                endPool(Termination(kind: .ended, status: 0, message: message, vcpuIndex: worker.index))
                return .ended
            }
        }
    }

    /// Ends the pool with this status (the first end wins) and stops every vCPU.
    public func terminate(status: Int32, message: String, vcpuIndex: Int?) {
        endPool(Termination(kind: .terminated, status: status, message: message, vcpuIndex: vcpuIndex))
    }

    /// Stage 4b (`ThreadHost.stopAllThreads`): ends the pool. Every vCPU
    /// running guest code is kicked out of KVM_RUN; threads blocked in the
    /// kernel stop when their trap returns. Safe from any host thread,
    /// with or without the kernel lock; never blocks on guest threads.
    /// Diagnostics: workers running guest code with no VM exit for at
    /// least `ms`: each is kicked once to sample its state (read the
    /// sample* fields on a later call).
    public func longGuestRuns(atLeast ms: UInt64) -> [Worker] {
        let now = monotonicMilliseconds()
        let list = lock.withLock { workers.filter { $0.running } }
        let stuck = list.filter {
            !$0.inHandler.load(ordering: .relaxed) && $0.lastExitMs.load(ordering: .relaxed) != 0
                && now &- $0.lastExitMs.load(ordering: .relaxed) >= ms
        }
        for w in stuck {
            w.sampleRequested.store(true, ordering: .relaxed)
            _ = ckvm_kick_thread(UInt(w.hostThread), Self.kickSignal)
        }
        return stuck
    }

    /// Diagnostics: every worker's state, one line each.
    public func workerStates() -> [String] {
        let now = monotonicMilliseconds()
        return lock.withLock { workers }.map { w in
            "vCPU \(w.index) tid \(w.hostTID.load(ordering: .relaxed)) running \(w.running) inHandler \(w.inHandler.load(ordering: .relaxed)) "
                + "x16 \(Int64(bitPattern: w.lastTrapX16.load(ordering: .relaxed))) handler age \(now &- w.handlerSince.load(ordering: .relaxed)) ms "
                + "last exit \(now &- w.lastExitMs.load(ordering: .relaxed)) ms ago, context \(w.context.map { "\($0)" } ?? "none")"
        }
    }

    /// Diagnostics: workers inside a trap handler for at least `ms`.
    public func longHandlers(atLeast ms: UInt64) -> [Worker] {
        let now = monotonicMilliseconds()
        return lock.withLock { workers }.filter {
            $0.inHandler.load(ordering: .relaxed) && now &- $0.handlerSince.load(ordering: .relaxed) >= ms
        }
    }

    public func requestStop(_ message: String = "stopped") {
        endPool(Termination(kind: .stopped, status: 0, message: message, vcpuIndex: nil))
    }

    private func endPool(_ reason: Termination) {
        let recorded: Termination? = lock.withLock {
            // The first end wins, except that a thread's own end (exit
            // status, exec) replaces a stop (a kick that raced with it).
            var changed: Termination?
            if termination == nil || (termination!.kind == .stopped && reason.kind != .stopped) {
                termination = reason
                changed = reason
            }
            if ending.exchange(true, ordering: .acquiringAndReleasing) {
                terminated.broadcast()
                return changed
            }
            // No vCPU enters the guest again: immediate_exit stays set.
            let me = pthread_self()
            for worker in workers {
                worker.vcpu.setImmediateExit(true)
                worker.wakeup.broadcast()
                // A thread inside the trap handler stops when it returns to
                // its run loop (a blocked one when the kernel wakes it).
                if worker.running, !worker.inHandler.load(ordering: .relaxed), pthread_equal(worker.hostThread, me) == 0,
                   !Self.debugNoKick {
                    _ = ckvm_kick_thread(UInt(worker.hostThread), Self.kickSignal)
                }
            }
            terminated.broadcast()
            return changed
        }
        if let recorded { onEnd(recorded) }
    }

    // MARK: Supervisor

    /// Waits until the pool ends, or until `timeoutMilliseconds` pass. On
    /// timeout every running vCPU is kicked out of KVM_RUN and the returned
    /// termination (status 71) reports where each thread was.
    public func waitForTermination(timeoutMilliseconds: UInt64) -> Termination {
        lock.lock()
        let deadline = monotonicMilliseconds() + timeoutMilliseconds
        while termination == nil {
            let now = monotonicMilliseconds()
            if now >= deadline { break }
            terminated.wait(lock, milliseconds: deadline - now)
        }
        if let termination {
            lock.unlock()
            return termination
        }
        lock.unlock()
        let report = stopAll()
        return Termination(kind: .stopped, status: 71,
                           message: "watchdog: guest still running after \(timeoutMilliseconds) ms\n" + report, vcpuIndex: nil)
    }

    /// Ends the pool, kicks every running vCPU out of the guest, and
    /// collects one line per vCPU (where each thread was). Waits at most
    /// `milliseconds` for the kicked threads.
    public func stopAll(milliseconds: UInt64 = 1000) -> String {
        lock.withLock { reportStops = true }
        endPool(Termination(kind: .stopped, status: 71, message: "stopped by the supervisor", vcpuIndex: nil))
        lock.lock()
        let snapshot = workers
        let deadline = monotonicMilliseconds() + milliseconds
        while monotonicMilliseconds() < deadline,
              snapshot.contains(where: { $0.running && !$0.inHandler.load(ordering: .relaxed) && stopReports[$0.index] == nil }) {
            terminated.wait(lock, milliseconds: 50)
        }
        var lines: [String] = []
        func h(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }
        for worker in snapshot {
            if let report = stopReports[worker.index] {
                lines.append(report)
            } else if worker.running {
                let x16 = Int32(truncatingIfNeeded: worker.lastTrapX16.load(ordering: .relaxed))
                let where_ = worker.inHandler.load(ordering: .relaxed) ? "blocked in trap x16=\(x16)" : "did not stop"
                lines.append("  vCPU \(worker.index): \(where_) (ELR \(h(worker.lastTrapELR.load(ordering: .relaxed))), threads run \(worker.threadCount))")
            } else {
                lines.append("  vCPU \(worker.index): parked (threads run \(worker.threadCount))")
            }
        }
        lock.unlock()
        return lines.joined(separator: "\n")
    }

    /// Records where a stopped vCPU was (for `stopAll`).
    private func acknowledgeStop(_ worker: Worker, _ exit: VCPUExit) {
        guard lock.withLock({ reportStops }) else { return }
        let vcpu = worker.vcpu
        func h(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }
        func reg(_ r: CoreRegister) -> String { (try? vcpu.get(r)).map(h) ?? "?" }
        let pstate = (try? vcpu.get(.pstate)) ?? 0
        var line = "  vCPU \(worker.index): stopped (\(exit)) pc \(reg(.pc)) pstate \(h(pstate))"
        if pstate & 0xF == 0 {
            line += " [EL0] sp \(reg(.spEL0)) lr \(reg(.x(30)))"
        } else {
            line += " [EL1] elr \(reg(.elrEL1)) sp_el0 \(reg(.spEL0))"
        }
        line += "; last trap x16=\(Int32(truncatingIfNeeded: worker.lastTrapX16.load(ordering: .relaxed))) ELR \(h(worker.lastTrapELR.load(ordering: .relaxed))); threads run \(worker.threadCount)"
        lock.withLock {
            stopReports[worker.index] = line
            terminated.broadcast()
        }
    }

    // MARK: Teardown

    /// Waits until every host thread of the ended pool returned, at most
    /// `milliseconds` (nil = no limit). Returns true when they all did.
    @discardableResult
    public func waitUntilFinished(milliseconds: UInt64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let deadline = milliseconds.map { monotonicMilliseconds() + $0 }
        while !(ending.load(ordering: .relaxed) && liveHostThreads == 0) {
            if let deadline {
                let now = monotonicMilliseconds()
                if now >= deadline { return false }
                terminated.wait(lock, milliseconds: deadline - now)
            } else {
                terminated.wait(lock)
            }
        }
        return true
    }

    /// Joins every host thread of the pool. Call only once the pool is
    /// finished (`onFinished`, `waitUntilFinished`), never from one of its
    /// own threads. Breaks the handler closures' references to the owner.
    public func joinThreads() {
        let snapshot: [Worker] = lock.withLock { workers.filter { !$0.joined } }
        for worker in snapshot {
            pthread_join(worker.hostThread, nil)
            lock.withLock { worker.joined = true }
        }
        lock.withLock {
            idle.removeAll()
            for worker in workers { worker.context = nil }
        }
        trapHandler = { _, _ in .terminate(status: 71, message: "pool torn down") }
        exitHandler = { _, _ in .terminate(status: 71, message: "pool torn down") }
        shouldStop = { true }
        onEnd = { _ in }
        onFinished = {}
        preBootCleanRanges = { [] }
        sampleStackReader = nil
        log = { _ in }
    }

    /// Ends the pool, waits for its host threads, and joins them (an owner
    /// that gives up on an image it was building).
    public func shutdown() {
        requestStop("shut down")
        waitUntilFinished(milliseconds: nil)
        joinThreads()
    }
}

/// The host threads that create reserved vCPUs for every pool of the process
/// (`VCPUPool.start`), so that no caller of `start` (a trap handler holding
/// the kernel lock) waits for KVM_CREATE_VCPU or pthread_create.
///
/// `YCODE_VCPU_CREATORS=N` sets the number of threads (default 2, at most
/// 16; 0 turns deferred creation off: `start` creates inline). Requests run
/// first in, first out. Lock order: kernel lock, then a pool's lock, then
/// the creator's queue lock (a leaf: nothing is called while it is held). A
/// creator thread takes a VM's lock and a pool's lock, never the kernel lock.
final class VCPUCreator: @unchecked Sendable {
    static let shared: VCPUCreator? = {
        let n = getenv("YCODE_VCPU_CREATORS").flatMap { Int(String(cString: $0)) } ?? 2
        return n <= 0 ? nil : VCPUCreator(threads: min(n, 16))
    }()

    private let lock = HostMutex(name: "vCPU creator queue")
    private let wake = HostCondition()
    private var queue: [(pool: VCPUPool, creation: VCPUPool.InFlight)] = []
    private let threadLimit: Int
    private var threads = 0
    private var idleThreads = 0

    init(threads: Int) { threadLimit = threads }

    /// Queues a creation. Wakes an idle creator thread, or starts one.
    func submit(_ pool: VCPUPool, _ creation: VCPUPool.InFlight) {
        lock.lock()
        queue.append((pool, creation))
        let startThread = idleThreads == 0 && threads < threadLimit
        if startThread { threads += 1 }
        wake.signal()
        lock.unlock()
        if startThread { startCreatorThread() }
    }

    private func startCreatorThread() {
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED))
        let box = Unmanaged.passRetained(self).toOpaque()
        var thread = pthread_t()
        let result = pthread_create(&thread, &attributes, { argument in
            let creator = Unmanaged<VCPUCreator>.fromOpaque(argument!).takeRetainedValue()
            creator.run()
            return nil
        }, box)
        if result != 0 {
            Unmanaged<VCPUCreator>.fromOpaque(box).release()
            // No new thread: the request waits for a running one; with none
            // at all, it runs on this thread (no request is ever stranded).
            let none: Bool = lock.withLock {
                threads -= 1
                return threads == 0
            }
            if none { drainInline() }
        }
    }

    /// Runs every queued request on the calling thread (no creator thread).
    private func drainInline() {
        while let next = take(waiting: false) { next.pool.createReserved(next.creation) }
    }

    /// The oldest request a thread start waits for, else the oldest one;
    /// waits for one when `waiting`.
    private func take(waiting: Bool) -> (pool: VCPUPool, creation: VCPUPool.InFlight)? {
        lock.lock()
        defer { lock.unlock() }
        while queue.isEmpty {
            guard waiting else { return nil }
            idleThreads += 1
            wake.wait(lock)
            idleThreads -= 1
        }
        let i = queue.firstIndex { $0.creation.urgent.load(ordering: .relaxed) } ?? 0
        return queue.remove(at: i)
    }

    private func run() {
        while let next = take(waiting: true) { next.pool.createReserved(next.creation) }
    }
}

/// The calling thread's page faults (minor + major) and voluntary and
/// involuntary context switches so far (diagnostics; getrusage RUSAGE_THREAD).
public func hostThreadUsage() -> (faults: UInt64, voluntarySwitches: UInt64, involuntarySwitches: UInt64) {
    var c: (Int, Int, Int, Int) = (0, 0, 0, 0)
    withUnsafeMutablePointer(to: &c) { $0.withMemoryRebound(to: Int.self, capacity: 4) { ckvm_thread_usage($0) } }
    return (UInt64(c.0 + c.1), UInt64(c.2), UInt64(c.3))
}

/// The calling thread's user and system CPU time (µs) and minor faults
/// (diagnostics; getrusage RUSAGE_THREAD).
public func hostThreadTimes() -> (userMicros: UInt64, systemMicros: UInt64, minorFaults: UInt64) {
    var c: (UInt64, UInt64, UInt64) = (0, 0, 0)
    withUnsafeMutablePointer(to: &c) { $0.withMemoryRebound(to: CUnsignedLongLong.self, capacity: 3) { ckvm_thread_times($0) } }
    return (c.0, c.1, c.2)
}

/// The calling host thread's CPU time (CLOCK_THREAD_CPUTIME_ID, ns).
public func hostThreadCPUNanoseconds() -> UInt64 {
    var t = timespec()
    guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t) == 0 else { return 0 }
    return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
}

/// The calling thread's Linux thread id (diagnostics).
public func ckvmThreadID() -> Int { ckvm_gettid() }

/// Diagnostics: a host thread's counters (`ckvm_task_stats`): utime,
/// stime, guest time (clock ticks), minor and major faults, CPU time and
/// run-queue wait (ns), the scheduler state letter. Nil when it is gone.
public func hostTaskStats(_ tid: Int) -> [UInt64]? {
    var out = [UInt64](repeating: 0, count: 8)
    return ckvm_task_stats(tid, &out) == 0 ? out : nil
}

/// Clock ticks per second of the /proc CPU times.
public let hostClockTicks = UInt64(max(1, ckvm_clock_ticks()))

/// CLOCK_MONOTONIC in nanoseconds.
public func monotonicNanoseconds() -> UInt64 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec)
}

/// CLOCK_MONOTONIC in milliseconds.
public func monotonicMilliseconds() -> UInt64 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return UInt64(now.tv_sec) * 1000 + UInt64(now.tv_nsec) / 1_000_000
}
#endif
