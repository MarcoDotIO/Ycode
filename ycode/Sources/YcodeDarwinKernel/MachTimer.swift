// Mach timer ports: mk_timer_create (-91), mk_timer_destroy (-92),
// mk_timer_arm (-93), mk_timer_cancel (-94), mk_timer_arm_leeway (-95).
// Semantics from xnu osfmk/kern/mk_timer.c and osfmk/mach/mk_timer.h
// (level 1):
// - create: a new port whose receive right goes to the caller (the name is
//   the trap's result; MACH_PORT_NULL on failure); the timer keeps a send
//   right of its own;
// - arm(name, deadline in mach_absolute_time units): the caller must hold
//   the receive right (KERN_INVALID_NAME / KERN_INVALID_RIGHT), the port must
//   be a timer (KERN_INVALID_ARGUMENT). At the deadline (at once if it has
//   passed) the kernel sends one `mk_timer_expire_msg_t`: a 48-byte simple
//   message, remote = the port (COPY_SEND), local 0, id 0, three zero u64s.
//   Re-arming replaces the deadline. The message is preallocated, so while
//   an earlier expiry is still queued no second one is sent;
// - cancel(name, &armed): disarms and writes the armed deadline (0 when not
//   armed); a NULL pointer is allowed;
// - destroy(name): mach_port_destroy of the receive right (receive right
//   and timer port required).
// CoreFoundation's run-loop timers are built on these ("Unable to create
// timer Port" otherwise).

import YcodeDarwinABI

/// The timer behind a timer port. Lock held for every access.
final class MachTimer {
    weak var port: IPCPort?
    /// Host deadline (KernelClock ns) while armed.
    var deadline: UInt64?
    /// The armed deadline in guest mach_absolute_time units.
    var armedTicks: UInt64 = 0

    init(port: IPCPort) { self.port = port }
}

extension MachIPC {
    /// mk_timer_create: a receive right for the caller, the timer's own send right.
    func mkTimerCreate() -> UInt32 {
        let p = newPort()
        guard let name = newEntry(bits: MachPortType.receive, urefs: 0, port: p) else { return 0 }
        p.receiver = self
        p.mkTimer = MachTimer(port: p)
        p.srights += 1
        return name
    }

    /// The timer of a receive right the caller holds, or the trap's error.
    func mkTimer(named name: UInt32) -> Result<MachTimer, KernError> {
        guard MachPortName.isValid(name), let i = lookup(name) else { return .failure(KernError(MachKern.invalidName)) }
        guard entries[i].bits & MachPortType.receive != 0, let p = entries[i].port else {
            return .failure(KernError(MachKern.invalidRight))
        }
        guard let t = p.mkTimer else { return .failure(KernError(MachKern.invalidArgument)) }
        return .success(t)
    }

    /// Sends the expiry message unless one is still queued.
    func mkTimerExpire(_ t: MachTimer) {
        guard let p = t.port, p.active else { return }
        if p.messages.all.contains(where: { $0.isTimerExpiry }) { return }
        p.srights += 1
        var m = KMessage(complex: false, destination: .send(p), destinationType: MachMsgType.portSend,
                         reply: .null, replyType: 0, id: 0)
        m.inline = [UInt8](repeating: 0, count: 24)
        m.fromKernel = true
        m.isTimerExpiry = true
        sendKernelMessage(m)
    }
}

extension DarwinKernel {
    static let mkTimerCreate = -91, mkTimerDestroy = -92, mkTimerArm = -93, mkTimerCancel = -94, mkTimerArmLeeway = -95

    /// The mk_timer traps; nil for other numbers. Lock held.
    func mkTimerTrap(_ n: Int, _ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) -> UInt64? {
        guard let ipc = machIPC as? MachIPC else { return nil }
        let name = UInt32(truncatingIfNeeded: a[0])
        switch n {
        case Self.mkTimerCreate:
            call = "mk_timer_create()"
            return UInt64(ipc.mkTimerCreate())
        case Self.mkTimerDestroy:
            call = "mk_timer_destroy(\(hx(name)))"
            switch ipc.mkTimer(named: name) {
            case let .failure(e): return UInt64(e.code)
            case .success: return UInt64(ipc.portDestroy(name))
            }
        case Self.mkTimerArm, Self.mkTimerArmLeeway:
            let ticks = n == Self.mkTimerArm ? a[1] : a[2]
            call = n == Self.mkTimerArm ? "mk_timer_arm(\(hx(name)), \(hx(ticks)))"
                : "mk_timer_arm_leeway(\(hx(name)), flags=\(hx(a[1])), \(hx(ticks)), leeway=\(hx(a[3])))"
            switch ipc.mkTimer(named: name) {
            case let .failure(e): return UInt64(e.code)
            case let .success(t):
                t.armedTicks = ticks
                t.deadline = hostDeadline(machTicks: ticks)
                kevents.mkTimers[ObjectIdentifier(t)] = t
                if ticks <= counter() {
                    _ = fireDueTimers()
                } else {
                    startTimerThreadIfNeeded()
                    kevents.timerWake.wakeAll()
                }
                return 0
            }
        case Self.mkTimerCancel:
            call = "mk_timer_cancel(\(hx(name)), \(hx(a[1])))"
            switch ipc.mkTimer(named: name) {
            case let .failure(e): return UInt64(e.code)
            case let .success(t):
                let armed = t.deadline != nil ? t.armedTicks : 0
                t.deadline = nil
                kevents.mkTimers[ObjectIdentifier(t)] = nil
                if a[1] != 0, (try? mem.write(va: a[1], bytes: le64(armed))) == nil { return UInt64(MachKern.failure) }
                return 0
            }
        default:
            return nil
        }
    }

    /// Fires the due mk timers (from `fireDueTimers`). Returns the earliest
    /// remaining deadline.
    func fireDueMachTimers(now: UInt64) -> UInt64? {
        var next: UInt64?
        for (key, t) in kevents.mkTimers {
            guard let p = t.port, p.active, let d = t.deadline else {
                kevents.mkTimers[key] = nil
                continue
            }
            if d <= now {
                t.deadline = nil
                kevents.mkTimers[key] = nil
                (machIPC as? MachIPC)?.mkTimerExpire(t)
            } else {
                next = min(next ?? d, d)
            }
        }
        return next
    }
}
