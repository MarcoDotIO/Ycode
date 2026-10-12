// Diagnostics: what each thread of a process is blocked in, and for Mach
// receives the port it waits on and, for a send-and-receive, the
// destination's receiving process (stage 6 boot analysis).

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
        // Mach-port knotes whose port has messages queued (a lost wakeup
        // shows here as an idle servicer with pending messages).
        for kq in allKQueues {
            for kn in kq.knotes where kn.filter == EVFilter.machport && machPortHasMessage(UInt32(truncatingIfNeeded: kn.ident)) {
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
    func describePort(_ name: UInt32) -> String {
        guard MachPortName.isValid(name), let i = lookup(name) else { return "no such name" }
        if entries[i].set != nil { return "port set" }
        guard let p = entries[i].port else { return "dead name" }
        if let k = p.kernelObject { return "kernel object \(k)" }
        if !p.active { return "dead port" }
        guard let r = p.receiver else { return "receive right in transit, \(p.messages.count) queued" }
        if r === self { return "own port, \(p.messages.count) queued" }
        return "received by pid \(r.pid), \(p.messages.count) queued"
    }
}
