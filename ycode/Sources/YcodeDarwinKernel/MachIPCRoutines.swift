// The port routines (`mach-ipc.md` §1.7) and right copyin (§2.4). Callers
// hold the kernel lock. Results are `kern_return_t` values.

/// Where a right is copied in from.
enum CopyinSlot {
    case destination, reply, body, routine
}

enum CopyinFailure: Error {
    /// No entry under the name.
    case noEntry
    /// The entry lacks the right the disposition needs.
    case noRight
}

/// `mach_port_options_t` (32 bytes, `mach-ipc.md` §1.7).
public struct MachPortOptions: Equatable, Sendable {
    public var flags: UInt32
    public var qlimit: UInt32
    /// The first word of the 16-byte union (`service_port_name` for a connection port).
    public var unionWord: UInt64

    public init(flags: UInt32, qlimit: UInt32 = 0, unionWord: UInt64 = 0) {
        self.flags = flags
        self.qlimit = qlimit
        self.unionWord = unionWord
    }

    public init(bytes: [UInt8]) {
        flags = bytes.readLE(UInt32.self, at: 0)
        qlimit = bytes.readLE(UInt32.self, at: 4)
        unionWord = bytes.readLE(UInt64.self, at: 8)
    }
}

extension MachIPC {
    typealias T = MachPortType

    // MARK: Copyin

    /// Copies in (or with `apply: false`, only checks) `name` with
    /// `disposition` from the space (§2.4). `reserved` is the number of send
    /// user references an earlier slot of the same header takes from the same
    /// entry. A dead send or send-once right yields `.dead` (the caller turns
    /// it into a destination error). The checks never depend on `apply`, so a
    /// successful check guarantees a successful apply.
    func copyin(_ name: UInt32, _ disposition: UInt32, slot: CopyinSlot, apply: Bool,
                reserved: UInt32 = 0) -> Result<CarriedRight, CopyinFailure> {
        guard let i = self.slot(of: name) else { return .failure(.noEntry) }
        // A dead send-once destination without a dead-name request: the send
        // succeeds and the message is destroyed (§1.5).
        if slot == .destination, disposition == MachMsgType.moveSendOnce,
           entries[i].bits & T.sendOnce != 0, let p = entries[i].port, !p.active,
           !p.deadNameNotified.contains(dn(name)) {
            if apply { freeName(i) }
            return .success(.sendOnce(p))
        }
        convertIfDead(i)
        let e = entries[i]
        if let p = e.port, p.isSpecialReply, e.bits & T.portRights != 0 {
            let allowed = (disposition == MachMsgType.makeSendOnce && (slot == .reply || slot == .destination))
                || (disposition == MachMsgType.moveSendOnce && slot == .destination)
            if !allowed { return .failure(.noRight) }
        }
        switch disposition {
        case MachMsgType.moveReceive:
            guard e.bits & T.receive != 0, let p = e.port, !p.immovable else { return .failure(.noRight) }
            if apply {
                dropReceive(i)
                p.guarded = false
                p.strict = false
                p.context = 0
            }
            return .success(.receive(p))

        case MachMsgType.moveSend, MachMsgType.copySend:
            if e.bits & T.deadName != 0 {
                if apply && disposition == MachMsgType.moveSend { dropDeadReference(i) }
                return .success(.dead)
            }
            guard e.bits & T.send != 0, let p = e.port, e.urefs > reserved || e.urefs == MachPortName.urefsMax else {
                return .failure(.noRight)
            }
            if apply {
                p.srights += 1
                if disposition == MachMsgType.moveSend && e.urefs != MachPortName.urefsMax {
                    entries[i].urefs -= 1
                    if entries[i].urefs == 0 {
                        entries[i].bits &= ~T.send
                        p.srights -= 1
                        if entries[i].bits & T.receive == 0 { freeName(i) }
                    }
                }
            }
            return .success(.send(p))

        case MachMsgType.moveSendOnce:
            if e.bits & T.deadName != 0 {
                if apply { dropDeadReference(i) }
                return .success(.dead)
            }
            guard e.bits & T.sendOnce != 0, let p = e.port else { return .failure(.noRight) }
            if apply { freeName(i) }
            return .success(.sendOnce(p))

        case MachMsgType.makeSend:
            guard e.bits & T.receive != 0, let p = e.port else { return .failure(.noRight) }
            if apply {
                p.mscount &+= 1
                p.srights += 1
            }
            return .success(.send(p))

        case MachMsgType.makeSendOnce:
            guard e.bits & T.receive != 0, let p = e.port else { return .failure(.noRight) }
            if apply { p.sorights += 1 }
            return .success(.sendOnce(p))

        default:
            return .failure(.noRight)
        }
    }

    /// Drops one dead-name reference (pegged counts stay).
    func dropDeadReference(_ i: Int) {
        if entries[i].urefs == MachPortName.urefsMax { return }
        entries[i].urefs -= 1
        if entries[i].urefs == 0 { freeName(i) }
    }

    /// Copies `right` out under the caller-chosen `name` (insert_right).
    /// Checks first; on failure the right is untouched and still the caller's.
    func copyout(_ right: CarriedRight, as name: UInt32, check: Bool) -> UInt32 {
        guard let p = right.port else { return MachKern.invalidCapability }
        let claimed: NameClaim
        switch claim(name: name) {
        case let .failure(e): return e.code
        case let .success(c): claimed = c
        }
        let coalesces: Bool
        switch right {
        case .send, .receive: coalesces = true
        default: coalesces = false
        }
        if coalesces, let existing = reverse[ObjectIdentifier(p)], existing != name { return MachKern.rightExists }
        switch claimed {
        case let .sameName(i):
            guard coalesces, entries[i].port === p, entries[i].bits & (T.send | T.receive) != 0 else {
                return MachKern.nameExists
            }
            if case .receive = right, entries[i].bits & T.receive != 0 { return MachKern.nameExists }
            if check { return MachKern.success }
            switch right {
            case .send:
                if entries[i].bits & T.send != 0 { p.srights -= 1 } else { entries[i].bits |= T.send }
                entries[i].urefs = pegAdd(entries[i].urefs, 1)
            case .receive:
                entries[i].bits |= T.receive
                p.receiver = self
                p.transitHolder = nil
            default: break
            }
            return MachKern.success
        case let .free(i):
            if check { return MachKern.success }
            switch right {
            case .send: _ = newEntry(at: i, name: name, bits: T.send, urefs: 1, port: p)
            case .sendOnce: _ = newEntry(at: i, name: name, bits: T.sendOnce, urefs: 1, port: p)
            case .receive:
                _ = newEntry(at: i, name: name, bits: T.receive, urefs: 0, port: p)
                p.receiver = self
                p.transitHolder = nil
            default: break
            }
            return MachKern.success
        }
    }

    // MARK: Lookups

    /// The receive right under `name`: `KERN_INVALID_NAME` without an entry,
    /// `KERN_INVALID_RIGHT` without a receive right.
    func receiveRight(_ name: UInt32) -> Result<(Int, IPCPort), KernError> {
        guard let i = lookup(name) else { return .failure(KernError(MachKern.invalidName)) }
        guard entries[i].bits & T.receive != 0, let p = entries[i].port else {
            return .failure(KernError(MachKern.invalidRight))
        }
        return .success((i, p))
    }

    // MARK: Allocation

    func portAllocate(right: UInt32) -> (kr: UInt32, name: UInt32) {
        switch right {
        case MachPortRight.receive:
            let p = newPort()
            guard let name = newEntry(bits: T.receive, urefs: 0, port: p) else { return (MachKern.noSpace, 0) }
            p.receiver = self
            return (MachKern.success, name)
        case MachPortRight.portSet:
            let s = IPCPortSet(serial: nextSerial())
            guard let name = newEntry(bits: T.portSet, urefs: 0, set: s) else { return (MachKern.noSpace, 0) }
            return (MachKern.success, name)
        case MachPortRight.deadName:
            guard let name = newEntry(bits: T.deadName, urefs: 1) else { return (MachKern.noSpace, 0) }
            return (MachKern.success, name)
        default:
            return (MachKern.invalidValue, 0)
        }
    }

    func portAllocateName(right: UInt32, name: UInt32) -> UInt32 {
        guard [MachPortRight.receive, MachPortRight.portSet, MachPortRight.deadName].contains(right) else {
            return MachKern.invalidValue
        }
        let i: Int
        switch claim(name: name) {
        case let .failure(e): return e.code
        case .success(.sameName): return MachKern.nameExists
        case let .success(.free(slot)): i = slot
        }
        switch right {
        case MachPortRight.receive:
            let p = newPort()
            _ = newEntry(at: i, name: name, bits: T.receive, urefs: 0, port: p)
            p.receiver = self
        case MachPortRight.portSet:
            _ = newEntry(at: i, name: name, bits: T.portSet, urefs: 0, set: IPCPortSet(serial: nextSerial()))
        default:
            _ = newEntry(at: i, name: name, bits: T.deadName, urefs: 1)
        }
        return MachKern.success
    }

    // MARK: Destroy, deallocate, mod_refs

    func portDestroy(_ name: UInt32) -> UInt32 {
        guard MachPortName.isValid(name) else { return MachKern.success }
        guard let i = lookup(name) else { return MachKern.invalidName }
        let e = entries[i]
        if let s = e.set {
            freeName(i)
            receiveRightGoneHandler?(name)
            destroySet(s)
            return MachKern.success
        }
        guard let p = e.port else {
            freeName(i)
            return MachKern.success
        }
        if e.bits & T.receive != 0, p.guarded, p.context != 0 { return MachKern.invalidRight }
        if e.bits & T.receive != 0 {
            dropReceive(i)
            if slot(of: name) != nil { freeName(i) }
            destroyReceive(p)
            if e.bits & T.send != 0 { releaseSend(p) }
        } else {
            freeName(i)
            if e.bits & T.send != 0 { releaseSend(p) }
            if e.bits & T.sendOnce != 0 { destroySendOnce(p) }
        }
        return MachKern.success
    }

    func portDeallocate(_ name: UInt32) -> UInt32 {
        guard MachPortName.isValid(name) else { return MachKern.success }
        guard let i = lookup(name) else { return MachKern.invalidName }
        let e = entries[i]
        if let s = e.set {
            freeName(i)
            receiveRightGoneHandler?(name)
            destroySet(s)
            return MachKern.success
        }
        if e.bits & T.deadName != 0 {
            dropDeadReference(i)
            return MachKern.success
        }
        if e.bits & T.sendOnce != 0, let p = e.port {
            freeName(i)
            destroySendOnce(p)
            return MachKern.success
        }
        if e.bits & T.send != 0, let p = e.port {
            if e.urefs == MachPortName.urefsMax { return MachKern.success }
            entries[i].urefs -= 1
            if entries[i].urefs == 0 {
                entries[i].bits &= ~T.send
                if entries[i].bits & T.receive == 0 { freeName(i) }
                releaseSend(p)
            }
            return MachKern.success
        }
        return MachKern.invalidRight
    }

    func portModRefs(_ name: UInt32, right: UInt32, delta: Int32) -> UInt32 {
        guard right < MachPortRight.number else { return MachKern.invalidValue }
        guard MachPortName.isValid(name) else {
            return right == MachPortRight.send || right == MachPortRight.sendOnce ? MachKern.success : MachKern.invalidName
        }
        guard let i = lookup(name) else { return MachKern.invalidName }
        let e = entries[i]
        switch right {
        case MachPortRight.receive:
            guard e.bits & T.receive != 0, let p = e.port else { return MachKern.invalidRight }
            if delta == 0 { return MachKern.success }
            guard delta == -1 else { return MachKern.invalidValue }
            if p.guarded { return MachKern.invalidRight }
            dropReceive(i)
            destroyReceive(p)
            return MachKern.success

        case MachPortRight.portSet:
            guard let s = e.set else { return MachKern.invalidRight }
            if delta == 0 { return MachKern.success }
            guard delta == -1 else { return MachKern.invalidValue }
            freeName(i)
            receiveRightGoneHandler?(name)
            destroySet(s)
            return MachKern.success

        case MachPortRight.sendOnce:
            guard e.bits & T.sendOnce != 0, let p = e.port else { return MachKern.invalidRight }
            if delta == 0 { return MachKern.success }
            guard delta == -1 else { return MachKern.invalidValue }
            freeName(i)
            destroySendOnce(p)
            return MachKern.success

        case MachPortRight.send, MachPortRight.deadName:
            let bit = right == MachPortRight.send ? T.send : T.deadName
            guard e.bits & bit != 0 else { return MachKern.invalidRight }
            guard delta >= -Int32(MachPortName.urefsMax), delta <= Int32(MachPortName.urefsMax) else {
                return MachKern.invalidValue
            }
            if delta == 0 { return MachKern.success }
            if e.urefs == MachPortName.urefsMax && delta != -Int32(MachPortName.urefsMax) { return MachKern.success }
            let new = Int64(e.urefs) + Int64(delta)
            guard new >= 0 else { return MachKern.invalidValue }
            if new > 0 {
                entries[i].urefs = new >= Int64(MachPortName.urefsMax) ? MachPortName.urefsMax : UInt32(new)
                return MachKern.success
            }
            if right == MachPortRight.deadName {
                freeName(i)
            } else if let p = e.port {
                entries[i].urefs = 0
                entries[i].bits &= ~T.send
                if entries[i].bits & T.receive == 0 { freeName(i) }
                releaseSend(p)
            }
            return MachKern.success

        default:
            return MachKern.invalidRight
        }
    }

    func portGetRefs(_ name: UInt32, right: UInt32) -> (kr: UInt32, refs: UInt32) {
        guard right < MachPortRight.number else { return (MachKern.invalidValue, 0) }
        guard MachPortName.isValid(name) else {
            return right == MachPortRight.send || right == MachPortRight.sendOnce
                ? (MachKern.success, 1) : (MachKern.invalidName, 0)
        }
        guard let i = lookup(name) else { return (MachKern.invalidName, 0) }
        let e = entries[i]
        switch right {
        case MachPortRight.send: return (MachKern.success, e.bits & T.send != 0 ? e.urefs : 0)
        case MachPortRight.deadName: return (MachKern.success, e.bits & T.deadName != 0 ? e.urefs : 0)
        default: return (MachKern.success, e.bits & T.of(right: right) != 0 ? 1 : 0)
        }
    }

    func portType(_ name: UInt32) -> (kr: UInt32, type: UInt32) {
        if name == MachPortName.null { return (MachKern.invalidName, 0) }
        if name == MachPortName.dead { return (MachKern.success, T.deadName) }
        guard let i = lookup(name) else { return (MachKern.invalidName, 0) }
        var type = entries[i].bits
        if let p = entries[i].port, p.dnRequests[dn(name)] != nil { type |= T.dnRequest }
        return (MachKern.success, type)
    }

    // MARK: insert_right / extract_right

    func portInsertRight(_ name: UInt32, poly: UInt32, polyPoly: UInt32) -> UInt32 {
        guard MachPortName.isValid(name), MachMsgType.isPortDisposition(polyPoly) else { return MachKern.invalidValue }
        guard MachPortName.isValid(poly) else { return MachKern.invalidCapability }
        let checked: CarriedRight
        switch copyin(poly, polyPoly, slot: .routine, apply: false) {
        case .failure(.noEntry): return MachKern.invalidName
        case .failure(.noRight): return MachKern.invalidRight
        case let .success(r): checked = r
        }
        guard checked.port != nil, checked.port!.active else { return MachKern.invalidCapability }
        // A receive right moved onto a name that it is leaving: the entry is
        // re-created, so only check conflicts against other names.
        let check = copyout(checked, as: name, check: true)
        if check != MachKern.success, !(name == poly && polyPoly == MachMsgType.moveReceive) { return check }
        guard case let .success(right) = copyin(poly, polyPoly, slot: .routine, apply: true) else {
            return MachKern.invalidRight
        }
        let kr = copyout(right, as: name, check: false)
        if kr != MachKern.success { release(right) }
        return kr
    }

    func portExtractRight(_ name: UInt32, msgtName: UInt32) -> (kr: UInt32, right: CarriedRight, type: UInt32) {
        guard MachMsgType.isPortDisposition(msgtName) else { return (MachKern.invalidValue, .null, 0) }
        guard MachPortName.isValid(name) else { return (MachKern.invalidRight, .null, 0) }
        switch copyin(name, msgtName, slot: .routine, apply: true) {
        case .failure(.noEntry): return (MachKern.invalidName, .null, 0)
        case .failure(.noRight): return (MachKern.invalidRight, .null, 0)
        case let .success(r): return (MachKern.success, r, MachMsgType.received(msgtName))
        }
    }

    // MARK: construct / destruct / guards / context

    func portConstruct(_ options: MachPortOptions, context: UInt64) -> (kr: UInt32, name: UInt32) {
        let f = options.flags
        guard f & ~MachPortConstruct.known == 0,
              MachPortConstruct.typeValues.contains(f & MachPortConstruct.typeMask) else {
            return (MachKern.invalidArgument, 0)
        }
        if f & MachPortConstruct.tgBlockTracking != 0 { return (MachKern.denied, 0) }
        if f & MachPortConstruct.qlimit != 0, options.qlimit > UInt32(MachIPCLimits.qlimitMax) {
            return (MachKern.invalidValue, 0)
        }
        if f & MachPortConstruct.typeMask == MachPortConstruct.connectionPort,
           !MachPortName.isValid(UInt32(truncatingIfNeeded: options.unionWord)) {
            return (MachKern.invalidArgument, 0)
        }
        let p = newPort()
        let insertSend = f & MachPortConstruct.insertSendRight != 0
        guard let name = newEntry(bits: insertSend ? T.receive | T.send : T.receive, urefs: insertSend ? 1 : 0,
                                  port: p) else { return (MachKern.noSpace, 0) }
        p.receiver = self
        if insertSend {
            p.srights = 1
            p.mscount = 1
        }
        if f & MachPortConstruct.qlimit != 0 { p.qlimit = Int(options.qlimit) }
        p.context = context
        if f & MachPortConstruct.contextAsGuard != 0 {
            p.guarded = true
            p.strict = f & MachPortConstruct.strict != 0
        }
        if f & MachPortConstruct.immovableReceive != 0 { p.immovable = true }
        return (MachKern.success, name)
    }

    func portDestruct(_ name: UInt32, srdelta: Int32, guard value: UInt64) -> UInt32 {
        guard MachPortName.isValid(name) else { return MachKern.invalidName }
        let i: Int, p: IPCPort
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((slot, port)): (i, p) = (slot, port)
        }
        if srdelta > 0 { return MachKern.invalidValue }
        if srdelta != 0 {
            guard entries[i].bits & T.send != 0 else { return MachKern.invalidRight }
            if entries[i].urefs != MachPortName.urefsMax, Int64(entries[i].urefs) + Int64(srdelta) < 0 {
                return MachKern.invalidValue
            }
        }
        if p.guarded && value != p.context { return MachKern.invalidArgument }
        if srdelta != 0 {
            let pegged = entries[i].urefs == MachPortName.urefsMax
            if !pegged || srdelta == -Int32(MachPortName.urefsMax) {
                entries[i].urefs = UInt32(Int64(entries[i].urefs) + Int64(srdelta))
                if entries[i].urefs == 0 {
                    entries[i].bits &= ~T.send
                    releaseSend(p)
                }
            }
        }
        dropReceive(i)
        destroyReceive(p)
        return MachKern.success
    }

    func portGuard(_ name: UInt32, guard value: UInt64, strict: Bool, immovable: Bool = false) -> UInt32 {
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((_, p)):
            guard p.context == 0, !p.guarded else { return MachKern.invalidArgument }
            p.context = value
            p.guarded = true
            p.strict = strict
            if immovable { p.immovable = true }
            return MachKern.success
        }
    }

    func portUnguard(_ name: UInt32, guard value: UInt64) -> UInt32 {
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((_, p)):
            guard p.guarded, p.context == value else { return MachKern.invalidArgument }
            p.context = 0
            p.guarded = false
            p.strict = false
            return MachKern.success
        }
    }

    func portSwapGuard(_ name: UInt32, old: UInt64, new: UInt64) -> UInt32 {
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((_, p)):
            guard p.guarded, !p.strict, p.context == old else { return MachKern.invalidArgument }
            p.context = new
            return MachKern.success
        }
    }

    func portGetContext(_ name: UInt32) -> (kr: UInt32, context: UInt64) {
        guard MachPortName.isValid(name) else { return (MachKern.invalidRight, 0) }
        switch receiveRight(name) {
        case let .failure(e): return (e.code, 0)
        case let .success((_, p)): return (MachKern.success, p.strict ? 0 : p.context)
        }
    }

    func portSetContext(_ name: UInt32, context: UInt64) -> UInt32 {
        guard MachPortName.isValid(name) else { return MachKern.invalidRight }
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((_, p)):
            if p.guarded && p.strict { return MachKern.invalidArgument }
            p.context = context
            return MachKern.success
        }
    }

    func portSetMscount(_ name: UInt32, _ mscount: UInt32) -> UInt32 {
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((_, p)):
            p.mscount = mscount
            return MachKern.success
        }
    }

    func portSetSeqno(_ name: UInt32, _ seqno: UInt32) -> UInt32 {
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((_, p)):
            p.seqno = seqno
            return MachKern.success
        }
    }

    // MARK: Attributes

    /// The 10-word `mach_port_status_t`.
    func status(_ p: IPCPort) -> [UInt32] {
        let flags: UInt32 = (p.guarded ? 0x02 : 0) | (p.strict ? 0x04 : 0) | (p.immovable ? 0x40 : 0)
        return [p.sets.isEmpty ? 0 : 1, p.seqno, p.mscount, UInt32(p.qlimit), UInt32(p.messages.count),
                UInt32(max(0, p.sorights)), p.srights > 0 ? 1 : 0, p.pdRequest != nil ? 1 : 0,
                p.nsRequest != nil ? 1 : 0, flags]
    }

    /// `mach_port_get_attributes`: the words of the result (their count is
    /// the new `*count`). Flavors (xnu `mach_port_get_attributes`): 1
    /// LIMITS_INFO, 2 RECEIVE_STATUS, 3 DNREQUESTS_SIZE, 7 INFO_EXT, 9
    /// SERVICE_THROTTLED (no service ports: `KERN_INVALID_CAPABILITY`); any
    /// other flavor (8 GUARD_INFO included) is `KERN_INVALID_ARGUMENT`.
    func portGetAttributes(_ name: UInt32, flavor: UInt32, count: UInt32) -> (kr: UInt32, words: [UInt32]) {
        let needed: UInt32
        switch flavor {
        case 1, 3, 9: needed = 1
        case 2: needed = 10
        case 7: needed = 17
        default: return (MachKern.invalidArgument, [])
        }
        guard count >= needed else { return (MachKern.failure, []) }
        if !MachPortName.isValid(name) {
            switch flavor {
            case 1: return (MachKern.success, [])
            case 3: return (MachKern.success, [0])
            default: return (MachKern.invalidRight, [])
            }
        }
        let p: IPCPort
        switch receiveRight(name) {
        case let .failure(e): return (e.code, [])
        case let .success((_, port)): p = port
        }
        switch flavor {
        case 1: return (MachKern.success, [UInt32(p.qlimit)])
        case 2: return (MachKern.success, status(p))
        case 3: return (MachKern.success, [UInt32(p.dnRequests.count)])
        case 7: return (MachKern.success, status(p) + [UInt32](repeating: 0, count: 7))
        default: return (MachKern.invalidCapability, [])
        }
    }

    /// `mach_port_set_attributes` (xnu order: count, value, name, right).
    /// 1 LIMITS_INFO sets the queue limit; 3 DNREQUESTS_SIZE, 4 TEMPOWNER,
    /// 5 IMPORTANCE_RECEIVER, and 6 DENAP_RECEIVER are accepted for a receive
    /// right (no effect in Ycode; 4–6 refuse special reply ports); 9
    /// SERVICE_THROTTLED needs a service port (`KERN_INVALID_CAPABILITY`);
    /// any other flavor is `KERN_INVALID_ARGUMENT`.
    func portSetAttributes(_ name: UInt32, flavor: UInt32, info: [UInt32]) -> UInt32 {
        switch flavor {
        case 1, 3:
            guard info.count >= 1 else { return MachKern.failure }
            if flavor == 1, info[0] > UInt32(MachIPCLimits.qlimitMax) { return MachKern.invalidValue }
        case 4, 5, 6, 9: break
        default: return MachKern.invalidArgument
        }
        guard MachPortName.isValid(name) else { return MachKern.invalidRight }
        let p: IPCPort
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((_, port)): p = port
        }
        switch flavor {
        case 1:
            p.qlimit = Int(info[0])
            p.sendWaiters.wakeAll()
            return MachKern.success
        case 4, 5, 6:
            return p.isKernelObject || p.isSpecialReply ? MachKern.invalidArgument : MachKern.success
        case 9:
            return MachKern.invalidCapability
        default:
            return MachKern.success
        }
    }

    // MARK: Notifications

    /// `mach_port_request_notification` (§3.6). `notify` is the copied-in
    /// send-once right (or NULL/DEAD as is). On failure the caller still owns
    /// `notify`.
    func portRequestNotification(_ name: UInt32, id: Int32, sync: UInt32,
                                 notify: CarriedRight) -> (kr: UInt32, previous: CarriedRight) {
        guard MachPortName.isValid(name) else { return (MachKern.invalidArgument, .null) }
        if case .dead = notify { return (MachKern.invalidCapability, .null) }
        let so: IPCPort?
        if case let .sendOnce(p) = notify { so = p } else { so = nil }
        switch id {
        case MachNotify.portDestroyed:
            let p: IPCPort
            switch receiveRight(name) {
            case let .failure(e): return (e.code, .null)
            case let .success((_, port)): p = port
            }
            guard sync == 0 else { return (MachKern.invalidValue, .null) }
            guard p.pdRequest == nil, !p.isSpecialReply else { return (MachKern.failure, .null) }
            p.pdRequest = so
            return (MachKern.success, .null)

        case MachNotify.noSenders:
            let p: IPCPort
            switch receiveRight(name) {
            case let .failure(e): return (e.code, .null)
            case let .success((_, port)): p = port
            }
            let previous: CarriedRight = p.nsRequest.map { .sendOnce($0) } ?? .null
            p.nsRequest = nil
            if let so {
                if p.srights == 0 && sync <= p.mscount {
                    sendNotification(to: so, id: MachNotify.noSenders, body: machNDRRecord + le32(p.mscount))
                } else {
                    p.nsRequest = so
                }
            }
            return (MachKern.success, previous)

        case MachNotify.deadName:
            guard let i = lookup(name) else { return (MachKern.invalidName, .null) }
            if entries[i].bits & T.deadName != 0 { return (MachKern.invalidArgument, .null) }
            guard entries[i].bits & T.portRights != 0, let p = entries[i].port else {
                return (MachKern.invalidRight, .null)
            }
            let previous: CarriedRight = p.dnRequests.removeValue(forKey: dn(name)).map { .sendOnce($0) } ?? .null
            if let so { p.dnRequests[dn(name)] = so }
            return (MachKern.success, previous)

        case MachNotify.sendPossible:
            guard let i = lookup(name) else { return (MachKern.invalidName, .null) }
            guard entries[i].bits & T.send != 0 else { return (MachKern.invalidRight, .null) }
            // Ycode fires it at once (§2.13).
            if let so { sendNotification(to: so, id: MachNotify.sendPossible, body: machNDRRecord + le32(name)) }
            return (MachKern.success, .null)

        default:
            return (MachKern.invalidValue, .null)
        }
    }

    // MARK: Port sets

    func portMoveMember(_ member: UInt32, after: UInt32) -> UInt32 {
        guard MachPortName.isValid(member), after != MachPortName.dead else { return MachKern.invalidRight }
        let p: IPCPort
        switch receiveRight(member) {
        case let .failure(e): return e.code
        case let .success((_, port)): p = port
        }
        var target: IPCPortSet?
        if after != MachPortName.null {
            guard let ai = lookup(after) else { return MachKern.invalidName }
            guard let s = entries[ai].set else { return MachKern.invalidRight }
            target = s
        }
        if target == nil && p.sets.isEmpty { return MachKern.notInSet }
        removeFromAllSets(p)
        if let s = target { addMember(p, to: s) }
        p.changeStamp = nextStamp()
        p.receiveWaiters.wakeAll()
        return MachKern.success
    }

    func portInsertMember(_ name: UInt32, set: UInt32) -> UInt32 {
        guard MachPortName.isValid(name), MachPortName.isValid(set) else { return MachKern.invalidRight }
        let p: IPCPort
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((_, port)): p = port
        }
        guard let si = lookup(set) else { return MachKern.invalidName }
        guard let s = entries[si].set else { return MachKern.invalidRight }
        if p.sets.contains(where: { $0 === s }) { return MachKern.alreadyInSet }
        addMember(p, to: s)
        p.changeStamp = nextStamp()
        p.receiveWaiters.wakeAll()
        return MachKern.success
    }

    func portExtractMember(_ name: UInt32, set: UInt32) -> UInt32 {
        guard MachPortName.isValid(name), MachPortName.isValid(set) else { return MachKern.invalidRight }
        let p: IPCPort
        switch receiveRight(name) {
        case let .failure(e): return e.code
        case let .success((_, port)): p = port
        }
        guard let si = lookup(set) else { return MachKern.invalidName }
        guard let s = entries[si].set else { return MachKern.invalidRight }
        guard p.sets.contains(where: { $0 === s }) else { return MachKern.notInSet }
        p.sets.removeAll { $0 === s }
        s.members.removeAll { $0 === p }
        s.waiters.wakeAll()
        p.changeStamp = nextStamp()
        p.receiveWaiters.wakeAll()
        return MachKern.success
    }

    func addMember(_ p: IPCPort, to s: IPCPortSet) {
        p.sets.append(s)
        s.members.append(p)
        if !p.messages.isEmpty {
            s.waiters.wakeAll()
            messageQueuedHandler?(s.name)
        }
    }
}
