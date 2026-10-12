import Foundation
import YcodeDarwinABI

// Darwin threads of stage 4a (`specs/simulator/stage4a-contract.md` §2, §5;
// `specs/simulator/threads-and-events.md` §1). One Darwin thread runs on one
// vCPU, and each vCPU has its own host thread. The hypervisor implements
// `ThreadHost`; the kernel calls it to start a vCPU for a new thread.

/// One Darwin thread, as the kernel sees it. The hypervisor passes the
/// thread's context to every `DarwinKernel.handle` call made for that
/// thread's vCPU. All mutable state is changed only under the kernel lock.
public final class ThreadContext: @unchecked Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// The process's first thread.
        case main
        /// Made by `bsdthread_create`.
        case pthread
        /// A workqueue worker (`start_wqthread`).
        case workqueue
    }

    /// `thread_selfid`: unique, non-zero, never reused (main = 1).
    public let threadID: UInt64
    /// The thread's port name in the task's space (`name & 3 == 3`).
    public internal(set) var portName: UInt32
    /// The vCPU that runs this thread; the hypervisor may set it.
    public var vcpuIndex: Int
    public let kind: Kind
    /// The `pthread_t` (the worker's `self` for workqueue threads; 0 for the
    /// main thread until known).
    public internal(set) var pthreadAddress: UInt64
    /// False once the thread terminated.
    public internal(set) var isAlive = true
    /// True while the thread sleeps in a `WaitQueue`.
    public internal(set) var blockedInKernel = false
    /// The trap in progress (diagnostics: the blocked-thread report): x16
    /// and x0…x7 at entry; nil between traps. Set by the VMM.
    public var trapInProgress: (x16: UInt64, args: [UInt64])?
    /// The user registers at the entry of the trap in progress (nil while
    /// the thread runs guest code): what thread_get_state reports.
    public internal(set) var entryFrame: TrapFrame?
    /// Diagnostics: set from the moment the VMM sees the trap (before it
    /// takes the kernel lock) until it returns.
    public var arrivingTrap: UInt64?
    /// Diagnostics: traps made, and the last 16 (x16, x0 and x1 at entry, x0
    /// at return with bit 63 set when carry was set), newest last.
    public var trapCount = 0
    public var recentTraps: [(UInt64, UInt64, UInt64, UInt64)] = []
    /// The process image (kernel) this thread belongs to (stage 4b). Set
    /// when the kernel makes the thread, or at its first trap.
    public internal(set) weak var kernel: DarwinKernel?

    /// The per-thread signal mask (`__pthread_sigmask`).
    var signalMask: UInt32 = 0
    /// Workqueue bookkeeping (workers only).
    var worker: WorkerState?
    /// A thread created with `PTHREAD_START_SUSPENDED` that has not started.
    var suspendedStart: ThreadStartState?

    public init(threadID: UInt64, portName: UInt32, vcpuIndex: Int, kind: Kind, pthreadAddress: UInt64 = 0) {
        self.threadID = threadID
        self.portName = portName
        self.vcpuIndex = vcpuIndex
        self.kind = kind
        self.pthreadAddress = pthreadAddress
    }

    public var description: String {
        "thread \(threadID) port \(hx(portName)) vcpu \(vcpuIndex) \(kind)"
    }
}

/// The EL0 register state a new thread starts with. Every register not
/// listed is zero (x6–x28, fp, lr, V0–V31, FPSR, FPCR); PSTATE is EL0t with
/// NZCV = 0.
public struct ThreadStartState: Equatable, Sendable {
    /// x0…x30.
    public var x: [UInt64]
    public var pc: UInt64
    public var sp: UInt64
    public var tpidrro: UInt64
    public var tpidr: UInt64

    public init(x: [UInt64] = [], pc: UInt64, sp: UInt64, tpidrro: UInt64, tpidr: UInt64 = 0) {
        var regs = Array(x.prefix(TrapFrame.registerCount))
        regs += [UInt64](repeating: 0, count: TrapFrame.registerCount - regs.count)
        self.x = regs
        self.pc = pc
        self.sp = sp
        self.tpidrro = tpidrro
        self.tpidr = tpidr
    }

    /// The trap frame that resumes EL0 at this state (`elr` = pc, SPSR = 0).
    public var frame: TrapFrame {
        TrapFrame(x: x, spEL0: sp, elr: pc, spsr: 0, tpidrro: tpidrro, tpidr: tpidr,
                  kind: TrapFrame.Kind.svc.rawValue)
    }

    /// Overwrites `frame`'s EL0 state with this one (a restart of the thread).
    public func apply(to frame: inout TrapFrame) {
        frame.x = x
        frame.spEL0 = sp
        frame.elr = pc
        frame.spsr = 0
        frame.tpidrro = tpidrro
        frame.tpidr = tpidr
    }
}

/// Implemented by the hypervisor (agent V): the vCPU pool.
public protocol ThreadHost: AnyObject {
    /// Starts a vCPU (a parked one from the pool when there is one) running
    /// EL0 at `start`, on its own host thread, which passes `context` to
    /// every `DarwinKernel.handle` call it makes. Returns the vCPU index.
    ///
    /// Called with the kernel lock held: it must not call back into the
    /// kernel. The new thread's first trap simply waits for the lock.
    /// Throws when no vCPU is available (the pool is exhausted); the kernel
    /// then fails `bsdthread_create` with EAGAIN or keeps a workqueue request
    /// pending.
    func startThread(_ start: ThreadStartState, context: ThreadContext) throws -> Int

    /// Stage 4b (`stage4b-contract.md` §3.4): makes every vCPU of this
    /// process that is running guest code return to the VMM soon, so that it
    /// sees the process's termination (kill, exit from another thread, exec).
    /// Called with the kernel lock held; must not call back into the kernel.
    func stopAllThreads()
}

extension ThreadHost {
    public func stopAllThreads() {}
}

/// What the kernel needs from the in-process Mach IPC (agent I's `MachIPC`
/// conforms). Every call is made with the kernel lock held.
public protocol MachIPCHandling: AnyObject {
    /// Handles a Mach trap (negative `x16`) or a private trap in
    /// `0x7963_2000…0x7963_20FF`. Returns nil for traps it does not own.
    func handleTrap(x16: Int64, frame: inout TrapFrame, context: ThreadContext,
                    memory: any GuestVirtualMemory) -> TrapOutcome?
    /// A new thread port name (`name & 3 == 3`) holding one send right.
    func allocateThreadPort() -> UInt32
    /// Drops one user reference on `name` (thread ports at thread exit).
    func deallocate(name: UInt32)
    /// True when the port (or a member of the port set) has a message queued.
    func messageQueued(on port: UInt32) -> Bool
    /// Set by the kernel. `MachIPC` calls it, with the lock held, whenever a
    /// message is queued on a receive right: once with the port's name and
    /// once with the name of each port set that contains it (EVFILT_MACHPORT).
    var messageQueuedHandler: ((_ name: UInt32) -> Void)? { get set }
    /// The semaphore object behind a semaphore port name (`semaphore_create`
    /// makes `KernelSemaphore(value:)`; `semaphore_destroy` calls `destroy()`).
    func semaphore(named name: UInt32) -> KernelSemaphore?
    /// Receives the first message of `port` for an EVFILT_MACHPORT event that
    /// asked for `MACH_RCV_MSG`, never waiting, into [buffer, buffer+size)
    /// with the receive `options` (threads-and-events.md §3.7.3). Nil =
    /// not supported (the event is then delivered without a message).
    func receiveForKevent(port: UInt32, options: UInt32, buffer: UInt64, size: UInt64,
                          context: ThreadContext, memory: any GuestVirtualMemory) -> KeventMachReceive?
}

extension MachIPCHandling {
    public func receiveForKevent(port: UInt32, options: UInt32, buffer: UInt64, size: UInt64,
                                 context: ThreadContext, memory: any GuestVirtualMemory) -> KeventMachReceive? { nil }
}

/// The result of `MachIPCHandling.receiveForKevent` (the out fields of the
/// event, threads-and-events.md §3.7.3).
public struct KeventMachReceive: Equatable, Sendable {
    /// The `mach_msg` return code (`fflags`).
    public var returnCode: UInt32
    /// Message + trailer size, or the size needed for `MACH_RCV_TOO_LARGE` (`ext[1]`).
    public var size: UInt64
    /// (priority << 32) | override `pthread_priority_t` (`ext[2]`).
    public var priorityAndQoS: UInt64
    /// Auxiliary data size after the message (`ext[3]`).
    public var auxiliarySize: UInt64
    /// `data`: the port name for TOO_LARGE with `MACH_RCV_LARGE_IDENTITY`, else 0.
    public var data: UInt64

    public init(returnCode: UInt32, size: UInt64, priorityAndQoS: UInt64 = 0, auxiliarySize: UInt64 = 0, data: UInt64 = 0) {
        self.returnCode = returnCode
        self.size = size
        self.priorityAndQoS = priorityAndQoS
        self.auxiliarySize = auxiliarySize
        self.data = data
    }
}

// MARK: - Kernel side

extension DarwinKernel {
    /// `bsdthread_create` flag bits.
    public enum PthreadStart {
        public static let custom: UInt32 = 0x0100_0000
        public static let setSched: UInt32 = 0x0200_0000
        public static let qosClass: UInt32 = 0x0800_0000
        public static let tsdBaseSet: UInt32 = 0x1000_0000
        public static let suspended: UInt32 = 0x2000_0000
    }

    /// A new thread port name from the task's space.
    func allocateThreadPort() -> UInt32 {
        guard let ipc = machIPC else { preconditionFailure("DarwinKernel.machIPC is not attached") }
        return ipc.allocateThreadPort()
    }

    func deallocateThreadPort(_ name: UInt32) {
        machIPC?.deallocate(name: name)
    }

    /// The thread is gone: its port dies and its name loses the reference
    /// the kernel gave it at creation.
    func threadPortTerminated(_ ctx: ThreadContext) {
        if let ipc = machIPC as? MachIPC { ipc.threadTerminated(ctx) } else { deallocateThreadPort(ctx.portName) }
    }

    /// Makes a thread object with a new id and port name (not started).
    func makeThread(kind: ThreadContext.Kind, pthread: UInt64) -> ThreadContext {
        let ctx = ThreadContext(threadID: nextThreadID, portName: allocateThreadPort(), vcpuIndex: -1, kind: kind,
                                pthreadAddress: pthread)
        nextThreadID += 1
        ctx.kernel = self
        threadsByPort[ctx.portName] = ctx
        return ctx
    }

    /// Ends the process: every blocked thread wakes and every later trap
    /// returns `.exit(status:)`.
    public func shutdown(status: Int32 = 0) {
        lock.withLock {
            // Stage 4b: a process in the table exits for good.
            if termination == nil, let p = system.record(of: self) {
                system.exitProcess(p, waitStatus: (status & 0xFF) << 8, outcome: .exit(status: status))
                return
            }
            if termination == nil { termination = .exit(status: status) }
            lock.terminate()
            kevents.timerWake.wakeAll()
        }
    }

    /// Starts a thread created with `PTHREAD_START_SUSPENDED` (for
    /// `thread_resume`). Returns false when the port names no such thread
    /// or it cannot start.
    public func resumeSuspendedThread(port: UInt32) -> Bool {
        lock.withLock {
            guard let ctx = threadsByPort[port], let start = ctx.suspendedStart, let host = threadHost else { return false }
            guard let index = try? host.startThread(start, context: ctx) else { return false }
            ctx.vcpuIndex = index
            ctx.suspendedStart = nil
            return true
        }
    }

    // MARK: bsdthread_create (360)

    func bsdthreadCreate(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> BSDResult {
        let flags = UInt32(truncatingIfNeeded: a[4])
        call = "bsdthread_create(func=\(hx(a[0])), arg=\(hx(a[1])), stack=\(hx(a[2])), pthread=\(hx(a[3])), flags=\(hx(flags)))"
        guard let reg = threadRegistration else { throw Failure(errno: Errno.EINVAL) }
        guard flags & PthreadStart.custom != 0 else { throw Failure(errno: Errno.EINVAL) }
        if flags & PthreadStart.qosClass != 0 {
            let pp = flags & 0x00FF_FFFF
            guard PthreadPriority.qos(pp) != nil, (-15...0).contains(PthreadPriority.relativePriority(pp)) else {
                throw Failure(errno: Errno.EINVAL)
            }
        }
        let pthread = a[3], stack = a[2]
        let ctx = makeThread(kind: .pthread, pthread: pthread)
        func undo() {
            threadsByPort[ctx.portName] = nil
            ctx.isAlive = false
            deallocateThreadPort(ctx.portName)
        }
        var outFlags = flags & ~PthreadStart.suspended
        var tpidrro: UInt64 = 0
        if reg.tsdOffset != 0 {
            tpidrro = pthread &+ UInt64(reg.tsdOffset)
            outFlags |= PthreadStart.tsdBaseSet
        }
        if reg.machThreadSelfOffset != 0 {
            do {
                try writeU64(pthread &+ UInt64(reg.tsdOffset) &+ UInt64(reg.machThreadSelfOffset), UInt64(ctx.portName), mem)
            } catch {
                undo()
                throw error
            }
        }
        let start = ThreadStartState(x: [pthread, UInt64(ctx.portName), a[0], a[1], stack, UInt64(outFlags)],
                                     pc: reg.threadStart, sp: stack, tpidrro: tpidrro)
        if flags & PthreadStart.suspended != 0 {
            ctx.suspendedStart = start
            call += " [\(ctx), suspended]"
            return .value(pthread)
        }
        guard let host = threadHost else {
            undo()
            log("note: bsdthread_create: no thread host; EAGAIN")
            throw Failure(errno: Self.EAGAIN)
        }
        do {
            ctx.vcpuIndex = try host.startThread(start, context: ctx)
        } catch {
            undo()
            log("note: bsdthread_create: cannot start a vCPU (\(error)); EAGAIN")
            throw Failure(errno: Self.EAGAIN)
        }
        call += " [\(ctx)]"
        return .value(pthread)
    }

    static let EAGAIN: Int32 = 35

    // MARK: bsdthread_terminate (361)

    func bsdthreadTerminate(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> BSDResult {
        let ctx = current
        var port = UInt32(truncatingIfNeeded: a[2])
        var semaphoreName = UInt32(truncatingIfNeeded: a[3])
        call = "bsdthread_terminate(stack=\(hx(a[0])), size=\(hx(a[1])), port=\(hx(port)), sema_or_ulock=\(hx(a[3])))"
        if ctx.kind == .workqueue { workqueueThreadTerminating(ctx) }
        // Join gate: an aligned address instead of a semaphore name.
        var gate: (address: UInt64, port: UInt32)?
        if a[3] != 0, a[3] | 3 != a[3] {
            gate = (a[3], port)
            port = 0
            semaphoreName = 0
        }
        if a[0] != 0, a[1] != 0 {
            if ctx.kind == .main {
                let size = (a[1] - 1) & ~Self.pageMask
                if size > 0 { try? mem.protect(va: a[0] & ~Self.pageMask, size: size, protection: []) }
            } else {
                let start = a[0] & ~Self.pageMask
                try? mem.unmap(va: start, size: roundUp(a[1] + (a[0] - start), to: Self.pageSize))
            }
        }
        ctx.isAlive = false
        threadsByPort[ctx.portName] = nil
        if semaphoreName != 0 { semaphore(named: semaphoreName)?.signal() }
        // The reference on the thread's own name is dropped with the thread
        // (below); any other name passed is dropped here.
        if port != 0, port != ctx.portName { deallocateThreadPort(port) }
        if let gate {
            try? writeU32(gate.address, gate.port & ~3, mem)
            let (_, woke) = ulockWakeCore(operation: ULock.unfairLock | ULockFlag.wakeAll | ULockFlag.wakeAllowNonOwner,
                                          addr: gate.address, wakeValue: 0)
            if gate.port != 0, gate.port != ctx.portName { deallocateThreadPort(gate.port) }
            call += " [join gate \(hx(gate.address)) = \(hx(gate.port & ~3)), woke \(woke)]"
        }
        threadPortTerminated(ctx)
        // A freed vCPU may let a pending workqueue request start.
        pumpWorkqueue(mem)
        if threadsByPort.isEmpty {
            call += " [last thread]"
            return .exit(0)
        }
        return .threadExit
    }

    // MARK: bsdthread_ctl (478)

    func bsdthreadCtl(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let cmd = UInt32(truncatingIfNeeded: a[0])
        call = "bsdthread_ctl(cmd=\(hx(cmd)), \(hx(a[1])), \(hx(a[2])), \(hx(a[3])))"
        switch cmd {
        case 0x10, 0x401, 0x402:
            throw Failure(errno: Errno.ENOTSUP)
        case 0x40, 0x80, 0x200, 0x400, 0x1000, 0x2000, 0x4000:
            return 0
        case 0x800:
            return UInt64(WorkqueueState.parallelism)
        case 0x100:
            let ctx = current
            let flags = UInt32(truncatingIfNeeded: a[3])
            if flags & 0x01 != 0, PthreadPriority.qos(UInt32(truncatingIfNeeded: a[1])) == nil {
                throw Failure(errno: Errno.EINVAL)
            }
            if flags & 0x10 != 0 {
                guard let w = ctx.worker, w.boundBucket != Self.managerQoS, !(w.boundQueue?.kind == .workloop) else {
                    throw Failure(errno: Errno.EINVAL)
                }
                guard w.boundQueue != nil else { throw Failure(errno: Self.EALREADY) }
                unbindWorker(ctx, release: false)
                call += " [kevent unbind]"
            }
            return 0
        default:
            throw Failure(errno: Errno.EINVAL)
        }
    }

    // MARK: thread_switch (−61)

    func handleThreadSwitch(_ n: Int, _ frame: inout TrapFrame) -> Outcome? {
        if n == Mach.swtchPri || n == Mach.swtch {
            lock.yield()
            frame.x[0] = 0
            log("trap mach \(n) \(n == Mach.swtch ? "swtch" : "swtch_pri")(\(Int32(truncatingIfNeeded: frame.x[0]))) -> 0 [yield]")
            return .resume
        }
        guard n == Mach.threadSwitch else { return nil }
        let option = Int32(truncatingIfNeeded: frame.x[1])
        let ms = UInt64(UInt32(truncatingIfNeeded: frame.x[2]))
        // SWITCH_OPTION_DEPRESS (1) and SWITCH_OPTION_WAIT (2) take a time in ms.
        if (option == 1 || option == 2) && ms > 0 {
            _ = WaitQueue().wait(on: lock, deadline: KernelClock.deadline(afterNanoseconds: min(ms, 10_000) * 1_000_000))
        } else {
            lock.yield()
        }
        frame.x[0] = KernReturn.success
        log("trap mach \(n) thread_switch(thread=\(hx(UInt32(truncatingIfNeeded: frame.x[0]))), option=\(option), time=\(ms)) -> KERN_SUCCESS")
        return .resume
    }
}

// MARK: - thread_get_state (stage 6)

extension DarwinKernel {
    /// thread_get_state for a thread of the caller's task (xnu
    /// `osfmk/arm64/status.c` machine_thread_get_state, `mach/arm/
    /// thread_status.h`; level 1). The state is the thread's user registers
    /// at the entry of its trap in progress: the caller's own thread, or a
    /// thread blocked in (or entering) the kernel. A thread executing guest
    /// code on its vCPU cannot be sampled here and gets KERN_FAILURE —
    /// libobjc then treats it as inside a cache critical section and keeps
    /// the old caches (objc4 `_collecting_in_critical`; level 1). Flavors:
    /// ARM_THREAD_STATE64 (6, 68 words), ARM_EXCEPTION_STATE64 (7, 4 words),
    /// ARM_THREAD_STATE (1, the unified form: {flavor 6, count 68} + state,
    /// 70 words). Others are KERN_INVALID_ARGUMENT (Ycode keeps no FP, NEON
    /// or debug registers of other threads).
    func threadGetState(_ a: [UInt64], ipc: MachIPC, memory: any GuestVirtualMemory) -> (UInt32, String) {
        let name = UInt32(truncatingIfNeeded: a[0]), flavor = UInt32(truncatingIfNeeded: a[1])
        guard let (port, object) = ipc.kernelObject(named: name), case .thread = object else {
            return (MachKern.invalidArgument, " [not a thread of this task]")
        }
        guard let thread = threadsByPort.values.first(where: { ipc.kernelObject(named: $0.portName)?.0 === port }),
              thread.isAlive else {
            return (MachKern.invalidArgument, " [not a thread of this task]")
        }
        guard let capacityBytes = try? memory.read(va: a[3], count: 4) else { return (MachKern.invalidAddress, "") }
        let capacity = capacityBytes.readLE(UInt32.self, at: 0)
        let needed: UInt32
        switch flavor {
        case 1: needed = 70
        case 6: needed = 68
        case 7: needed = 4
        default: return (MachKern.invalidArgument, " [flavor \(flavor) not kept]")
        }
        guard capacity >= needed else { return (MachKern.invalidArgument, " [count \(capacity) < \(needed)]") }
        guard let f = thread.entryFrame else { return (MachKern.failure, " [thread \(thread.threadID) is running]") }
        var out: [UInt8] = []
        switch flavor {
        case 7:
            out.appendLE(f.far)
            out.appendLE(UInt32(truncatingIfNeeded: f.esr))
            out.appendLE(UInt32(truncatingIfNeeded: f.esr >> 26))  // exception class
        default:
            if flavor == 1 { out.appendLE(UInt32(6)); out.appendLE(UInt32(68)) }
            for r in 0..<29 { out.appendLE(f.x[r]) }
            out.appendLE(f.x[29])
            out.appendLE(f.x[30])
            out.appendLE(f.spEL0)
            out.appendLE(f.elr)
            out.appendLE(UInt32(truncatingIfNeeded: f.spsr))
            out.appendLE(UInt32(0))
        }
        guard (try? memory.write(va: a[2], bytes: out)) != nil,
              (try? memory.write(va: a[3], bytes: le32(needed))) != nil else { return (MachKern.invalidAddress, "") }
        return (MachKern.success, " [thread \(thread.threadID) pc \(hx(f.elr))]")
    }
}
