// Messages sent to kernel-object ports (`mach-ipc.md` §1.6, §5.3): the VMM
// runs the MIG server routine synchronously and sends the reply to the
// request's reply right. The task port serves the `mach_port` subsystem
// (3200) for the routines the port traps cover plus the MIG-only ones;
// every other request gets `MIG_BAD_ID`.

/// A MIG reply in kernel form.
struct MIGReply {
    var inline: [UInt8]
    var items: [KItem] = []
    var complex: Bool { !items.isEmpty }

    /// `mig_reply_error_t` / a simple reply: NDR, RetCode, out arguments.
    static func simple(_ kr: UInt32, _ out: [UInt8] = []) -> MIGReply {
        MIGReply(inline: machNDRRecord + le32(kr) + out)
    }

    static func error(_ kr: UInt32) -> MIGReply { simple(kr) }
}

extension MachIPC {
    /// Handles a message to a kernel-object port. Returns a trace note.
    func serveKernelObject(_ m: KMessage, port p: IPCPort) -> String {
        p.seqno &+= 1
        consumeDestination(m.destination)
        var request = m
        request.destination = .null
        let replyRight = request.reply
        request.reply = .null
        var note = " [kernel object \(p.kernelObject?.description ?? "?") id \(m.id)"
        let reply: MIGReply?
        switch p.kernelObject {
        case .task: reply = machPortServer(&request)
        default: reply = .error(MachKern.migBadID)
        }
        destroyMessage(request)
        guard let reply else {
            release(replyRight)
            return note + " no reply]"
        }
        guard replyRight.port != nil else {
            for item in reply.items { releaseItem(item) }
            return note + " reply dropped]"
        }
        var replyType = MachMsgType.portSend
        if case .sendOnce = replyRight { replyType = MachMsgType.portSendOnce }
        var r = KMessage(complex: reply.complex, destination: replyRight, destinationType: replyType,
                         reply: .null, replyType: 0, id: m.id &+ 100)
        r.items = reply.items
        r.inline = reply.inline
        r.fromKernel = true
        sendKernelMessage(r)
        if !reply.complex, reply.inline.count >= 12 {
            note += " -> \(MachMsgReturn.name(reply.inline.readLE(UInt32.self, at: 8)))"
        }
        return note + "]"
    }

    /// The `mach_port` subsystem (3200) on the task port (`mach-ipc.md` §1.8).
    /// Request layouts: header, [body + descriptors], NDR, arguments packed to
    /// 4 bytes. A size or descriptor-count mismatch is `MIG_BAD_ARGUMENTS`.
    func machPortServer(_ m: inout KMessage) -> MIGReply? {
        let b = m.inline
        let size = m.size
        func u32(_ at: Int) -> UInt32 { b.readLE(UInt32.self, at: at - (size - b.count)) }
        func u64(_ at: Int) -> UInt64 { b.readLE(UInt64.self, at: at - (size - b.count)) }
        func expect(_ s: Int, descriptors: Int = 0) -> Bool {
            size == s && m.items.count == descriptors && m.complex == (descriptors > 0)
        }
        let bad = MIGReply.error(MachKern.migBadArguments)
        switch m.id {
        case 3201: // type(name) -> ptype
            guard expect(36) else { return bad }
            let (kr, type) = portType(u32(32))
            return kr == 0 ? .simple(0, le32(type)) : .error(kr)
        case 3203: // allocate_name(right, name)
            guard expect(40) else { return bad }
            return .simple(portAllocateName(right: u32(32), name: u32(36)))
        case 3204: // allocate(right) -> name
            guard expect(36) else { return bad }
            let (kr, name) = portAllocate(right: u32(32))
            return kr == 0 ? .simple(0, le32(name)) : .error(kr)
        case 3205: // destroy(name)
            guard expect(36) else { return bad }
            return .simple(portDestroy(u32(32)))
        case 3206: // deallocate(name)
            guard expect(36) else { return bad }
            return .simple(portDeallocate(u32(32)))
        case 3207: // get_refs(name, right) -> refs
            guard expect(40) else { return bad }
            let (kr, refs) = portGetRefs(u32(32), right: u32(36))
            return kr == 0 ? .simple(0, le32(refs)) : .error(kr)
        case 3208: // mod_refs(name, right, delta)
            guard expect(44) else { return bad }
            return .simple(portModRefs(u32(32), right: u32(36), delta: Int32(bitPattern: u32(40))))
        case 3210: // set_mscount(name, mscount)
            guard expect(40) else { return bad }
            return .simple(portSetMscount(u32(32), u32(36)))
        case 3212: // move_member(member, after)
            guard expect(40) else { return bad }
            return .simple(portMoveMember(u32(32), after: u32(36)))
        case 3213: // request_notification(name, msgid, sync, notify) -> previous
            guard expect(60, descriptors: 1), case let .port(notify, _) = m.items[0] else { return bad }
            m.items[0] = .port(.null, type: 0)
            let (kr, previous) = portRequestNotification(u32(48), id: Int32(bitPattern: u32(52)), sync: u32(56),
                                                         notify: notify)
            guard kr == 0 else {
                if case let .sendOnce(so) = notify { releaseSendOnceQuietly(so) }
                return .error(kr)
            }
            return MIGReply(inline: [], items: [.port(previous, type: MachMsgType.portSendOnce)])
        case 3214: // insert_right(name, poly)
            guard expect(52, descriptors: 1), case let .port(poly, _) = m.items[0] else { return bad }
            let name = u32(48)
            guard MachPortName.isValid(name) else { return .error(MachKern.invalidValue) }
            guard let p = poly.port, p.active else { return .error(MachKern.invalidCapability) }
            let kr = copyout(poly, as: name, check: true)
            guard kr == 0 else { return .error(kr) }
            m.items[0] = .port(.null, type: 0)
            _ = copyout(poly, as: name, check: false)
            return .simple(0)
        case 3215: // extract_right(name, msgt_name) -> poly
            guard expect(40) else { return bad }
            let (kr, right, type) = portExtractRight(u32(32), msgtName: u32(36))
            return kr == 0 ? MIGReply(inline: [], items: [.port(right, type: type)]) : .error(kr)
        case 3216: // set_seqno(name, seqno)
            guard expect(40) else { return bad }
            return .simple(portSetSeqno(u32(32), u32(36)))
        case 3217: // get_attributes(name, flavor, count) -> info[count]
            guard expect(44) else { return bad }
            let (kr, words) = portGetAttributes(u32(32), flavor: u32(36), count: min(u32(40), 17))
            guard kr == 0 else { return .error(kr) }
            return .simple(0, le32(UInt32(words.count)) + words.flatMap(le32))
        case 3218: // set_attributes(name, flavor, info[count])
            guard size >= 44 else { return bad }
            let count = Int(min(u32(40), 17))
            guard expect(44 + 4 * count) else { return bad }
            let info = (0..<count).map { u32(44 + 4 * $0) }
            return .simple(portSetAttributes(u32(32), flavor: u32(36), info: info))
        case 3226: // insert_member(name, pset)
            guard expect(40) else { return bad }
            return .simple(portInsertMember(u32(32), set: u32(36)))
        case 3227: // extract_member(name, pset)
            guard expect(40) else { return bad }
            return .simple(portExtractMember(u32(32), set: u32(36)))
        case 3228: // get_context(name) -> context
            guard expect(36) else { return bad }
            let (kr, context) = portGetContext(u32(32))
            return kr == 0 ? .simple(0, le64(context)) : .error(kr)
        case 3229: // set_context(name, context)
            guard expect(44) else { return bad }
            return .simple(portSetContext(u32(32), context: u64(36)))
        case 3231: // construct(options[32], context) -> name
            guard expect(72) else { return bad }
            let options = MachPortOptions(flags: u32(32), qlimit: u32(36), unionWord: u64(40))
            let (kr, name) = portConstruct(options, context: u64(64))
            return kr == 0 ? .simple(0, le32(name)) : .error(kr)
        case 3232: // destruct(name, srdelta, guard)
            guard expect(48) else { return bad }
            return .simple(portDestruct(u32(32), srdelta: Int32(bitPattern: u32(36)), guard: u64(40)))
        case 3233: // guard(name, guard, strict)
            guard expect(48) else { return bad }
            return .simple(portGuard(u32(32), guard: u64(36), strict: u32(44) != 0))
        case 3234: // unguard(name, guard)
            guard expect(44) else { return bad }
            return .simple(portUnguard(u32(32), guard: u64(36)))
        case 3236: // special_reply_port_reset_link(name) -> srp_lost_link
            guard expect(36) else { return bad }
            return .simple(0, le32(0))
        case 3237: // guard_with_flags(name, guard, flags)
            guard expect(52) else { return bad }
            let flags = u64(44)
            guard flags & ~3 == 0 else { return .error(MachKern.invalidArgument) }
            return .simple(portGuard(u32(32), guard: u64(36), strict: flags & 1 != 0, immovable: flags & 2 != 0))
        case 3238: // swap_guard(name, old, new)
            guard expect(52) else { return bad }
            return .simple(portSwapGuard(u32(32), old: u64(36), new: u64(44)))
        default:
            return .error(MachKern.migBadID)
        }
    }
}
