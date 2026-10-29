// Diagnostics: what each thread of a process is blocked in, and for Mach
// receives the port it waits on and, for a send-and-receive, the
// destination's receiving process (stage 6 boot analysis).

import Synchronization

/// A thread's last 16 traps (`ThreadContext.recentTraps`). The thread's own
/// host thread records every trap, also on the paths that take no kernel
/// lock, while a report reads the ring from another thread: the storage is
/// allocated once and never moves, so a read during a write can at worst
/// show one torn entry, never touch freed or shifted memory (an array's
/// `removeFirst` under a concurrent `map` trapped with an index out of
/// range).
public final class TrapRing: @unchecked Sendable {
    public static let capacity = 16
    private let slots = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity * 4)
    private let written = Atomic<Int>(0)

    public init() { slots.initialize(repeating: 0, count: Self.capacity * 4) }
    deinit { slots.deallocate() }

    /// Owner thread only.
    public func record(_ x16: UInt64, _ x0: UInt64, _ x1: UInt64, _ result: UInt64) {
        let n = written.load(ordering: .relaxed)
        let s = slots + (n % Self.capacity) * 4
        s[0] = x16; s[1] = x0; s[2] = x1; s[3] = result
        written.store(n + 1, ordering: .releasing)
    }

    /// Oldest first. Any thread.
    public var entries: [(UInt64, UInt64, UInt64, UInt64)] {
        let n = written.load(ordering: .acquiring)
        return (max(0, n - Self.capacity)..<n).map { i in
            let s = slots + (i % Self.capacity) * 4
            return (s[0], s[1], s[2], s[3])
        }
    }
}

extension DarwinKernel {
    /// Record each knote's last state changes (set by the VMM for reports).
    nonisolated(unsafe) public static var recordKnoteHistory = false

    /// One trap-ring entry: `x16(x0,x1)->result` (`!errno` when carry was set).
    public static func ringEntry(_ e: (UInt64, UInt64, UInt64, UInt64)) -> String {
        let result = e.3 & (1 << 63) != 0 ? "!\(e.3 & 0xFFFF_FFFF)" : hx(e.3)
        return "\(Int64(bitPattern: e.0))(\(hx(e.1)),\(hx(e.2)))->\(result)"
    }

    /// One line per thread that is inside a trap. Lock held.
    public func blockedThreadReport() -> [String] {
        withEvents { withPorts { blockedThreadReportLocked() } }
    }

    private func blockedThreadReportLocked() -> [String] {
        var lines: [String] = []
        let ipc = machIPC as? MachIPC
        for t in threadsByPort.values.sorted(by: { $0.threadID < $1.threadID }) {
            if t.trapCount > 0 {
                let recent = t.recentTraps.map { Self.ringEntry($0) }
                lines.append("thread \(t.threadID): \(t.trapCount) traps; last: " + recent.joined(separator: " "))
            }
            guard let (x16, a) = t.trapInProgress else {
                let state = t.arrivingTrap.map { "in trap \(Int64(bitPattern: $0)) before the kernel took it (waiting for the kernel lock?)" }
                    ?? (t.isAlive ? "in user code" : "terminated")
                lines.append("thread \(t.threadID): \(state) (\(t.kind), vCPU \(t.vcpuIndex))")
                continue
            }
            let n = Int64(bitPattern: x16)
            var text = "thread \(t.threadID): trap \(n)"
            if n == -47, let ipc {
                let options = a[1]
                let remote = UInt32(truncatingIfNeeded: a[3]), id = Int32(bitPattern: UInt32(truncatingIfNeeded: a[4] >> 32))
                let rcv = UInt32(truncatingIfNeeded: a[5] >> 32)
                text += " mach_msg2 options \(hx(options))"
                if options & 1 != 0 { text += " sent id \(id) to \(hx(remote)) (\(ipc.describePort(remote)))" }
                if options & 2 != 0 { text += " receiving on \(hx(rcv)) (\(ipc.describePort(rcv)))" }
            } else if n == -31 {
                text += " mach_msg options \(hx(a[1])) rcv_name \(hx(a[4]))"
            } else {
                text += " args " + a.prefix(4).map { hx($0) }.joined(separator: " ")
            }
            lines.append(text)
        }
        let lost = lostWorkloopRequests()
        if !lost.isEmpty {
            lines.append("workloops marked as requested that no queue holds: " + lost.map { hx($0.workloopID) }.joined(separator: " ")
                + " (\(workqueue.idle.count) idle workers, \(workqueue.workers.count) workers)")
            for kq in lost { lines.append("  workloop \(hx(kq.workloopID)) requests: " + kq.requestLogText) }
        }
        // Mach-port knotes whose port has messages queued (a lost wakeup
        // shows here as an idle servicer with pending messages).
        var loggedWorkloops = Set<ObjectIdentifier>()
        for kq in allKQueues {
            for kn in kq.knotes where kn.filter == EVFilter.machport && machPortHasMessage(UInt32(truncatingIfNeeded: kn.ident)) {
                if kq.kind == .workloop, kq.servicer == nil, loggedWorkloops.insert(ObjectIdentifier(kq)).inserted {
                    lines.append("workloop \(hx(kq.workloopID)) (no servicer) requests: " + kq.requestLogText)
                }
                let where_: String
                switch kq.kind {
                case .workloop: where_ = "workloop \(hx(kq.workloopID)) servicer \(kq.servicer.map { "t\($0.threadID)" } ?? "none") owner \(kq.owner.map { "t\($0.threadID)" } ?? "none") requested \(kq.requested)"
                case .workq: where_ = "workq bucket \(kn.bucket) bound \(kq.buckets[kn.bucket]?.boundWorker.map { "t\($0.threadID)" } ?? "none") requested \(kq.buckets[kn.bucket]?.requested ?? false)"
                default: where_ = "\(kq.kind)"
                }
                if kq.kind == .workloop, let sv = kq.servicer, threadsByPort[sv.portName] !== sv {
                    lines.append("note: servicer t\(sv.threadID) of workloop \(hx(kq.workloopID)) is not a live thread of this process (alive \(sv.isAlive))")
                }
                for h in kn.history { lines.append("    history: " + h) }
                lines.append("knote port \(hx(kn.ident)) [\(ipc?.describePort(UInt32(truncatingIfNeeded: kn.ident)) ?? "?")]: enabled \(kn.enabled) active \(kn.active) suppressed \(kn.suppressed) deletePending \(kn.deletePending) flags \(hx(UInt64(kn.flags))) in \(where_)")
            }
        }
        return lines
    }
}

extension MachIPC {
    /// Who receives on `name` in this space (diagnostics). Lock held.
    /// Who can still send to `p` (diagnostics for a thread waiting on its own
    /// port, e.g. for a reply): the spaces with send or send-once rights,
    /// and queued messages that carry a right to it.
    static func rightHolders(_ p: IPCPort, system: DarwinSystem?, mach: MachIPCSystem) -> String {
        var holders: [String] = []
        var spaces = system?.snapshotSpaces() ?? []
        if let host = mach.hostTask { spaces.append(host.ipc) }
        func carries(_ r: CarriedRight) -> Bool { r.port === p }
        for space in spaces {
            for e in space.entries where e.inUse && e.port === p && e.bits & (MachPortType.send | MachPortType.sendOnce) != 0 {
                holders.append("pid \(space.pid)\(e.bits & MachPortType.sendOnce != 0 ? " (send-once)" : "")")
            }
            for (index, e) in space.entries.enumerated() where e.inUse {
                guard let q = e.port else { continue }
                let ename = UInt32(index) << 8 | e.generation << 2 | 3
                // Notification requests on q hold send-once rights to their notify ports.
                if q.pdRequest === p { holders.append("port-destroyed request of 0x\(String(ename, radix: 16)) in pid \(space.pid)") }
                if q.nsRequest === p { holders.append("no-senders request of 0x\(String(ename, radix: 16)) in pid \(space.pid)") }
                if q.dnRequests.values.contains(where: { $0 === p }) {
                    holders.append("dead-name or send-possible request on 0x\(String(ename, radix: 16)) in pid \(space.pid)")
                }
                guard q.receiver === space else { continue }
                for m in Array(q.messages.all) + q.snapshotPendingSends.map(\.message) {
                    if carries(m.reply) { holders.append("reply right in a message queued for pid \(space.pid) on 0x\(String(ename, radix: 16)) (id \(m.id))") }
                    if carries(m.destination) { holders.append("message to it queued at pid \(space.pid)") }
                    for item in m.items {
                        switch item {
                        case let .port(r, _), let .guarded(r, _, _):
                            if carries(r) { holders.append("a right in the body of a message queued for pid \(space.pid) (id \(m.id))") }
                        case let .oolPorts(list, _, _):
                            if list.contains(where: carries) { holders.append("a right in the body of a message queued for pid \(space.pid) (id \(m.id))") }
                        case .ool: break
                        }
                    }
                }
            }
        }
        if holders.isEmpty, p.sorights > 0 {
            holders.append("(the send-once right is in no space, queue or notification request: a host service or a kernel object holds it)")
        }
        return "; srights \(p.srights) sorights \(p.sorights); held by " + (holders.isEmpty ? "nobody" : holders.joined(separator: ", "))
    }

    func describePort(_ name: UInt32) -> String {
        guard MachPortName.isValid(name), let i = lookup(name) else { return "no such name" }
        if entries[i].set != nil { return "port set" }
        guard let p = entries[i].port else { return "dead name" }
        if let k = p.kernelObject { return "kernel object \(k)" }
        if !p.active { return "dead port" }
        guard let r = p.receiver else { return "receive right in transit, \(p.messages.count) queued" }
        if r === self { return "own port, \(p.messages.count) queued" + Self.rightHolders(p, system: kernel?.system, mach: system) }
        return "received by pid \(r.pid), \(p.messages.count) queued"
    }
}

extension DarwinKernel {
    /// Diagnostics for a snapshot (snapshot.md §12.5; the caller holds the
    /// kernel lock and every fine lock): threads blocked in a Mach receive
    /// on one of their own ports, waiting for a reply whose send-once right
    /// no guest space, queued message or notification request holds — a
    /// reply that only a host service or a kernel object can still send,
    /// with the destination of the request the thread sent in the same call.
    public func snapshotReplyWaitsWithoutGuestHolder() -> [String] {
        guard let ipc = machIPC as? MachIPC else { return [] }
        var lines: [String] = []
        for t in threadsByPort.values.sorted(by: { $0.threadID < $1.threadID }) {
            guard t.trapInProgress != nil, let f = t.entryFrame, Int64(bitPattern: f.x[16]) == -47 else { continue }
            let options = f.x[1]
            guard options & 2 != 0 else { continue }
            let rcv = UInt32(truncatingIfNeeded: f.x[5] >> 32), remote = UInt32(truncatingIfNeeded: f.x[3])
            guard MachPortName.isValid(rcv), let i = ipc.lookup(rcv), let p = ipc.entries[i].port, p.receiver === ipc,
                  p.sorights > 0 else { continue }
            let holders = MachIPC.rightHolders(p, system: system, mach: ipc.system)
            guard holders.contains("in no space") else { continue }
            let id = Int32(bitPattern: UInt32(truncatingIfNeeded: f.x[4] >> 32))
            let sent = options & 1 != 0 ? "its request (id \(id)) went to \(hx(remote)) (\(ipc.describePort(remote)))" : "no send in this call"
            lines.append("pid \(pid) thread \(t.threadID) waits on \(hx(rcv)) for a reply no guest holds; \(sent)")
        }
        return lines
    }
}
