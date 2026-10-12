import YcodeDarwinABI

// The trap layer of `MachIPC` (`stage4a-contract.md` §6, §8;
// `mach-ipc.md` §1.8, §2.7, §4; `host-libraries.md` §10). Mach traps return
// a `kern_return_t` (or a port name) in x0 and leave carry alone. The
// Ycode-private Mach routines `0x7963_2000 + n` return a `kern_return_t` in
// x0 with carry clear.

extension MachIPC {
    /// Mach trap numbers this type serves.
    public enum Trap {
        public static let portAllocate = -16, portDeallocate = -18, portModRefs = -19, portMoveMember = -20,
                          portInsertRight = -21, portInsertMember = -22, portExtractMember = -23,
                          portConstruct = -24, portDestruct = -25, replyPort = -26, threadSelf = -27,
                          taskSelf = -28, hostSelf = -29, machMsg = -31, machMsgOverwrite = -32,
                          portGetAttributes = -40, portGuard = -41, portUnguard = -42,
                          taskNameForPid = -44, taskForPid = -45, pidForTask = -46, machMsg2 = -47,
                          threadGetSpecialReplyPort = -50, hostCreateMachVoucher = -70,
                          voucherExtractAttrRecipe = -72, portType = -76, portRequestNotification = -77

        public static let all: Set<Int> = [-16, -18, -19, -20, -21, -22, -23, -24, -25, -26, -27, -28, -29,
                                           -31, -32, -40, -41, -42, -44, -45, -46, -47, -50, -70, -72, -76, -77]
    }

    /// The Ycode-private Mach routines (`host-libraries.md` §10, contract §7).
    public enum Routine {
        public static let rangeStart: UInt32 = 0x7963_2000
        public static let rangeEnd: UInt32 = 0x7963_20FF
        public static let hostGetClockService: UInt32 = 0x7963_2001
        public static let clockGetTime: UInt32 = 0x7963_2002
        public static let semaphoreCreate: UInt32 = 0x7963_2003
        public static let semaphoreDestroy: UInt32 = 0x7963_2004
        public static let taskGetSpecialPort: UInt32 = 0x7963_2005
        public static let taskSetSpecialPort: UInt32 = 0x7963_2006
        public static let hostCreateMachVoucher: UInt32 = 0x7963_2007
        /// `mach_ports_register3(task, p0, p1, p2)` (`processes.md` §3.4).
        public static let portsRegister3: UInt32 = 0x7963_2008
        /// `mach_ports_lookup3(task, &p0, &p1, &p2)` (`processes.md` §3.4).
        public static let portsLookup3: UInt32 = 0x7963_2009
        /// `mach_make_memory_entry_64(task, &size, offset, permission, &handle, parent)`.
        public static let makeMemoryEntry: UInt32 = 0x7963_200A
        /// `mach_vm_map` with a memory object: `(task, &addr, size, mask, flags, &block)`,
        /// block = u64 {object, offset, copy, cur, max, inherit}.
        public static let vmMapObject: UInt32 = 0x7963_200B
        /// `mach_vm_remap(_new)`: `(task, &addr, size, mask, flags, &block)`, block = u64
        /// {src_task, src_address, copy, &cur, &max, inherit, is_new}.
        public static let vmRemap: UInt32 = 0x7963_200C
        /// `task_threads(task, &list, &count)`.
        public static let taskThreads: UInt32 = 0x7963_200D
        /// `mach_port_get_context(task, name, &context)` / `mach_port_set_context(task, name, context)`.
        public static let portGetContext: UInt32 = 0x7963_200E
        public static let portSetContext: UInt32 = 0x7963_200F
    }

    /// `TASK_BOOTSTRAP_PORT`.
    static let taskBootstrapPort: Int32 = 4
    /// The largest voucher recipe array `host_create_mach_voucher` accepts.
    static let maxVoucherRecipeSize: Int32 = 5120

    // MARK: Entry point

    /// Handles a Mach trap (negative `x16`) or a private trap in
    /// `0x7963_2000…0x7963_20FF`. Returns nil for traps it does not own.
    /// Takes the kernel lock (with `context`) when the caller does not hold it.
    public func handleTrap(x16: Int64, frame: inout TrapFrame, context: ThreadContext,
                           memory: any GuestVirtualMemory) -> TrapOutcome? {
        if frame.x.count < TrapFrame.registerCount {
            frame.x += [UInt64](repeating: 0, count: TrapFrame.registerCount - frame.x.count)
        }
        if lock.isHeldByCurrentThread {
            return handleTrapLocked(x16: x16, frame: &frame, context: context, memory: memory)
        }
        return lock.withLock(context: context) {
            handleTrapLocked(x16: x16, frame: &frame, context: context, memory: memory)
        }
    }

    func handleTrapLocked(x16: Int64, frame: inout TrapFrame, context: ThreadContext,
                          memory: any GuestVirtualMemory) -> TrapOutcome? {
        let low = UInt32(truncatingIfNeeded: x16)
        if (Routine.rangeStart...Routine.rangeEnd).contains(low) {
            return handleRoutine(low, &frame, context: context, memory: memory)
        }
        let n = Int(Int32(bitPattern: low))
        guard Trap.all.contains(n) else { return nil }
        return handleMachTrap(n, &frame, context: context, memory: memory)
    }

    // MARK: Mach traps

    private func handleMachTrap(_ n: Int, _ frame: inout TrapFrame, context: ThreadContext,
                                memory: any GuestVirtualMemory) -> TrapOutcome {
        let a = Array(frame.x[0..<8])
        func u32(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: a[i]) }
        func i32(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        var call = "mach \(n)"
        let prefix = "trap mach \(n)"
        func kr(_ value: UInt32, _ extra: String = "") -> TrapOutcome {
            frame.x[0] = UInt64(value)
            log("\(prefix) \(call) -> \(MachMsgReturn.name(value))\(extra)")
            return .resume
        }
        func nameResult(_ name: UInt32) -> TrapOutcome {
            frame.x[0] = UInt64(name)
            log("\(prefix) \(call) -> \(hx(name))")
            return .resume
        }
        func write32(_ va: UInt64, _ v: UInt32) -> Bool { (try? memory.write(va: va, bytes: le32(v))) != nil }
        func targetOK(_ name: UInt32) -> Bool { isTaskSelf(name) }

        switch n {
        case Trap.portAllocate:
            call = "mach_port_allocate(target=\(hx(u32(0))), right=\(u32(1)), name=\(hx(a[2])))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            let (result, name) = portAllocate(right: u32(1))
            guard result == 0 else { return kr(result) }
            guard write32(a[2], name) else { return kr(MachKern.copyFault) }
            return kr(0, " [name=\(hx(name))]")

        case Trap.portDeallocate:
            call = "mach_port_deallocate(target=\(hx(u32(0))), name=\(hx(u32(1))))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            return kr(portDeallocate(u32(1)))

        case Trap.portModRefs:
            call = "mach_port_mod_refs(target=\(hx(u32(0))), name=\(hx(u32(1))), right=\(u32(2)), delta=\(i32(3)))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            return kr(portModRefs(u32(1), right: u32(2), delta: i32(3)))

        case Trap.portMoveMember:
            call = "mach_port_move_member(target=\(hx(u32(0))), member=\(hx(u32(1))), after=\(hx(u32(2))))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            return kr(portMoveMember(u32(1), after: u32(2)))

        case Trap.portInsertRight:
            call = "mach_port_insert_right(target=\(hx(u32(0))), name=\(hx(u32(1))), poly=\(hx(u32(2))), "
                + "polyPoly=\(u32(3)))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            return kr(portInsertRight(u32(1), poly: u32(2), polyPoly: u32(3)))

        case Trap.portInsertMember, Trap.portExtractMember:
            let insert = n == Trap.portInsertMember
            call = "mach_port_\(insert ? "insert" : "extract")_member(target=\(hx(u32(0))), name=\(hx(u32(1))), "
                + "pset=\(hx(u32(2))))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            return kr(insert ? portInsertMember(u32(1), set: u32(2)) : portExtractMember(u32(1), set: u32(2)))

        case Trap.portConstruct:
            call = "mach_port_construct(target=\(hx(u32(0))), options=\(hx(a[1])), context=\(hx(a[2])), name=\(hx(a[3])))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            guard let raw = try? memory.read(va: a[1], count: 32) else { return kr(MachKern.copyFault) }
            let options = MachPortOptions(bytes: raw)
            call += " [flags=\(hx(options.flags)) qlimit=\(options.qlimit)]"
            let (result, name) = portConstruct(options, context: a[2])
            guard result == 0 else { return kr(result) }
            guard write32(a[3], name) else { return kr(MachKern.copyFault) }
            return kr(0, " [name=\(hx(name))]")

        case Trap.portDestruct:
            call = "mach_port_destruct(target=\(hx(u32(0))), name=\(hx(u32(1))), srdelta=\(i32(2)), guard=\(hx(a[3])))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            return kr(portDestruct(u32(1), srdelta: i32(2), guard: a[3]))

        case Trap.replyPort:
            call = "mach_reply_port()"
            return nameResult(portAllocate(right: MachPortRight.receive).name)

        case Trap.threadSelf:
            call = "thread_self_trap()"
            if let (p, _) = kernelObject(named: context.portName) { return nameResult(copyoutNewSend(p)) }
            return nameResult(context.portName)

        case Trap.taskSelf:
            call = "task_self_trap()"
            return nameResult(copyoutNewSend(taskPort))

        case Trap.hostSelf:
            call = "host_self_trap()"
            return nameResult(copyoutNewSend(hostPort))

        case Trap.machMsg, Trap.machMsgOverwrite:
            return machMsgTrap(n, &frame, context: context, memory: memory)

        case Trap.taskForPid:
            // Ycode (`processes.md` §3.5): self only; any other pid fails.
            let pidArg = i32(1)
            call = "task_for_pid(target_tport=\(hx(u32(0))), pid=\(pidArg), t=\(hx(a[2])))"
            var name: UInt32 = 0
            var result = MachKern.failure
            if isTaskSelf(u32(0)), pidArg != 0, let target = space(forPID: pidArg), target === self {
                name = copyoutNewSend(taskPort)
                result = MachKern.success
            }
            if !write32(a[2], name), result == MachKern.success {
                _ = portDeallocate(name)
                return kr(MachKern.invalidAddress)
            }
            return kr(result, " [\(hx(name))]")

        case Trap.taskNameForPid:
            let pidArg = i32(1)
            call = "task_name_for_pid(target_tport=\(hx(u32(0))), pid=\(pidArg), t=\(hx(a[2])))"
            var name: UInt32 = 0
            var result = MachKern.failure
            if isTaskSelf(u32(0)), pidArg > 0, let target = space(forPID: pidArg) {
                name = copyoutNewSend(target.taskNamePort)
                result = MachKern.success
            }
            if !write32(a[2], name), result == MachKern.success {
                _ = portDeallocate(name)
                return kr(MachKern.invalidAddress)
            }
            return kr(result, " [\(hx(name))]")

        case Trap.pidForTask:
            call = "pid_for_task(t=\(hx(u32(0))), pid=\(hx(a[1])))"
            var pidOut: Int32 = -1
            var result = MachKern.failure
            if let (p, object) = kernelObject(named: u32(0)), object.isTaskFlavor, p.active,
               let task = p.task, !task.isTerminated {
                pidOut = task.currentPID
                result = MachKern.success
            }
            if !write32(a[1], UInt32(bitPattern: pidOut)) { return kr(MachKern.invalidAddress) }
            return kr(result, " [pid \(pidOut)]")

        case Trap.machMsg2:
            return machMsg2Trap(&frame, context: context, memory: memory)

        case Trap.portGetAttributes:
            call = "mach_port_get_attributes(target=\(hx(u32(0))), name=\(hx(u32(1))), flavor=\(u32(2)), "
                + "info=\(hx(a[3])), count=\(hx(a[4])))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            guard let raw = try? memory.read(va: a[4], count: 4) else { return kr(MachKern.copyFault) }
            let count = min(raw.readLE(UInt32.self, at: 0), 17)
            let (result, words) = portGetAttributes(u32(1), flavor: u32(2), count: count)
            guard result == 0 else { return kr(result) }
            if !words.isEmpty {
                guard (try? memory.write(va: a[3], bytes: words.flatMap(le32))) != nil else { return kr(MachKern.copyFault) }
            }
            guard write32(a[4], UInt32(words.count)) else { return kr(MachKern.copyFault) }
            return kr(0, " [\(words.map { String($0) }.joined(separator: ","))]")

        case Trap.portGuard:
            call = "mach_port_guard(target=\(hx(u32(0))), name=\(hx(u32(1))), guard=\(hx(a[2])), strict=\(u32(3) & 0xFF))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            return kr(portGuard(u32(1), guard: a[2], strict: u32(3) & 0xFF != 0))

        case Trap.portUnguard:
            call = "mach_port_unguard(target=\(hx(u32(0))), name=\(hx(u32(1))), guard=\(hx(a[2])))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            return kr(portUnguard(u32(1), guard: a[2]))

        case Trap.threadGetSpecialReplyPort:
            call = "thread_get_special_reply_port()"
            let p = newPort()
            p.isSpecialReply = true
            guard let name = newEntry(bits: T.receive | T.send, urefs: 1, port: p) else { return nameResult(0) }
            p.receiver = self
            p.srights = 1
            p.mscount = 1
            specialReplyPorts[context.threadID] = p
            return nameResult(name)

        case Trap.hostCreateMachVoucher:
            call = "host_create_mach_voucher_trap(host=\(hx(u32(0))), recipes=\(hx(a[1])), size=\(i32(2)), "
                + "voucher=\(hx(a[3])))"
            if i32(2) < 0 { return kr(MachKern.invalidArgument) }
            if i32(2) > Self.maxVoucherRecipeSize { return kr(MachKern.migArrayTooLarge) }
            guard write32(a[3], 0) else { return kr(MachKern.copyFault) }
            return kr(0, " [voucher=0x0]")

        case Trap.voucherExtractAttrRecipe:
            call = "mach_voucher_extract_attr_recipe_trap(voucher=\(hx(u32(0))), key=\(u32(1)), recipe=\(hx(a[2])), "
                + "size=\(hx(a[3])))"
            return kr(MachMsgReturn.sendInvalidDest, " [no voucher objects]")

        case Trap.portType:
            call = "mach_port_type(target=\(hx(u32(0))), name=\(hx(u32(1))), ptype=\(hx(a[2])))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            let (result, type) = portType(u32(1))
            guard result == 0 else { return kr(result) }
            guard write32(a[2], type) else { return kr(MachKern.copyFault) }
            return kr(0, " [\(hx(type))]")

        case Trap.portRequestNotification:
            call = "mach_port_request_notification(target=\(hx(u32(0))), name=\(hx(u32(1))), msgid=\(i32(2)), "
                + "sync=\(u32(3)), notify=\(hx(u32(4))), notifyPoly=\(u32(5)), previous=\(hx(a[6])))"
            guard targetOK(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            let poly = u32(5)
            guard poly == MachMsgType.makeSendOnce || poly == MachMsgType.moveSendOnce else {
                return kr(MachMsgReturn.sendInvalidDest)
            }
            var notify: CarriedRight = u32(4) == MachPortName.dead ? .dead : .null
            if MachPortName.isValid(u32(4)) {
                switch copyin(u32(4), poly, slot: .routine, apply: true) {
                case .failure(.noEntry): return kr(MachKern.invalidName)
                case .failure(.noRight): return kr(MachKern.invalidRight)
                case let .success(r): notify = r
                }
            }
            let (result, previous) = portRequestNotification(u32(1), id: i32(2), sync: u32(3), notify: notify)
            guard result == 0 else {
                if case let .sendOnce(so) = notify { releaseSendOnceQuietly(so) }
                return kr(result)
            }
            let (previousName, _) = copyout(previous)
            if a[6] != 0, !write32(a[6], previousName) { return kr(MachKern.copyFault) }
            return kr(0, " [previous=\(hx(previousName))]")

        default:
            return kr(MachKern.failure)
        }
    }

    // MARK: mach_msg traps

    /// `mach_msg_trap` (−31) and `mach_msg_overwrite_trap` (−32): the header
    /// is read from memory (§2.7).
    private func machMsgTrap(_ n: Int, _ frame: inout TrapFrame, context: ThreadContext,
                             memory: any GuestVirtualMemory) -> TrapOutcome {
        let a = Array(frame.x[0..<8])
        let msg = a[0]
        let options = UInt64(UInt32(truncatingIfNeeded: a[1]))
        let sendSize = Int(UInt32(truncatingIfNeeded: a[2]))
        let rcvSize = UInt64(UInt32(truncatingIfNeeded: a[3]))
        let rcvName = UInt32(truncatingIfNeeded: a[4])
        let timeout = UInt32(truncatingIfNeeded: a[5])
        var call = "\(n == Trap.machMsg ? "mach_msg_trap" : "mach_msg_overwrite_trap")(msg=\(hx(msg)), "
            + "option=\(hx(options)), send_size=\(sendSize), rcv_size=\(rcvSize), rcv_name=\(hx(rcvName)), "
            + "timeout=\(timeout))"
        var note = ""
        func finish(_ value: UInt32) -> TrapOutcome {
            frame.x[0] = UInt64(value)
            log("trap mach \(n) \(call) -> \(MachMsgReturn.name(value))\(note)")
            return .resume
        }
        if options & MachMsgOption.sendMsg != 0 {
            if sendSize < 24 || sendSize % 4 != 0 { return finish(MachMsgReturn.sendMsgTooSmall) }
            if sendSize > Int(MachIPCLimits.maxSendSize) { return finish(MachMsgReturn.sendTooLarge) }
            guard let bytes = try? memory.read(va: msg, count: sendSize) else {
                return finish(MachMsgReturn.sendInvalidData)
            }
            let bits = bytes.readLE(UInt32.self, at: 0) & MachMsgBits.user
            let complex = bits & MachMsgBits.complex != 0
            let bodyStart = complex ? min(28, sendSize) : 24
            let request = MachSendRequest(
                bits: bits, size: sendSize, remote: bytes.readLE(UInt32.self, at: 8),
                local: bytes.readLE(UInt32.self, at: 12), voucher: bytes.readLE(UInt32.self, at: 16),
                id: bytes.readLE(Int32.self, at: 20),
                descriptorCount: complex && sendSize >= 28 ? bytes.readLE(UInt32.self, at: 24) : 0,
                body: Array(bytes[bodyStart...]))
            call += " [bits=\(hx(bits)) remote=\(hx(request.remote)) local=\(hx(request.local)) id=\(request.id)]"
            let (code, pseudo, sendNote) = send(request, options: options, timeout: timeout, msg2: false, memory: memory)
            note += sendNote
            if code != 0 {
                var result = code
                if let pseudo {
                    let (out, resource) = pseudoReceive(pseudo, memory: memory)
                    try? memory.write(va: msg, bytes: out)
                    result |= resource
                    note += " [pseudo-received]"
                }
                return finish(result)
            }
        }
        if options & MachMsgOption.rcvMsg != 0 {
            let buffer = n == Trap.machMsgOverwrite && a[7] != 0 ? a[7] : msg
            let r = MachReceiveRequest(name: rcvName, options: options, buffer: buffer, size: rcvSize, timeout: timeout,
                                       syncDestination: UInt32(truncatingIfNeeded: a[6]))
            let result = receive(r, context: context, memory: memory)
            note += result.note
            return finish(result.code)
        }
        return finish(MachMsgReturn.success)
    }

    /// `mach_msg2_trap` (−47): header fields come from the registers (§2.7).
    private func machMsg2Trap(_ frame: inout TrapFrame, context: ThreadContext,
                              memory: any GuestVirtualMemory) -> TrapOutcome {
        let a = Array(frame.x[0..<8])
        func lo(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: a[i]) }
        func hi(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: a[i] >> 32) }
        let data = a[0]
        let options = a[1]
        let timeout = lo(7)
        let vector = options & MachMsgOption.msgVector != 0
        let call = "mach_msg2(data=\(hx(data)), options=\(hx(options)), bits=\(hx(lo(2))), "
            + "\(vector ? "send_vecs" : "send_size")=\(hi(2)), remote=\(hx(lo(3))), local=\(hx(hi(3))), "
            + "voucher=\(hx(lo(4))), id=\(Int32(bitPattern: hi(4))), descs=\(lo(5)), rcv_name=\(hx(hi(5))), "
            + "\(vector ? "rcv_vecs" : "rcv_size")=\(lo(6)), timeout=\(timeout))"
        var note = ""
        func finish(_ value: UInt32) -> TrapOutcome {
            frame.x[0] = UInt64(value)
            log("trap mach -47 \(call) -> \(MachMsgReturn.name(value))\(note)")
            return .resume
        }
        struct Vector { var data: UInt64; var rcvAddr: UInt64; var sendSize: UInt32; var rcvSize: UInt32 }
        func readVectors(_ count: Int) -> [Vector]? {
            guard let raw = try? memory.read(va: data, count: 24 * count) else { return nil }
            return (0..<count).map { k in
                Vector(data: raw.readLE(UInt64.self, at: 24 * k), rcvAddr: raw.readLE(UInt64.self, at: 24 * k + 8),
                       sendSize: raw.readLE(UInt32.self, at: 24 * k + 16), rcvSize: raw.readLE(UInt32.self, at: 24 * k + 20))
            }
        }

        if options & MachMsgOption.sendMsg != 0 {
            var messageAddress = data
            var sendSize = Int(hi(2))
            var aux: [UInt8]?
            if vector {
                let count = Int(hi(2))
                if count == 0 { return finish(MachMsgReturn.sendMsgTooSmall) }
                if count > 2 { return finish(MachMsgReturn.sendInvalidData) }
                guard let vecs = readVectors(count) else { return finish(MachMsgReturn.sendInvalidData) }
                messageAddress = vecs[0].data
                sendSize = Int(vecs[0].sendSize)
                if count == 2 {
                    // xnu mach_msg_validate_data_vectors: an empty aux vector
                    // means no aux data; a non-empty one needs data and at
                    // least the 8-byte aux header.
                    let auxSize = Int(vecs[1].sendSize)
                    if auxSize != 0 && vecs[1].data == 0 { return finish(MachMsgReturn.sendInvalidData) }
                    if auxSize != 0 && auxSize < 8 { return finish(MachMsgReturn.sendAuxTooSmall) }
                    if auxSize > MachIPCLimits.maxAuxSize { return finish(MachMsgReturn.sendAuxTooLarge) }
                    if auxSize > 0 {
                        guard let bytes = try? memory.read(va: vecs[1].data, count: auxSize) else {
                            return finish(MachMsgReturn.sendInvalidData)
                        }
                        aux = bytes
                    }
                }
            }
            let bits = lo(2) & MachMsgBits.user
            let complex = bits & MachMsgBits.complex != 0
            if sendSize < 24 || sendSize % 4 != 0 || (complex && sendSize < 28) {
                return finish(MachMsgReturn.sendMsgTooSmall)
            }
            if sendSize > Int(MachIPCLimits.maxSendSize) { return finish(MachMsgReturn.sendTooLarge) }
            let bodyStart = complex ? 28 : 24
            guard let body = try? memory.read(va: messageAddress + UInt64(bodyStart), count: sendSize - bodyStart) else {
                return finish(MachMsgReturn.sendInvalidData)
            }
            let request = MachSendRequest(bits: bits, size: sendSize, remote: lo(3), local: hi(3), voucher: lo(4),
                                          id: Int32(bitPattern: hi(4)), descriptorCount: lo(5), body: body, aux: aux)
            let (code, pseudo, sendNote) = send(request, options: options, timeout: timeout, msg2: true, memory: memory)
            note += sendNote
            if code != 0 {
                var result = code
                if let pseudo {
                    let (out, resource) = pseudoReceive(pseudo, memory: memory)
                    try? memory.write(va: messageAddress, bytes: out)
                    result |= resource
                    note += " [pseudo-received]"
                }
                return finish(result)
            }
        }
        if options & MachMsgOption.rcvMsg != 0 {
            var r = MachReceiveRequest(name: hi(5), options: options, buffer: data, size: UInt64(lo(6)), timeout: timeout)
            // xnu mach_msg2_trap: the sync-wait link target is always the
            // header's msgh_remote_port name, also on a combined send and
            // receive (libxpc's pipe routines with a special reply port).
            r.syncDestination = lo(3)
            if vector {
                let count = Int(lo(6))
                guard count == 1 || count == 2 else { return finish(MachMsgReturn.rcvInvalidArguments) }
                guard let vecs = readVectors(count) else { return finish(MachMsgReturn.rcvInvalidArguments) }
                r.buffer = vecs[0].rcvAddr != 0 ? vecs[0].rcvAddr : vecs[0].data
                r.size = UInt64(vecs[0].rcvSize)
                if count == 2 {
                    r.auxBuffer = vecs[1].rcvAddr != 0 ? vecs[1].rcvAddr : vecs[1].data
                    r.auxSize = UInt64(vecs[1].rcvSize)
                }
            }
            let result = receive(r, context: context, memory: memory)
            note += result.note
            return finish(result.code)
        }
        return finish(MachMsgReturn.success)
    }

    // MARK: Private Mach routines

    private func handleRoutine(_ number: UInt32, _ frame: inout TrapFrame, context: ThreadContext,
                               memory: any GuestVirtualMemory) -> TrapOutcome {
        let a = Array(frame.x[0..<8])
        func u32(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: a[i]) }
        func i32(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        let prefix = "trap yc \(hx(number & 0xFFFF))"
        var call = "private \(hx(number))"
        func kr(_ value: UInt32, _ extra: String = "") -> TrapOutcome {
            frame.x[0] = UInt64(value)
            frame.carry = false
            log("\(prefix) \(call) -> \(MachMsgReturn.name(value))\(extra)")
            return .resume
        }
        func write32(_ va: UInt64, _ v: UInt32) -> Bool { (try? memory.write(va: va, bytes: le32(v))) != nil }

        switch number {
        case Routine.hostGetClockService:
            let id = i32(1)
            call = "host_get_clock_service(host=\(hx(u32(0))), clock_id=\(id), out=\(hx(a[2])))"
            guard id == 0 || id == 1 else { return kr(MachKern.invalidArgument) }
            let p: IPCPort
            if let existing = clockPorts[id] {
                p = existing
            } else {
                p = newPort()
                p.kernelObject = .clock(id: id)
                clockPorts[id] = p
            }
            let name = copyoutNewSend(p)
            guard write32(a[2], name) else {
                _ = portDeallocate(name)
                return kr(MachKern.invalidAddress)
            }
            return kr(0, " [\(id == 0 ? "SYSTEM_CLOCK" : "CALENDAR_CLOCK") \(hx(name))]")

        case Routine.clockGetTime:
            call = "clock_get_time(clock=\(hx(u32(0))), out=\(hx(a[1])))"
            guard let (_, object) = kernelObject(named: u32(0)), case let .clock(id) = object else {
                return kr(MachKern.invalidArgument)
            }
            let t = id == 0 ? systemClock() : calendarClock()
            let bytes = le32(UInt32(truncatingIfNeeded: t.seconds)) + le32(UInt32(truncatingIfNeeded: t.nanoseconds))
            guard (try? memory.write(va: a[1], bytes: bytes)) != nil else { return kr(MachKern.invalidAddress) }
            return kr(0, " [\(t.seconds).\(t.nanoseconds)]")

        case Routine.semaphoreCreate:
            let value = i32(3)
            call = "semaphore_create(task=\(hx(u32(0))), out=\(hx(a[1])), policy=\(i32(2)), value=\(value))"
            guard value >= 0 else { return kr(MachKern.invalidArgument) }
            guard let (p, name) = makeKernelObjectName(.semaphore(serial: nextSerial())) else {
                return kr(MachKern.noSpace)
            }
            p.semaphore = KernelSemaphore(value: value)
            own(p)
            guard write32(a[1], name) else {
                _ = portDeallocate(name)
                portDeath(p)
                return kr(MachKern.invalidAddress)
            }
            return kr(0, " [\(hx(name))]")

        case Routine.semaphoreDestroy:
            let name = u32(1)
            call = "semaphore_destroy(task=\(hx(u32(0))), semaphore=\(hx(name)))"
            guard let (p, object) = kernelObject(named: name), case .semaphore = object, p.active else {
                return kr(MachKern.invalidName)
            }
            _ = portDeallocate(name)
            portDeath(p)
            return kr(0)

        case Routine.taskGetSpecialPort:
            let which = i32(1)
            call = "task_get_special_port(task=\(hx(u32(0))), which=\(which), out=\(hx(a[2])))"
            let target: MachIPC
            switch taskControl(named: u32(0)) {
            case .invalidDest: return kr(MachMsgReturn.sendInvalidDest)
            case .notTask: return kr(MachKern.invalidArgument)
            case let .task(t): target = t
            }
            let right: CarriedRight
            switch target.getSpecialPort(which) {
            case let .failure(e): return kr(e.code)
            case let .success(r): right = r
            }
            let (name, _) = copyout(right)
            guard write32(a[2], name) else {
                _ = portDeallocate(name)
                return kr(MachKern.invalidAddress)
            }
            return kr(0, " [\(hx(name))]")

        case Routine.taskSetSpecialPort:
            let which = i32(1)
            let name = u32(2)
            call = "task_set_special_port(task=\(hx(u32(0))), which=\(which), port=\(hx(name)))"
            let target: MachIPC
            switch taskControl(named: u32(0)) {
            case .invalidDest: return kr(MachMsgReturn.sendInvalidDest)
            case .notTask: return kr(MachKern.invalidArgument)
            case let .task(t): target = t
            }
            let right: CarriedRight
            switch copyinSendArgument(name) {
            case let .failure(e): return kr(e.code)
            case let .success(r): right = r
            }
            let result = target.setSpecialPort(which, right)
            if result != MachKern.success { release(right) }
            return kr(result)

        case Routine.portsRegister3:
            call = "mach_ports_register3(task=\(hx(u32(0))), \(hx(u32(1))), \(hx(u32(2))), \(hx(u32(3))))"
            let target: MachIPC
            switch taskControl(named: u32(0)) {
            case .invalidDest: return kr(MachMsgReturn.sendInvalidDest)
            case .notTask: return kr(MachKern.invalidArgument)
            case let .task(t): target = t
            }
            var rights: [CarriedRight] = []
            for k in 1...3 {
                switch copyinSendArgument(u32(k)) {
                case let .failure(e):
                    rights.forEach(release)
                    return kr(e.code)
                case let .success(r): rights.append(r)
                }
            }
            target.setRegisteredPorts(rights)
            return kr(0)

        case Routine.portsLookup3:
            call = "mach_ports_lookup3(task=\(hx(u32(0))), \(hx(a[1])), \(hx(a[2])), \(hx(a[3])))"
            let target: MachIPC
            switch taskControl(named: u32(0)) {
            case .invalidDest: return kr(MachMsgReturn.sendInvalidDest)
            case .notTask: return kr(MachKern.invalidArgument)
            case let .task(t): target = t
            }
            let names = target.slots.registered.map { copyout(target.copySend($0)).name }
            for k in 0..<3 where !write32(a[k + 1], names[k]) {
                names.forEach { _ = portDeallocate($0) }
                return kr(MachKern.invalidAddress)
            }
            return kr(0, " [\(names.map(hx).joined(separator: ","))]")

        case Routine.makeMemoryEntry:
            call = "mach_make_memory_entry_64(task=\(hx(u32(0))), size=\(hx(a[1])), offset=\(hx(a[2])), "
                + "permission=\(hx(u32(3))), handle=\(hx(a[4])), parent=\(hx(u32(5))))"
            let (code, note) = makeMemoryEntry(a, memory: memory)
            return kr(code, note)

        case Routine.vmMapObject:
            call = "mach_vm_map(task=\(hx(u32(0))), addr=\(hx(a[1])), size=\(hx(a[2])), mask=\(hx(a[3])), "
                + "flags=\(hx(u32(4))), block=\(hx(a[5])))"
            let (code, note) = vmMapObject(a, memory: memory)
            return kr(code, note)

        case Routine.vmRemap:
            call = "mach_vm_remap(task=\(hx(u32(0))), addr=\(hx(a[1])), size=\(hx(a[2])), mask=\(hx(a[3])), "
                + "flags=\(hx(u32(4))), block=\(hx(a[5])))"
            let (code, note) = vmRemap(a, memory: memory)
            return kr(code, note)

        case Routine.taskThreads:
            call = "task_threads(task=\(hx(u32(0))), list=\(hx(a[1])), count=\(hx(a[2])))"
            guard let kernel else { return kr(MachKern.failure) }
            let (code, note) = kernel.taskThreads(a, memory: memory)
            return kr(code, note)

        case Routine.portGetContext, Routine.portSetContext:
            // xnu osfmk/ipc/mach_port.c: a receive right in the task's space
            // (KERN_INVALID_RIGHT for a null/dead name, translate errors as
            // usual); a strictly guarded port reads as context 0 and cannot be
            // set (KERN_INVALID_ARGUMENT); a guarded one cannot be set either.
            let isGet = number == Routine.portGetContext
            let name = u32(1)
            call = isGet ? "mach_port_get_context(task=\(hx(u32(0))), name=\(hx(name)), out=\(hx(a[2])))"
                : "mach_port_set_context(task=\(hx(u32(0))), name=\(hx(name)), context=\(hx(a[2])))"
            guard isTaskSelf(u32(0)) else { return kr(MachMsgReturn.sendInvalidDest) }
            guard MachPortName.isValid(name) else { return kr(MachKern.invalidRight) }
            guard let i = lookup(name) else { return kr(MachKern.invalidName) }
            guard entries[i].bits & MachPortType.receive != 0, let p = entries[i].port else { return kr(MachKern.invalidRight) }
            if isGet {
                let value = p.strict ? 0 : p.context
                guard (try? memory.write(va: a[2], bytes: le64(value))) != nil else { return kr(MachKern.invalidAddress) }
                return kr(0, " [\(hx(value))]")
            }
            if p.strict && p.guarded { return kr(MachKern.invalidArgument) }
            if p.guarded { return kr(MachKern.invalidArgument) }
            p.context = a[2]
            return kr(0)

        case Routine.hostCreateMachVoucher:
            call = "host_create_mach_voucher(host=\(hx(u32(0))), recipes=\(hx(a[1])), size=\(i32(2)), voucher=\(hx(a[3])))"
            guard write32(a[3], 0) else { return kr(MachKern.invalidAddress) }
            return kr(0, " [voucher=0x0]")

        default:
            frame.x[0] = UInt64(DarwinKernel.Errno.ENOSYS)
            frame.x[1] = 0
            frame.carry = true
            log("\(prefix) \(call) -> unimplemented")
            return .unimplemented(description: "unimplemented private \(hx(number))\n" + frame.description)
        }
    }

    /// Copies in a port argument of a private routine as COPY_SEND
    /// (NULL/DEAD pass through). A bad name or one without a send right is
    /// `MACH_SEND_INVALID_RIGHT` (the MIG copyin failure).
    func copyinSendArgument(_ name: UInt32) -> Result<CarriedRight, KernError> {
        guard MachPortName.isValid(name) else { return .success(name == MachPortName.dead ? .dead : .null) }
        switch copyin(name, MachMsgType.copySend, slot: .body, apply: true) {
        case .failure: return .failure(KernError(MachMsgReturn.sendInvalidRight))
        case let .success(r): return .success(r)
        }
    }

    // MARK: kevent

    /// EVFILT_MACHPORT delivery with `MACH_RCV_MSG` (threads-and-events.md
    /// §3.7.3): receives the first message of `port` into [buffer,
    /// buffer+size) without waiting.
    public func receiveForKevent(port: UInt32, options: UInt32, buffer: UInt64, size: UInt64,
                                 context: ThreadContext, memory: any GuestVirtualMemory) -> KeventMachReceive? {
        lock.withLock {
            var r = MachReceiveRequest(name: port, options: UInt64(options), buffer: buffer, size: size, timeout: 0)
            r.mayBlock = false
            let result = receive(r, context: context, memory: memory)
            log("kevent machport receive \(hx(port)) -> \(MachMsgReturn.name(result.code))\(result.note)")
            return KeventMachReceive(returnCode: result.code, size: result.size, auxiliarySize: result.auxSize,
                                     data: result.code == MachMsgReturn.rcvTooLarge ? UInt64(result.identity) : 0)
        }
    }
}
