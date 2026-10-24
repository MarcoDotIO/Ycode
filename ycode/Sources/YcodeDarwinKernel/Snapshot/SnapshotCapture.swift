// Capture of the kernel personality's objects into snapshot records
// (specs/simulator/snapshot.md §2.3, §2.4, §6). Runs with the kernel lock
// held, after `KernelSnapshotQuiesce.classify` said the system is settled.
// Objects get ids in a first pass and are encoded in a second, so records may
// reference each other freely (the restore creates every object before it
// fills any).

import Foundation
import YcodeDarwinABI

/// One image's input from the VMM.
public struct SnapshotImageInput {
    public let kernel: DarwinKernel
    /// Threads held by the VMM's gates, by `ObjectIdentifier` of their context.
    public var parked: [ObjectIdentifier: SnapshotParkedThread]
    /// FP/SIMD state of the vCPU of a blocked thread.
    public var fpState: (ThreadContext) -> [UInt8]?
    /// The image was launched suspended and its main thread has not started.
    public var mainStart: SnapshotMainStart?

    public init(kernel: DarwinKernel, parked: [ObjectIdentifier: SnapshotParkedThread],
                fpState: @escaping (ThreadContext) -> [UInt8]?, mainStart: SnapshotMainStart? = nil) {
        self.kernel = kernel
        self.parked = parked
        self.fpState = fpState
        self.mainStart = mainStart
    }
}

/// Builds the records of one snapshot.
public final class KernelSnapshotCapture {
    public let system: DarwinSystem
    public let classification: SnapshotClassification
    /// Census: object counts by kind.
    public private(set) var counts: [String: Int] = [:]
    /// Objects the restore cannot rebuild, by kind (the snapshot is refused
    /// for writing, a census just reports them).
    public private(set) var unsupported: [String: Int] = [:]
    public private(set) var records: [SnapshotRecord] = []

    private var nextID: UInt64 = 100
    private var ids: [ObjectIdentifier: UInt64] = [:]
    /// Objects to encode, in discovery order.
    private var ports: [IPCPort] = []
    private var portSets: [IPCPortSet] = []
    private var semaphores: [KernelSemaphore] = []
    private var openFiles: [DarwinOpenFile] = []
    private var hostFiles: [GuestFile] = []
    private var pipes: [KernelPipe] = []
    private var kqueues: [(KQueue, DarwinKernel)] = []
    /// Shared memory objects (memory entries, shared mappings), with their ids.
    public private(set) var sharedObjects: [(id: UInt64, object: SharedMemoryObject)] = []
    /// After `capture`: a newly seen shared object gets its record at once.
    private var recordsDone = false
    private var spaces: [MachIPC] = []
    private var objectFiles: [ObjectIdentifier: DarwinOpenFile] = [:]
    private var sockets: [UnixSocket] = []
    private var shmSegments: [PosixShmSegment] = []
    private var posixSemaphores: [PosixSemaphore] = []
    private let hostNowNs = KernelClock.now()

    public static let systemID: UInt64 = 1
    public static let clockID: UInt64 = 2

    public init(system: DarwinSystem, classification: SnapshotClassification) {
        self.system = system
        self.classification = classification
    }

    func count(_ kind: String, _ n: Int = 1) { counts[kind, default: 0] += n }
    func refuse(_ kind: String) { unsupported[kind, default: 0] += 1 }

    /// The id of an object (assigned on first sight). `isNew` tells the caller to enqueue it.
    private func id(of object: AnyObject) -> (id: UInt64, isNew: Bool) {
        let key = ObjectIdentifier(object)
        if let v = ids[key] { return (v, false) }
        nextID += 1
        ids[key] = nextID
        return (nextID, true)
    }

    /// The id of an object already seen (0 = none or unseen).
    func existingID(_ object: AnyObject?) -> UInt64 {
        guard let object else { return 0 }
        return ids[ObjectIdentifier(object)] ?? 0
    }

    public func imageID(of kernel: DarwinKernel) -> UInt64 { existingID(kernel) }
    public func threadID(of context: ThreadContext) -> UInt64 { existingID(context) }

    // MARK: Discovery

    private func see(_ p: IPCPort?) {
        guard let p else { return }
        if id(of: p).isNew {
            ports.append(p)
            if let s = p.semaphore { see(s) }
            if let f = p.fileportFile { see(f) }
            if let m = p.memoryEntry { _ = sharedObjectID(m.object) }
            for set in p.sets { see(set) }
            see(p.pdRequest)
            see(p.nsRequest)
            for r in p.dnRequests.values { see(r) }
            see(p.transitHolder)
            if let r = p.receiver { see(r) }
            if let t = p.task { see(t) }
            for m in queuedMessages(p) { see(m) }
            switch p.kernelObject {
            default: break
            }
        }
    }

    private func see(_ s: IPCPortSet?) {
        guard let s, id(of: s).isNew else { return }
        portSets.append(s)
        for m in s.members { see(m) }
    }

    private func see(_ s: KernelSemaphore) {
        if id(of: s).isNew { semaphores.append(s) }
    }

    private func see(_ space: MachIPC) {
        guard id(of: space).isNew else { return }
        spaces.append(space)
        for e in space.entries where e.inUse {
            see(e.port)
            see(e.set)
        }
        see(space.taskPort)
        see(space.taskNamePort)
        see(space.taskReadPort)
        see(space.taskInspectPort)
        see(space.mainThreadPort)
        for p in space.clockPorts.values { see(p) }
        see(space.slots)
        for p in space.ownedKernelPorts { see(p) }
        for p in space.specialReplyPorts.values { see(p) }
        for slots in space.threadExceptions.values { for s in slots { see(s.port) } }
    }

    private func see(_ slots: TaskPortSlots) {
        for r in [slots.host, slots.bootstrap, slots.access, slots.debugControl, slots.resourceNotify] + slots.registered {
            see(r)
        }
        for e in slots.exceptions { see(e.port) }
    }

    private func see(_ r: CarriedRight) { see(r.port) }

    private func see(_ m: KMessage) {
        see(m.destination)
        see(m.reply)
        for item in m.items {
            switch item {
            case let .port(r, _), let .guarded(r, _, _): see(r)
            case let .oolPorts(rights, _, _): for r in rights { see(r) }
            case .ool: break
            }
        }
    }

    private func see(_ f: DarwinOpenFile) {
        guard id(of: f).isNew else { return }
        openFiles.append(f)
        switch f.node {
        case .console: break
        case let .file(g): see(g)
        case let .object(o):
            objectFiles[ObjectIdentifier(o)] = f
            if let end = o as? PipeEnd {
                if id(of: end.pipe).isNew { pipes.append(end.pipe) }
            } else if let kqo = o as? KQueueObject {
                if let k = kqo.kernel { see(kqo.queue, kernel: k) }
            } else if o is DarwinDevice {
            } else if let sock = o as? UnixSocket {
                see(sock)
            } else if let shm = o as? PosixShmDescriptor {
                see(shm.segment)
            } else if let sem = o as? PosixSemDescriptor {
                if id(of: sem.semaphore).isNew { posixSemaphores.append(sem.semaphore) }
            } else {
                refuse("descriptor object \(type(of: o))")
            }
        }
        if f.lastCloseHandlers.keys.contains(where: { $0 != "locks" }) { refuse("file with an unknown close handler") }
    }

    private func see(_ sock: UnixSocket) {
        guard id(of: sock).isNew else { return }
        sockets.append(sock)
        if sock.hostSink != nil { refuse("host stream socket") }
        if let p = sock.peer { see(p) }
        for p in sock.pending { see(p) }
        for w in sock.connectedSenders { if let p = w.socket { see(p) } }
        for seg in sock.segments { for f in seg.rights ?? [] { see(f) } }
        for d in sock.datagrams { for f in d.rights ?? [] { see(f) } }
    }

    private func see(_ seg: PosixShmSegment) {
        guard id(of: seg).isNew else { return }
        shmSegments.append(seg)
        if let o = seg.object { _ = sharedObjectID(o) }
    }

    private func see(_ g: GuestFile) {
        if id(of: g).isNew { hostFiles.append(g) }
    }

    private func see(_ kq: KQueue, kernel: DarwinKernel) {
        guard id(of: kq).isNew else { return }
        kqueues.append((kq, kernel))
        for kn in kq.knotes {
            _ = id(of: kn)
            switch kn.filter {
            case EVFilter.user, EVFilter.timer, EVFilter.machport, EVFilter.proc, EVFilter.signal, EVFilter.workloop,
                 EVFilter.vnode, EVFilter.fs:
                break
            case EVFilter.read, EVFilter.write:
                if let o = kn.object, objectFiles[ObjectIdentifier(o)] == nil, !(o is PipeEnd) {
                    refuse("knote on descriptor object \(type(of: o))")
                }
            default:
                refuse("knote filter \(kn.filter)")
            }
            if kn.isSyncKnote, !kn.syncWaiters.isEmpty, !kn.syncWaiters.waitingContexts.allSatisfy({
                classification.blocked[ObjectIdentifier($0)] != nil
            }) {
                refuse("workloop sync knote with an unsettled waiter")
            }
        }
    }

    // MARK: Capture

    /// Captures the system and `images`. `clock`: the guest counter and its frequency now.
    public func capture(images: [SnapshotImageInput], guestCounter: UInt64, frequency: UInt64, bootCounter: UInt64) {
        // The system is quiesced (no other thread runs): the lock split's
        // checks are off while every object is read (`mach-ipc-locking.md` §4.2).
        let threadLocks = KernelThreadLocks.current
        let wasQuiesced = threadLocks.quiesced
        threadLocks.quiesced = true
        defer { threadLocks.quiesced = wasQuiesced }
        precondition(system.lock.isHeldByCurrentThread, "capture needs the kernel lock")
        // Pass 1: ids.
        let processes = system.processes.values.sorted { $0.pid < $1.pid }
        for p in processes { _ = id(of: p) }
        for input in images {
            let k = input.kernel
            _ = id(of: k)
            for t in k.threadsByPort.values { _ = id(of: t) }
            if let s = k.machIPC as? MachIPC { see(s) }
            for fd in k.fileSystem.openDescriptors {
                if let f = try? k.fileSystem.openFile(for: fd) { see(f) }
            }
            if let q = k.kevents.workq { see(q, kernel: k) }
            for q in k.kevents.workloops.values { see(q, kernel: k) }
            for q in k.kevents.descriptorQueues.values { see(q, kernel: k) }
            for c in k.extended.directoryCursors.values { see(c.file) }
            for t in k.kevents.mkTimers.values { see(t.port) }
        }
        see(system.mach.hostPort)
        see(system.mach.bootstrapPort)
        if let h = system.mach.hostTask { see(h.ipc); count("host task") }
        for seg in system.posixShmSegments.values.sorted(by: { $0.name < $1.name }) { see(seg) }
        for sem in system.posixSemaphoreStorage.values.sorted(by: { $0.name < $1.name }) where id(of: sem).isNew {
            posixSemaphores.append(sem)
        }
        see(system.mach.ioMain)
        for p in system.mach.ioRegistryPaths.values { see(p) }
        for o in system.mach.ioObjects.values {
            switch o.kind {
            case let .iterator(entries, _): for p in entries { see(p) }
            case let .connection(service, _): see(service)
            default: break
            }
        }

        // Pass 2: records.
        var sys = SnapshotFields()
        sys.u64(ST.System.lastPID, UInt64(bitPattern: Int64(system.lastPID)))
        sys.u64(ST.System.nextPIDVersion, UInt64(system.nextPIDVersion))
        sys.u64(ST.System.nextUniqueID, system.nextUniqueID)
        sys.u64(ST.System.bootSalt, UInt64(system.bootSalt))
        sys.string(ST.System.bootSessionUUID, system.bootSessionUUID)
        sys.u64(ST.System.auditSession, UInt64(system.mach.auditSessionID))
        sys.u64(ST.System.serialCounter, system.mach.serialCounter)
        sys.u64(ST.System.stampCounter, system.mach.stampCounter)
        sys.u64(ST.System.spaceCounter, system.mach.spaceCounter)
        sys.bool(ST.System.hostBootstrapDefault, system.mach.hostBootstrapIsDefault)
        sys.ref(ST.System.hostPort, existingID(system.mach.hostPort))
        sys.ref(ST.System.bootstrapPort, existingID(system.mach.bootstrapPort))
        sys.nested(ST.System.ioKit, encodeIOKit())
        sys.nested(ST.System.fileLocks, encodeFileLocks())
        sys.list(ST.System.shmNames, system.posixShmSegments.sorted { $0.key < $1.key }.map { name, seg in
            var g = SnapshotFields()
            g.string(1, name)
            g.ref(2, existingID(seg))
            return g
        })
        sys.list(ST.System.semNames, system.posixSemaphoreStorage.sorted { $0.key < $1.key }.map { name, sem in
            var g = SnapshotFields()
            g.string(1, name)
            g.ref(2, existingID(sem))
            return g
        })
        records.append(SnapshotRecord(kind: .system, id: Self.systemID, fields: sys))
        for sock in sockets { records.append(encode(sock)) }
        count("unix socket", sockets.count)
        for seg in shmSegments { records.append(encode(seg)) }
        for sem in posixSemaphores { records.append(encode(sem)) }

        var clock = SnapshotFields()
        clock.u64(ST.Clock.guestCounter, guestCounter)
        clock.u64(ST.Clock.hostNanoseconds, hostNowNs)
        clock.u64(ST.Clock.frequency, frequency)
        clock.u64(ST.Clock.bootCounter, bootCounter)
        clock.u64(ST.Clock.wallSeconds, UInt64(Date().timeIntervalSince1970))
        records.append(SnapshotRecord(kind: .clock, id: Self.clockID, fields: clock))

        for p in processes { records.append(encode(p)) }
        count("process", processes.count)
        count("zombie", processes.filter { $0.state == .zombie }.count)
        for input in images { encodeImage(input) }
        for p in ports { records.append(encode(p)) }
        count("port", ports.count)
        count("message", ports.reduce(0) { $0 + queuedMessages($1).count })
        count("message bytes", ports.reduce(0) { $0 + $1.messages.all.reduce(0) { $0 + $1.size } })
        for s in portSets { records.append(encode(s)) }
        count("port set", portSets.count)
        for s in semaphores { records.append(encode(s)) }
        count("semaphore", semaphores.count)
        for s in spaces { records.append(encode(s)) }
        count("Mach space", spaces.count)
        for g in hostFiles { records.append(encode(g)) }
        count("host file", hostFiles.count)
        for p in pipes { records.append(encode(p)) }
        count("pipe", pipes.count)
        for f in openFiles { records.append(encode(f)) }
        count("open file description", openFiles.count)
        for (q, k) in kqueues { records.append(encode(q, kernel: k)) }
        count("kqueue", kqueues.count)
        count("knote", kqueues.reduce(0) { $0 + $1.0.knotes.count })
        for (id, o) in sharedObjects { records.append(encodeShared(o, id: id)) }
        recordsDone = true
    }

    /// The record id of a shared memory object (registered on first sight).
    public func sharedObjectID(_ o: SharedMemoryObject) -> UInt64 {
        let (oid, isNew) = id(of: o)
        guard isNew else { return oid }
        sharedObjects.append((oid, o))
        if o.isFileView, o.snapshotFileSource == nil { refuse("shared view of a host file without its source") }
        count("shared memory object")
        count("shared memory bytes", Int(o.size))
        if recordsDone { records.append(encodeShared(o, id: oid)) }
        return oid
    }

    /// Shared objects whose pages the VMM saves (anonymous ones, and file
    /// views of files that are gone).
    public func savesPages(_ o: SharedMemoryObject) -> Bool {
        guard o.isFileView else { return true }
        guard let src = o.snapshotFileSource else { return false }
        return access(src.hostPath, F_OK) != 0
    }

    private func encodeShared(_ o: SharedMemoryObject, id: UInt64) -> SnapshotRecord {
        var f = SnapshotFields()
        f.u64(ST.SharedMemory.size, o.size)
        // A view of a file that is gone is restored as plain shared memory.
        f.bool(ST.SharedMemory.file, o.isFileView && !savesPages(o))
        f.u64(ST.SharedMemory.serial, o.serial)
        if let src = o.snapshotFileSource {
            f.string(ST.SharedMemory.guestPath, src.guestPath)
            f.string(ST.SharedMemory.hostPath, src.hostPath)
            f.u64(ST.SharedMemory.offset, src.offset)
            f.u64(ST.SharedMemory.requested, src.requestedSize)
        }
        return SnapshotRecord(kind: .sharedMemory, id: id, fields: f)
    }

    /// A port's queue as the image has it: its messages, then the messages
    /// of blocked senders whose send completes in the image (§4.2).
    private func queuedMessages(_ p: IPCPort) -> [KMessage] {
        Array(p.messages.all) + p.snapshotPendingSends.filter { classification.blocked[$0.context]?.queuedSend == true }.map(\.message)
    }

    // MARK: Encoders (sockets, POSIX objects, locks, IOKit)

    private func encode(_ u: DescriptorUser) -> SnapshotFields {
        var g = SnapshotFields()
        g.i64(1, Int64(u.pid))
        g.u64(2, UInt64(u.pidVersion))
        g.u64(3, UInt64(u.uid))
        g.u64(4, UInt64(u.gid))
        return g
    }

    private func refs(_ files: [DarwinOpenFile]?) -> [UInt64]? { files.map { $0.map { existingID($0) } } }

    private func encode(_ s: UnixSocket) -> SnapshotRecord {
        typealias U = ST.Socket
        var f = SnapshotFields()
        f.u64(U.kind, UInt64(s.kind.rawValue))
        f.nested(U.creator, encode(s.creator))
        f.nested(U.lastUser, encode(s.lastUser))
        if let a = s.address { f.bytes(U.address, a) }
        if let p = s.boundPath { f.string(U.boundPath, p) }
        f.ref(U.peer, existingID(s.peer))
        if let l = s.logSink { f.string(U.logSink, l) }
        var flags: UInt64 = 0
        for (bit, on) in [s.isConnected, s.cantReceiveMore, s.cantSendMore, s.closed, s.isListening, s.noSigPipe].enumerated() where on {
            flags |= 1 << UInt64(bit)
        }
        f.u64(U.flags, flags)
        f.i64(U.error, Int64(s.error))
        f.i64(U.backlog, Int64(s.backlog))
        f.u64s(U.pending, s.pending.map { existingID($0) })
        if let l = s.listenUser { f.nested(U.listenUser, encode(l)) }
        f.list(U.segments, s.segments.map { seg in
            var g = SnapshotFields()
            g.bytes(1, Array(seg.bytes[seg.offset...]))
            if let r = refs(seg.rights) { g.u64s(2, r); g.bool(3, true) }
            return g
        })
        f.list(U.datagrams, s.datagrams.map { d in
            var g = SnapshotFields()
            g.bytes(1, d.bytes)
            g.bytes(4, d.from)
            if let r = refs(d.rights) { g.u64s(2, r); g.bool(3, true) }
            return g
        })
        f.u64s(U.connectedSenders, s.connectedSenders.compactMap { $0.socket.map { existingID($0) } })
        f.i64(U.sendBuffer, Int64(s.sendBufferSize))
        f.i64(U.receiveBuffer, Int64(s.receiveBufferSize))
        f.i64(U.sendLowWater, Int64(s.sendLowWater))
        f.i64(U.receiveLowWater, Int64(s.receiveLowWater))
        if let t = s.receiveTimeout { f.u64(U.receiveTimeout, t) }
        if let t = s.sendTimeout { f.u64(U.sendTimeout, t) }
        f.i64(U.lingerOn, Int64(s.linger.onOff))
        f.i64(U.lingerSeconds, Int64(s.linger.seconds))
        f.list(U.options, s.otherOptions.sorted { $0.key < $1.key }.map { k, v in
            var g = SnapshotFields()
            g.i64(1, Int64(k))
            g.bytes(2, v)
            return g
        })
        if let c = s.peerCredentials { f.nested(U.peerCredentials, encode(c)) }
        count("socket bytes", s.queuedBytes)
        return SnapshotRecord(kind: .unixSocket, id: existingID(s), fields: f)
    }

    private func encode(_ seg: PosixShmSegment) -> SnapshotRecord {
        var f = SnapshotFields()
        f.string(1, seg.name)
        f.u64(2, UInt64(seg.mode))
        f.u64(3, UInt64(seg.uid))
        f.u64(4, UInt64(seg.gid))
        f.ref(5, existingID(seg.object))
        f.u64(6, seg.length)
        f.bool(7, seg.sized)
        return SnapshotRecord(kind: .posixShm, id: existingID(seg), fields: f)
    }

    private func encode(_ sem: PosixSemaphore) -> SnapshotRecord {
        var f = SnapshotFields()
        f.string(1, sem.name)
        f.u64(2, UInt64(sem.mode))
        f.i64(3, Int64(sem.count))
        return SnapshotRecord(kind: .posixSem, id: existingID(sem), fields: f)
    }

    private func encodeFileLocks() -> SnapshotFields {
        var g = SnapshotFields()
        guard let t = system.fileLockStorage else { return g }
        g.list(1, t.files.compactMap { id, state in
            var h = SnapshotFields()
            h.u64(1, UInt64(id.dev))
            h.u64(2, id.ino)
            h.list(3, state.locks.compactMap { l in
                var k = SnapshotFields()
                switch l.owner {
                case let .process(pid): k.i64(1, Int64(pid))
                case let .description(key):
                    guard let file = openFiles.first(where: { ObjectIdentifier($0) == key }) else { return nil }
                    k.ref(2, existingID(file))
                }
                k.u64(3, l.kind == .posix ? 0 : l.kind == .ofd ? 1 : 2)
                k.bool(4, l.exclusive)
                k.i64(5, l.start)
                k.i64(6, l.end)
                return k
            })
            count("file lock", state.locks.count)
            return h
        })
        g.list(2, t.protectionClasses.map { id, c in
            var h = SnapshotFields()
            h.u64(1, UInt64(id.dev))
            h.u64(2, id.ino)
            h.i64(3, Int64(c))
            return h
        })
        return g
    }

    private func encodeIOKit() -> SnapshotFields {
        var g = SnapshotFields()
        g.ref(1, existingID(system.mach.ioMain))
        g.list(2, system.mach.ioRegistryPaths.sorted { $0.key < $1.key }.map { path, port in
            var h = SnapshotFields()
            h.string(1, path)
            h.ref(2, existingID(port))
            return h
        })
        g.list(3, system.mach.ioObjects.sorted { $0.key < $1.key }.map { serial, o in
            var h = SnapshotFields()
            h.u64(1, serial)
            switch o.kind {
            case let .entry(className, name, path, superclasses, entryID):
                h.u64(2, 1)
                h.string(3, className)
                h.string(4, name)
                h.string(5, path)
                h.list(6, superclasses.map { var x = SnapshotFields(); x.string(1, $0); return x })
                h.u64(7, entryID)
            case let .iterator(entries, next):
                h.u64(2, 2)
                h.u64s(8, entries.map { existingID($0) })
                h.i64(9, Int64(next))
            case .notification:
                h.u64(2, 3)
            case let .connection(service, type):
                h.u64(2, 4)
                h.ref(10, existingID(service))
                h.u64(11, UInt64(type))
            }
            return h
        })
        count("IOKit object", system.mach.ioObjects.count)
        return g
    }

    // MARK: Encoders

    private func encode(_ p: DarwinProcess) -> SnapshotRecord {
        var f = SnapshotFields()
        typealias T = ST.Process
        f.i64(T.pid, Int64(p.pid))
        f.i64(T.ppid, Int64(p.ppid))
        f.i64(T.pgid, Int64(p.pgid))
        f.i64(T.sid, Int64(p.sid))
        f.u64(T.uniqueID, p.uniqueID)
        f.u64(T.state, p.state == .running ? 0 : p.state == .stopped ? 1 : 2)
        f.i64(T.status, Int64(p.status))
        f.i64(T.exitHighBits, Int64(p.exitHighBits))
        f.ref(T.image, existingID(p.kernel))
        f.u64s(T.children, p.children.map { UInt64(bitPattern: Int64($0)) })
        f.string(T.executablePath, p.executablePath)
        f.string(T.comm, p.comm)
        f.string(T.name, p.name)
        f.bool(T.hasExeced, p.hasExeced)
        f.i64(T.startSeconds, p.startTime.seconds)
        f.i64(T.startMicroseconds, p.startTime.microseconds)
        f.u64(T.startAbsTime, p.startAbsTime)
        f.u64(T.exitAbsTime, p.exitAbsTime)
        f.u64(T.parentUniqueID, p.parentUniqueID)
        f.u64(T.originalParentPIDVersion, UInt64(p.originalParentPIDVersion))
        f.bool(T.exiting, p.exiting)
        f.bool(T.continuedPending, p.continuedPending)
        f.i64(T.continuedBy, Int64(p.continuedBy))
        f.u64(T.dirtyState, UInt64(p.dirtyState))
        f.u64(T.processType, UInt64(p.processType))
        f.u64(T.processControl, UInt64(p.processControl))
        f.u64(T.pidVersion, UInt64(p.pidVersion))
        if let r = p.exitReason { f.string(T.exitReason, r) }
        if let held = p.holdStart {
            f.u64(T.holdElapsed, KernelClock.now() &- held)
            f.string(T.holdLabel, p.holdLabel)
        }
        f.u64(T.qosClamp, UInt64(p.qosClamp))
        f.u64(T.darwinRole, UInt64(p.darwinRole))
        f.bool(T.requestedDarwinBG, p.requestedDarwinBG)
        if !p.watchers.isEmpty { count("EVFILT_PROC watcher", p.watchers.count) }
        return SnapshotRecord(kind: .process, id: existingID(p), fields: f)
    }

    private func encodeImage(_ input: SnapshotImageInput) {
        let k = input.kernel
        typealias T = ST.Image
        var f = SnapshotFields()
        f.i64(T.pid, Int64(k.pid))
        f.u64(T.pidVersion, UInt64(k.pidVersion))
        if let h = k.executableHostPath { f.string(T.executableHostPath, h) }
        if let p = k.processRecord { f.string(T.executablePath, p.executablePath) }
        f.u64(T.allImageInfos, k.allImageInfosAddress)
        f.u64(T.allImageInfosSize, k.allImageInfosSize)
        f.u64(T.mainStackTop, k.mainStackTop)
        if let r = k.threadRegistration {
            var g = SnapshotFields()
            typealias R = ST.Registration
            g.u64(R.threadStart, r.threadStart)
            g.u64(R.startWorkqueueThread, r.startWorkqueueThread)
            g.u64(R.pthreadSize, UInt64(r.pthreadSize))
            g.u64(R.dispatchQueueOffset, r.dispatchQueueOffset)
            g.u64(R.tsdOffset, UInt64(r.tsdOffset))
            g.u64(R.returnToKernelOffset, UInt64(r.returnToKernelOffset))
            g.u64(R.machThreadSelfOffset, UInt64(r.machThreadSelfOffset))
            g.u64(R.joinableOffsetBits, UInt64(r.joinableOffsetBits))
            g.u64(R.quantumExpiryOffset, UInt64(r.quantumExpiryOffset))
            f.nested(T.registration, g)
        }
        f.u64(T.nextActivityID, k.nextActivityID)
        f.u64(T.nextThreadID, k.nextThreadID)
        f.u64s(T.purgeable, k.purgeableStates.sorted { $0.key < $1.key }.flatMap { [$0.key, UInt64(bitPattern: Int64($0.value))] })
        if let v = k.exitValue { f.i64(T.exitValue, Int64(v)) }
        if let v = k.deathSignal { f.i64(T.deathSignal, Int64(v)) }
        f.list(T.sysctl, k.sysctl.entries.map(encode))
        // A sigsuspend that restarts sets its mask again; the image keeps the
        // mask from before it (the lowest thread id wins when several wait).
        var extended = k.extended
        if let saved = k.threadsByPort.values.sorted(by: { $0.threadID < $1.threadID })
            .compactMap({ classification.blocked[ObjectIdentifier($0)]?.savedSignalMask }).first {
            extended.signalMask = saved
        }
        f.nested(T.extended, encode(extended))
        f.list(T.ulocks, k.ulocks.sorted { $0.key < $1.key }.map { addr, q in
            var g = SnapshotFields()
            g.u64(ST.ULock.address, addr)
            g.u64(ST.ULock.opcode, UInt64(q.opcode))
            g.ref(ST.ULock.owner, existingID(q.owner))
            return g
        })
        count("ulock queue", k.ulocks.count)
        f.nested(T.workqueue, encodeWorkqueue(k))
        f.ref(T.space, existingID(k.machIPC as? MachIPC))
        var descriptors: [SnapshotFields] = []
        for fd in k.fileSystem.openDescriptors {
            guard let file = try? k.fileSystem.openFile(for: fd) else { continue }
            var g = SnapshotFields()
            typealias D = ST.Descriptor
            g.i64(D.fd, Int64(fd))
            g.ref(D.file, existingID(file))
            g.bool(D.cloexec, (try? k.fileSystem.closeOnExec(fd)) ?? false)
            g.bool(D.clofork, (try? k.fileSystem.closeOnFork(fd)) ?? false)
            if let guardState = try? k.fileSystem.guardState(of: fd) {
                g.u64(D.guardValue, guardState.value)
                g.u64(D.guardFlags, UInt64(guardState.flags))
            }
            descriptors.append(g)
        }
        count("descriptor", descriptors.count)
        f.list(T.descriptors, descriptors)
        f.string(T.cwd, k.fileSystem.cwd)
        f.i64(T.maxDescriptors, Int64(k.fileSystem.maxDescriptors))
        f.ref(T.workqKQueue, existingID(k.kevents.workq))
        f.u64s(T.workloops, k.kevents.workloops.values.map { existingID($0) })
        f.u64s(T.descriptorQueues, k.kevents.descriptorQueues.sorted { $0.key < $1.key }.flatMap {
            [UInt64(bitPattern: Int64($0.key)), existingID($0.value)]
        })
        f.u64s(T.mkTimers, k.kevents.mkTimers.values.map { existingID($0.port) })
        f.u64(T.mainThreadID, k.mainThread.threadID)
        records.append(SnapshotRecord(kind: .image, id: existingID(k), fields: f))

        // Threads.
        for t in k.threadsByPort.values.sorted(by: { $0.threadID < $1.threadID }) {
            records.append(encodeThread(t, kernel: k, input: input))
        }
        count("thread", k.threadsByPort.count)
    }

    private func encode(_ e: SysctlTable.Entry) -> SnapshotFields {
        var g = SnapshotFields()
        typealias S = ST.Sysctl
        g.string(S.name, e.name)
        g.u64s(S.mib, e.mib.map { UInt64(bitPattern: Int64($0)) })
        switch e.value {
        case let .integer(v, size):
            g.u64(S.kind, 1)
            g.i64(S.int, v)
            g.i64(S.size, Int64(size))
        case let .string(s):
            g.u64(S.kind, 2)
            g.bytes(S.bytes, Array(s.utf8))
        case let .error(e):
            g.u64(S.kind, 3)
            g.i64(S.int, Int64(e))
        case let .bytes(b):
            g.u64(S.kind, 4)
            g.bytes(S.bytes, b)
        }
        return g
    }

    private func encode(_ x: ExtendedBSDState) -> SnapshotFields {
        typealias E = ST.Extended
        var g = SnapshotFields()
        g.u64(E.signalMask, UInt64(x.signalMask))
        g.u64(E.pendingSignals, UInt64(x.pendingSignals))
        g.list(E.actions, x.signalActions.sorted { $0.key < $1.key }.map { sig, a in
            var h = SnapshotFields()
            h.i64(E.key, Int64(sig))
            h.u64(E.a, a.handler)
            h.u64(E.b, UInt64(a.mask))
            h.i64(E.c, Int64(a.flags))
            return h
        })
        g.u64(E.altSP, x.alternateStack.sp)
        g.u64(E.altSize, x.alternateStack.size)
        g.i64(E.altFlags, Int64(x.alternateStack.flags))
        g.list(E.rlimits, x.rlimits.sorted { $0.key < $1.key }.map { which, l in
            var h = SnapshotFields()
            h.i64(E.key, Int64(which))
            h.u64(E.a, l.cur)
            h.u64(E.b, l.max)
            return h
        })
        g.u64(E.umask, UInt64(x.umask))
        g.list(E.cursors, x.directoryCursors.sorted { $0.key < $1.key }.map { fd, c in
            var h = SnapshotFields()
            h.i64(E.key, Int64(fd))
            h.ref(E.file, existingID(c.file))
            h.u64(E.a, UInt64(c.next))
            h.list(E.names, c.entries.map { e in
                var n = SnapshotFields()
                n.string(E.key, e.name)
                n.u64(E.a, e.ino)
                n.u64(E.b, UInt64(e.type))
                return n
            })
            return h
        })
        g.u64s(E.ioPolicies, x.ioPolicies.sorted { $0.key < $1.key }.flatMap {
            [UInt64(bitPattern: Int64($0.key)), UInt64(bitPattern: Int64($0.value))]
        })
        g.list(E.threadIOPolicies, x.threadIOPolicies.sorted { $0.key < $1.key }.map { tid, policies in
            var h = SnapshotFields()
            h.u64(E.key, tid)
            h.u64s(E.a, policies.sorted { $0.key < $1.key }.flatMap {
                [UInt64(bitPattern: Int64($0.key)), UInt64(bitPattern: Int64($0.value))]
            })
            return h
        })
        g.i64(E.backgroundPolicy, Int64(x.darwinBackgroundIOPolicy))
        return g
    }

    private func encodeWorkqueue(_ k: DarwinKernel) -> SnapshotFields {
        typealias W = ST.Workqueue
        let w = k.workqueue
        var g = SnapshotFields()
        g.bool(W.isOpen, w.isOpen)
        if let d = w.dispatchConfig {
            g.bool(W.hasDispatch, true)
            g.u64(W.dispatchVersion, UInt64(d.version))
            g.u64(W.serialOffset, d.serialOffset)
            g.u64(W.labelOffset, d.labelOffset)
        }
        g.u64(W.newSPIOffset, UInt64(w.newSPIOffset))
        g.u64(W.managerPriority, UInt64(w.managerPriority))
        // Idle workers whose park is restarted are not idle (§4.1).
        g.u64s(W.idle, w.idle.filter { classification.blocked[ObjectIdentifier($0)]?.idleWorker != true }.map { existingID($0) })
        g.list(W.plainPending, w.plainPending.sorted { ($0.key.qos, $0.key.overcommit ? 1 : 0) < ($1.key.qos, $1.key.overcommit ? 1 : 0) }.map { key, n in
            var h = SnapshotFields()
            h.i64(W.qos, Int64(key.qos))
            h.bool(W.overcommit, key.overcommit)
            h.i64(W.count, Int64(n))
            return h
        })
        g.u64s(W.pendingWorkloops, w.pendingWorkloops.map { existingID($0) })
        g.u64(W.idleTimeout, w.idleTimeoutNanoseconds)
        count("workqueue worker", w.workers.count)
        return g
    }

    private func encodeThread(_ t: ThreadContext, kernel k: DarwinKernel, input: SnapshotImageInput) -> SnapshotRecord {
        typealias T = ST.Thread
        var f = SnapshotFields()
        f.ref(T.image, existingID(k))
        f.u64(T.threadID, t.threadID)
        f.u64(T.portName, UInt64(t.portName))
        f.u64(T.kind, t.kind == .main ? 0 : t.kind == .pthread ? 1 : 2)
        f.u64(T.pthreadAddress, t.pthreadAddress)
        f.u64(T.signalMask, UInt64(t.signalMask))
        f.bool(T.isMain, t === k.mainThread)
        let key = ObjectIdentifier(t)
        if let parked = input.parked[key] {
            f.u64(T.restoreKind, parked.kind.rawValue)
            f.bytes(T.frame, parked.frame.encoded())
            f.bytes(T.fp, parked.fp)
            count("thread \(parked.kind)")
        } else if let blocked = classification.blocked[key] {
            f.u64(T.restoreKind, (blocked.completed ? SnapshotThreadKind.resume : .blocked).rawValue)
            f.bytes(T.frame, blocked.frame.encoded())
            f.bytes(T.fp, input.fpState(t) ?? [])
            f.string(T.note, blocked.note)
            count("thread blocked")
        } else if t.suspendedStart != nil {
            f.u64(T.restoreKind, SnapshotThreadKind.suspended.rawValue)
            count("thread suspended")
        } else if t === k.mainThread, let start = input.mainStart {
            f.u64(T.restoreKind, SnapshotThreadKind.unstarted.rawValue)
            var g = SnapshotFields()
            g.u64s(ST.Start.x, start.registers)
            g.u64(ST.Start.pc, start.pc)
            g.u64(ST.Start.sp, start.sp)
            g.u64(ST.Start.tpidrro, start.tpidrro)
            g.u64(ST.Start.tpidr, start.tpidr)
            f.nested(T.mainStart, g)
            count("thread unstarted")
        } else {
            refuse("thread in no restorable state")
        }
        if let s = t.suspendedStart { f.nested(T.suspendedStart, encode(s)) }
        if let carried = t.carriedImportance { f.i64(T.carriedImportancePID, Int64(carried.pid)) }
        if let w = t.worker {
            typealias W = ST.Worker
            var g = SnapshotFields()
            let idleRestart = classification.blocked[key]?.idleWorker == true
            g.u64(W.base, w.base)
            g.u64(W.phase, idleRestart ? 0 : w.phase == .running ? 0 : w.phase == .idle ? 1 : 2)
            g.bool(W.firstRun, w.firstRun)
            g.i64(W.qos, Int64(w.qos))
            g.bool(W.constrained, w.constrained)
            g.ref(W.boundQueue, existingID(w.boundQueue))
            if let b = w.boundBucket { g.i64(W.boundBucket, Int64(b)) }
            g.bool(W.keventRun, w.keventRun)
            g.u64s(W.delivered, w.delivered.map { existingID($0) })
            if w.assignment != nil { refuse("worker with a pending assignment") }
            g.bool(W.idle, k.workqueue.workers[t.threadID] != nil)
            f.nested(T.worker, g)
        }
        return SnapshotRecord(kind: .thread, id: existingID(t), fields: f)
    }

    private func encode(_ s: ThreadStartState) -> SnapshotFields {
        var g = SnapshotFields()
        g.u64s(ST.Start.x, s.x)
        g.u64(ST.Start.pc, s.pc)
        g.u64(ST.Start.sp, s.sp)
        g.u64(ST.Start.tpidrro, s.tpidrro)
        g.u64(ST.Start.tpidr, s.tpidr)
        return g
    }

    func encode(_ r: CarriedRight) -> SnapshotFields {
        var g = SnapshotFields()
        switch r {
        case .null: g.u64(ST.Right.kind, 0)
        case .dead: g.u64(ST.Right.kind, 1)
        case let .send(p): g.u64(ST.Right.kind, 2); g.ref(ST.Right.port, existingID(p))
        case let .sendOnce(p): g.u64(ST.Right.kind, 3); g.ref(ST.Right.port, existingID(p))
        case let .receive(p): g.u64(ST.Right.kind, 4); g.ref(ST.Right.port, existingID(p))
        }
        return g
    }

    private func encode(_ p: IPCPort) -> SnapshotRecord {
        typealias T = ST.Port
        var f = SnapshotFields()
        f.u64(T.serial, p.serial)
        if let o = p.kernelObject {
            let (kind, value): (UInt64, UInt64) = switch o {
            case .task: (1, 0)
            case .taskName: (2, 0)
            case .taskRead: (3, 0)
            case .taskInspect: (4, 0)
            case let .thread(serial): (5, serial)
            case .host: (6, 0)
            case .bootstrap: (7, 0)
            case let .clock(id): (8, UInt64(bitPattern: Int64(id)))
            case let .semaphore(serial): (9, serial)
            case let .fileport(serial): (10, serial)
            case let .memoryEntry(serial): (11, serial)
            case .ioMain: (12, 0)
            case let .ioObject(serial): (13, serial)
            }
            f.u64(T.kobjectKind, kind)
            f.u64(T.kobjectValue, value)
        }
        if let s = p.semaphore { f.ref(T.semaphore, existingID(s)) }
        f.bool(T.specialReply, p.isSpecialReply)
        f.ref(T.task, existingID(p.task))
        if let file = p.fileportFile { f.ref(T.fileport, existingID(file)) }
        if let t = p.mkTimer {
            var g = SnapshotFields()
            g.bool(T.timerArmed, t.deadline != nil)
            if let d = t.deadline { g.i64(T.timerDeadline, Int64(bitPattern: d &- hostNowNs)) }
            g.u64(T.timerTicks, t.armedTicks)
            f.nested(T.mkTimer, g)
            count("mk_timer")
        }
        f.bool(T.active, p.active)
        f.ref(T.receiver, existingID(p.receiver))
        f.ref(T.transitHolder, existingID(p.transitHolder))
        f.i64(T.srights, Int64(p.srights))
        f.i64(T.sorights, Int64(p.sorights))
        f.u64(T.mscount, UInt64(p.mscount))
        f.u64(T.seqno, UInt64(p.seqno))
        f.i64(T.qlimit, Int64(p.qlimit))
        f.u64(T.context, p.context)
        f.bool(T.guarded, p.guarded)
        f.bool(T.strict, p.strict)
        f.bool(T.immovable, p.immovable)
        f.ref(T.pdRequest, existingID(p.pdRequest))
        f.ref(T.nsRequest, existingID(p.nsRequest))
        f.list(T.dnRequests, p.dnRequests.sorted { $0.key < $1.key }.map { key, port in
            var g = SnapshotFields()
            g.u64(T.space, key.space)
            g.u64(T.name, UInt64(key.name))
            g.ref(T.port, existingID(port))
            return g
        })
        f.list(T.spRequests, p.spRequests.sorted { $0.key < $1.key }.map { key, armed in
            var g = SnapshotFields()
            g.u64(T.space, key.space)
            g.u64(T.name, UInt64(key.name))
            g.bool(T.armed, armed)
            return g
        })
        f.list(T.deadNameNotified, p.deadNameNotified.sorted().map { key in
            var g = SnapshotFields()
            g.u64(T.space, key.space)
            g.u64(T.name, UInt64(key.name))
            return g
        })
        f.u64s(T.sets, p.sets.map { existingID($0) })
        f.u64(T.readyStamp, p.readyStamp)
        f.u64(T.changeStamp, p.changeStamp)
        f.list(T.messages, queuedMessages(p).map(encode))
        if p.importanceDonation { f.bool(T.importanceDonation, true) }
        if p.tempOwner { f.bool(T.tempOwner, true) }
        if let w = p.watchProcess { f.i64(T.watchPID, Int64(w.pid)) }
        if let m = p.memoryEntry {
            var g = SnapshotFields()
            g.ref(ST.SharedMemory.serial, existingID(m.object))
            g.u64(ST.SharedMemory.size, m.size)
            g.u64(ST.SharedMemory.file, m.offset)
            g.u64(ST.SharedMemory.pages, UInt64(m.protection.rawValue))
            f.nested(T.memoryEntry, g)
        }
        return SnapshotRecord(kind: .port, id: existingID(p), fields: f)
    }

    private func encode(_ m: KMessage) -> SnapshotFields {
        typealias M = ST.Message
        var g = SnapshotFields()
        g.bool(M.complex, m.complex)
        g.nested(M.destination, encode(m.destination))
        g.u64(M.destinationType, UInt64(m.destinationType))
        g.nested(M.reply, encode(m.reply))
        g.u64(M.replyType, UInt64(m.replyType))
        g.u64(M.voucher, UInt64(m.voucherRaw))
        g.i64(M.id, Int64(m.id))
        g.list(M.items, m.items.map { item in
            var h = SnapshotFields()
            switch item {
            case let .port(r, type):
                h.u64(M.itemKind, 1)
                h.nested(M.right, encode(r))
                h.u64(M.type, UInt64(type))
            case let .ool(data, copy, volatile):
                h.u64(M.itemKind, 2)
                h.bytes(M.data, data)
                h.u64(M.copy, UInt64(copy))
                h.bool(M.volatile, volatile)
            case let .oolPorts(rights, type, copy):
                h.u64(M.itemKind, 3)
                h.list(M.rights, rights.map(encode))
                h.u64(M.type, UInt64(type))
                h.u64(M.copy, UInt64(copy))
            case let .guarded(r, flags, type):
                h.u64(M.itemKind, 4)
                h.nested(M.right, encode(r))
                h.u64(M.flags, UInt64(flags))
                h.u64(M.type, UInt64(type))
            }
            return h
        })
        g.bytes(M.inline, m.inline)
        if let aux = m.aux {
            g.bool(M.hasAux, true)
            g.bytes(M.aux, aux)
        }
        g.bool(M.fromKernel, m.fromKernel)
        g.bool(M.timerExpiry, m.isTimerExpiry)
        if m.importance { g.bool(M.importance, true) }
        if m.pushClass >= 0 { g.i64(M.pushClass, Int64(m.pushClass)) }
        if let s = m.sender {
            var h = SnapshotFields()
            h.u64(M.uid, UInt64(s.uid))
            h.u64(M.gid, UInt64(s.gid))
            h.i64(M.pid, Int64(s.pid))
            h.u64(M.pidVersion, UInt64(s.pidVersion))
            h.u64(M.asid, UInt64(s.auditSessionID))
            g.nested(M.sender, h)
        }
        return g
    }

    private func encode(_ s: IPCPortSet) -> SnapshotRecord {
        var f = SnapshotFields()
        f.u64(ST.PortSet.serial, s.serial)
        f.u64(ST.PortSet.name, UInt64(s.name))
        f.u64s(ST.PortSet.members, s.members.map { existingID($0) })
        f.bool(ST.PortSet.active, s.active)
        f.u64(ST.PortSet.changeStamp, s.changeStamp)
        return SnapshotRecord(kind: .portSet, id: existingID(s), fields: f)
    }

    private func encode(_ s: KernelSemaphore) -> SnapshotRecord {
        var f = SnapshotFields()
        f.i64(ST.Semaphore.count, Int64(s.count))
        f.bool(ST.Semaphore.destroyed, s.isDestroyed)
        return SnapshotRecord(kind: .semaphore, id: existingID(s), fields: f)
    }

    private func encode(_ s: MachIPC) -> SnapshotRecord {
        typealias T = ST.Space
        var f = SnapshotFields()
        f.ref(T.image, existingID(s.kernel))
        f.u64(T.spaceID, s.spaceID)
        f.bool(T.isHostTask, s === system.mach.hostTask?.ipc)
        f.i64(T.pid, Int64(s.pid))
        f.u64(T.pidVersion, UInt64(s.pidVersion))
        f.u64(T.uid, UInt64(s.uid))
        f.u64(T.gid, UInt64(s.gid))
        f.bool(T.terminated, s.isTerminated)
        var entries: [SnapshotFields] = []
        for (i, e) in s.entries.enumerated() where i > 0 && (e.inUse || e.generation != 63) {
            var g = SnapshotFields()
            g.u64(T.index, UInt64(i))
            g.u64(T.generation, UInt64(e.generation))
            g.bool(T.inUse, e.inUse)
            g.u64(T.bits, UInt64(e.bits))
            g.u64(T.urefs, UInt64(e.urefs))
            g.ref(T.port, existingID(e.port))
            g.ref(T.set, existingID(e.set))
            entries.append(g)
        }
        count("Mach name", s.entries.filter(\.inUse).count)
        f.list(T.entries, entries)
        f.u64(T.nextFresh, UInt64(s.nextFresh))
        f.u64s(T.freeList, s.freeList.map { UInt64($0) })
        f.ref(T.taskPort, existingID(s.taskPort))
        f.ref(T.taskNamePort, existingID(s.taskNamePort))
        f.ref(T.taskReadPort, existingID(s.taskReadPort))
        f.ref(T.taskInspectPort, existingID(s.taskInspectPort))
        f.ref(T.mainThreadPort, existingID(s.mainThreadPort))
        f.u64s(T.clockPorts, s.clockPorts.sorted { $0.key < $1.key }.flatMap { [UInt64(bitPattern: Int64($0.key)), existingID($0.value)] })
        f.nested(T.slots, encode(s.slots))
        f.u64s(T.ownedKernelPorts, s.ownedKernelPorts.map { existingID($0) })
        f.u64s(T.specialReplyPorts, s.specialReplyPorts.sorted { $0.key < $1.key }.flatMap { [$0.key, existingID($0.value)] })
        var exceptions: [SnapshotFields] = []
        for (key, slots) in s.threadExceptions {
            guard let port = s.ownedKernelPorts.first(where: { ObjectIdentifier($0) == key }) ?? ports.first(where: { ObjectIdentifier($0) == key }) else { continue }
            var g = SnapshotFields()
            g.ref(T.key, existingID(port))
            g.list(T.slots, slots.map(encode))
            exceptions.append(g)
        }
        f.list(T.threadExceptions, exceptions)
        return SnapshotRecord(kind: .machSpace, id: existingID(s), fields: f)
    }

    private func encode(_ e: ExceptionSlot) -> SnapshotFields {
        var g = SnapshotFields()
        g.nested(ST.Slots.right, encode(e.port))
        g.u64(ST.Slots.behavior, UInt64(e.behavior))
        g.u64(ST.Slots.flavor, UInt64(e.flavor))
        return g
    }

    private func encode(_ s: TaskPortSlots) -> SnapshotFields {
        typealias T = ST.Slots
        var g = SnapshotFields()
        g.nested(T.host, encode(s.host))
        g.nested(T.bootstrap, encode(s.bootstrap))
        g.nested(T.access, encode(s.access))
        g.nested(T.debugControl, encode(s.debugControl))
        g.nested(T.resourceNotify, encode(s.resourceNotify))
        g.list(T.registered, s.registered.map(encode))
        g.list(T.exceptions, s.exceptions.map(encode))
        return g
    }

    /// The path the host file has now, when it still has one and it is the
    /// same file (Linux: the `/proc/self/fd` link follows renames). Nil
    /// when unknown or unlinked.
    static func currentHostPath(_ fd: Int32) -> String? {
        #if os(Linux)
        var buffer = [CChar](repeating: 0, count: 4097)
        let n = readlink("/proc/self/fd/\(fd)", &buffer, 4096)
        guard n > 0 else { return nil }
        let path = String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard path.hasPrefix("/"), !path.hasSuffix(" (deleted)") else { return nil }
        var a = stat(), b = stat()
        guard fstat(fd, &a) == 0, stat(path, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino else { return nil }
        return path
        #else
        return nil
        #endif
    }

    /// The guest path of a host file that moved from `old` (guest path
    /// `guestPath`) to `new`: the part both paths share at their end is
    /// the path below the prefix that maps one to the other.
    static func guestPath(of new: String, renamedFrom old: String, guestPath: String) -> String {
        if old == guestPath { return new }
        let o = old.split(separator: "/", omittingEmptySubsequences: false)
        let g = guestPath.split(separator: "/", omittingEmptySubsequences: false)
        var common = 0
        while common < min(o.count, g.count) - 1, o[o.count - 1 - common] == g[g.count - 1 - common] { common += 1 }
        let hostBase = o.dropLast(common).joined(separator: "/"), guestBase = g.dropLast(common).joined(separator: "/")
        guard new.hasPrefix(hostBase + "/") else { return guestPath }
        return guestBase + new.dropFirst(hostBase.count)
    }

    /// The host file's modification time (seconds) as `fstat` reports it now.
    static func currentModificationTime(_ fd: Int32) -> Int64? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        #if os(Linux)
        return Int64(st.st_mtim.tv_sec)
        #else
        return Int64(st.st_mtimespec.tv_sec)
        #endif
    }

    private func encode(_ g: GuestFile) -> SnapshotRecord {
        typealias T = ST.HostFile
        var f = SnapshotFields()
        // A file renamed while open (an atomic save: write "x.tmp", rename
        // it to "x", close later) is recorded under its current name, so
        // the restore reopens the file the process has open, not a path
        // that no longer exists.
        var guestPath = g.guestPath, hostPath = g.hostPath
        if let moved = Self.currentHostPath(g.hostFD), moved != hostPath {
            count("open file renamed")
            guestPath = Self.guestPath(of: moved, renamedFrom: hostPath, guestPath: guestPath)
            hostPath = moved
        }
        f.string(T.guestPath, guestPath)
        f.string(T.hostPath, hostPath)
        f.u64(T.size, g.size)
        // The modification time now (not when the file was opened), so a
        // restore reports only files that changed after the snapshot.
        f.i64(T.mtime, Self.currentModificationTime(g.hostFD) ?? g.stat.mtime.sec)
        let writable = openFiles.contains { o in o.guestFile === g && o.isWritable }
        f.bool(T.writable, writable)
        // A file unlinked while open has no path to reopen: its bytes go
        // into the snapshot and the restore makes an unlinked copy.
        var st = stat()
        if fstat(g.hostFD, &st) == 0, st.st_nlink == 0 {
            count("unlinked open file")
            if g.size <= 256 << 20, let bytes = try? g.read(count: Int(g.size), offset: 0) {
                f.bool(T.unlinked, true)
                f.bytes(T.content, bytes)
                count("unlinked file bytes", bytes.count)
            } else {
                refuse("unlinked open file over 256 MiB")
            }
        }
        return SnapshotRecord(kind: .hostFile, id: existingID(g), fields: f)
    }

    private func encode(_ p: KernelPipe) -> SnapshotRecord {
        typealias T = ST.Pipe
        var f = SnapshotFields()
        f.bytes(T.buffer, p.buffer.peek(p.buffer.count))
        f.bool(T.readerOpen, p.readerOpen)
        f.bool(T.writerOpen, p.writerOpen)
        f.i64(T.atimeS, p.accessTime.sec)
        f.i64(T.atimeN, p.accessTime.nsec)
        f.i64(T.mtimeS, p.modifyTime.sec)
        f.i64(T.mtimeN, p.modifyTime.nsec)
        count("pipe bytes", p.buffer.count)
        return SnapshotRecord(kind: .pipe, id: existingID(p), fields: f)
    }

    private func encode(_ o: DarwinOpenFile) -> SnapshotRecord {
        typealias T = ST.OpenFile
        var f = SnapshotFields()
        switch o.node {
        case let .console(stream):
            f.u64(T.nodeKind, 1)
            f.i64(T.stream, Int64(stream))
        case let .file(g):
            f.u64(T.nodeKind, 2)
            f.ref(T.file, existingID(g))
        case let .object(obj):
            if let end = obj as? PipeEnd {
                f.u64(T.nodeKind, 3)
                f.ref(T.object, existingID(end.pipe))
                f.bool(T.readEnd, end.isReadEnd)
            } else if let kqo = obj as? KQueueObject {
                f.u64(T.nodeKind, 4)
                f.ref(T.object, existingID(kqo.queue))
            } else if let d = obj as? DarwinDevice {
                f.u64(T.nodeKind, 5)
                f.string(T.device, d.kind.rawValue)
            } else if let sock = obj as? UnixSocket {
                f.u64(T.nodeKind, 6)
                f.ref(T.object, existingID(sock))
            } else if let shm = obj as? PosixShmDescriptor {
                f.u64(T.nodeKind, 7)
                f.ref(T.object, existingID(shm.segment))
            } else if let sem = obj as? PosixSemDescriptor {
                f.u64(T.nodeKind, 8)
                f.ref(T.object, existingID(sem.semaphore))
            } else {
                f.u64(T.nodeKind, 0)
            }
        }
        f.u64(T.offset, o.offset)
        f.i64(T.statusFlags, Int64(o.statusFlags))
        f.bool(T.noSigPipe, o.noSigPipe)
        f.bool(T.confined, o.confinedToProcess)
        f.bool(T.lockHandler, o.lastCloseHandlers["locks"] != nil)
        return SnapshotRecord(kind: .openFile, id: existingID(o), fields: f)
    }

    private func encode(_ q: KQueue, kernel k: DarwinKernel) -> SnapshotRecord {
        typealias T = ST.KQueue
        var f = SnapshotFields()
        f.ref(T.image, existingID(k))
        switch q.kind {
        case let .descriptor(fd): f.u64(T.kind, 1); f.i64(T.fd, Int64(fd))
        case .workq: f.u64(T.kind, 2)
        case .workloop: f.u64(T.kind, 3)
        }
        f.bool(T.hasObject, q.object != nil)
        if let l = q.legacyFormat { f.u64(T.legacy, l ? 1 : 2) }
        f.list(T.buckets, q.buckets.sorted { $0.key < $1.key }.map { b, s in
            var g = SnapshotFields()
            g.i64(T.bucket, Int64(b))
            g.bool(T.requested, s.requested)
            g.ref(T.boundWorker, existingID(s.boundWorker))
            return g
        })
        f.u64(T.workloopID, q.workloopID)
        f.ref(T.servicer, existingID(q.servicer))
        f.ref(T.owner, existingID(q.owner))
        f.bool(T.requested, q.requested)
        f.i64(T.requestQoS, Int64(q.requestQoS))
        f.bool(T.overcommit, q.requestOvercommit)
        f.bool(T.fixedPriority, q.fixedPriority)
        f.bool(T.createReference, q.createReference)
        // A sync knote whose waiter restarts its kevent call is made again by it.
        let kept = q.knotes.filter { kn in
            !(kn.isSyncKnote && !kn.syncWaiters.isEmpty
              && kn.syncWaiters.waitingContexts.allSatisfy { classification.blocked[ObjectIdentifier($0)] != nil })
        }
        f.list(T.knotes, kept.map { kn in
            typealias N = ST.Knote
            var g = SnapshotFields()
            g.u64(N.id, existingID(kn))
            g.u64(N.ident, kn.ident)
            g.i64(N.filter, Int64(kn.filter))
            g.u64(N.flags, UInt64(kn.flags))
            g.u64(N.fflags, UInt64(kn.fflags))
            g.i64(N.data, kn.data)
            g.u64(N.udata, kn.udata)
            g.u64(N.qos, UInt64(kn.qos))
            g.u64s(N.ext, kn.ext)
            var state: UInt64 = 0
            for (bit, on) in [kn.enabled, kn.active, kn.suppressed, kn.deletePending, kn.syntheticDelete, kn.dropped,
                              kn.receiveGone, kn.procExited].enumerated() where on {
                state |= 1 << UInt64(bit)
            }
            g.u64(N.state, state)
            g.i64(N.bucket, Int64(kn.bucket))
            g.u64(N.userFlags, UInt64(kn.userFlags))
            if let d = kn.timerDeadline { g.i64(N.timerDeadline, Int64(bitPattern: d &- hostNowNs)) }
            g.u64(N.timerInterval, kn.timerInterval)
            g.i64(N.timerFires, kn.timerFires)
            g.u64(N.procFired, UInt64(kn.procFired))
            g.i64(N.procData, kn.procData)
            g.i64(N.signalCount, kn.signalCount)
            if let o = kn.object, let file = objectFiles[ObjectIdentifier(o)] { g.ref(N.object, existingID(file)) }
            g.bool(N.hostDescriptor, kn.hostDescriptor)
            g.bool(N.requestsVanish, kn.requestsVanish)
            g.bool(N.syncWoken, kn.syncWoken)
            count("knote filter \(kn.filter)")
            return g
        })
        return SnapshotRecord(kind: .kqueue, id: existingID(q), fields: f)
    }
}
