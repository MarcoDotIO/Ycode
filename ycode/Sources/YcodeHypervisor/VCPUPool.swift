// The per-VM vCPU pool of stage 4a: one Darwin thread = one vCPU, each vCPU
// driven by its own host thread running that vCPU's KVM_RUN loop.
// Contract: specs/simulator/stage4a-contract.md §2 and §4.
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
// - Process end: the first thread that ends the process (exit, a fatal trap,
//   an unexpected VM exit) records the status and stops; the supervisor (the
//   thread that calls `waitForTermination`) wakes and returns it. On the
//   watchdog the supervisor kicks every running vCPU out of KVM_RUN
//   (immediate_exit plus a signal) to report where each thread was.

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
        /// End the process with this status (exit, fatal trap, ...).
        case terminate(status: Int32, message: String)
    }

    /// Why the process ended.
    public struct Termination: Sendable {
        public var status: Int32
        public var message: String
        /// The vCPU that ended the process, or nil (watchdog).
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

        fileprivate unowned let pool: VCPUPool
        fileprivate var pending: VCPUStartState?
        fileprivate var running = false
        fileprivate var started = false
        fileprivate var hostThread = pthread_t()
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
    private let stopping = Atomic<Bool>(false)
    private var stopReports: [Int: String] = [:]
    private var activeThreads = 0
    /// The most threads alive at once (statistics).
    public private(set) var peakThreads = 0

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
    /// The termination, once a thread has ended the process.
    public var currentTermination: Termination? { lock.withLock { termination } }

    /// Creates the next vCPU and its host thread without starting a guest
    /// thread on it (it is parked until `start`). Lets the VMM read vCPU
    /// state (the counter, its frequency) before the first thread runs.
    public func createWorker() throws -> Worker {
        try lock.withLock {
            guard workers.count < capacity else { throw KVMError("vCPU pool", detail: "all \(capacity) vCPUs exist") }
            let vcpu = try vm.makeVCPU(id: workers.count)
            let worker = Worker(index: workers.count, vcpu: vcpu, pool: self)
            workers.append(worker)
            try spawn(worker)
            idle.insert(worker, at: 0)
            return worker
        }
    }

    // MARK: Starting threads

    /// Starts a guest thread on a parked vCPU, or on a new vCPU when none is
    /// parked. Returns nil when the pool is exhausted (EAGAIN for the caller).
    /// `context` is attached to the worker before the thread runs. Safe to
    /// call from any host thread, including from inside a trap handler.
    @discardableResult
    public func start(_ state: VCPUStartState, context: AnyObject?) throws -> Worker? {
        try lock.withLock {
            if termination != nil || stopping.load(ordering: .relaxed) { return nil }
            let worker: Worker
            if !idle.isEmpty {
                // Prefer the lowest-numbered idle vCPU (vCPU 0 for the main thread).
                let i = idle.indices.min { idle[$0].index < idle[$1].index }!
                let reused = idle.remove(at: i)
                worker = reused
            } else {
                guard workers.count < capacity else { return nil }
                let vcpu = try vm.makeVCPU(id: workers.count)
                worker = Worker(index: workers.count, vcpu: vcpu, pool: self)
                workers.append(worker)
                try spawn(worker)
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
    }

    // MARK: The host thread of one vCPU

    private func threadMain(_ worker: Worker) -> Never {
        while true {
            lock.lock()
            while worker.pending == nil {
                if termination != nil || stopping.load(ordering: .relaxed) { break }
                worker.wakeup.wait(lock)
            }
            guard let state = worker.pending, termination == nil, !stopping.load(ordering: .relaxed) else {
                lock.unlock()
                blockForever()
            }
            worker.pending = nil
            worker.running = true
            lock.unlock()

            do {
                try begin(worker, state)
                try runLoop(worker)
            } catch {
                terminate(status: 1, message: "vCPU \(worker.index): \(error)", vcpuIndex: worker.index)
                blockForever()
            }

            // The guest thread ended: park.
            lock.withLock {
                worker.running = false
                worker.context = nil
                activeThreads -= 1
                idle.append(worker)
            }
        }
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

    /// Runs the vCPU until its guest thread ends (returns) or the process ends (never returns).
    private func runLoop(_ worker: Worker) throws {
        let vcpu = worker.vcpu
        while true {
            if maxExitsPerVCPU > 0, vcpu.exitCount >= maxExitsPerVCPU {
                finish(worker, .terminate(status: 71, message: "vCPU \(worker.index) exceeded \(maxExitsPerVCPU) VM exits"))
            }
            if stopping.load(ordering: .acquiring) { acknowledgeStop(worker, .interrupted) }
            let exit = try vcpu.runOnce()
            if stopping.load(ordering: .acquiring) { acknowledgeStop(worker, exit) }
            let disposition: Disposition
            switch exit {
            case let .mmio(.write, address, frameAddress, 8) where address == VMLayout.doorbellGPA && frameAddress == worker.frameGPA:
                var frame = try TrapFrame(decoding: vm.read(gpa: frameAddress, count: TrapFrame.byteCount))
                worker.lastTrapX16.store(frame.x[16], ordering: .relaxed)
                worker.lastTrapELR.store(frame.elr, ordering: .relaxed)
                worker.inHandler.store(true, ordering: .relaxed)
                disposition = trapHandler(worker, &frame)
                worker.inHandler.store(false, ordering: .relaxed)
                if case .resume = disposition { try vm.write(gpa: frameAddress, bytes: frame.encoded()) }
            case .interrupted:
                continue
            default:
                disposition = exitHandler(worker, exit)
            }
            switch disposition {
            case .resume: continue
            case .park: return
            case .terminate: finish(worker, disposition)
            }
        }
    }

    private func finish(_ worker: Worker, _ disposition: Disposition) -> Never {
        if case let .terminate(status, message) = disposition {
            terminate(status: status, message: message, vcpuIndex: worker.index)
        }
        blockForever()
    }

    /// Records the end of the process (the first call wins) and wakes the supervisor.
    public func terminate(status: Int32, message: String, vcpuIndex: Int?) {
        lock.withLock {
            if termination == nil { termination = Termination(status: status, message: message, vcpuIndex: vcpuIndex) }
            terminated.broadcast()
        }
    }

    private func blockForever() -> Never {
        let never = HostCondition()
        lock.lock()
        while true { never.wait(lock) }
    }

    // MARK: Supervisor

    /// Waits until a thread ends the process, or until `timeoutMilliseconds`
    /// pass. On timeout every running vCPU is kicked out of KVM_RUN and the
    /// returned termination (status 71) reports where each thread was.
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
        return Termination(status: 71, message: "watchdog: guest still running after \(timeoutMilliseconds) ms\n" + report, vcpuIndex: nil)
    }

    /// Kicks every running vCPU out of the guest and collects one line per vCPU.
    public func stopAll() -> String {
        stopping.store(true, ordering: .releasing)
        let snapshot: [Worker] = lock.withLock { workers }
        var kicked = 0
        for worker in snapshot {
            let running = lock.withLock { worker.running }
            guard running else { continue }
            // A thread inside the trap handler stops when it returns to its
            // run loop (unless it is blocked in the kernel).
            worker.vcpu.setImmediateExit(true)
            if !worker.inHandler.load(ordering: .relaxed) {
                _ = ckvm_kick_thread(UInt(worker.hostThread), Self.kickSignal)
                kicked += 1
            }
        }
        lock.lock()
        let deadline = monotonicMilliseconds() + 1000
        while stopReports.count < kicked, monotonicMilliseconds() < deadline {
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

    private func acknowledgeStop(_ worker: Worker, _ exit: VCPUExit) -> Never {
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
        blockForever()
    }
}

func monotonicMilliseconds() -> UInt64 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return UInt64(now.tv_sec) * 1000 + UInt64(now.tv_nsec) / 1_000_000
}
#endif
