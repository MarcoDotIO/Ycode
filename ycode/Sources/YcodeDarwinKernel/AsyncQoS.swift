import Foundation
import Synchronization

// The QoS of a queued asynchronous message (`YCODE_ASYNC_QOS`;
// `specs/simulator/scheduling-policy.md` §4.11).
//
// xnu (level 1: `osfmk/ipc/ipc_kmsg.c` `ipc_kmsg_set_qos`, `ipc_kmsg_enqueue`;
// `osfmk/ipc/ipc_pset.c` `filt_machport_adjust_qos`, `filt_machportprocess`):
// - At send a message gets a priority (the sending work item's, from the
//   voucher's pthread-priority attribute, or the `MACH_SEND_OVERRIDE`
//   argument in its `mach_msg_priority_t` form) and an override QoS (that
//   priority's QoS raised to the override argument's).
// - Queued, each message raises the override of the messages ahead of it, so
//   the head carries the queue's highest. An EVFILT_MACHPORT knote that
//   receives messages (`MACH_RCV_MSG`) adjusts its event QoS to the head's
//   override: the workloop's thread request asks for that QoS, and a thread
//   already servicing the workloop is overridden to it. Only that thread or
//   that request: not the other threads of the receiving task.
// - The delivered event carries `(priority << 32) | override` in `ext[2]`;
//   libdispatch runs the message's handler at that priority.
// - A darwin-bg task's threads are not lifted by such overrides (only a
//   synchronous waiter's turnstile push is, `thread_policy.c`); importance
//   does that (§2.3, ReplyImportance.swift).
//
// Ycode has no vouchers: the sending thread's requested QoS stands for the
// voucher's priority. kqworkq buckets keep their own QoS (not modelled).

public enum AsyncQoS {
    /// `YCODE_ASYNC_QOS=1` (with `YCODE_SCHED_QOS`): messages carry a QoS
    /// that overrides the workloop that drains their port (§4.11). Off by default.
    nonisolated(unsafe) public static var enabled = SchedPolicy.flag("YCODE_ASYNC_QOS", false)
    @inline(__always) public static var active: Bool { enabled && SchedPolicy.qosEnabled }

    /// Raised servicers (the counter is atomic: event locks of many images).
    public static let servicerOverrides = Atomic<UInt64>(0)

    static var report: String {
        guard active else { return "" }
        return "; async QoS: servicers overridden \(servicerOverrides.load(ordering: .relaxed))"
    }

    /// `mach_msg_priority_t` in its encoded form (not a pthread priority):
    /// the QoS, relative priority and override QoS fields.
    static func isPthreadPriority(_ pri: UInt32) -> Bool { pri & 0xFF == 0xFF }
    static func encodedQoS(_ pri: UInt32) -> Int { let q = Int((pri >> 16) & 0xF); return q <= 6 ? q : 0 }
    static func encodedOverride(_ pri: UInt32) -> Int { let q = Int((pri >> 20) & 0xF); return q <= 6 ? q : 0 }
    static func encodedRelpri(_ pri: UInt32) -> Int { Int(Int8(bitPattern: UInt8((pri >> 8) & 0xFF))) + 1 }

    /// Sets the message's priority and override at send (§4.11). G held.
    static func set(_ m: inout KMessage, sender ctx: ThreadContext, options: UInt64, priority: UInt32) {
        let override = options & MachMsgOption.sendOverride != 0
        var pp: UInt32 = 0
        var ovr = 0
        if override, priority != 0, !isPthreadPriority(priority) {
            let q = encodedQoS(priority)
            if q > 0 { pp = PthreadPriority.make(qos: q, relpri: encodedRelpri(priority)) }
            ovr = max(q, encodedOverride(priority))
        } else {
            // The voucher's priority: the sending thread's requested QoS.
            let q = ctx.baseQoS
            if q > 0 && q <= 6 { pp = PthreadPriority.make(qos: q) }
            ovr = PthreadPriority.qos(pp) ?? 0
            if override, let o = PthreadPriority.qos(priority) { ovr = max(ovr, o) }
        }
        m.ppriority = pp
        m.qosOverride = UInt8(max(0, min(6, ovr)))
    }

    /// The `ext[2]` word of a received message: `(priority << 32) |
    /// override` as a pthread priority (the head's override, which is the
    /// queue's highest when it was taken).
    static func receivedPriorityAndQoS(_ m: KMessage, headOverride: Int) -> UInt64 {
        guard active else { return 0 }
        let q = max(Int(m.qosOverride), headOverride)
        let ovr: UInt32 = q > 0 ? PthreadPriority.make(qos: q) : 0
        return UInt64(m.ppriority) << 32 | UInt64(ovr)
    }
}

extension MachIPC {
    /// The highest override QoS queued on the port (or the members of the
    /// port set) named `name` in this space; 0 none (§4.11).
    public func queuedOverrideQoS(on name: UInt32) -> Int {
        lock.withLock {
            guard let i = lookup(name) else { return 0 }
            if let s = entries[i].set { return s.members.map(\.messages.maxOverride).max() ?? 0 }
            guard entries[i].bits & MachPortType.receive != 0, let p = entries[i].port else { return 0 }
            return p.messages.maxOverride
        }
    }
}

extension DarwinKernel {
    /// The override QoS a machport knote's queue puts on its event (§4.11):
    /// only knotes that receive the message (`MACH_RCV_MSG`).
    func machPortOverrideQoS(_ kn: Knote) -> Int {
        guard AsyncQoS.active, kn.filter == EVFilter.machport, kn.fflags & MachRcv.msg != 0 else { return 0 }
        return (machIPC as? MachIPC)?.queuedOverrideQoS(on: UInt32(truncatingIfNeeded: kn.ident)) ?? 0
    }

    /// A message was queued for `kn`'s workloop while a thread services it:
    /// that thread is overridden to the queue's override QoS (§4.11). Event lock held.
    func overrideServicer(of kn: Knote) {
        guard AsyncQoS.active, let kq = kn.kq, kq.kind == .workloop, let s = kq.servicer, s.isAlive else { return }
        let q = machPortOverrideQoS(kn)
        guard q > s.keventOverrideQoS else { return }
        s.keventOverrideQoS = q
        AsyncQoS.servicerOverrides.wrappingAdd(1, ordering: .relaxed)
        refreshSchedClass(s)
    }
}
