import Foundation
import YcodeDarwinABI

/// Mach IPC (`specs/simulator/stage4a-contract.md` §6,
/// `specs/simulator/mach-ipc.md` §1–§5, `processes.md` §3–§4): one task's
/// port name space and its task state (kernel ports, special, registered,
/// and exception ports), and the Mach traps and Ycode-private Mach-routine
/// traps of that task. Ports, port sets, and messages are shared by every
/// task of one `MachIPCSystem` (stage 4b); a right moves between spaces by
/// copyin in the sender's space and copyout in the receiver's.
///
/// One instance serves one task (one image). Every method expects the kernel lock to be
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
    /// Whether trace lines are built. A space attached to a kernel follows the
    /// kernel's `tracing`; one without a kernel always traces (as before).
    var tracesCalls: Bool {
        (kernel.map { traceTextWanted($0.tracing) } ?? true) && !lock.callerIsFast
    }
    /// One trace line, built only when `tracesCalls`.
    @inline(__always) func trace(_ line: @autoclosure () -> String) {
        if tracesCalls { log(line()) }
    }
    /// EVFILT_MACHPORT: called (lock held) whenever a message is queued on a
    /// receive right in the space: once with the port's name and once with
    /// the name of each port set that contains it.
    /// Nil once an attached kernel is gone (the hooks belong to it).
    public var messageQueuedHandler: ((_ name: UInt32) -> Void)? {
        get { kernelGone ? nil : queuedHook }
        set { queuedHook = newValue }
    }
    /// Called (lock held) when a receive right or a port set leaves the space
    /// (moved away or destroyed), with its former name (kevent `EV_EOF`).
    /// Nil once an attached kernel is gone.
    public var receiveRightGoneHandler: ((_ name: UInt32) -> Void)? {
        get { kernelGone ? nil : goneHook }
        set { goneHook = newValue }
    }
    private var queuedHook: ((_ name: UInt32) -> Void)?
    private var goneHook: ((_ name: UInt32) -> Void)?
    /// True when this space was made for a kernel (`init(kernel:)`).
    private var attachedToKernel = false
    /// True when the kernel this space was made for has been freed: its
    /// hooks must not run. The space and its ports may outlive the kernel
    /// (other tasks still name them).
    var kernelGone: Bool { attachedToKernel && kernel == nil }
    /// What the trailer reports for this task's messages (`mach-ipc.md` §2.6,
    /// `processes.md` §4.5) when no kernel is attached; with a kernel, its
    /// `pid` and `pidVersion` win.
    public var pid: Int32
    public var pidVersion: UInt32 = 0
    public var uid: UInt32
    public var gid: UInt32
    /// The state every task of the system shares (ports, host, bootstrap).
    public let system: MachIPCSystem
    /// The kernel (image) this space belongs to, if any.
    public internal(set) weak var kernel: DarwinKernel?
    /// This space's identity for per-space keys.
    let spaceID: UInt64
    /// The ports of a spawn's IMP_WATCHPORTS actions, until the process
    /// layer binds them to the new process (`scheduling-policy.md` §4.2).
    var pendingWatchPorts: [IPCPort] = []
    /// True once `terminateTask()` ran: the task's kernel ports are dead.
    public internal(set) var isTerminated = false
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

    // MARK: Kernel objects

    let taskPort: IPCPort
    let taskNamePort: IPCPort
    var taskReadPort: IPCPort?
    var taskInspectPort: IPCPort?
    var hostPort: IPCPort { system.hostPort }
    var bootstrapPort: IPCPort { system.bootstrapPort }
    let mainThreadPort: IPCPort
    var clockPorts: [Int32: IPCPort] = [:]
    /// The task's stored ports (`processes.md` §3.2): send rights the kernel holds.
    var slots = TaskPortSlots()
    /// Kernel objects this task owns besides its task ports (threads,
    /// semaphores): they die with the task.
    var ownedKernelPorts: [IPCPort] = []
    /// Each thread's bound special reply port, by thread id.
    var specialReplyPorts: [UInt64: IPCPort] = [:]
    /// Thread-level exception ports (thread_set_exception_ports), by the
    /// thread's kernel port; absent until first set (xnu `exc_actions` NULL).
    var threadExceptions: [ObjectIdentifier: [ExceptionSlot]] = [:]

    /// The well-known names.
    public static let taskName: UInt32 = 0x103
    public static let mainThreadName: UInt32 = 0x203
    public static let hostName: UInt32 = 0x303
    public static let bootstrapName: UInt32 = 0x503

    // MARK: Init

    /// - Parameters:
    ///   - lock: the system's kernel lock (`DarwinKernel.lock`).
    ///   - log: the trace sink.
    ///   - pid: the task's pid, for trailers.
    ///   - system: the shared Mach state (nil: a private one-task system).
    public init(lock: KernelLock, log: @escaping (String) -> Void = { _ in },
                pid: Int32 = VMLayout.guestPID, uid: UInt32 = DarwinFileSystem.guestUID,
                gid: UInt32 = DarwinFileSystem.guestGID, system: MachIPCSystem? = nil) {
        let system = system ?? MachIPCSystem()
        self.system = system
        // The lock split: every space of the system is guarded by its port lock.
        self.lock = system.portLock ?? lock
        self.log = log
        self.pid = pid
        self.uid = uid
        self.gid = gid
        spaceID = system.nextSpaceID()
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
        func kobject(_ o: MachKernelObject) -> IPCPort {
            let p = IPCPort(serial: system.nextSerial())
            p.kernelObject = o
            return p
        }
        taskPort = kobject(.task)
        mainThreadPort = kobject(.thread(serial: 0))
        taskNamePort = kobject(.taskName)
        taskPort.task = self
        mainThreadPort.task = self
        taskNamePort.task = self
        // Indices 1, 2, 3, 5 are the well-known names; 4 is the first free slot.
        seed(taskPort, index: 1)
        seed(mainThreadPort, index: 2)
        seed(system.hostPort, index: 3)
        let bootstrap = system.defaultBootstrapPort
        seed(bootstrap, index: 5)
        nextFresh = 6
        freeList = [4]
        // The root task's host and bootstrap slots: the system's objects.
        system.hostPort.srights += 1
        slots.host = .send(system.hostPort)
        bootstrap.srights += 1
        slots.bootstrap = .send(bootstrap)
    }

    /// A `MachIPC` wired to `kernel`: its lock, log, pid, clocks, and the
    /// system's shared Mach state. Does not attach itself (set `kernel.machIPC`).
    public convenience init(kernel: DarwinKernel) {
        // Weak captures: the kernel may be freed after its process exits
        // while this space and its ports stay reachable from other tasks.
        // Without the kernel: no log, a zero system clock, the host calendar.
        self.init(lock: kernel.lock, log: { [weak kernel] in kernel?.log($0) }, pid: kernel.pid,
                  system: kernel.system.mach)
        self.kernel = kernel
        attachedToKernel = true
        pidVersion = kernel.pidVersion
        systemClock = { [weak kernel] in
            guard let kernel else { return (0, 0) }
            let ticks = kernel.counter() &- kernel.bootCounter
            let f = max(kernel.counterFrequency, 1)
            return (ticks / f, (ticks % f) * 1_000_000_000 / f)
        }
        let hostCalendar = calendarClock
        calendarClock = { [weak kernel] in
            guard let kernel else { return hostCalendar() }
            let w = kernel.wallClock()
            return (UInt64(max(0, w.seconds)), UInt64(max(0, w.nanoseconds)))
        }
    }

    /// Installs a send right to `p` under the well-known name of `index`
    /// (generation 0).
    func seed(_ p: IPCPort, index: Int) {
        while entries.count <= index { entries.append(IPCEntry()) }
        if let k = freeList.lastIndex(of: index) { freeList.remove(at: k) }
        entries[index].generation = 0
        entries[index].inUse = true
        entries[index].bits = MachPortType.send
        entries[index].urefs = 1
        entries[index].port = p
        entries[index].set = nil
        p.srights += 1
        reverse[ObjectIdentifier(p)] = nameOf(index)
    }

    // MARK: Helpers

    func nextSerial() -> UInt64 { system.nextSerial() }

    func nextStamp() -> UInt64 { system.nextStamp() }

    /// The per-space key of `name` (dead-name requests).
    func dn(_ name: UInt32) -> DNKey { DNKey(space: spaceID, name: name) }

    /// The `MACH_PORT_TYPE_*` request bits of this space's `name` on `p`
    /// (xnu `ipc_port_request_type`).
    func requestTypeBits(_ p: IPCPort, _ name: UInt32) -> UInt32 {
        guard p.dnRequests[dn(name)] != nil else { return 0 }
        guard let armed = p.spRequests[dn(name)] else { return MachPortType.dnRequest }
        return MachPortType.dnRequest | MachPortType.spRequest | (armed ? 0 : MachPortType.spRequestDelayed)
    }

    /// `MACH_SEND_NOTIFY` (xnu `ipc_port_request_sparm`): a send by this
    /// space to `p` under `name` arms the entry's delayed send-possible
    /// request when the queue is full.
    func armSendPossible(_ p: IPCPort, name: UInt32) {
        guard p.active, !p.isKernelObject, p.spRequests[dn(name)] == false,
              p.occupiedSlots >= p.qlimit else { return }
        p.spRequests[dn(name)] = true
    }

    /// A message was received from `p` (xnu `ipc_port_spnotify`): every armed
    /// send-possible request fires and is used up.
    func fireSendPossible(_ p: IPCPort) {
        guard p.hasArmedSendPossible else { return }
        for (key, armed) in p.spRequests.sorted(by: { $0.key < $1.key }) where armed {
            p.spRequests[key] = nil
            guard let so = p.dnRequests.removeValue(forKey: key) else { continue }
            sendNotification(to: so, id: MachNotify.sendPossible, body: machNDRRecord + le32(key.name))
        }
    }

    /// The identity this task's messages carry (`processes.md` §4.5).
    var senderIdentity: MachSenderIdentity {
        MachSenderIdentity(uid: uid, gid: gid, pid: kernel?.pid ?? pid, pidVersion: kernel?.pidVersion ?? pidVersion,
                           auditSessionID: system.auditSessionID)
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
        if p.deadNameNotified.remove(dn(name)) != nil { urefs = pegAdd(urefs, 1) }
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
            p.spRequests[dn(name)] = nil
            if let so = p.dnRequests.removeValue(forKey: dn(name)) {
                if p.active {
                    sendNotification(to: so, id: MachNotify.portDeleted, body: machNDRRecord + le32(name))
                } else {
                    releaseSendOnceQuietly(so)
                }
            }
            p.deadNameNotified.remove(dn(name))
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
        p.receiver = nil
        removeFromAllSets(p)
        p.changeStamp = nextStamp()
        p.receiveWaiters.wakeAll()
        if entries[i].bits & MachPortType.send == 0 {
            freeName(i)
        }
        hookReceiveGone(self, name)
    }

    /// Runs `space`'s EVFILT_MACHPORT hook for `name` (a message was queued,
    /// or the receive right or set left): at once under L0; on a fast path
    /// (`mach-ipc-locking.md` §4.5) once this thread holds no lock, under the
    /// receiving image's event lock.
    @inline(__always) func hookQueued(_ space: MachIPC, _ name: UInt32) {
        guard let handler = space.messageQueuedHandler else { return }
        runHook(space, handler, name)
    }

    @inline(__always) func hookReceiveGone(_ space: MachIPC, _ name: UInt32) {
        guard let handler = space.receiveRightGoneHandler else { return }
        runHook(space, handler, name)
    }

    private func runHook(_ space: MachIPC, _ handler: @escaping (UInt32) -> Void, _ name: UInt32) {
        // The hook is the receiving image's event-lock state; this thread
        // holds the port lock, which comes after it in the order.
        if let events = space.kernel?.eventLock {
            lock.deferIfFast(.fineLock(events)) { handler(name) }
        } else {
            handler(name)
        }
    }

    /// Releases a dying port's payload (a semaphore wakes L0 waiters; a
    /// fileport's file or a memory entry may close host objects): under L0
    /// at once, or, on a fast path, once this thread holds no lock.
    func releasePayload(_ release: @escaping () -> Void) {
        guard let l0 = lock.root else { release(); return }
        lock.deferIfFast(.kernelLock(l0), release)
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
                p.receiver = self
                return (name, true)
            }
            guard let name = newEntry(bits: MachPortType.receive, urefs: 0, port: p) else {
                destroyReceive(p)
                return (0, false)
            }
            p.receiver = self
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
        // A fileport lives while send rights exist (`processes.md` §4.9).
        // So does a memory entry (xnu: no-senders destroys the named entry).
        if p.srights <= 0, p.fileportFile != nil || p.memoryEntry != nil { portDeath(p) }
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
        p.receiver = nil
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
        p.receiver = nil
        p.transitHolder = nil
        p.changeStamp = nextStamp()
        removeFromAllSets(p)
        let queued = p.messages.removeAll()
        if p.importanceCount > 0 {
            p.creditedProcess?.changeImportance(-p.importanceCount)
            p.importanceCount = 0
            p.creditedProcess = nil
        }
        for m in queued { destroyMessage(m) }
        p.receiveWaiters.wakeAll()
        p.sendWaiters.wakeAll()
        if let ns = p.nsRequest {
            p.nsRequest = nil
            destroySendOnce(ns)
        }
        for (key, so) in p.dnRequests.sorted(by: { $0.key < $1.key }) {
            p.deadNameNotified.insert(key)
            sendNotification(to: so, id: MachNotify.deadName, body: machNDRRecord + le32(key.name))
        }
        p.dnRequests = [:]
        p.spRequests = [:]
        if let s = p.semaphore {
            p.semaphore = nil
            releasePayload { s.destroy() }
        }
        if p.fileportFile != nil || p.memoryEntry != nil {
            // The last references go where the payload is released.
            var payload: (DarwinOpenFile?, MachMemoryEntry?) = (p.fileportFile, p.memoryEntry)
            p.fileportFile = nil
            p.memoryEntry = nil
            releasePayload { payload = (nil, nil) }
            _ = payload
        }
        p.mkTimer?.deadline = nil
        p.mkTimer = nil
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
        if MachTrafficStats.enabled { MachTrafficStats.count(from: self, to: p, id: m.id, inline: m.inline) }
        for r in m.receiveRights { r.transitHolder = p }
        if p.messages.isEmpty { p.readyStamp = nextStamp() }
        p.messages.append(m)
        if m.importance { importanceQueued(on: p) }
        p.receiveWaiters.wakeAll()
        for s in p.sets { s.waiters.wakeAll() }
        // The hooks of the space that holds the receive right.
        if let space = p.receiver, space.messageQueuedHandler != nil,
           let name = space.reverse[ObjectIdentifier(p)] {
            hookQueued(space, name)
            for s in p.sets where s.active { hookQueued(space, s.name) }
        }
    }

    /// `YCODE_PORT_SLOT_HANDOFF` (default on; `=0` off): a dequeue from a
    /// full queue wakes one blocked sender and gives it the freed slot
    /// (`mach-ipc.md` §2.9) instead of waking every blocked sender.
    nonisolated(unsafe) static var slotHandoff = getenv("YCODE_PORT_SLOT_HANDOFF").map { String(cString: $0) != "0" } ?? true

    /// Takes the first message of `p` (the caller checked there is one).
    func dequeue(_ p: IPCPort) -> (KMessage, seqno: UInt32) {
        let m = p.messages.popFirst()!
        if m.importance { importanceDequeued(from: p) }
        let seqno = p.seqno
        p.seqno &+= 1
        if !p.messages.isEmpty { p.readyStamp = nextStamp() }
        for r in m.receiveRights { r.transitHolder = nil }
        if Self.slotHandoff {
            // The freed slot goes to the oldest blocked sender, which is
            // woken for it alone (xnu: a dequeue wakes one full-queue
            // waiter and hands it the slot). Waking every blocked sender
            // made all but one of them take the lock again and go back to
            // sleep, once per message received (boot-profile.md §8).
            if p.occupiedSlots < p.qlimit, p.sendWaiters.wake(count: 1) == 1 { p.grantedSlots += 1 }
        } else {
            p.sendWaiters.wakeAll()
        }
        fireSendPossible(p)
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
            guard let (p, name) = makeKernelObjectName(.thread(serial: nextSerial())) else { return 0 }
            own(p)
            return name
        }
    }

    /// Records a kernel object of this task (it dies with the task).
    func own(_ p: IPCPort) {
        p.task = self
        if ownedKernelPorts.count >= 64 { ownedKernelPorts.removeAll { !$0.active } }
        ownedKernelPorts.append(p)
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
            if let thread, let slots = threadExceptions.removeValue(forKey: ObjectIdentifier(thread)) {
                slots.forEach { release($0.port) }
            }
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
            if let p = entries[i].port { type |= requestTypeBits(p, name) }
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

/// Diagnostics (`YCODE_DEBUG_MACH_STATS=1`): queued Mach messages by sending
/// process, receiving process, and message id. Every `reportEvery` messages
/// the busiest pairs are printed. Called from `enqueue` with the kernel lock
/// held (one lock for the whole system), which also guards the table.
enum MachTrafficStats {
    static let enabled = getenv("YCODE_DEBUG_MACH_STATS").map { String(cString: $0) == "1" } ?? false
    static let reportEvery: UInt64 = 100_000
    nonisolated(unsafe) static var total: UInt64 = 0
    nonisolated(unsafe) static var pairs: [String: UInt64] = [:]

    static func name(_ space: MachIPC?) -> String {
        guard let space else { return "none" }
        guard let k = space.kernel else { return space.kernelGone ? "gone" : "host" }
        return k.processRecord?.comm ?? "pid \(k.pid)"
    }

    /// `YCODE_DEBUG_MACH_DUMP=<receiver comm>`: the printable strings of the
    /// first 12 messages queued for that process.
    static let dumpReceiver = getenv("YCODE_DEBUG_MACH_DUMP").map { String(cString: $0) }
    nonisolated(unsafe) static var dumped = 0

    static func count(from sender: MachIPC, to p: IPCPort, id: Int32, inline: [UInt8] = []) {
        total += 1
        let receiver = name(p.receiver)
        let key = "\(name(sender)) -> \(receiver) id \(id)"
        pairs[key, default: 0] += 1
        if let d = dumpReceiver, d == receiver, dumped < 12 {
            dumped += 1
            var strings: [String] = []
            var run: [UInt8] = []
            for b in inline + [0] {
                if b >= 0x20 && b < 0x7F { run.append(b); continue }
                if run.count >= 3 { strings.append(String(decoding: run, as: UTF8.self)) }
                run = []
            }
            FileHandle.standardError.write(Data("ycode-mach-dump: \(key), \(inline.count) bytes: \(strings.joined(separator: " | "))\n".utf8))
        }
        guard total % reportEvery == 0 else { return }
        let top = pairs.sorted { $0.value > $1.value }.prefix(20).map { "\($0.key): \($0.value)" }.joined(separator: "; ")
        FileHandle.standardError.write(Data("ycode-mach-stats: \(total) messages; top: \(top)\n".utf8))
    }
}
