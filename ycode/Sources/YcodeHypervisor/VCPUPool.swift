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
        public let samplePSTATE = Atomic<UInt64>(0)
        public let sampleELR1 = Atomic<UInt64>(0)
        public let sampleESR1 = Atomic<UInt64>(0)
        public let sampleCount = Atomic<UInt64>(0)
        /// The host (Linux) thread id of this vCPU's thread.
        public let hostTID = Atomic<UInt64>(0)

        fileprivate unowned let pool: VCPUPool
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
    /// Diagnostics (one line each).
    public var log: (String) -> Void = { _ in }

    /// The signal that kicks a vCPU host thread out of KVM_RUN.
    public static let kickSignal = SIGUSR2

    private let lock = HostMutex()
    private let terminated = HostCondition()
    private var workers: [Worker] = []
    private var idle: [Worker] = []
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

    public init(vm: VirtualMachine, bootTemplate: BootInfo, limit: Int = VCPUSlots.count, maxExitsPerVCPU: Int = 0) throws {
        self.vm = vm
        self.capacity = max(1, min(vm.maxVCPUs, limit, VCPUSlots.count))
        self.bootTemplate = bootTemplate
        self.maxExitsPerVCPU = maxExitsPerVCPU
        try kvmCheck(ckvm_kick_install(Self.kickSignal), "sigaction (vCPU kick signal)")
    }

    /// The number of vCPUs created so far.
    public var vcpuCount: Int { lock.withLock { workers.count } }
    /// The number of created vCPUs with no guest thread.
    public var parkedCount: Int { lock.withLock { idle.count } }
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
        try lock.withLock {
            guard !ending.load(ordering: .relaxed) else { throw KVMError("vCPU pool", detail: "the pool has ended") }
            guard workers.count < capacity else { throw KVMError("vCPU pool", detail: "all \(capacity) vCPUs exist") }
            let worker = try makeWorkerLocked()
            idle.insert(worker, at: 0)
            return worker
        }
    }

    private func makeWorkerLocked() throws -> Worker {
        let vcpu = try vm.makeVCPU(id: workers.count)
        let worker = Worker(index: workers.count, vcpu: vcpu, pool: self)
        try spawn(worker)
        workers.append(worker)
        return worker
    }

    // MARK: Starting threads

    /// Starts a guest thread on a parked vCPU, or on a new vCPU when none is
    /// parked. Returns nil when the pool is exhausted or has ended (EAGAIN
    /// for the caller). `context` is attached to the worker before the
    /// thread runs. Safe to call from any host thread, including from inside
    /// a trap handler.
    @discardableResult
    public func start(_ state: VCPUStartState, context: AnyObject?) throws -> Worker? {
        try lock.withLock {
            if ending.load(ordering: .relaxed) { return nil }
            let worker: Worker
            if !idle.isEmpty {
                // Prefer the lowest-numbered idle vCPU (vCPU 0 for the main thread).
                let i = idle.indices.min { idle[$0].index < idle[$1].index }!
                worker = idle.remove(at: i)
            } else {
                guard workers.count < capacity else { return nil }
                worker = try makeWorkerLocked()
            }
            worker.context = context
            worker.pending = state
            worker.threadCount += 1
            activeThreads += 1
            peakThreads = max(peakThreads, activeThreads)
            worker.wakeup.signal()
            return worker
        }
    }

    /// True when `start` would find a vCPU now (an idle one, or room for a new one).
    public var hasRoom: Bool {
        lock.withLock { !ending.load(ordering: .relaxed) && (!idle.isEmpty || workers.count < capacity) }
    }

    /// Called on a vCPU's host thread (no lock held) each time a thread ends
    /// and its vCPU returns to the idle list.
    public var onParked: (() -> Void)? {
        get { lock.withLock { parkedHandler } }
        set { lock.withLock { parkedHandler = newValue } }
    }
    private var parkedHandler: (() -> Void)?

    private func spawn(_ worker: Worker) throws {
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setstacksize(&attributes, 16 << 20)
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
        liveHostThreads += 1
        hostThreadsCreated += 1
    }

    // MARK: The host thread of one vCPU

    private enum RunEnd { case parked, ended }

    private func threadMain(_ worker: Worker) {
        worker.hostTID.store(UInt64(ckvm_gettid()), ordering: .relaxed)
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
        lock.lock()
        worker.context = nil
        liveHostThreads -= 1
        let last = liveHostThreads == 0
        if last { finished = true }
        terminated.broadcast()
        lock.unlock()
        if last { onFinished() }
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
            info.tpidrEL0 = state.tpidr
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
            frame.tpidr = state.tpidr
            frame.flushTLB = true
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
            let exit = try vcpu.runOnce()
            worker.lastExitMs.store(monotonicMilliseconds(), ordering: .relaxed)
            if case .interrupted = exit {
                if worker.sampleRequested.exchange(false, ordering: .relaxed) {
                    worker.samplePC.store((try? vcpu.get(.pc)) ?? 0, ordering: .relaxed)
                    worker.samplePSTATE.store((try? vcpu.get(.pstate)) ?? 0, ordering: .relaxed)
                    worker.sampleELR1.store((try? vcpu.get(.elrEL1)) ?? 0, ordering: .relaxed)
                    worker.sampleESR1.store((try? vcpu.get(SystemRegister.esrEL1)) ?? 0, ordering: .relaxed)
                    worker.sampleCount.wrappingAdd(1, ordering: .relaxed)
                }
                continue
            }
            if ending.load(ordering: .acquiring) {
                // The pool ended while this vCPU ran: drop the exit.
                acknowledgeStop(worker, exit)
                return .ended
            }
            let disposition: Disposition
            switch exit {
            case let .mmio(.write, address, frameAddress, 8) where address == VMLayout.doorbellGPA && frameAddress == worker.frameGPA:
                var frame = try TrapFrame(decoding: vm.read(gpa: frameAddress, count: TrapFrame.byteCount))
                worker.lastTrapX16.store(frame.x[16], ordering: .relaxed)
                worker.lastTrapELR.store(frame.elr, ordering: .relaxed)
                worker.lastTrapKind.store(UInt64(frame.kind), ordering: .relaxed)
                worker.lastTrapESR.store(frame.esr, ordering: .relaxed)
                worker.handlerSince.store(monotonicMilliseconds(), ordering: .relaxed)
                worker.inHandler.store(true, ordering: .relaxed)
                disposition = trapHandler(worker, &frame)
                worker.inHandler.store(false, ordering: .relaxed)
                if case .resume = disposition { try vm.write(gpa: frameAddress, bytes: frame.encoded()) }
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
                if worker.running, !worker.inHandler.load(ordering: .relaxed), pthread_equal(worker.hostThread, me) == 0 {
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

/// CLOCK_MONOTONIC in milliseconds.
public func monotonicMilliseconds() -> UInt64 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return UInt64(now.tv_sec) * 1000 + UInt64(now.tv_nsec) / 1_000_000
}
#endif
