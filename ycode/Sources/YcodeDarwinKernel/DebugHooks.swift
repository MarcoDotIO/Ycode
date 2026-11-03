import Foundation
import YcodeDarwinABI

// The kernel's side of Ycode's debug stub (`specs/simulator/debug-stub.md`
// §5). A debugger attached to an image takes the exceptions a debugger
// handles on Darwin (breakpoint instructions, single steps, faults) instead
// of the process ending, and stops and resumes threads with the Mach
// suspension machinery (`threads-and-events.md` §1.6): each thread has a
// debugger hold that closes its run gate like a suspend count, separate
// from the counts the program itself changes with `thread_suspend` and
// `task_suspend`.
//
// Everything here takes the kernel lock (L0) itself, except
// `debugException`, which runs inside a trap that holds it.

/// What the debugger was told about a thread's stop.
public struct KernelDebugStop: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A `brk` instruction (the debugger's or the program's).
        case breakpoint(immediate: UInt16)
        /// A single step finished.
        case step
        /// A hardware watchpoint matched an access at `address` (FAR_EL1;
        /// `write`: ESR_EL1.ISS.WnR). The access has not happened yet.
        case watchpoint(address: UInt64, write: Bool)
        /// Another exception (fault, undefined instruction, ...); the
        /// signal it raises on Darwin.
        case fault(signal: Int32, description: String)
    }
    public var kind: Kind
    /// The PC the thread stopped at.
    public var pc: UInt64
}

/// What the debugger does with an exception.
public enum KernelDebugDecision: Equatable, Sendable {
    /// The thread and every other thread of the image stop; the thread
    /// resumes from its frame as the debugger leaves it.
    case stop
    /// The thread runs the instruction again at once (a breakpoint the
    /// debugger removed while the thread was on its way into the trap).
    case retry
    /// The exception takes its normal course (a fault ends the process).
    case decline
}

/// The debugger an image reports to (ycode-simd's stub).
public protocol KernelDebugger: AnyObject {
    /// Thread `thread` took a debug-relevant exception; `stop` says which.
    /// Called inside the thread's trap with the kernel lock held: record it
    /// and return at once.
    func kernelDebugException(_ kernel: DarwinKernel, thread: ThreadContext, stop: KernelDebugStop) -> KernelDebugDecision
}

extension DarwinKernel {
    // MARK: The trap path

    /// A non-SVC trap of the current thread while a debugger may be
    /// attached: `.resume` when the debugger takes it, nil otherwise. Lock held.
    func debugException(_ frame: inout TrapFrame) -> Outcome? {
        let syndrome = frame.syndrome
        guard let hook = debugHook else {
            // A step or watchpoint trap left over from a detach: nothing to report.
            return syndrome.exceptionClass == .softwareStepLowerEL || syndrome.exceptionClass == .watchpointLowerEL ? .resume : nil
        }
        let t = current
        let stop: KernelDebugStop
        switch syndrome.exceptionClass {
        case .brk?:
            stop = KernelDebugStop(kind: .breakpoint(immediate: UInt16(truncatingIfNeeded: frame.esr & 0xFFFF)), pc: frame.elr)
        case .softwareStepLowerEL?:
            stop = KernelDebugStop(kind: .step, pc: frame.elr)
        case .watchpointLowerEL?:
            stop = KernelDebugStop(kind: .watchpoint(address: frame.far, write: frame.esr & (1 << 6) != 0), pc: frame.elr)
        default:
            if t.debugDeliversFault {
                // Resumed with the fault's signal: the fault ends the process.
                t.debugDeliversFault = false
                return nil
            }
            stop = KernelDebugStop(kind: .fault(signal: Self.faultSignal(frame), description: Self.faultDescription(frame)), pc: frame.elr)
        }
        switch hook.kernelDebugException(self, thread: t, stop: stop) {
        case .decline: return nil
        case .retry: return .resume
        case .stop:
            t.debugStop = stop
            holdAllForDebugger()
            return .resume
        }
    }

    /// `notifyMonitorOfImageListChanges` while a debugger is attached: the
    /// trap returns into the `notification` function of the image list
    /// (`dyld_all_image_infos` +16, the host page's `ret` stub) as the call
    /// `notification(mode, count, dyld_image_info[count])` a host dyld
    /// makes (mode 0 adding, 1 removing; `mach-o/dyld_images.h`), with the
    /// caller's return address in x30. The debugger's breakpoint there
    /// sees the change. The array (24-byte entries, mod date 0) is built
    /// below the thread's red zone. False when nothing could be set up (the
    /// call then just returns). Lock held.
    func debuggerImageNotification(_ frame: inout TrapFrame, unloading: Bool, count: Int, addresses: UInt64, paths: UInt64,
                                   _ mem: any KernelGuestMemory) -> Bool {
        guard let notify = try? readU64(allImageInfosAddress + UInt64(DyldAllImageInfos.Offset.notification), mem), notify != 0 else {
            return false
        }
        let n = min(count, 1 << 14)
        guard let loads = try? mem.read(va: addresses, count: 8 * n), let names = try? mem.read(va: paths, count: 8 * n) else { return false }
        var entries: [UInt8] = []
        entries.reserveCapacity(24 * n)
        for i in 0..<n {
            entries.appendLE(loads.readLE(UInt64.self, at: 8 * i))
            entries.appendLE(names.readLE(UInt64.self, at: 8 * i))
            entries.appendLE(UInt64(0))
        }
        // Below the 128-byte red zone of the Apple arm64 ABI, 16-byte aligned.
        let array = (frame.spEL0 &- 128 &- UInt64(entries.count)) & ~UInt64(15)
        guard (try? mem.write(va: array, bytes: entries)) != nil else { return false }
        frame.x[0] = unloading ? 1 : 0
        frame.x[1] = UInt64(n)
        frame.x[2] = array
        frame.carry = false
        frame.elr = notify
        return true
    }

    /// `dyld_sim` called its "main called" notification (libdyld's state is
    /// "program running").
    public var debugDyldMainCalled: Bool { lock.withLock { dyldMainCalled } }

    /// A short text for a fault, as a debugger shows it.
    static func faultDescription(_ frame: TrapFrame) -> String {
        let s = frame.syndrome
        let what = s.exceptionClass.map { "\($0)" } ?? "ESR \(hx(s.raw))"
        switch s.exceptionClass {
        case .dataAbortLowerEL?, .instructionAbortLowerEL?:
            return "\(Signal.name(faultSignal(frame))): \(what) at address \(hx(frame.far))"
        default:
            return "\(Signal.name(faultSignal(frame))): \(what)"
        }
    }

    /// Holds every live thread (a debug stop). Lock held.
    private func holdAllForDebugger() {
        debugAllHeld = true
        for t in threadsByPort.values where t.isAlive {
            t.debugHold = true
            refreshGate(t)
        }
    }

    // MARK: Attach and detach (lock taken)

    /// Attaches `debugger`, holding every thread; false when another
    /// debugger is attached or the image is ending.
    public func debugAttach(_ debugger: any KernelDebugger) -> Bool {
        lock.withLock {
            guard debugHook == nil, !isTerminating else { return false }
            debugHook = debugger
            for t in threadsByPort.values { t.debugStop = nil }
            holdAllForDebugger()
            return true
        }
    }

    /// Detaches: every hold is released and the threads run on (a pending
    /// step is dropped).
    public func debugDetach() {
        lock.withLock {
            debugHook = nil
            debugAllHeld = false
            for t in threadsByPort.values {
                t.debugStop = nil
                t.debugDeliversFault = false
                t.gate.cancelStep()
                if t.debugHold {
                    t.debugHold = false
                    if t.isAlive { refreshGate(t) }
                }
            }
        }
    }

    /// True while `debugger` is this image's debugger.
    public func isDebugged(by debugger: any KernelDebugger) -> Bool {
        lock.withLock { debugHook === debugger }
    }

    /// Holds every thread (an interrupt).
    public func debugStopAll() {
        lock.withLock { holdAllForDebugger() }
    }

    /// One thread's resume in `debugResume`.
    public enum DebugResume: Equatable, Sendable {
        case stay
        case run(deliverSignal: Bool)
        case step
    }

    /// Resumes threads: each thread's action by its id, else `others`.
    /// Stop reasons are cleared; a step runs one instruction and stops.
    public func debugResume(_ actions: [UInt64: DebugResume], others: DebugResume) {
        lock.withLock {
            debugAllHeld = false
            for t in threadsByPort.values where t.isAlive {
                let action = actions[t.threadID] ?? others
                t.debugStop = nil
                t.debugDeliversFault = false
                switch action {
                case .stay:
                    t.debugHold = true
                case let .run(deliver):
                    t.debugDeliversFault = deliver
                    t.debugHold = false
                case .step:
                    t.gate.requestStep()
                    t.debugHold = false
                }
                refreshGate(t)
            }
        }
    }

    /// Asks every thread's next return through the shim to flush the TLB
    /// (the debugger wrote code, which may have moved a page).
    public func debugRequestFlush() {
        lock.withLock { for t in threadsByPort.values where t.isAlive { t.gate.requestFlush() } }
    }

    // MARK: State (lock taken)

    /// The live threads, ordered by thread id (the main thread first).
    public var debugThreads: [ThreadContext] {
        lock.withLock { threadsByPort.values.filter(\.isAlive).sorted { $0.threadID < $1.threadID } }
    }

    /// True when every held thread runs no guest code (parked, in the
    /// kernel, not on a vCPU), and each thread with a stop to report has
    /// reached its gate (its registers are then the parked ones, which a
    /// register write changes in place), or the image is ending.
    public func debugAllStopped() -> Bool {
        lock.withLock {
            isTerminating || threadsByPort.values.allSatisfy { t in
                guard t.isAlive, t.debugHold else { return true }
                guard isStopped(t) else { return false }
                return t.debugStop == nil || t.gate.parked != nil || !t.gate.attached.load(ordering: .acquiring)
            }
        }
    }

    /// Kicks the vCPUs of held threads that still run guest code (a kick
    /// that found a vCPU in the shim is lost; call again).
    public func debugKickRunning() {
        lock.withLock {
            for t in threadsByPort.values where t.isAlive && t.debugHold && !isStopped(t) { threadHost?.kickThread(t) }
        }
    }

    /// The user registers of a stopped thread: where it parked, the entry
    /// of the trap it is in, or its start state.
    public func debugRegisters(_ t: ThreadContext) -> TrapFrame? {
        lock.withLock {
            if let (frame, _) = t.gate.parked { return frame }
            if let entry = t.entryFrame { return entry }
            if let start = t.suspendedStart {
                var f = TrapFrame()
                for (i, v) in start.x.prefix(TrapFrame.registerCount).enumerated() { f.x[i] = v }
                f.elr = start.pc
                f.spEL0 = start.sp
                return f
            }
            return nil
        }
    }

    /// Gives a stopped thread new user registers (x0–x30, sp, pc, NZCV).
    public func debugSetRegisters(_ t: ThreadContext, _ frame: TrapFrame) -> Bool {
        lock.withLock { isStopped(t) && applyThreadState(frame, to: t) != nil }
    }

    /// `t` is parked at its gate (its registers are the parked ones).
    public func debugIsParked(_ t: ThreadContext) -> Bool { lock.withLock { t.gate.parked != nil } }

    /// The stop the debugger was told about for `t`.
    public func debugStopOf(_ t: ThreadContext) -> KernelDebugStop? { lock.withLock { t.debugStop } }

    /// How the image ended: the wait status word (`processes.md` §2.3);
    /// nil while it runs.
    public var debugTerminationStatus: Int32? {
        lock.withLock { termination.map { waitStatus(for: $0).status } }
    }

    /// Runs `body` with the kernel lock held (the debugger's changes of the
    /// address space, ordered with the image's own mmap calls).
    public func debugLocked<T>(_ body: () throws -> T) rethrows -> T { try lock.withLock(body) }

    /// The parent's pid (1 when the record is gone).
    public var debugParentPID: Int32 { lock.withLock { processRecord?.ppid ?? 1 } }

    /// Ends the process with SIGKILL.
    public func debugKill() {
        lock.withLock { postSignal(Signal.sigkill) }
    }
}
