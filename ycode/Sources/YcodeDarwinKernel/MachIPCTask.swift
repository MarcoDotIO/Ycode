import YcodeDarwinABI

// Task-level Mach state between tasks (`processes.md` §3, §4.6–§4.8,
// stage4b-contract.md §5): stored special, registered, and exception ports;
// inheritance and spawn port actions; task lookup by port and by pid; and
// task termination. Callers hold the kernel lock.

/// `task_special_port_t` numbers (`processes.md` §3.2).
public enum TaskSpecialPort {
    public static let kernel: Int32 = 1
    public static let host: Int32 = 2
    public static let name: Int32 = 3
    public static let bootstrap: Int32 = 4
    public static let inspect: Int32 = 5
    public static let read: Int32 = 6
    public static let access: Int32 = 9
    public static let debugControl: Int32 = 10
    public static let resourceNotify: Int32 = 11
}

/// Exception-port constants (`processes.md` §4.8).
public enum MachException {
    /// Valid exception mask: types 1–13.
    public static let validMask: UInt32 = 0x3FFE
    /// Slots per task, including the unused 0.
    public static let slotCount = 14
    /// Behavior flag bits that may be ORed into a behavior.
    public static let behaviorFlags: UInt32 = 0x8000_0000 | 0x4000_0000 | 0x2000_0000
    /// Valid base behaviors: DEFAULT … STATE_IDENTITY_PROTECTED.
    public static let behaviors: ClosedRange<UInt32> = 1...5

    public static func isValidBehavior(_ b: UInt32) -> Bool { behaviors.contains(b & ~behaviorFlags) }
}

/// One exception-port slot: a send right with its behavior and flavor.
struct ExceptionSlot {
    var port: CarriedRight = .null
    var behavior: UInt32 = 0
    var flavor: UInt32 = 0
}

/// The ports a task stores (`processes.md` §3.2): host, bootstrap, access,
/// debug-control, resource-notify, three registered ports, and 14 exception
/// slots. Every port is a send right (or NULL/DEAD) the kernel holds.
struct TaskPortSlots {
    var host: CarriedRight = .null
    var bootstrap: CarriedRight = .null
    var access: CarriedRight = .null
    var debugControl: CarriedRight = .null
    var resourceNotify: CarriedRight = .null
    var registered: [CarriedRight] = [.null, .null, .null]
    var exceptions = [ExceptionSlot](repeating: ExceptionSlot(), count: MachException.slotCount)
}

/// What a `task` argument names.
enum TaskLookup {
    case task(MachIPC)
    /// No send right under the name (or a dead name): the routine's message
    /// could not be sent.
    case invalidDest
    /// A right to something that is not a task control port.
    case notTask
}

extension MachIPC {
    // MARK: Task lookup

    /// The task a send right under `name` stands for, when it is a task
    /// control port of a live task.
    func taskControl(named name: UInt32) -> TaskLookup {
        guard MachPortName.isValid(name), let i = lookup(name), entries[i].bits & T.send != 0,
              let p = entries[i].port else { return .invalidDest }
        guard p.kernelObject == .task else { return .notTask }
        guard p.active, let task = p.task, !task.isTerminated else { return .invalidDest }
        return .task(task)
    }

    /// The pid of a task and the live space of a pid, through the process
    /// table of the kernel's system (`processes.md` §3.5).
    func space(forPID pid: Int32) -> MachIPC? {
        if pid == (kernel?.pid ?? self.pid), !isTerminated { return self }
        guard let k = kernel?.system.kernel(forPID: pid), let ipc = k.machIPC as? MachIPC,
              !ipc.isTerminated else { return nil }
        return ipc
    }

    var currentPID: Int32 { kernel?.pid ?? pid }

    // MARK: Slots

    /// A new copy of a stored send right (for get and inheritance).
    func copySend(_ r: CarriedRight) -> CarriedRight {
        if case let .send(p) = r {
            p.srights += 1
            return .send(p)
        }
        return r
    }

    /// The port of a task flavor, created lazily for read/inspect.
    func flavorPort(_ object: MachKernelObject) -> IPCPort {
        switch object {
        case .taskName: return taskNamePort
        case .taskRead:
            if let p = taskReadPort { return p }
            let p = newPort()
            p.kernelObject = .taskRead
            p.task = self
            taskReadPort = p
            return p
        case .taskInspect:
            if let p = taskInspectPort { return p }
            let p = newPort()
            p.kernelObject = .taskInspect
            p.task = self
            taskInspectPort = p
            return p
        default: return taskPort
        }
    }

    /// `task_get_special_port` on this task: a new right (copy) for the
    /// caller, or a `kern_return_t` (`processes.md` §3.2).
    func getSpecialPort(_ which: Int32) -> Result<CarriedRight, KernError> {
        if isTerminated { return .failure(KernError(MachKern.failure)) }
        switch which {
        case TaskSpecialPort.kernel: return .success(copySend(.send(taskPort)))
        case TaskSpecialPort.name: return .success(copySend(.send(taskNamePort)))
        case TaskSpecialPort.inspect: return .success(copySend(.send(flavorPort(.taskInspect))))
        case TaskSpecialPort.read: return .success(copySend(.send(flavorPort(.taskRead))))
        case TaskSpecialPort.host: return .success(copySend(slots.host))
        case TaskSpecialPort.bootstrap: return .success(copySend(slots.bootstrap))
        case TaskSpecialPort.access: return .success(copySend(slots.access))
        case TaskSpecialPort.debugControl: return .success(copySend(slots.debugControl))
        case TaskSpecialPort.resourceNotify: return .success(copySend(slots.resourceNotify))
        default: return .failure(KernError(MachKern.invalidArgument))
        }
    }

    /// Checks `task_set_special_port(which)` without changing anything.
    func checkSetSpecialPort(_ which: Int32) -> UInt32 {
        if isTerminated { return MachKern.failure }
        switch which {
        case TaskSpecialPort.kernel, TaskSpecialPort.host: return MachKern.noAccess
        case TaskSpecialPort.bootstrap, TaskSpecialPort.debugControl, TaskSpecialPort.resourceNotify:
            return MachKern.success
        case TaskSpecialPort.access:
            if case let .send(p) = slots.access, p.active { return MachKern.noAccess }
            return MachKern.success
        default: return MachKern.invalidArgument
        }
    }

    /// `task_set_special_port` on this task with a copied-in right. On
    /// success the slot owns `right` and the old right is released; on
    /// failure the caller still owns `right`.
    func setSpecialPort(_ which: Int32, _ right: CarriedRight) -> UInt32 {
        let kr = checkSetSpecialPort(which)
        guard kr == MachKern.success else { return kr }
        let old: CarriedRight
        switch which {
        case TaskSpecialPort.bootstrap: old = slots.bootstrap; slots.bootstrap = right
        case TaskSpecialPort.debugControl: old = slots.debugControl; slots.debugControl = right
        case TaskSpecialPort.resourceNotify: old = slots.resourceNotify; slots.resourceNotify = right
        default: old = slots.access; slots.access = right
        }
        release(old)
        return MachKern.success
    }

    /// Replaces the three registered ports (they own `rights`).
    func setRegisteredPorts(_ rights: [CarriedRight]) {
        let old = slots.registered
        slots.registered = (0..<3).map { $0 < rights.count ? rights[$0] : .null }
        old.forEach(release)
    }

    /// Sets the exception slots in `mask` to (`right`, behavior, flavor): each
    /// slot gets its own send right; `right` itself is consumed.
    func setExceptionPorts(mask: UInt32, _ right: CarriedRight, behavior: UInt32, flavor: UInt32) -> UInt32 {
        guard mask & ~MachException.validMask == 0 else { return MachKern.invalidArgument }
        if right.port != nil, !MachException.isValidBehavior(behavior) { return MachKern.invalidArgument }
        for type in 1..<MachException.slotCount where mask & (1 << UInt32(type)) != 0 {
            let old = slots.exceptions[type].port
            slots.exceptions[type] = ExceptionSlot(port: copySend(right), behavior: behavior, flavor: flavor)
            release(old)
        }
        release(right)
        return MachKern.success
    }

    /// The stored exception port of one type (tests and tracing).
    public func exceptionPort(type: Int) -> (name: UInt32, behavior: UInt32, flavor: UInt32)? {
        lock.withLock {
            guard (1..<MachException.slotCount).contains(type) else { return nil }
            let slot = slots.exceptions[type]
            guard let p = slot.port.port else { return nil }
            return (reverse[ObjectIdentifier(p)] ?? 0, slot.behavior, slot.flavor)
        }
    }

    // MARK: Well-known names in a new space

    /// Makes the well-known names `0x303` (host) and `0x503` (bootstrap) hold
    /// a send right to the current host and bootstrap slots (`processes.md`
    /// §3.3, Ycode normative). Used when a task is created, before it runs.
    func syncWellKnownNames() {
        sync(index: 3, stored: slots.host)
        sync(index: 5, stored: slots.bootstrap)
    }

    private func sync(index: Int, stored: CarriedRight) {
        let target: IPCPort?
        if case let .send(p) = stored, p.active { target = p } else { target = nil }
        if index < entries.count, entries[index].inUse {
            if let target, entries[index].port === target, entries[index].bits & T.send != 0 { return }
            // Drop the seeded right under the well-known name.
            let e = entries[index]
            if e.bits == T.send, let p = e.port {
                freeName(index)
                releaseSend(p)
            } else {
                return  // the guest's own entry: leave it
            }
        }
        guard let target else { return }
        if let existing = reverse[ObjectIdentifier(target)], slot(of: existing) != nil { return }
        seed(target, index: index)
        if index >= nextFresh { nextFresh = index + 1 }
    }

    // MARK: Inheritance and spawn port actions (contract-pinned, §3.7)

    /// Contract-pinned (stage 4b §3.7): copies `parent`'s host, bootstrap,
    /// access, registered, and exception ports (types 1–13) into this new task
    /// as send-right copies (`processes.md` §3.3); debug-control and
    /// resource-notify start null. Spawn: parent = the spawner; exec: parent =
    /// the old image (call this before `parent.terminateTask()`). Lock held.
    public func inheritTaskPorts(from parent: MachIPC) {
        lock.withLock {
            let old = slots
            var new = TaskPortSlots()
            new.host = copySend(parent.slots.host)
            new.bootstrap = copySend(parent.slots.bootstrap)
            new.access = copySend(parent.slots.access)
            new.registered = parent.slots.registered.map(copySend)
            for type in 1..<MachException.slotCount {
                let s = parent.slots.exceptions[type]
                new.exceptions[type] = ExceptionSlot(port: copySend(s.port), behavior: s.behavior, flavor: s.flavor)
            }
            slots = new
            for r in [old.host, old.bootstrap, old.access, old.debugControl, old.resourceNotify] + old.registered {
                release(r)
            }
            old.exceptions.forEach { release($0.port) }
            let threadSlots = threadExceptions
            threadExceptions = [:]
            threadSlots.values.forEach { $0.forEach { release($0.port) } }
            syncWellKnownNames()
            log("mach inherit task ports from pid \(parent.currentPID)")
        }
    }

    /// Contract-pinned (stage 4b §3.7): applies `posix_spawn` port actions to
    /// this new task (`processes.md` §1.8), after inheritance. Every named
    /// port is copied in from `caller`'s space as COPY_SEND; NULL and DEAD
    /// pass through. Throws `DarwinErrnoError(EINVAL)` for an unknown type,
    /// an exceeded limit, a name without a send right, or a failed special /
    /// exception setting; rights copied in but not kept are released. Lock held.
    public func applySpawnPortActions(_ actions: [SpawnPortAction], from caller: MachIPC) throws {
        try lock.withLock {
            // 1. Count the types first.
            var exceptions = 0, watches = 0, registered = 0, ptrauth = 0
            for a in actions {
                switch a.kind {
                case .exception: exceptions += 1
                case .importanceWatch: watches += 1
                case .registered: registered += 1
                case .ptrauthTask: ptrauth += 1
                case .special, .auditSession: break
                case nil: throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
                }
            }
            guard exceptions <= 14, watches <= 128, registered <= 3, ptrauth <= 1 else {
                throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
            }
            // 2. Copy every right in from the caller (COPY_SEND).
            var rights: [CarriedRight] = []
            for a in actions {
                if !MachPortName.isValid(a.port) {
                    rights.append(a.port == MachPortName.dead ? .dead : .null)
                    continue
                }
                guard case let .success(r) = caller.copyin(a.port, MachMsgType.copySend, slot: .body, apply: true) else {
                    rights.forEach(release)
                    throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
                }
                rights.append(r)
            }
            // 3. Check what can fail before changing anything.
            for a in actions {
                switch a.kind {
                case .special:
                    guard checkSetSpecialPort(a.which) == MachKern.success else {
                        rights.forEach(release)
                        throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
                    }
                case .exception:
                    guard a.mask & ~MachException.validMask == 0,
                          a.port == 0 || MachException.isValidBehavior(a.behavior) else {
                        rights.forEach(release)
                        throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
                    }
                default: break
                }
            }
            // 4. Apply. SPECIAL in order (a repeated `which` keeps the last);
            //    REGISTERED in action order; the rest are dropped.
            var registeredRights: [CarriedRight] = []
            for (a, r) in zip(actions, rights) {
                switch a.kind {
                case .special:
                    if setSpecialPort(a.which, r) != MachKern.success { release(r) }
                case .exception:
                    _ = setExceptionPorts(mask: a.mask, r, behavior: a.behavior, flavor: a.flavor)
                case .registered:
                    registeredRights.append(r)
                case .importanceWatch:
                    if let p = r.port { pendingWatchPorts.append(p) }
                    release(r)
                default:
                    release(r)
                }
            }
            if registered > 0 { setRegisteredPorts(registeredRights) }
            syncWellKnownNames()
            log("mach spawn port actions: \(actions.count) applied from pid \(caller.currentPID)")
        }
    }

    // MARK: Termination (processes.md §4.6)

    /// Contract-pinned (stage 4b §3.7): tears the task down in
    /// `processes.md` §4.6 order — its kernel ports stop resolving; its space
    /// is destroyed (receive rights first, in index order: ports die or are
    /// diverted by port-destroyed requests; then the other entries: send
    /// rights released with no-senders, send-once rights destroyed with
    /// send-once notifications, armed dead-name requests cancelled with
    /// port-deleted notifications, port sets destroyed); then its stored
    /// special/registered/exception ports are released; finally its kernel
    /// ports (task, name, threads, semaphores) die. Every notification is
    /// queued before this returns (so before NOTE_EXIT). Lock held.
    public func terminateTask() {
        lock.withLock {
            guard !isTerminated else { return }
            // 1. Kernel ports stop resolving to the task.
            isTerminated = true
            messageQueuedHandler = nil
            receiveRightGoneHandler = nil
            // Keep the identity for anything that still asks after the kernel is freed.
            if let k = kernel {
                pid = k.pid
                pidVersion = k.pidVersion
            }
            // 2. The space: receive rights first, in index order.
            for i in entries.indices where entries[i].inUse && entries[i].bits & T.receive != 0 {
                guard let p = entries[i].port else { continue }
                let hadSend = entries[i].bits & T.send != 0
                freeName(i)  // cancels this entry's dead-name request (port-deleted)
                p.receiver = nil
                removeFromAllSets(p)
                p.changeStamp = nextStamp()
                p.receiveWaiters.wakeAll()
                if hadSend { p.srights -= 1 }
                destroyReceive(p)
            }
            // Then every other entry, in index order.
            for i in entries.indices where entries[i].inUse {
                let e = entries[i]
                freeName(i)
                if let s = e.set {
                    destroySet(s)
                } else if let p = e.port {
                    if e.bits & T.send != 0 {
                        releaseSend(p)
                    } else if e.bits & T.sendOnce != 0 {
                        if p.active { destroySendOnce(p) } else { p.sorights -= 1 }
                    }
                }
            }
            reverse = [:]
            specialReplyPorts = [:]
            // 3. Stored special, registered, and exception ports.
            let old = slots
            slots = TaskPortSlots()
            for r in [old.host, old.bootstrap, old.access, old.debugControl, old.resourceNotify] + old.registered {
                release(r)
            }
            old.exceptions.forEach { release($0.port) }
            let threadSlots = threadExceptions
            threadExceptions = [:]
            threadSlots.values.forEach { $0.forEach { release($0.port) } }
            // 4. The task's own kernel ports die: holders elsewhere see dead names.
            for p in [taskPort, taskNamePort, mainThreadPort] + [taskReadPort, taskInspectPort].compactMap({ $0 })
                + ownedKernelPorts {
                portDeath(p)
            }
            ownedKernelPorts = []
            log("mach task terminated (pid \(currentPID))")
        }
    }
}
