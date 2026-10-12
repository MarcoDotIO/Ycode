import Foundation
import YcodeDarwinABI

/// In-process Mach IPC of stage 4a (`specs/simulator/stage4a-contract.md` §6,
/// `specs/simulator/mach-ipc.md` §1–§5): one task's port name space, ports
/// and port sets, user references, messages, notifications, and the Mach
/// traps and Ycode-private Mach-routine traps that use them.
///
/// One instance serves one VM. Every method expects the kernel lock to be
/// held, except `handleTrap`, which takes it when the caller does not hold
/// it, and the small public helpers, which take it re-entrantly. Blocking
/// sends and receives wait on `WaitQueue`s of that lock.
///
/// Ycode choices (normative for the VMM, `mach-ipc.md` §1.4): names are
/// allocated deterministically (sequential indices from 1, last-freed-first
/// reuse, generation step 1). The well-known names are real entries: task
/// `0x103`, main thread `0x203`, host `0x303`, bootstrap `0x503`; index 4 is
/// the first free slot.
public final class MachIPC: MachIPCHandling, @unchecked Sendable {
    // MARK: Configuration

    /// The VM's kernel lock.
    public let lock: KernelLock
    /// Receives one line per trap.
    public var log: (String) -> Void
    /// EVFILT_MACHPORT: called (lock held) whenever a message is queued on a
    /// receive right in the space: once with the port's name and once with
    /// the name of each port set that contains it.
    public var messageQueuedHandler: ((_ name: UInt32) -> Void)?
    /// Called (lock held) when a receive right or a port set leaves the space
    /// (moved away or destroyed), with its former name (kevent `EV_EOF`).
    public var receiveRightGoneHandler: ((_ name: UInt32) -> Void)?
    /// What the trailer reports for user senders (`mach-ipc.md` §2.6).
    public var pid: Int32
    public var uid: UInt32
    public var gid: UInt32
    /// The system clock (uptime since VM start) and the calendar clock, for
    /// `clock_get_time`.
    public var systemClock: () -> (seconds: UInt64, nanoseconds: UInt64)
    public var calendarClock: () -> (seconds: UInt64, nanoseconds: UInt64)

    // MARK: Name space

    var entries: [IPCEntry] = [IPCEntry()]
    /// Freed slots below `nextFresh`, most recently freed last.
    var freeList: [Int] = []
    /// The next never-used index.
    var nextFresh = 1
    /// Port → its send/receive name in the space.
    var reverse: [ObjectIdentifier: UInt32] = [:]
    var serialCounter: UInt64 = 0
    var stampCounter: UInt64 = 0

    // MARK: Kernel objects

    let taskPort: IPCPort
    let hostPort: IPCPort
    let bootstrapPort: IPCPort
    let mainThreadPort: IPCPort
    var clockPorts: [Int32: IPCPort] = [:]
    /// `task_set_special_port` values: send rights the kernel holds.
    var specialPorts: [Int32: CarriedRight] = [:]
    /// Each thread's bound special reply port, by thread id.
    var specialReplyPorts: [UInt64: IPCPort] = [:]

    /// The well-known names.
    public static let taskName: UInt32 = 0x103
    public static let mainThreadName: UInt32 = 0x203
    public static let hostName: UInt32 = 0x303
    public static let bootstrapName: UInt32 = 0x503

    // MARK: Init

    /// - Parameters:
    ///   - lock: the VM's kernel lock (`DarwinKernel.lock`).
    ///   - log: the trace sink.
    ///   - pid: the task's pid, for trailers.
    public init(lock: KernelLock, log: @escaping (String) -> Void = { _ in },
                pid: Int32 = VMLayout.guestPID, uid: UInt32 = DarwinFileSystem.guestUID,
                gid: UInt32 = DarwinFileSystem.guestGID) {
        self.lock = lock
        self.log = log
        self.pid = pid
        self.uid = uid
        self.gid = gid
        let start = KernelClock.now()
        systemClock = {
            let ns = KernelClock.now() &- start
            return (ns / 1_000_000_000, ns % 1_000_000_000)
        }
        calendarClock = {
            let t = Date().timeIntervalSince1970
            let s = t.rounded(.down)
            return (UInt64(max(0, s)), UInt64(max(0, (t - s) * 1e9)))
        }
        var serial: UInt64 = 0
        func kobject(_ o: MachKernelObject) -> IPCPort {
            serial += 1
            let p = IPCPort(serial: serial)
            p.kernelObject = o
            return p
        }
        taskPort = kobject(.task)
        mainThreadPort = kobject(.thread(serial: 0))
        hostPort = kobject(.host)
        bootstrapPort = kobject(.bootstrap)
        serialCounter = serial
        // Indices 1, 2, 3, 5 are the well-known names; 4 is the first free slot.
        seed(taskPort, index: 1)
        seed(mainThreadPort, index: 2)
        seed(hostPort, index: 3)
        seed(bootstrapPort, index: 5)
        nextFresh = 6
        freeList = [4]
    }

    /// A `MachIPC` wired to `kernel`: its lock, log, pid, and clocks. Does not
    /// attach itself (set `kernel.machIPC`).
    public convenience init(kernel: DarwinKernel) {
        self.init(lock: kernel.lock, log: { [unowned kernel] in kernel.log($0) }, pid: kernel.pid)
        systemClock = { [unowned kernel] in
            let ticks = kernel.counter() &- kernel.bootCounter
            let f = max(kernel.counterFrequency, 1)
            return (ticks / f, (ticks % f) * 1_000_000_000 / f)
        }
        calendarClock = { [unowned kernel] in
            let w = kernel.wallClock()
            return (UInt64(max(0, w.seconds)), UInt64(max(0, w.nanoseconds)))
        }
    }

    private func seed(_ p: IPCPort, index: Int) {
        while entries.count <= index { entries.append(IPCEntry()) }
        entries[index].generation = 0
        entries[index].inUse = true
        entries[index].bits = MachPortType.send
        entries[index].urefs = 1
        entries[index].port = p
        p.srights = 1
        reverse[ObjectIdentifier(p)] = nameOf(index)
    }

    // MARK: Helpers

    func nextSerial() -> UInt64 {
        serialCounter += 1
        return serialCounter
    }

    func nextStamp() -> UInt64 {
        stampCounter += 1
        return stampCounter
    }

    func newPort() -> IPCPort { IPCPort(serial: nextSerial()) }

    func nameOf(_ index: Int) -> UInt32 {
        UInt32(index) << 8 | entries[index].generation << 2 | 3
    }

    /// The slot of `name` if it is in use with that exact name (no dead-name
    /// conversion).
    func slot(of name: UInt32) -> Int? {
        let i = Int(name >> 8)
        guard i > 0, i < entries.count, entries[i].inUse, nameOf(i) == name else { return nil }
        return i
    }

    /// The slot of `name` after the lazy dead-name conversion (§1.5).
    func lookup(_ name: UInt32) -> Int? {
        guard MachPortName.isValid(name), let i = slot(of: name) else { return nil }
        convertIfDead(i)
        return i
    }

    /// Adds `delta` to a uref count, pegging at the maximum (§1.2 rule 5).
    func pegAdd(_ urefs: UInt32, _ delta: UInt32) -> UInt32 {
        let sum = UInt64(urefs) + UInt64(delta)
        return sum >= UInt64(MachPortName.urefsMax) ? MachPortName.urefsMax : UInt32(sum)
    }

    /// Converts a send or send-once entry whose port died into a dead name.
    func convertIfDead(_ i: Int) {
        guard let p = entries[i].port, !p.active,
              entries[i].bits & (MachPortType.send | MachPortType.sendOnce) != 0 else { return }
        let name = nameOf(i)
        var urefs: UInt32
        if entries[i].bits & MachPortType.send != 0 {
            p.srights -= 1
            urefs = entries[i].urefs
            if reverse[ObjectIdentifier(p)] == name { reverse[ObjectIdentifier(p)] = nil }
        } else {
            p.sorights -= 1
            urefs = 1
        }
        if p.deadNameNotified.remove(name) != nil { urefs = pegAdd(urefs, 1) }
        entries[i].bits = MachPortType.deadName
        entries[i].urefs = urefs
        entries[i].port = nil
    }

    /// Takes a free slot (last freed first, else the next fresh index).
    func allocateSlot() -> Int? {
        if let i = freeList.popLast() { return i }
        while nextFresh < entries.count && entries[nextFresh].inUse { nextFresh += 1 }
        guard nextFresh <= MachIPCLimits.maxIndex else { return nil }
        if nextFresh == entries.count { entries.append(IPCEntry()) }
        let i = nextFresh
        nextFresh += 1
        return i
    }

    /// Creates an entry under a kernel-chosen name. Nil when the table is full.
    func newEntry(bits: UInt32, urefs: UInt32, port: IPCPort? = nil, set: IPCPortSet? = nil) -> UInt32? {
        guard let i = allocateSlot() else { return nil }
        entries[i].generation = (entries[i].generation + 1) & 63
        return fill(i, bits: bits, urefs: urefs, port: port, set: set)
    }

    private func fill(_ i: Int, bits: UInt32, urefs: UInt32, port: IPCPort?, set: IPCPortSet?) -> UInt32 {
        entries[i].inUse = true
        entries[i].bits = bits
        entries[i].urefs = urefs
        entries[i].port = port
        entries[i].set = set
        let name = nameOf(i)
        if let port, bits & (MachPortType.send | MachPortType.receive) != 0 {
            reverse[ObjectIdentifier(port)] = name
        }
        set?.name = name
        return name
    }

    enum NameClaim { case free(Int), sameName(Int) }

    /// Checks a caller-chosen name (§1.4). Returns the slot, free or holding
    /// exactly that name, or a `kern_return_t`.
    func claim(name: UInt32) -> Result<NameClaim, KernError> {
        guard MachPortName.isValid(name), name & 3 == 3 else { return .failure(KernError(MachKern.invalidValue)) }
        let i = Int(name >> 8)
        guard i > 0 else { return .failure(KernError(MachKern.failure)) }
        guard i <= MachIPCLimits.maxIndex else { return .failure(KernError(MachKern.noSpace)) }
        if i < entries.count, entries[i].inUse {
            return nameOf(i) == name ? .success(.sameName(i)) : .failure(KernError(MachKern.failure))
        }
        return .success(.free(i))
    }

    /// Creates an entry under a caller-chosen free slot `i` with `name`.
    func newEntry(at i: Int, name: UInt32, bits: UInt32, urefs: UInt32, port: IPCPort? = nil,
                  set: IPCPortSet? = nil) -> UInt32 {
        while entries.count <= i { entries.append(IPCEntry()) }
        if let k = freeList.lastIndex(of: i) { freeList.remove(at: k) }
        entries[i].generation = (name & 0xFF) >> 2
        return fill(i, bits: bits, urefs: urefs, port: port, set: set)
    }

    /// Frees the name of slot `i`. An armed dead-name request on the name is
    /// cancelled with a port-deleted notification (§3.1).
    func freeName(_ i: Int) {
        let name = nameOf(i)
        if let p = entries[i].port {
            if let so = p.dnRequests.removeValue(forKey: name) {
                if p.active {
                    sendNotification(to: so, id: MachNotify.portDeleted, body: machNDRRecord + le32(name))
                } else {
                    releaseSendOnceQuietly(so)
                }
            }
            p.deadNameNotified.remove(name)
            if reverse[ObjectIdentifier(p)] == name { reverse[ObjectIdentifier(p)] = nil }
        }
        let generation = entries[i].generation
        entries[i] = IPCEntry()
        entries[i].generation = generation
        if i < nextFresh { freeList.append(i) }
    }

    /// The receive right of slot `i` leaves the space (moved or destroyed).
    /// The entry keeps any send right; otherwise the name is freed.
    func dropReceive(_ i: Int) {
        guard let p = entries[i].port else { return }
        let name = nameOf(i)
        entries[i].bits &= ~MachPortType.receive
        p.inSpace = false
        removeFromAllSets(p)
        p.changeStamp = nextStamp()
        p.receiveWaiters.wakeAll()
        if entries[i].bits & MachPortType.send == 0 {
            freeName(i)
        }
        receiveRightGoneHandler?(name)
    }

    // MARK: Rights

    /// Copies a carried right out into the space (§2.5). Returns the name
    /// (0 or DEAD for right-less values) and false when the space is full
    /// (the right is then destroyed and the name is 0).
    func copyout(_ right: CarriedRight) -> (name: UInt32, ok: Bool) {
        switch right {
        case .null: return (MachPortName.null, true)
        case .dead: return (MachPortName.dead, true)
        case let .send(p):
            if !p.active {
                p.srights -= 1
                return (MachPortName.dead, true)
            }
            if let name = reverse[ObjectIdentifier(p)], let i = slot(of: name) {
                if entries[i].bits & MachPortType.send != 0 {
                    p.srights -= 1  // merges into the entry's send right
                } else {
                    entries[i].bits |= MachPortType.send
                }
                entries[i].urefs = pegAdd(entries[i].urefs, 1)
                return (name, true)
            }
            guard let name = newEntry(bits: MachPortType.send, urefs: 1, port: p) else {
                releaseSend(p)
                return (0, false)
            }
            return (name, true)
        case let .sendOnce(p):
            if !p.active {
                p.sorights -= 1
                return (MachPortName.dead, true)
            }
            guard let name = newEntry(bits: MachPortType.sendOnce, urefs: 1, port: p) else {
                destroySendOnce(p)
                return (0, false)
            }
            return (name, true)
        case let .receive(p):
            p.transitHolder = nil
            if let name = reverse[ObjectIdentifier(p)], let i = slot(of: name) {
                entries[i].bits |= MachPortType.receive
                p.inSpace = true
                return (name, true)
            }
            guard let name = newEntry(bits: MachPortType.receive, urefs: 0, port: p) else {
                destroyReceive(p)
                return (0, false)
            }
            p.inSpace = true
            return (name, true)
        }
    }

    /// Destroys a carried right.
    func release(_ right: CarriedRight) {
        switch right {
        case .null, .dead: break
        case let .send(p): releaseSend(p)
        case let .sendOnce(p): destroySendOnce(p)
        case let .receive(p):
            p.transitHolder = nil
            destroyReceive(p)
        }
    }

    /// One send right is gone; fires an armed no-senders request when it was
    /// the last (§3.5).
    func releaseSend(_ p: IPCPort) {
        p.srights -= 1
        checkNoSenders(p)
    }

    func checkNoSenders(_ p: IPCPort) {
        guard p.srights == 0, p.active, let ns = p.nsRequest else { return }
        p.nsRequest = nil
        sendNotification(to: ns, id: MachNotify.noSenders, body: machNDRRecord + le32(p.mscount))
    }

    /// A send-once right is destroyed without a message: send-once
    /// notification to its port (§3.3), unless the port is dead, a kernel
    /// object, or at the kernel queue limit.
    func destroySendOnce(_ p: IPCPort) {
        if p.active, !p.isKernelObject, p.messages.count < MachIPCLimits.qlimitKernel {
            sendNotification(to: p, id: MachNotify.sendOnce, body: [])
        } else {
            p.sorights -= 1
        }
    }

    /// Drops a send-once right with no notification at all.
    func releaseSendOnceQuietly(_ p: IPCPort) {
        p.sorights -= 1
    }

    /// The destination right of a message that was delivered (consumed).
    func consumeDestination(_ right: CarriedRight) {
        switch right {
        case let .send(p): releaseSend(p)
        case let .sendOnce(p): p.sorights -= 1
        default: break
        }
    }

    /// Destroys a message: every right and memory region in it (§1.5, §2.8).
    /// With `consumeDestination`, the destination right counts as used (no
    /// send-once notification).
    func destroyMessage(_ m: KMessage, consumeDestination consume: Bool = false) {
        for p in m.receiveRights { p.transitHolder = nil }
        if consume { consumeDestination(m.destination) } else { release(m.destination) }
        release(m.reply)
        for item in m.items {
            switch item {
            case let .port(r, _), let .guarded(r, _, _): release(r)
            case let .oolPorts(rights, _, _): rights.forEach(release)
            case .ool: break
            }
        }
    }

    /// The receive right of `p` (not in the space) is destroyed: the port is
    /// sent in a port-destroyed notification if one is armed (§3.4), else it
    /// dies.
    func destroyReceive(_ p: IPCPort) {
        p.inSpace = false
        if let pd = p.pdRequest {
            p.pdRequest = nil
            if pd.active && pd !== p {
                p.guarded = false
                p.strict = false
                p.context = 0
                removeFromAllSets(p)
                p.changeStamp = nextStamp()
                p.receiveWaiters.wakeAll()
                var m = KMessage(complex: true, destination: .sendOnce(pd), destinationType: MachMsgType.portSendOnce,
                                 reply: .null, replyType: 0, id: MachNotify.portDestroyed)
                m.items = [.port(.receive(p), type: MachMsgType.portReceive)]
                m.fromKernel = true
                sendKernelMessage(m)
                return
            }
            releaseSendOnceQuietly(pd)
        }
        portDeath(p)
    }

    /// A port dies (§1.5).
    func portDeath(_ p: IPCPort) {
        guard p.active else { return }
        p.active = false
        p.inSpace = false
        p.transitHolder = nil
        p.changeStamp = nextStamp()
        removeFromAllSets(p)
        let queued = p.messages.removeAll()
        for m in queued { destroyMessage(m) }
        p.receiveWaiters.wakeAll()
        p.sendWaiters.wakeAll()
        if let ns = p.nsRequest {
            p.nsRequest = nil
            destroySendOnce(ns)
        }
        for (name, so) in p.dnRequests.sorted(by: { $0.key < $1.key }) {
            p.deadNameNotified.insert(name)
            sendNotification(to: so, id: MachNotify.deadName, body: machNDRRecord + le32(name))
        }
        p.dnRequests = [:]
        if let s = p.semaphore {
            p.semaphore = nil
            s.destroy()
        }
    }

    func removeFromAllSets(_ p: IPCPort) {
        for s in p.sets {
            s.members.removeAll { $0 === p }
            s.waiters.wakeAll()
        }
        p.sets = []
    }

    func destroySet(_ s: IPCPortSet) {
        s.active = false
        for p in s.members {
            p.sets.removeAll { $0 === s }
            p.changeStamp = nextStamp()
            p.receiveWaiters.wakeAll()
        }
        s.members = []
        s.changeStamp = nextStamp()
        s.waiters.wakeAll()
    }

    // MARK: Kernel messages

    /// Sends a simple notification through the send-once right `so`.
    func sendNotification(to so: IPCPort, id: Int32, body: [UInt8]) {
        var m = KMessage(complex: false, destination: .sendOnce(so), destinationType: MachMsgType.portSendOnce,
                         reply: .null, replyType: 0, id: id)
        m.inline = body
        m.fromKernel = true
        sendKernelMessage(m)
    }

    /// Queues a kernel-originated message (ignores `qlimit` for send-once
    /// destinations; a full send-right destination drops it).
    func sendKernelMessage(_ m: KMessage) {
        guard let p = m.destination.port, p.active, !p.isKernelObject,
              p.messages.count < MachIPCLimits.qlimitKernel else {
            destroyMessage(m)
            return
        }
        if case .send = m.destination, p.messages.count >= p.qlimit {
            destroyMessage(m)
            return
        }
        enqueue(m, on: p)
    }

    /// Appends a message to a live port's queue and wakes its receivers.
    func enqueue(_ m: KMessage, on p: IPCPort) {
        for r in m.receiveRights { r.transitHolder = p }
        if p.messages.isEmpty { p.readyStamp = nextStamp() }
        p.messages.append(m)
        p.receiveWaiters.wakeAll()
        for s in p.sets { s.waiters.wakeAll() }
        if let handler = messageQueuedHandler, p.inSpace, let name = reverse[ObjectIdentifier(p)] {
            handler(name)
            for s in p.sets where s.active { handler(s.name) }
        }
    }

    /// Takes the first message of `p` (the caller checked there is one).
    func dequeue(_ p: IPCPort) -> (KMessage, seqno: UInt32) {
        let m = p.messages.popFirst()!
        let seqno = p.seqno
        p.seqno &+= 1
        if !p.messages.isEmpty { p.readyStamp = nextStamp() }
        for r in m.receiveRights { r.transitHolder = nil }
        p.sendWaiters.wakeAll()
        return (m, seqno)
    }

    // MARK: Kernel-object helpers

    /// A new kernel-object port with one send right copied out to the space.
    func makeKernelObjectName(_ object: MachKernelObject) -> (IPCPort, UInt32)? {
        let p = newPort()
        p.kernelObject = object
        p.srights = 1
        let (name, ok) = copyout(.send(p))
        return ok ? (p, name) : nil
    }

    /// Gives the space one more send right to `p` (merging) and returns the name.
    func copyoutNewSend(_ p: IPCPort) -> UInt32 {
        p.srights += 1
        return copyout(.send(p)).name
    }

    /// The kernel object a name sends to, if any.
    func kernelObject(named name: UInt32) -> (IPCPort, MachKernelObject)? {
        guard let i = lookup(name), entries[i].bits & MachPortType.send != 0,
              let p = entries[i].port, let o = p.kernelObject else { return nil }
        return (p, o)
    }

    /// True when `name` is a send right to the caller's task port.
    func isTaskSelf(_ name: UInt32) -> Bool {
        guard let (p, _) = kernelObject(named: name) else { return false }
        return p === taskPort
    }

    // MARK: MachIPCHandling

    public func allocateThreadPort() -> UInt32 {
        lock.withLock {
            makeKernelObjectName(.thread(serial: nextSerial()))?.1 ?? 0
        }
    }

    public func deallocate(name: UInt32) {
        lock.withLock { _ = portDeallocate(name) }
    }

    /// Drops one reference on a terminated thread's port name, kills the
    /// thread's kernel port (other names for it become dead names), and
    /// unbinds its special reply port.
    public func threadTerminated(_ context: ThreadContext) {
        lock.withLock {
            let thread = kernelObject(named: context.portName)?.0
            _ = portDeallocate(context.portName)
            if let thread, thread !== mainThreadPort { portDeath(thread) }
            specialReplyPorts[context.threadID] = nil
        }
    }

    public func messageQueued(on port: UInt32) -> Bool {
        lock.withLock {
            guard let i = lookup(port) else { return false }
            if let s = entries[i].set { return s.members.contains { !$0.messages.isEmpty } }
            guard entries[i].bits & MachPortType.receive != 0, let p = entries[i].port else { return false }
            return !p.messages.isEmpty
        }
    }

    public func semaphore(named name: UInt32) -> KernelSemaphore? {
        lock.withLock {
            guard let (p, o) = kernelObject(named: name), case .semaphore = o, p.active else { return nil }
            return p.semaphore
        }
    }

    /// What `name` can be received on.
    public func receiveTarget(of name: UInt32) -> MachReceiveTarget {
        lock.withLock {
            guard let i = lookup(name) else { return .none }
            if entries[i].set != nil { return .portSet }
            guard entries[i].bits & MachPortType.receive != 0, let p = entries[i].port else { return .notReceivable }
            return p.isSpecialReply ? .specialReplyPort : .port
        }
    }

    // MARK: Inspection (tests and tracing)

    /// The type bits and user references of a name, without side effects
    /// other than the lazy dead-name conversion. Nil when the name has no entry.
    public func entry(_ name: UInt32) -> (type: UInt32, urefs: UInt32)? {
        lock.withLock {
            guard let i = lookup(name) else { return nil }
            var type = entries[i].bits
            if let p = entries[i].port, p.dnRequests[name] != nil { type |= MachPortType.dnRequest }
            return (type, entries[i].urefs)
        }
    }

    /// Port counters of a name's port: (srights, sorights, mscount, seqno, qlimit, msgcount).
    public func portCounters(_ name: UInt32) -> (srights: Int, sorights: Int, mscount: UInt32, seqno: UInt32,
                                                  qlimit: Int, msgcount: Int, active: Bool)? {
        lock.withLock {
            guard let i = slot(of: name), let p = entries[i].port else { return nil }
            return (p.srights, p.sorights, p.mscount, p.seqno, p.qlimit, p.messages.count, p.active)
        }
    }

    /// The kernel object a name sends to.
    public func kernelObjectKind(of name: UInt32) -> MachKernelObject? {
        lock.withLock { kernelObject(named: name)?.1 }
    }

    /// The number of names in use.
    public var nameCount: Int {
        lock.withLock { entries.reduce(0) { $0 + ($1.inUse ? 1 : 0) } }
    }
}

/// A `kern_return_t` failure.
struct KernError: Error, Equatable {
    var code: UInt32
    init(_ code: UInt32) { self.code = code }
}

func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
     UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
}

func le64(_ v: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }
}
