import Foundation
import YcodeDarwinABI

// Mach thread and task suspension (`specs/simulator/threads-and-events.md`
// §1.6): `thread_suspend`, `thread_resume`, `thread_abort`,
// `thread_abort_safely`, `thread_set_state`, `task_suspend`, `task_resume`.
// Semantics from the public Mach documentation and xnu's open-source
// `osfmk/kern/thread_act.c` and `task.c` (level 1): counted suspension, a
// resume at count zero fails with KERN_FAILURE, a thread may suspend itself
// (it stops when it would return to user code), and `thread_suspend` of
// another thread returns only once that thread has stopped.
//
// How a thread stops (§1.6): each thread has a run gate
// (`GuestThreadGate`), closed while its suspend count or its task's is
// above zero. The vCPU host thread that runs it checks the gate before
// every guest entry and at every trap's entry and parks there, publishing
// the thread's user registers. Closing a gate also kicks the thread's vCPU
// out of guest mode (`ThreadHost.kickThread`). A thread blocked or running
// in the kernel counts as stopped: its registers at the trap's entry are
// published (`ThreadContext.entryFrame`), and it parks when the trap ends.
//
// The routines run on the locked path under L0 only (Ycode-private traps
// 0x7963_0020…0x7963_0025, `host-libraries.md` §11.7); they take the port
// lock G only to resolve a port name, and wait for a target to stop with
// every kernel lock released.

extension DarwinKernel.Private {
    /// `thread_suspend(thread)`.
    public static let threadSuspend: UInt32 = 0x7963_0020
    /// `thread_resume(thread)`.
    public static let threadResume: UInt32 = 0x7963_0021
    /// `thread_abort(thread)` (x1 = 0) and `thread_abort_safely(thread)` (x1 = 1).
    public static let threadAbort: UInt32 = 0x7963_0022
    /// `thread_set_state(thread, flavor, state, count)`.
    public static let threadSetState: UInt32 = 0x7963_0023
    /// `task_suspend(task)`.
    public static let taskSuspend: UInt32 = 0x7963_0024
    /// `task_resume(task)`.
    public static let taskResume: UInt32 = 0x7963_0025
}

extension DarwinKernel {
    /// ARM thread-state flavors and counts (public `mach/arm/thread_status.h`).
    enum ARMThreadState {
        static let unified: UInt32 = 1         // ARM_THREAD_STATE
        static let thread64: UInt32 = 6        // ARM_THREAD_STATE64
        static let exception64: UInt32 = 7     // ARM_EXCEPTION_STATE64
        static let unifiedCount: UInt32 = 70   // ARM_UNIFIED_THREAD_STATE_COUNT
        static let thread64Count: UInt32 = 68  // ARM_THREAD_STATE64_COUNT
        static let exception64Count: UInt32 = 4
    }

    /// What `thread_get_state` returns, through the guest library, while a
    /// suspended thread moves from its trap to its gate (a few
    /// microseconds): the library asks again. Never a `kern_return_t`.
    static let threadStateRetry: UInt64 = 0x7963_0000

    // MARK: Gates

    /// Closes or opens `t`'s gate from its suspend count and the task's
    /// (this image's). Closing kicks its vCPU out of guest code. Lock held.
    func refreshGate(_ t: ThreadContext) {
        if t.suspendCount > 0 || taskSuspendCount > 0 {
            if !t.gate.isClosed { t.gate.close() }
            threadHost?.kickThread(t)
        } else if t.gate.isClosed {
            t.gate.open()
        }
    }

    /// True when `t` runs no guest code and will not until its gate opens:
    /// parked at the gate, inside a trap (its registers at the trap's entry
    /// are published), not on a vCPU, gone, or its image is ending.
    func isStopped(_ t: ThreadContext) -> Bool {
        !t.isAlive || isTerminating || !t.gate.attached.load(ordering: .acquiring)
            || t.entryFrame != nil || t.gate.parked != nil
    }

    /// Waits with every kernel lock released until each thread of
    /// `targets` (with the image it belongs to) is stopped or its gate was
    /// opened meanwhile. The vCPUs are kicked again every millisecond (a
    /// kick that found the thread in the shim, or between two runs, is
    /// lost). L0 held at depth 1 (the private-trap path).
    func waitUntilStopped(_ targets: [(ThreadContext, DarwinKernel)]) {
        let began = GuestThreadGate.now()
        var rounds = 0
        var reported = false
        while !isTerminating {
            let pending = targets.filter { t, k in t.gate.isClosed && !k.isStopped(t) }
            guard let first = pending.first else { return }
            if rounds > 0 { for (t, k) in pending { k.threadHost?.kickThread(t) } }
            rounds += 1
            lock.unlocked { _ = first.0.gate.waitUntilParked(deadline: GuestThreadGate.now() + 1_000_000) }
            if !reported, GuestThreadGate.now() &- began > 2_000_000_000 {
                reported = true
                log("note: thread_suspend: \(pending.count) thread(s) not stopped after 2 s "
                    + pending.map { "\($0.1.pid)/\($0.0.threadID)" }.joined(separator: " ") + "; still waiting")
            }
        }
    }

    // MARK: Port lookups

    /// The thread a send right of the caller's space stands for, in any
    /// image, or the `kern_return_t` the routine fails with. L0 held.
    func lookupThread(named name: UInt32) -> Result<(ThreadContext, DarwinKernel), KernError> {
        guard let ipc = machIPC as? MachIPC else { return .failure(KernError(MachKern.failure)) }
        return withPorts {
            guard let (port, object) = ipc.kernelObject(named: name) else {
                return .failure(KernError(MachMsgReturn.sendInvalidDest))
            }
            guard case .thread = object else { return .failure(KernError(MachKern.invalidArgument)) }
            guard port.active, let owner = port.task, let k = owner.kernel,
                  let t = k.threadsByPort.values.first(where: { owner.kernelObject(named: $0.portName)?.0 === port }),
                  t.isAlive else {
                return .failure(KernError(UInt32(KernReturn.terminated)))
            }
            return .success((t, k))
        }
    }

    /// The image a task control (or read) port of the caller's space stands
    /// for, or the `kern_return_t` the routine fails with. L0 held.
    func lookupTaskImage(named name: UInt32) -> Result<DarwinKernel, KernError> {
        guard let ipc = machIPC as? MachIPC else { return .failure(KernError(MachKern.failure)) }
        return withPorts {
            guard let (port, object) = ipc.kernelObject(named: name) else {
                return .failure(KernError(MachMsgReturn.sendInvalidDest))
            }
            guard object == .task || object == .taskRead else { return .failure(KernError(MachKern.invalidArgument)) }
            guard port.active, let task = port.task, !task.isTerminated, let k = task.kernel, !k.isTerminating else {
                return .failure(KernError(MachMsgReturn.sendInvalidDest))
            }
            return .success(k)
        }
    }

    // MARK: The routines

    /// The private traps 0x7963_0020…0x7963_0025. Lock held.
    func handleThreadControl(_ number: UInt32, _ frame: inout TrapFrame, _ mem: any KernelGuestMemory) -> Outcome {
        let a = frame.x.prefixArray(4)
        let name = UInt32(truncatingIfNeeded: a[0])
        var call = CallText(tracing)
        func kr(_ value: UInt64, _ extra: String = "") -> Outcome {
            frame.x[0] = value
            frame.carry = false
            trace("trap yc \(hx(number & 0xFFFF)) \(call) -> \(KernReturn.name(value))\(extra)")
            return .resume
        }
        switch number {
        case Private.threadSuspend:
            call.set("thread_suspend(\(hx(name)))")
            switch lookupThread(named: name) {
            case let .failure(e): return kr(UInt64(e.code))
            case let .success((t, k)):
                t.suspendCount += 1
                k.refreshGate(t)
                if t !== current { waitUntilStopped([(t, k)]) }
                return kr(KernReturn.success, " [thread \(k.pid)/\(t.threadID) count \(t.suspendCount)]")
            }

        case Private.threadResume:
            call.set("thread_resume(\(hx(name)))")
            switch lookupThread(named: name) {
            case let .failure(e): return kr(UInt64(e.code))
            case let .success((t, k)):
                guard t.suspendCount > 0 else { return kr(KernReturn.failure, " [not suspended]") }
                t.suspendCount -= 1
                k.refreshGate(t)
                if t.suspendCount == 0, let start = t.suspendedStart {
                    // PTHREAD_START_SUSPENDED: the thread starts now (its
                    // gate stays closed while the task is suspended).
                    guard let host = k.threadHost, let index = try? host.startThread(start, context: t) else {
                        t.suspendCount = 1
                        return kr(KernReturn.failure, " [cannot start]")
                    }
                    t.vcpuIndex = index
                    t.suspendedStart = nil
                    return kr(KernReturn.success, " [thread \(k.pid)/\(t.threadID) started]")
                }
                return kr(KernReturn.success, " [thread \(k.pid)/\(t.threadID) count \(t.suspendCount)]")
            }

        case Private.threadAbort:
            let safely = a[1] != 0
            call.set("\(safely ? "thread_abort_safely" : "thread_abort")(\(hx(name)))")
            switch lookupThread(named: name) {
            case let .failure(e): return kr(UInt64(e.code))
            case let .success((t, k)):
                // A thread waiting in the kernel returns from its call as
                // interrupted (the library restarts what it restarts after
                // a signal); one in guest code is not affected.
                let woke = t === current ? false : k.lock.interrupt(t)
                return kr(KernReturn.success, woke ? " [wait interrupted]" : "")
            }

        case Private.threadSetState:
            let flavor = UInt32(truncatingIfNeeded: a[1]), count = UInt32(truncatingIfNeeded: a[3])
            call.set("thread_set_state(\(hx(name)), flavor=\(flavor), state=\(hx(a[2])), count=\(count))")
            switch lookupThread(named: name) {
            case let .failure(e): return kr(UInt64(e.code))
            case let .success((t, k)):
                let parsed = Self.parseThreadState(flavor: flavor, count: count, address: a[2], memory: mem)
                switch parsed {
                case let .failure(e): return kr(UInt64(e.code))
                case .success(nil): return kr(KernReturn.success, " [no effect]")
                case let .success(state?):
                    if t === current {
                        // The caller's own state: it continues there (x0 is
                        // this call's result).
                        frame.takeUserState(of: state)
                        return kr(KernReturn.success, " [own state, pc \(hx(state.elr))]")
                    }
                    // Another thread: held while its state is changed
                    // (xnu thread_set_state: hold, stop, set, release).
                    t.suspendCount += 1
                    k.refreshGate(t)
                    waitUntilStopped([(t, k)])
                    let how = k.applyThreadState(state, to: t)
                    t.suspendCount -= 1
                    k.refreshGate(t)
                    guard let how else { return kr(KernReturn.failure, " [thread not running]") }
                    return kr(KernReturn.success, " [thread \(k.pid)/\(t.threadID) \(how)]")
                }
            }

        case Private.taskSuspend:
            call.set("task_suspend(\(hx(name)))")
            switch lookupTaskImage(named: name) {
            case let .failure(e): return kr(UInt64(e.code))
            case let .success(k):
                k.taskSuspendCount += 1
                let threads = k.threadsByPort.values.filter(\.isAlive)
                for t in threads { k.refreshGate(t) }
                // xnu task_suspend waits for every thread but the caller.
                waitUntilStopped(threads.filter { $0 !== current }.map { ($0, k) })
                return kr(KernReturn.success, " [pid \(k.pid) count \(k.taskSuspendCount)]")
            }

        case Private.taskResume:
            call.set("task_resume(\(hx(name)))")
            switch lookupTaskImage(named: name) {
            case let .failure(e): return kr(UInt64(e.code))
            case let .success(k):
                guard k.taskSuspendCount > 0 else { return kr(KernReturn.failure, " [not suspended]") }
                k.taskResumed()
                return kr(KernReturn.success, " [pid \(k.pid) count \(k.taskSuspendCount)]")
            }

        default:
            return kr(KernReturn.failure)
        }
    }

    /// One `task_resume` (or the SIGCONT of a start-suspended process) of
    /// this image: the count goes down by one; at zero every thread may run
    /// and a main thread that waited for it starts. Lock held.
    func taskResumed() {
        guard taskSuspendCount > 0 else { return }
        taskSuspendCount -= 1
        guard taskSuspendCount == 0 else { return }
        for t in threadsByPort.values where t.isAlive { refreshGate(t) }
        if mainStartPending {
            mainStartPending = false
            if let p = processRecord {
                if p.state == .stopped { p.state = .running }
                p.image?.resume()
            }
        }
    }

    /// Marks this image as started suspended (POSIX_SPAWN_START_SUSPENDED):
    /// its task is suspended once and its main thread starts when the count
    /// reaches zero (`task_resume`, SIGCONT). Lock held.
    func startedSuspended() {
        taskSuspendCount += 1
        mainStartPending = true
    }

    /// Gives a stopped thread new user registers. Returns how, or nil when
    /// the thread cannot take them (not on a vCPU and not created
    /// suspended). Lock held, `t` stopped.
    func applyThreadState(_ state: TrapFrame, to t: ThreadContext) -> String? {
        if t.gate.modifyParked({ $0.takeUserState(of: state) }) { return "parked thread changed" }
        if t.gate.attached.load(ordering: .acquiring) {
            // In a trap (or between its trap and its gate): the registers
            // replace its state when the trap ends; x0, x1 and carry keep
            // the trap's results (as xnu's syscall return writes them).
            t.gate.setReplacement(state)
            return "applied at the end of its trap"
        }
        if var start = t.suspendedStart {
            start.x = Array(state.x)
            start.pc = state.elr
            start.sp = state.spEL0
            t.suspendedStart = start
            return "start state changed"
        }
        return nil
    }

    /// Decodes a thread state for `thread_set_state`: `.success(nil)` for a
    /// flavor that is accepted with no effect (ARM_EXCEPTION_STATE64).
    static func parseThreadState(flavor: UInt32, count: UInt32, address: UInt64,
                                 memory: any KernelGuestMemory) -> Result<TrapFrame?, KernError> {
        var skip = 0
        switch flavor {
        case ARMThreadState.unified:
            guard count == ARMThreadState.unifiedCount else { return .failure(KernError(MachKern.invalidArgument)) }
            skip = 8
        case ARMThreadState.thread64:
            guard count == ARMThreadState.thread64Count else { return .failure(KernError(MachKern.invalidArgument)) }
        case ARMThreadState.exception64:
            guard count == ARMThreadState.exception64Count else { return .failure(KernError(MachKern.invalidArgument)) }
            return .success(nil)
        default:
            return .failure(KernError(MachKern.invalidArgument))
        }
        guard let bytes = try? memory.read(va: address, count: Int(count) * 4) else {
            return .failure(KernError(MachKern.invalidAddress))
        }
        if skip > 0 {
            // The unified form names its flavor and count first.
            guard bytes.readLE(UInt32.self, at: 0) == ARMThreadState.thread64,
                  bytes.readLE(UInt32.self, at: 4) == ARMThreadState.thread64Count else {
                return .failure(KernError(MachKern.invalidArgument))
            }
        }
        var f = TrapFrame()
        for r in 0..<29 { f.x[r] = bytes.readLE(UInt64.self, at: skip + 8 * r) }
        f.x[29] = bytes.readLE(UInt64.self, at: skip + 8 * 29)   // fp
        f.x[30] = bytes.readLE(UInt64.self, at: skip + 8 * 30)   // lr
        f.spEL0 = bytes.readLE(UInt64.self, at: skip + 8 * 31)
        f.elr = bytes.readLE(UInt64.self, at: skip + 8 * 32)
        f.spsr = UInt64(bytes.readLE(UInt32.self, at: skip + 8 * 33))
        return .success(f)
    }
}
