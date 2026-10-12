import Foundation
import YcodeDarwinABI

// The host task (stage4c-contract.md §3): a Mach port space with no VM and no
// BSD process, in the same `MachIPCSystem` as the guest tasks, used by Swift
// code in the VMM. Host services are plain host threads that receive on
// ports of the host task and reply. Messages between guests and host ports
// are ordinary Mach messages (`mach-ipc.md`, `processes.md` §4): rights are
// copied in from the sender and out into the receiver, OOL memory is a
// snapshot, and trailers carry the sender's audit token.
//
// Every method may be called from any host thread that holds no kernel lock
// (it takes the system lock itself). A blocking call (a receive with a
// timeout other than zero, or a send to a full queue) must not be made with
// the lock held.

/// A failed host send or receive: a `mach_msg_return_t` or `kern_return_t`.
public struct MachHostError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: UInt32
    public init(_ code: UInt32) { self.code = code }
    public var description: String { MachMsgReturn.name(code) }

    public static let timedOut = MachHostError(MachMsgReturn.rcvTimedOut)
    public static let portChanged = MachHostError(MachMsgReturn.rcvPortChanged)
    public static let interrupted = MachHostError(MachMsgReturn.rcvInterrupted)
    public static let invalidName = MachHostError(MachMsgReturn.rcvInvalidName)
}

/// A descriptor of an outgoing host message.
public enum MachHostDescriptor: Equatable, Sendable {
    /// A right named in the host task, with a `MACH_MSG_TYPE_*` disposition
    /// (16 MOVE_RECEIVE, 17 MOVE_SEND, 18 MOVE_SEND_ONCE, 19 COPY_SEND,
    /// 20 MAKE_SEND, 21 MAKE_SEND_ONCE). Name 0 / 0xFFFFFFFF send NULL / DEAD.
    case port(name: UInt32, disposition: UInt32)
    /// Out-of-line bytes (the receiver gets a fresh region holding a copy).
    /// `copy` is `MACH_MSG_PHYSICAL_COPY` (0) or `MACH_MSG_VIRTUAL_COPY` (1).
    case ool(data: [UInt8], copy: UInt8 = 1, volatile: Bool = false)
    /// An out-of-line array of rights named in the host task, all with one disposition.
    case oolPorts(names: [UInt32], disposition: UInt32)
}

/// A message the host sends.
public struct MachHostOutgoingMessage: Equatable, Sendable {
    /// Destination name in the host task and its disposition (usually
    /// COPY_SEND 19, MOVE_SEND 17, or MOVE_SEND_ONCE 18 for a reply).
    public var remotePort: UInt32
    public var remoteDisposition: UInt32
    /// Reply port (`msgh_local_port`) and its disposition (0 = none;
    /// usually MAKE_SEND_ONCE 21).
    public var localPort: UInt32
    public var localDisposition: UInt32
    public var id: Int32
    public var descriptors: [MachHostDescriptor]
    /// The inline bytes after the descriptors. Its length must be a multiple
    /// of 4 (`MACH_SEND_MSG_TOO_SMALL` otherwise).
    public var body: [UInt8]
    /// `MACH_MSGH_BITS_COMPLEX`; nil = complex exactly when there are descriptors.
    public var complex: Bool?

    public init(remotePort: UInt32, remoteDisposition: UInt32 = MachMsgType.copySend, localPort: UInt32 = 0,
                localDisposition: UInt32 = 0, id: Int32, descriptors: [MachHostDescriptor] = [], body: [UInt8] = [],
                complex: Bool? = nil) {
        self.remotePort = remotePort
        self.remoteDisposition = remoteDisposition
        self.localPort = localPort
        self.localDisposition = localDisposition
        self.id = id
        self.descriptors = descriptors
        self.body = body
        self.complex = complex
    }

    public var isComplex: Bool { complex ?? !descriptors.isEmpty }
}

/// A descriptor of a received message. Rights are already copied out into
/// the host task: `name` is the host task's name, `type` the received type
/// (16 PORT_RECEIVE, 17 PORT_SEND, 18 PORT_SEND_ONCE).
public enum MachHostReceivedDescriptor: Equatable, Sendable {
    case port(name: UInt32, type: UInt32)
    case ool(data: [UInt8], copy: UInt8, volatile: Bool)
    case oolPorts(names: [UInt32], type: UInt32)
    /// A guarded port descriptor (`MACH_MSG_GUARDED_PORT_DESCRIPTOR`): the
    /// receive right arrives unguarded in the host task.
    case guardedPort(name: UInt32, flags: UInt16, type: UInt32)
}

/// The sender identity of a received message (`processes.md` §4.5).
public struct MachAuditToken: Equatable, Sendable {
    /// The eight words: auid, euid, egid, ruid, rgid, pid, asid, pid version.
    public var words: [UInt32]
    public init(words: [UInt32]) { self.words = words }
    public var auid: UInt32 { words[0] }
    public var euid: UInt32 { words[1] }
    public var egid: UInt32 { words[2] }
    public var ruid: UInt32 { words[3] }
    public var rgid: UInt32 { words[4] }
    public var pid: Int32 { Int32(bitPattern: words[5]) }
    public var auditSessionID: UInt32 { words[6] }
    public var pidVersion: UInt32 { words[7] }
}

/// A message the host received.
public struct MachHostReceivedMessage: Equatable, Sendable {
    /// `msgh_bits` as received (remote = reply type, local = destination type, COMPLEX).
    public var bits: UInt32
    /// The reply right (`msgh_remote_port`) as a host-task name (0 = none,
    /// 0xFFFFFFFF = dead), and its received type (0 when there is none).
    public var replyPort: UInt32
    public var replyType: UInt32
    /// The host-task name of the port the message arrived on (`msgh_local_port`).
    public var localPort: UInt32
    public var voucher: UInt32
    public var id: Int32
    public var descriptors: [MachHostReceivedDescriptor]
    /// The inline bytes after the descriptors.
    public var body: [UInt8]
    /// The received size without trailer (`msgh_size`).
    public var size: UInt32
    public var seqno: UInt32
    /// The port's context (`mach_port_context_t`) at receipt.
    public var context: UInt64
    /// Nil for kernel-originated messages (notifications, MIG replies).
    public var sender: MachAuditToken?

    public var isComplex: Bool { bits & MachMsgBits.complex != 0 }
    public var isFromKernel: Bool { sender == nil }
    /// The disposition that sends a reply on `replyPort` (MOVE_SEND_ONCE or MOVE_SEND).
    public var replyDisposition: UInt32 { replyType }

    /// The message in user layout as a guest would see it (header, body
    /// word, descriptors, inline data; no trailer), with the host task's
    /// names and OOL addresses written as 0.
    public var wireImage: [UInt8] {
        var out = le32(bits) + le32(size) + le32(replyPort) + le32(localPort) + le32(voucher)
            + le32(UInt32(bitPattern: id))
        if isComplex {
            out += le32(UInt32(descriptors.count))
            for d in descriptors {
                switch d {
                case let .port(name, type):
                    out += le32(name) + le32(0) + [0, 0, UInt8(truncatingIfNeeded: type), MachMsgDescriptor.port]
                case let .ool(data, copy, volatile):
                    out += le64(0) + [copy == MachMsgDescriptor.virtualCopy ? 1 : 0, copy, 0,
                                      volatile ? MachMsgDescriptor.oolVolatile : MachMsgDescriptor.ool]
                        + le32(UInt32(data.count))
                case let .oolPorts(names, type):
                    out += le64(0) + [1, MachMsgDescriptor.virtualCopy, UInt8(truncatingIfNeeded: type),
                                      MachMsgDescriptor.oolPorts] + le32(UInt32(names.count))
                case let .guardedPort(name, flags, type):
                    out += le64(0) + [UInt8(flags & 0xFF), UInt8(flags >> 8), UInt8(truncatingIfNeeded: type),
                                      MachMsgDescriptor.guardedPort] + le32(name)
                }
            }
        }
        return out + body
    }
}

/// The host task: a Mach port space owned by Swift code in the VMM.
public final class MachHostTask: @unchecked Sendable {
    public let lock: KernelLock
    public let system: MachIPCSystem
    /// The underlying space (no kernel, no memory).
    let ipc: MachIPC
    /// The receive right of the host bootstrap port, named in this task.
    public let bootstrapPort: UInt32

    init(lock: KernelLock, system: MachIPCSystem, log: @escaping (String) -> Void) {
        self.lock = lock
        self.system = system
        ipc = MachIPC(lock: lock, log: log, pid: 0, uid: 0, gid: 0, system: system)
        let (kr, name) = ipc.portAllocate(right: MachPortRight.receive)
        precondition(kr == 0)
        bootstrapPort = name
        system.hostBootstrapObject = ipc.entries[Int(name >> 8)].port
    }

    // MARK: Identity

    /// What the trailers of the host's messages say (default pid 0, uid 0, gid 0).
    public var pid: Int32 {
        get { lock.withLock { ipc.pid } }
        set { lock.withLock { ipc.pid = newValue } }
    }
    public var uid: UInt32 {
        get { lock.withLock { ipc.uid } }
        set { lock.withLock { ipc.uid = newValue } }
    }
    public var gid: UInt32 {
        get { lock.withLock { ipc.gid } }
        set { lock.withLock { ipc.gid = newValue } }
    }
    /// The trace sink (one line per host send/receive).
    public var log: (String) -> Void {
        get { lock.withLock { ipc.log } }
        set { lock.withLock { ipc.log = newValue } }
    }

    // MARK: Ports

    /// A new receive right; with `sendRight`, also a send right under the
    /// same name (as `mach_port_construct` with INSERT_SEND_RIGHT).
    /// `qlimit` sets the queue limit (default 5). Returns its name.
    public func makePort(sendRight: Bool = false, qlimit: Int? = nil) throws -> UInt32 {
        try lock.withLock {
            let flags = (sendRight ? MachPortConstruct.insertSendRight : 0) | (qlimit != nil ? MachPortConstruct.qlimit : 0)
            let (kr, name) = ipc.portConstruct(MachPortOptions(flags: flags, qlimit: UInt32(qlimit ?? 0)), context: 0)
            guard kr == 0 else { throw MachHostError(kr) }
            return name
        }
    }

    /// A fileport (`processes.md` §4.9) holding `file`, with one send right
    /// named in the host task (as `fileport_makeport` gives a process).
    /// The port lives while send rights to it exist. Returns its name.
    public func makeFileport(_ file: DarwinOpenFile) throws -> UInt32 {
        try lock.withLock {
            let p = ipc.newPort()
            p.kernelObject = .fileport(serial: p.serial)
            p.fileportFile = file
            p.srights = 1
            let (name, ok) = ipc.copyout(.send(p))
            guard ok else { throw MachHostError(MachKern.noSpace) }
            return name
        }
    }

    /// A new port set. Returns its name.
    public func makePortSet() throws -> UInt32 {
        try lock.withLock {
            let (kr, name) = ipc.portAllocate(right: MachPortRight.portSet)
            guard kr == 0 else { throw MachHostError(kr) }
            return name
        }
    }

    /// `mach_port_insert_member` / `mach_port_extract_member`.
    public func addMember(_ port: UInt32, to set: UInt32) throws {
        try check(lock.withLock { ipc.portInsertMember(port, set: set) })
    }

    public func removeMember(_ port: UInt32, from set: UInt32) throws {
        try check(lock.withLock { ipc.portExtractMember(port, set: set) })
    }

    /// `mach_port_insert_right(task, name, poly, disposition)` within the
    /// host task, e.g. `(p, p, MAKE_SEND)` adds a send right to a receive right.
    public func insertRight(_ name: UInt32, from poly: UInt32, disposition: UInt32) throws {
        try check(lock.withLock { ipc.portInsertRight(name, poly: poly, polyPoly: disposition) })
    }

    /// `mach_port_destroy`: every right under the name goes (a receive right:
    /// the port dies, or is diverted by a port-destroyed request).
    public func destroyPort(_ name: UInt32) throws {
        try check(lock.withLock { ipc.portDestroy(name) })
    }

    /// `mach_port_deallocate`: one user reference of a send, send-once, or
    /// dead name.
    public func deallocate(_ name: UInt32) throws {
        try check(lock.withLock { ipc.portDeallocate(name) })
    }

    /// `mach_port_mod_refs(name, right, delta)`.
    public func modRefs(_ name: UInt32, right: UInt32, delta: Int32) throws {
        try check(lock.withLock { ipc.portModRefs(name, right: right, delta: delta) })
    }

    /// The rights under a name (`MACH_PORT_TYPE_*` bits and user references), nil if none.
    public func rights(of name: UInt32) -> (type: UInt32, urefs: UInt32)? { ipc.entry(name) }

    /// `mach_port_request_notification(name, id, sync, notify, MAKE_SEND_ONCE)`:
    /// `id` is a `MachNotify` value (69 port-destroyed, 70 no-senders,
    /// 72 dead-name, 66 send-possible); `notifyPort` is a receive right of the
    /// host task (a send-once right is made from it), or 0 to cancel. Returns
    /// the host-task name of the previous request's send-once right (0 if none).
    @discardableResult
    public func requestNotification(_ name: UInt32, id: Int32, sync: UInt32 = 0, notifyPort: UInt32) throws -> UInt32 {
        try lock.withLock {
            var notify: CarriedRight = .null
            if MachPortName.isValid(notifyPort) {
                switch ipc.copyin(notifyPort, MachMsgType.makeSendOnce, slot: .routine, apply: true) {
                case .failure(.noEntry): throw MachHostError(MachKern.invalidName)
                case .failure(.noRight): throw MachHostError(MachKern.invalidRight)
                case let .success(r): notify = r
                }
            }
            let (kr, previous) = ipc.portRequestNotification(name, id: id, sync: sync, notify: notify)
            guard kr == 0 else {
                if case let .sendOnce(so) = notify { ipc.releaseSendOnceQuietly(so) }
                throw MachHostError(kr)
            }
            return ipc.copyout(previous).name
        }
    }

    // MARK: Messages

    /// Sends a message (`mach_msg` SEND semantics). `timeout` (nanoseconds)
    /// bounds the wait for room in a full queue; nil waits forever, 0 never
    /// waits. On failure after the rights were copied in, they come back
    /// into the host task (pseudo-receive). Throws `MachHostError`.
    public func send(_ message: MachHostOutgoingMessage, timeout: UInt64? = nil) throws {
        let code = lock.withLock { ipc.hostSend(message, timeout: timeout) }
        guard code == 0 else { throw MachHostError(code) }
    }

    /// Receives the next message on a receive right or a port set of the
    /// host task. `timeout` in nanoseconds: nil waits forever, 0 polls.
    /// Throws `MachHostError` (`.timedOut`, `.portChanged` when the port is
    /// destroyed or moved while waiting, `.interrupted`, `.invalidName`).
    public func receive(on name: UInt32, timeout: UInt64? = nil) throws -> MachHostReceivedMessage {
        let result = lock.withLock { ipc.hostReceive(name, timeout: timeout) }
        switch result {
        case let .success(m): return m
        case let .failure(e): throw MachHostError(e.code)
        }
    }

    /// Replies to `request` on its reply right (MOVE_SEND_ONCE or MOVE_SEND
    /// as received). `id` defaults to the request id + 100 (MIG). Throws
    /// `MachHostError(MACH_SEND_INVALID_DEST)` when the request has no reply port.
    public func reply(to request: MachHostReceivedMessage, id: Int32? = nil, descriptors: [MachHostDescriptor] = [],
                      body: [UInt8] = [], timeout: UInt64? = 0) throws {
        guard MachPortName.isValid(request.replyPort) else { throw MachHostError(MachMsgReturn.sendInvalidDest) }
        try send(MachHostOutgoingMessage(remotePort: request.replyPort, remoteDisposition: request.replyDisposition,
                                         id: id ?? request.id &+ 100, descriptors: descriptors, body: body),
                 timeout: timeout)
    }

    /// Drops every right a received message brought (its reply right and
    /// its descriptors' rights), for a message the host does not answer.
    public func discard(_ message: MachHostReceivedMessage) {
        lock.withLock {
            var names: [UInt32] = [message.replyPort]
            for d in message.descriptors {
                switch d {
                case let .port(name, _), let .guardedPort(name, _, _): names.append(name)
                case let .oolPorts(list, _): names += list
                case .ool: break
                }
            }
            for name in names where MachPortName.isValid(name) {
                guard let (type, _) = ipc.entry(name) else { continue }
                if type & MachPortType.receive != 0 {
                    _ = ipc.portModRefs(name, right: MachPortRight.receive, delta: -1)
                } else {
                    _ = ipc.portDeallocate(name)
                }
            }
        }
    }

    // MARK: Giving rights to guest tasks

    /// Gives `task` a send right to the host port `name` (a receive or send
    /// right of the host task) and stores it as special port `which`
    /// (`TaskSpecialPort.bootstrap` = 4, …) as `task_set_special_port`
    /// would. For the bootstrap slot, before the task runs, the right is also
    /// installed under the well-known name `0x503`. Throws `MachHostError`.
    public func setSpecialPort(of task: MachIPC, which: Int32, to name: UInt32) throws {
        try lock.withLock {
            let disposition: UInt32
            guard let (type, _) = ipc.entry(name) else { throw MachHostError(MachKern.invalidName) }
            disposition = type & MachPortType.send != 0 ? MachMsgType.copySend : MachMsgType.makeSend
            guard case let .success(r) = ipc.copyin(name, disposition, slot: .body, apply: true) else {
                throw MachHostError(MachKern.invalidRight)
            }
            let kr = task.setSpecialPort(which, r)
            guard kr == 0 else {
                ipc.release(r)
                throw MachHostError(kr)
            }
            if which == TaskSpecialPort.bootstrap { task.syncWellKnownNames() }
        }
    }

    /// Copies a right of the host task into `task`'s space (as a message
    /// would) and returns its name there. `disposition` as for descriptors.
    public func give(_ name: UInt32, disposition: UInt32, to task: MachIPC) throws -> UInt32 {
        try lock.withLock {
            guard MachMsgType.isPortDisposition(disposition) else { throw MachHostError(MachKern.invalidValue) }
            switch ipc.copyin(name, disposition, slot: .body, apply: true) {
            case .failure(.noEntry): throw MachHostError(MachKern.invalidName)
            case .failure(.noRight): throw MachHostError(MachKern.invalidRight)
            case let .success(r): return task.copyout(r).name
            }
        }
    }

    /// Ends the host task: its space is destroyed as at task exit
    /// (`processes.md` §4.6) — the host bootstrap port and every other host
    /// receive right die; guests see dead names.
    /// Also detaches it from the system (which breaks the reference cycle
    /// system → host task → space → system).
    public func shutdown() {
        lock.withLock {
            ipc.terminateTask()
            if system.hostTask === self {
                system.hostTask = nil
                system.hostBootstrapObject = nil
            }
        }
    }

    private func check(_ kr: UInt32) throws {
        guard kr == 0 else { throw MachHostError(kr) }
    }
}

extension MachIPCSystem {
    /// Makes the host task (once; later calls return the same one) with the
    /// system's kernel lock. Its first port is the host bootstrap port.
    @discardableResult
    public func makeHostTask(lock: KernelLock, log: @escaping (String) -> Void = { _ in }) -> MachHostTask {
        lock.withLock {
            if let hostTask { return hostTask }
            let t = MachHostTask(lock: lock, system: self, log: log)
            hostTask = t
            return t
        }
    }
}

extension DarwinSystem {
    /// The host task of this system (made on first use), sharing its lock.
    public var hostTask: MachHostTask { mach.makeHostTask(lock: lock) }
}

// MARK: - The space side

extension MachIPC {
    /// A host send (lock held). Returns a `mach_msg_return_t`.
    func hostSend(_ out: MachHostOutgoingMessage, timeout: UInt64?) -> UInt32 {
        let complex = out.isComplex
        guard out.body.count % 4 == 0 else { return MachMsgReturn.sendMsgTooSmall }
        var size = 24 + out.body.count
        if complex {
            size += 4
            for d in out.descriptors {
                if case .port = d { size += 12 } else { size += 16 }
            }
        } else if !out.descriptors.isEmpty {
            return MachMsgReturn.sendTooLarge
        }
        guard size <= Int(MachIPCLimits.maxSendSize) else { return MachMsgReturn.sendTooLarge }
        let bits = MachMsgBits.make(remote: out.remoteDisposition, local: out.localDisposition)
            | (complex ? MachMsgBits.complex : 0)
        let request = MachSendRequest(bits: bits, size: size, remote: out.remotePort, local: out.localPort,
                                      voucher: 0, id: out.id, descriptorCount: UInt32(out.descriptors.count), body: [])
        var m: KMessage
        switch copyinHeader(request) {
        case let .failure(e): return e.code
        case let .success(header): m = header
        }
        m.complex = complex
        m.inline = out.body
        m.sender = senderIdentity
        var rights = 0, oolBytes: UInt64 = 0
        func right(_ name: UInt32, _ disposition: UInt32) -> CarriedRight? {
            guard MachPortName.isValid(name) else { return name == 0 ? .null : .dead }
            guard case let .success(r) = copyin(name, disposition, slot: .body, apply: true) else { return nil }
            return r
        }
        for d in out.descriptors {
            switch d {
            case let .port(name, disposition):
                rights += 1
                guard MachMsgType.isPortDisposition(disposition), rights <= MachIPCLimits.maxRightsPerMessage else {
                    destroyMessage(m)
                    return MachMsgReturn.sendInvalidType
                }
                guard let r = right(name, disposition) else {
                    destroyMessage(m)
                    return MachMsgReturn.sendInvalidRight
                }
                m.items.append(.port(r, type: MachMsgType.received(disposition)))
            case let .ool(data, copy, volatile):
                oolBytes += UInt64(data.count)
                guard copy <= MachMsgDescriptor.virtualCopy, oolBytes <= MachIPCLimits.maxOOLBytes else {
                    destroyMessage(m)
                    return copy > MachMsgDescriptor.virtualCopy ? MachMsgReturn.sendInvalidType : MachMsgReturn.vmKernel
                }
                m.items.append(.ool(data: data, copy: copy, volatile: volatile))
            case let .oolPorts(names, disposition):
                rights += names.count
                guard MachMsgType.isPortDisposition(disposition), rights <= MachIPCLimits.maxRightsPerMessage else {
                    destroyMessage(m)
                    return MachMsgReturn.sendInvalidType
                }
                var list: [CarriedRight] = []
                for name in names {
                    guard let r = right(name, disposition) else {
                        list.forEach(release)
                        destroyMessage(m)
                        return MachMsgReturn.sendInvalidRight
                    }
                    list.append(r)
                }
                m.items.append(.oolPorts(list, type: MachMsgType.received(disposition), copy: MachMsgDescriptor.virtualCopy))
            }
        }
        if isCircular(m) {
            destroyMessage(m)
            log("host send id \(out.id) -> MACH_MSG_SUCCESS [circular: destroyed]")
            return MachMsgReturn.success
        }
        var options = MachMsgOption.sendMsg
        var ms: UInt32 = 0
        if let timeout {
            options |= MachMsgOption.sendTimeout
            ms = UInt32(min((timeout + 999_999) / 1_000_000, UInt64(UInt32.max)))
        }
        let (code, pseudo, note) = deliver(m, options: options, timeout: ms, msg2: false)
        if let pseudo {
            // Pseudo-receive: the rights come back into the host task.
            _ = copyout(pseudo.destination)
            _ = copyout(pseudo.reply)
            for item in pseudo.items {
                switch item {
                case let .port(r, _), let .guarded(r, _, _): _ = copyout(r)
                case let .oolPorts(list, _, _): list.forEach { _ = copyout($0) }
                case .ool: break
                }
            }
        }
        log("host send id \(out.id) to \(hx(out.remotePort)) -> \(MachMsgReturn.name(code))\(note)")
        return code
    }

    /// A host receive (lock held at depth 1 when it may block).
    func hostReceive(_ name: UInt32, timeout: UInt64?) -> Result<MachHostReceivedMessage, KernError> {
        guard let i = lookup(name) else { return .failure(KernError(MachMsgReturn.rcvInvalidName)) }
        let set = entries[i].set
        let port: IPCPort? = set == nil && entries[i].bits & T.receive != 0 ? entries[i].port : nil
        guard set != nil || port != nil else { return .failure(KernError(MachMsgReturn.rcvInvalidName)) }
        let deadline = timeout.map { KernelClock.deadline(afterNanoseconds: $0) }
        let source: IPCPort
        switch awaitMessage(name: name, slot: i, port: port, set: set, deadline: deadline, mayBlock: timeout != 0) {
        case let .failure(e): return .failure(e)
        case let .success(p): source = p
        }
        let (m, seqno) = dequeue(source)
        let (replyName, _) = copyout(m.reply)
        let local: UInt32 = !source.active ? MachPortName.dead
            : (source.receiver === self ? reverse[ObjectIdentifier(source)] ?? 0 : 0)
        consumeDestination(m.destination)
        var descriptors: [MachHostReceivedDescriptor] = []
        for item in m.items {
            switch item {
            case let .port(r, type): descriptors.append(.port(name: copyout(r).name, type: type))
            case let .guarded(r, flags, type): descriptors.append(.guardedPort(name: copyout(r).name, flags: flags, type: type))
            case let .ool(data, copy, volatile): descriptors.append(.ool(data: data, copy: copy, volatile: volatile))
            case let .oolPorts(rights, type, _): descriptors.append(.oolPorts(names: rights.map { copyout($0).name }, type: type))
            }
        }
        let bits = (m.complex ? MachMsgBits.complex : 0) | MachMsgBits.make(remote: m.replyType, local: m.destinationType)
        let sender: MachAuditToken? = m.fromKernel ? nil : MachAuditToken(words: (m.sender ?? senderIdentity).auditToken)
        let received = MachHostReceivedMessage(
            bits: bits, replyPort: replyName, replyType: m.reply.port == nil && replyName == 0 ? 0 : m.replyType,
            localPort: local, voucher: m.voucherRaw, id: m.id, descriptors: descriptors, body: m.inline,
            size: UInt32(m.size), seqno: seqno, context: source.context, sender: sender)
        log("host receive on \(hx(name)) -> id \(m.id) size \(m.size) seqno \(seqno)"
            + (sender.map { " from pid \($0.pid)" } ?? " from kernel"))
        return .success(received)
    }
}
