import Foundation
import Synchronization
import YcodeDarwinABI

// The fast paths of the lock split (`specs/simulator/mach-ipc-locking.md`
// §4.3): IPC traps that run with the IPC gate held for reading and the fine
// locks of the state they touch, not the kernel lock L0.
//
// | Trap | Locks |
// |---|---|
// | `mach_msg_trap` (−31), `mach_msg_overwrite_trap` (−32), `mach_msg2_trap` (−47) | the port lock G |
// | `kevent_id` (375) on a workloop, `kevent_qos` (374) on the workqueue kqueue, `workq_kernreturn` (368) | the image's event lock L_P; G inside for each Mach receive |
// | the port routine traps (−16 … −29 but −17, −40 … −42, −50, −70, −72, −76, −77) | the port lock G (`mach-ipc-locking.md` §4.10) |
//
// The kevent calls fall back when a change names a filter other than
// EVFILT_MACHPORT, EVFILT_WORKLOOP, EVFILT_USER or EVFILT_TIMER (the others
// register with descriptors or processes, which are L0 state);
// `workq_kernreturn` falls back for operations other than the thread
// returns, thread requests and SHOULD_NARROW.
//
// A fast path falls back (returns nil, having changed nothing) when the
// image traces, is ending, the thread is not bound to it, or a send's
// destination is a kernel-object port (served by kernel code that uses BSD
// and process state). Work it cannot do under these locks is deferred
// (`KernelThreadLocks.deferred`) and runs before the trap returns or sleeps.

extension DarwinKernel {
    /// `YCODE_IPC_FAST=0` keeps every trap on L0 even with the split on.
    nonisolated(unsafe) public static var ipcFastTrapsEnabled = getenv("YCODE_IPC_FAST").map { String(cString: $0) != "0" } ?? true

    /// Tests (`YCODE_IPC_LOCKS_TESTS=1`): the fast paths also run for a
    /// traced image (they write no trace text).
    nonisolated(unsafe) public static var fastPathsWhileTracing = DarwinSystem.splitForTests

    /// True for a trap number (`x16` as Int32) that `handleIPCFast` may serve.
    public static func isIPCFastTrap(_ number: Int32) -> Bool {
        switch number {
        case -47, -31, -32, 368, 374, 375: true
        default: portRoutineFastEnabled && (isPortRoutineFastTrap(number) || routineFastLocks(number) != nil)
        }
    }

    /// `YCODE_PORT_ROUTINES_FAST=0` keeps the port routine traps on L0
    /// (`mach-ipc-locking.md` §4.10).
    nonisolated(unsafe) public static var portRoutineFastEnabled =
        getenv("YCODE_PORT_ROUTINES_FAST").map { String(cString: $0) != "0" } ?? true

    /// The Mach port routine traps that touch only Mach state (spaces, ports,
    /// port sets, requests), all of it guarded by the port lock G: allocate,
    /// deallocate, mod_refs, move_member, insert_right, insert/extract_member,
    /// construct, destruct, mach_reply_port, thread/task/host_self,
    /// get_attributes, guard, unguard, thread_get_special_reply_port, the
    /// voucher traps, mach_port_type, request_notification. Not the
    /// pid-to-task traps (−44 … −46: the process table).
    @inline(__always) static func isPortRoutineFastTrap(_ number: Int32) -> Bool {
        switch number {
        case -16, -18, -19, -20, -21, -22, -23, -24, -25, -26, -27, -28, -29, -40, -41, -42, -50, -70, -72, -76, -77: true
        default: false
        }
    }

    /// The Ycode-private Mach routines on the fast path and the locks they
    /// take (`mach-ipc-locking.md` §4.10): G for the memory-entry and VM-map
    /// routines (their address-space work runs with G released, §4.2) and the
    /// port context; the event lock, then G, for the two that read the
    /// thread table (`thread_get_state`, `task_threads`). Nil: not one.
    enum RoutineLocks { case ports, eventsAndPorts }
    @inline(__always) static func routineFastLocks(_ number: Int32) -> RoutineLocks? {
        switch UInt32(bitPattern: number) {
        case MachIPC.Routine.makeMemoryEntry, MachIPC.Routine.vmMapObject, MachIPC.Routine.vmRemap,
             MachIPC.Routine.portGetContext, MachIPC.Routine.portSetContext: .ports
        case MachIPC.Routine.threadGetState, MachIPC.Routine.taskThreads: .eventsAndPorts
        default: nil
        }
    }

    /// Diagnostics: port routine traps served on the fast path.
    public static let portRoutineFastServed = Atomic<UInt64>(0)

    /// Diagnostics: traps served by a fast path, and fast traps that fell
    /// back to the locked path, since the process started.
    public static let ipcFastServed = Atomic<UInt64>(0)
    /// Diagnostics: fast IPC traps that fell back to the locked path.
    public static let ipcFastDeclined = Atomic<UInt64>(0)
    /// Fallbacks by reason: the image has descriptor knotes; a kevent change
    /// or workqueue operation the fast path does not take; a kernel-object
    /// destination.
    public static let ipcFastDeclinedDescriptors = Atomic<UInt64>(0)
    /// Diagnostics: fallbacks for a kevent change or workqueue operation the fast path does not take.
    public static let ipcFastDeclinedCall = Atomic<UInt64>(0)
    /// Diagnostics: fallbacks for a kernel-object destination.
    public static let ipcFastDeclinedKernelObject = Atomic<UInt64>(0)

    /// Diagnostics (`YCODE_DEBUG_DESCRIPTOR_CANDIDATES=1`): for each kevent
    /// or workqueue trap declined because the image has descriptor knotes,
    /// whether any of them could be reported now (active and enabled), by
    /// program.
    static let debugDescriptorCandidates = getenv("YCODE_DEBUG_DESCRIPTOR_CANDIDATES").map { String(cString: $0) == "1" } ?? false
    static let descriptorDeclines = Mutex<[String: (declined: UInt64, withCandidate: UInt64)]>([:])

    private func noteDescriptorDecline(_ events: KernelLock) {
        let candidate = events.withLock { () -> Bool in
            allKQueues.contains { kq in
                kq.descriptorKnotes > 0 && kq.knotes.contains {
                    EVFilter.isReadiness($0.filter) && !$0.dropped && $0.active && !$0.suppressed
                        && ($0.enabled || $0.syntheticDelete)
                }
            }
        }
        let name = executableHostPath.map { String($0.split(separator: "/").last ?? "?") } ?? "pid \(pid)"
        Self.descriptorDeclines.withLock {
            var e = $0[name] ?? (0, 0)
            e.declined &+= 1
            if candidate { e.withCandidate &+= 1 }
            $0[name] = e
        }
    }

    /// One line for the split report.
    static var descriptorDeclineReport: String {
        guard debugDescriptorCandidates else { return "" }
        return "descriptor-knote declines by program (declined/with a reportable descriptor knote): "
            + descriptorDeclines.withLock { $0 }.sorted { $0.value.declined > $1.value.declined }.prefix(20)
            .map { "\($0.key) \($0.value.declined)/\($0.value.withCandidate)" }.joined(separator: ", ")
    }

    /// Filters a fast kevent change may name.
    static let fastKEventFilters: Set<Int16> = [EVFilter.machport, EVFilter.workloop, EVFilter.user, EVFilter.timer]

    /// True when this image runs with the lock split (its fast paths exist).
    public var hasIPCFastPaths: Bool { eventLock != nil && Self.ipcFastTrapsEnabled }

    /// Handles an IPC trap on its fast path, or returns nil when the caller
    /// must take the locked path. Call from the trapping thread's host
    /// thread with no kernel lock held.
    public func handleIPCFast(_ frame: inout TrapFrame, context: ThreadContext, memory: any KernelGuestMemory) -> Outcome? {
        guard let events = eventLock, Self.ipcFastTrapsEnabled, !tracing || Self.fastPathsWhileTracing, frame.trapKind == .svc,
              frame.x.count >= TrapFrame.registerCount, context.kernel === self, !isTerminating,
              let ipc = machIPC as? MachIPC else { return nil }
        let number = Int32(truncatingIfNeeded: frame.x[16])
        guard Self.isIPCFastTrap(number) else { return nil }
        // Only from a thread that holds no kernel lock (the VMM's trap entry).
        let threadLocks = KernelThreadLocks.current
        guard threadLocks.held.isEmpty, !threadLocks.isFast else { return nil }
        // The port routines write their trace lines only on the locked path
        // (the tests trace some images).
        if tracing, Self.isPortRoutineFastTrap(number) || Self.routineFastLocks(number) != nil { return nil }
        // Descriptor readiness is L0 state (`mach-ipc-locking.md` §4.3).
        if number >= 0, number < 1000, !Self.descriptorEscalation, descriptorKnoteCount.load(ordering: .relaxed) > 0 {
            Self.ipcFastDeclined.wrappingAdd(1, ordering: .relaxed)
            Self.ipcFastDeclinedDescriptors.wrappingAdd(1, ordering: .relaxed)
            if Self.debugDescriptorCandidates { noteDescriptorDecline(events) }
            return nil
        }
        let generation = memory.tlbGeneration
        let profile = lock.trapProfile
        let start = profile != nil ? KernelClock.now() : 0
        var outcome: Outcome?
        defer {
            if let profile, outcome != nil {
                profile.noteHandler(TrapProfile.filtered(Int64(number), kernel: self), KernelClock.now() &- start)
            }
        }
        lock.withFastPath(context: context) {
            guard !isTerminating else { return }
            context.entryFrame = frame
            defer { context.entryFrame = nil }
            if let locks = Self.routineFastLocks(number) {
                // A private routine (§4.10). The thread-table readers take the
                // event lock first (the table changes only with L0 and it
                // held, so it is enough to read the table); a target's entry
                // frame has its own lock (§4.2).
                if locks == .eventsAndPorts {
                    events.withLock(context: context) {
                        outcome = ipc.handleFastPortRoutine(Int(number), &frame, context: context, memory: memory)
                    }
                } else {
                    outcome = ipc.handleFastPortRoutine(Int(number), &frame, context: context, memory: memory)
                }
                Self.portRoutineFastServed.wrappingAdd(1, ordering: .relaxed)
                return
            }
            if number < 0, Self.isPortRoutineFastTrap(number) {
                // Mach state only: the port lock (§4.10). What needs L0 (a
                // dying port's payload, a class refresh) or an event lock
                // (EVFILT_MACHPORT hooks) is deferred work, as for mach_msg.
                outcome = ipc.handleFastPortRoutine(Int(number), &frame, context: context, memory: memory)
                Self.portRoutineFastServed.wrappingAdd(1, ordering: .relaxed)
                return
            }
            if number < 0 {
                // Mach state only: the port lock (the blocking observer's
                // workqueue work is deferred to the event lock, §4.5).
                outcome = ipc.handleFastMachMsg(Int(number), &frame, context: context, memory: memory)
                if outcome == nil { Self.ipcFastDeclinedKernelObject.wrappingAdd(1, ordering: .relaxed) }
                return
            }
            events.withLock(context: context) {
                do {
                    let a = frame.x.prefixArray(8)
                    guard fastEventCallAllowed(number, a, memory) else {
                        Self.ipcFastDeclinedCall.wrappingAdd(1, ordering: .relaxed)
                        return
                    }
                    outcome = handleFastEventCall(Int(number), a, &frame, memory)
                }
            }
        }
        if outcome != nil, memory.tlbGeneration != generation { frame.requestTLBInvalidation(memory.tlbRange(since: generation)) }
        if outcome != nil {
            Self.ipcFastServed.wrappingAdd(1, ordering: .relaxed)
        } else {
            Self.ipcFastDeclined.wrappingAdd(1, ordering: .relaxed)
        }
        // The fast traps answer in registers and always resume.
        precondition(outcome == nil || outcome == .resume, "IPC fast path ended with \(String(describing: outcome))")
        return outcome
    }
}

extension DarwinKernel {
    /// Runs `body` holding this image's event lock (with the split; it guards
    /// the kevent engine and the workqueue). Re-entrant.
    @inline(__always) func withEvents<T>(_ body: () throws -> T) rethrows -> T {
        guard let events = eventLock else { return try body() }
        return try events.withLock(body)
    }

    /// Runs `body` holding the system's port lock (with the split; it guards
    /// every Mach space and port). Re-entrant.
    @inline(__always) func withPorts<T>(_ body: () throws -> T) rethrows -> T {
        guard let ports = system.mach.portLock else { return try body() }
        return try ports.withLock(body)
    }

    /// True when the kevent or workqueue call may run on the fast path
    /// (reads its arguments and change list only).
    func fastEventCallAllowed(_ n: Int32, _ a: [UInt64], _ mem: any KernelGuestMemory) -> Bool {
        // Descriptor readiness is L0 state (`mach-ipc-locking.md` §4.3); with
        // the escalation a scan takes L0 when it needs it (§4.11).
        guard Self.descriptorEscalation || descriptorKnoteCount.load(ordering: .relaxed) == 0 else { return false }
        let flags = UInt32(truncatingIfNeeded: a[7])
        switch n {
        case 375:
            guard flags & KEventFlag.workloop != 0, flags & KEventFlag.workq == 0 else { return false }
        case 374:
            guard flags & KEventFlag.workq != 0, flags & KEventFlag.workloop == 0 else { return false }
        case 368:
            switch UInt32(truncatingIfNeeded: a[0]) {
            case WorkqOp.threadReturn, WorkqOp.reqThreads, WorkqOp.reqThreads2, WorkqOp.shouldNarrow:
                return true
            case WorkqOp.keventReturn, WorkqOp.workloopReturn:
                break
            default:
                return false
            }
        default:
            return false
        }
        let count = Int(Int32(truncatingIfNeeded: a[2]))
        guard count > 0 else { return count == 0 }
        guard count <= 64, let changes = try? readKEvents(a[1], count: count, format: .qos, mem) else { return false }
        return changes.allSatisfy { Self.fastKEventFilters.contains($0.filter) }
    }

    /// The BSD result handling of the locked path (`handleBSD`), for the
    /// fast kevent and workqueue calls (no trace text: the fast path never
    /// runs for a traced image).
    func handleFastEventCall(_ n: Int, _ a: [UInt64], _ frame: inout TrapFrame, _ mem: any KernelGuestMemory) -> Outcome {
        var call = CallText(false)
        do {
            let result: BSDResult = n == BSD2.workqKernreturn ? try workqKernreturn(a, &call, mem)
                : .value(try keventCall(n, a, &call, mem))
            switch result {
            case let .value(v):
                frame.x[0] = v
                frame.x[1] = 0
                frame.carry = false
            case let .values(v0, v1):
                frame.x[0] = v0
                frame.x[1] = v1
                frame.carry = false
            case let .restart(start):
                start.apply(to: &frame)
            default:
                preconditionFailure("fast event call \(n) ended with \(result)")
            }
        } catch {
            frame.x[0] = UInt64(UInt32(bitPattern: errno(of: error, default: Errno.EINVAL)))
            frame.x[1] = 0
            frame.carry = true
        }
        return .resume
    }
}

extension MachIPC {
    /// `mach_msg` / `mach_msg2` on the fast path: the port lock is held for
    /// the trap (its waits give it up). Nil (nothing changed) when a send's
    /// destination is a kernel-object port.
    func handleFastMachMsg(_ n: Int, _ frame: inout TrapFrame, context: ThreadContext,
                           memory: any GuestVirtualMemory) -> TrapOutcome? {
        // Guest memory is this task's own: the send bytes are read before
        // the port lock, the received message written after it.
        let threadLocks = KernelThreadLocks.current
        prefetchSend(n, frame, memory, threadLocks)
        threadLocks.deferReceiveWrite = true
        defer {
            threadLocks.deferReceiveWrite = false
            threadLocks.prefetchedSend = nil
        }
        let outcome = lock.withLock(context: context) { () -> TrapOutcome? in
            guard fastSendAllowed(n, frame, memory) else { return nil }
            return handleTrapLocked(x16: Int64(n), frame: &frame, context: context, memory: memory)
        }
        if let w = threadLocks.pendingReceiveWrite {
            threadLocks.pendingReceiveWrite = nil
            if (try? w.memory.write(va: w.va, bytes: w.bytes)) == nil {
                frame.x[0] = UInt64(MachMsgReturn.rcvInvalidData)
            }
        }
        return outcome
    }

    /// A port routine trap on the fast path (`mach-ipc-locking.md` §4.10):
    /// the locked path's handler under the port lock alone. Never blocks.
    func handleFastPortRoutine(_ n: Int, _ frame: inout TrapFrame, context: ThreadContext,
                               memory: any GuestVirtualMemory) -> TrapOutcome? {
        lock.withLock(context: context) {
            handleTrapLocked(x16: Int64(n), frame: &frame, context: context, memory: memory)
        }
    }

    /// Reads the bytes a fast send will copy in (the same range the trap
    /// reads), before the port lock is taken. Vector sends are not prefetched.
    private func prefetchSend(_ n: Int, _ frame: TrapFrame, _ memory: any GuestVirtualMemory,
                              _ threadLocks: KernelThreadLocks) {
        let options = UInt64(truncatingIfNeeded: frame.x[1])
        guard options & MachMsgOption.sendMsg != 0 else { return }
        let va: UInt64, count: Int
        if n == Trap.machMsg2 {
            guard options & MachMsgOption.msgVector == 0 else { return }
            let bits = UInt32(truncatingIfNeeded: frame.x[2]) & MachMsgBits.user
            let size = Int(UInt32(truncatingIfNeeded: frame.x[2] >> 32))
            let bodyStart = bits & MachMsgBits.complex != 0 ? 28 : 24
            guard size >= bodyStart, size <= Int(MachIPCLimits.maxSendSize) else { return }
            va = frame.x[0] &+ UInt64(bodyStart)
            count = size - bodyStart
        } else {
            let size = Int(UInt32(truncatingIfNeeded: frame.x[2]))
            guard size >= 24, size <= Int(MachIPCLimits.maxSendSize) else { return }
            va = frame.x[0]
            count = size
        }
        if let bytes = try? memory.read(va: va, count: count) { threadLocks.prefetchedSend = (va, bytes) }
    }

    /// The send bytes at `va`: the prefetched copy when it is that range,
    /// else read now. Nil when the memory cannot be read.
    func readSendBytes(_ memory: any GuestVirtualMemory, _ va: UInt64, _ count: Int) -> [UInt8]? {
        if lock.root != nil {
            let threadLocks = KernelThreadLocks.current
            if let p = threadLocks.prefetchedSend, p.va == va, p.bytes.count == count {
                threadLocks.prefetchedSend = nil
                return p.bytes
            }
        }
        return try? memory.read(va: va, count: count)
    }

    /// Writes a received message: at once, or on a fast `mach_msg` after the
    /// port lock is released (its caller then answers
    /// MACH_RCV_INVALID_DATA if the write fails, as this would). True when
    /// written or deferred.
    func writeReceived(_ memory: any GuestVirtualMemory, _ va: UInt64, _ bytes: [UInt8]) -> Bool {
        if lock.root != nil {
            let threadLocks = KernelThreadLocks.current
            if threadLocks.deferReceiveWrite, threadLocks.pendingReceiveWrite == nil {
                threadLocks.pendingReceiveWrite = (memory, va, bytes)
                return true
            }
        }
        return (try? memory.write(va: va, bytes: bytes)) != nil
    }

    /// False when the send's destination name holds a kernel-object port
    /// (the locked path serves it). Reads only; a bad name or header is
    /// answered by the trap itself.
    private func fastSendAllowed(_ n: Int, _ frame: TrapFrame, _ memory: any GuestVirtualMemory) -> Bool {
        let options = UInt64(truncatingIfNeeded: frame.x[1])
        guard options & MachMsgOption.sendMsg != 0 else { return true }
        let remote: UInt32
        if n == Trap.machMsg2 {
            remote = UInt32(truncatingIfNeeded: frame.x[3])
        } else {
            guard let bytes = try? memory.read(va: frame.x[0] + 8, count: 4) else { return true }
            remote = bytes.readLE(UInt32.self, at: 0)
        }
        guard MachPortName.isValid(remote), let i = slot(of: remote), let p = entries[i].port else { return true }
        return !p.isKernelObject
    }
}
