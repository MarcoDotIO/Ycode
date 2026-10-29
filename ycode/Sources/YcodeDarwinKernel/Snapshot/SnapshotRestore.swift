// Restore of the kernel personality from snapshot records
// (specs/simulator/snapshot.md §7 steps 3, 4, 6, 7). The VMM drives it:
// `makeProcesses` before the images are launched (suspended), then
// `restoreObjects` once every image's memory is back, then it starts the
// returned threads.

import Foundation
import YcodeDarwinABI

/// Rebuilds the kernel personality from snapshot records (`snapshot.md` §7).
/// The VMM calls `makeProcesses`, launches the images suspended, calls
/// `restoreObjects` once their memory is back, starts the returned threads,
/// then calls `restoreStartHolds`.
public final class KernelSnapshotRestore {
    /// One live image to launch suspended: its restored kernel and process, and
    /// the guest and host paths of its executable.
    public struct ImagePlan {
        /// The image's record id in the snapshot.
        public let recordID: UInt64
        public let kernel: DarwinKernel
        public let pid: Int32
        public let executablePath: String
        public let hostExecutablePath: String
    }

    /// One thread for the VMM to start (§7 step 9): its frame and FP/SIMD state
    /// go into the vCPU, and `kind` says whether it resumes or re-enters its trap.
    public struct ThreadPlan {
        public let kernel: DarwinKernel
        public let context: ThreadContext
        public let kind: SnapshotThreadKind
        public let frame: TrapFrame
        public let fp: [UInt8]
        /// What the thread was blocked in, for the restore's report (empty if none).
        public let note: String
    }

    /// The snapshot's clock record (§5). `guestCounter`, `frequency` and
    /// `bootCounter` are in guest counter units; `hostNanoseconds` is host
    /// monotonic time at the capture.
    public struct Clock {
        public var guestCounter: UInt64
        public var hostNanoseconds: UInt64
        public var frequency: UInt64
        public var bootCounter: UInt64
    }

    /// The system that receives the restored processes and objects.
    public let system: DarwinSystem
    private var records: [UInt64: SnapshotRecord] = [:]
    private var fields: [UInt64: SnapshotFieldReader] = [:]
    private var byKind: [UInt16: [UInt64]] = [:]
    /// The clock record, read by `init`; the VMM sets the system clock offset from it.
    public private(set) var clock: Clock
    /// Problems found while restoring that did not stop it (one line each).
    public private(set) var warnings: [String] = []

    // The objects made for record ids.
    private var kernels: [UInt64: DarwinKernel] = [:]
    private var processes: [UInt64: DarwinProcess] = [:]
    private var ports: [UInt64: IPCPort] = [:]
    private var portSets: [UInt64: IPCPortSet] = [:]
    private var semaphores: [UInt64: KernelSemaphore] = [:]
    private var spaces: [UInt64: MachIPC] = [:]
    private var spaceIDMap: [UInt64: UInt64] = [:]
    private var hostFiles: [UInt64: GuestFile] = [:]
    private var pipes: [UInt64: KernelPipe] = [:]
    private var openFiles: [UInt64: DarwinOpenFile] = [:]
    private var kqueues: [UInt64: KQueue] = [:]
    private var knotes: [UInt64: Knote] = [:]
    private var threads: [UInt64: ThreadContext] = [:]
    private var memories: [ObjectIdentifier: any KernelGuestMemory] = [:]
    private var sharedObjects: [UInt64: SharedMemoryObject] = [:]
    private let sharedObjectsLock = NSRecursiveLock()
    private var rootFileSystem: DarwinFileSystem?
    /// Live host-task objects that stand for recorded ones.
    private var reusedPorts = Set<ObjectIdentifier>()
    private var reusedSets = Set<ObjectIdentifier>()
    private var sockets: [UInt64: UnixSocket] = [:]
    private var inetSockets: [UInt64: InetSocket] = [:]
    private var shmSegments: [UInt64: PosixShmSegment] = [:]
    private var posixSemaphores: [UInt64: PosixSemaphore] = [:]
    /// Processes in a start hold at the snapshot (process, label, ns held).
    private var heldProcesses: [(DarwinProcess, String, UInt64)] = []
    /// Images whose main thread had not started (§3.2 `unstarted`): the VMM
    /// keeps them suspended with this start state; resuming them (a start
    /// hold's release, `task_resume`) starts it.
    public private(set) var unstartedMains: [(kernel: DarwinKernel, start: SnapshotMainStart)] = []

    /// After the threads were started: the start holds of the snapshot are
    /// held again, with the time they had already been held counted.
    public func restoreStartHolds() {
        system.lock.withLock {
            for (p, label, elapsed) in heldProcesses where p.state != .zombie && !p.exiting {
                system.startHold(p, label: label)
                p.holdStart = KernelClock.now() &- elapsed
                system.schedStats.holds -= 1
            }
        }
    }
    /// The number of processes that were in a start hold at the snapshot.
    public var heldProcessCount: Int { heldProcesses.count }
    private let restoreNowNs = KernelClock.now()
    /// Calendar-time EVFILT_TIMER knotes whose deadline was set from the
    /// wall clock at the restore (§5), for the restore's report.
    public private(set) var wallClockTimers = 0
    /// Files opened read-write again although their mode had lost its
    /// write bit since the guest opened or mapped them (`openWritableAgain`).
    public private(set) var readOnlyReopens = 0

    /// Indexes `list` and reads the clock and system records.
    /// Throws `SnapshotError` if a record kind is unknown to this build, the clock
    /// or system record is missing, or the snapshot needs CPU features this host
    /// does not offer (`cpu-features.md` §9.4).
    public init(records list: [SnapshotRecord], system: DarwinSystem) throws {
        self.system = system
        for r in list {
            records[r.id] = r
            fields[r.id] = try r.fields()
            byKind[r.kind, default: []].append(r.id)
            if r.knownKind == nil && r.kind & 0x8000 == 0 {
                throw SnapshotError("snapshot record kind \(r.kind) is unknown to this build")
            }
        }
        guard let c = fields[KernelSnapshotCapture.clockID] else { throw SnapshotError("snapshot has no clock record") }
        clock = Clock(guestCounter: c.u64(ST.Clock.guestCounter), hostNanoseconds: c.u64(ST.Clock.hostNanoseconds),
                      frequency: c.u64(ST.Clock.frequency), bootCounter: c.u64(ST.Clock.bootCounter))
        guard let s = fields[KernelSnapshotCapture.systemID] else { throw SnapshotError("snapshot has no system record") }
        // cpu-features.md §6: the snapshot's guests may use every feature
        // they were told about; this host must offer all of them.
        let recorded = s.bytes(ST.System.cpuFeatures)
        if !recorded.isEmpty {
            let missing = CPUFeatureSet(storedBytes: recorded).subtracting(GuestCPUProfile.current.allowed)
            guard missing.isEmpty else {
                throw SnapshotError("snapshot was taken on a host with CPU features this host does not offer: "
                    + missing.names.joined(separator: ", "))
            }
        }
    }

    private func ids(_ kind: SnapshotRecordKind) -> [UInt64] { byKind[kind.rawValue] ?? [] }
    private func f(_ id: UInt64) -> SnapshotFieldReader { fields[id]! }

    /// Rebases a deadline stored as (deadline − snapshot host time).
    private func rebased(_ relative: Int64) -> UInt64 {
        relative <= 0 ? restoreNowNs : restoreNowNs &+ UInt64(relative)
    }

    // MARK: Step 3–4: the process table and the kernels

    /// Restores the system scalars and the process table, and makes one
    /// `DarwinKernel` per live image (with a file system from
    /// `makeFileSystem`). Lock taken.
    public func makeProcesses(makeFileSystem: () -> DarwinFileSystem) throws -> [ImagePlan] {
        // Mach state (the host and bootstrap ports, the audit session) is
        // the port lock's as well as L0's (`restoreObjects`).
        try system.lock.withLock { try system.lock.withAllFineLocks {
            let s = f(KernelSnapshotCapture.systemID)
            typealias S = ST.System
            system.lastPID = s.i32(S.lastPID)
            system.nextPIDVersion = s.u32(S.nextPIDVersion)
            system.nextUniqueID = s.u64(S.nextUniqueID)
            system.bootSalt = s.u32(S.bootSalt)
            if let u = s.string(S.bootSessionUUID) { system.bootSessionUUID = u }
            system.mach.auditSessionID = s.u32(S.auditSession)
            system.mach.hostBootstrapIsDefault = s.bool(S.hostBootstrapDefault)
            ports[s.ref(S.hostPort)] = system.mach.hostPort
            ports[s.ref(S.bootstrapPort)] = system.mach.bootstrapPort

            var plans: [ImagePlan] = []
            for id in ids(.process).sorted(by: { f($0).i64(ST.Process.pid) < f($1).i64(ST.Process.pid) }) {
                let r = f(id)
                typealias P = ST.Process
                let pid = r.i32(P.pid)
                let p: DarwinProcess
                if let existing = system.processes[pid], pid == DarwinSystem.initPID {
                    p = existing
                    p.ppid = r.i32(P.ppid)
                    p.pgid = r.i32(P.pgid)
                    p.sid = r.i32(P.sid)
                } else {
                    p = DarwinProcess(pid: pid, ppid: r.i32(P.ppid), pgid: r.i32(P.pgid), sid: r.i32(P.sid),
                                      uniqueID: r.u64(P.uniqueID), executablePath: r.string(P.executablePath) ?? "",
                                      startTime: (r.i64(P.startSeconds), r.i64(P.startMicroseconds)))
                }
                p.state = [DarwinProcess.State.running, .stopped, .zombie][Int(min(r.u64(P.state), 2))]
                p.status = r.i32(P.status)
                p.exitHighBits = r.i32(P.exitHighBits)
                p.children = r.u64s(P.children).map { Int32(truncatingIfNeeded: Int64(bitPattern: $0)) }
                p.setImagePath(r.string(P.executablePath) ?? p.executablePath)
                if let c = r.string(P.comm) { p.comm = c }
                if let n = r.string(P.name) { p.name = n }
                p.hasExeced = r.bool(P.hasExeced)
                p.startTime = (r.i64(P.startSeconds), r.i64(P.startMicroseconds))
                p.startAbsTime = r.u64(P.startAbsTime)
                p.exitAbsTime = r.u64(P.exitAbsTime)
                p.parentUniqueID = r.u64(P.parentUniqueID)
                p.originalParentPIDVersion = r.u32(P.originalParentPIDVersion)
                p.exiting = r.bool(P.exiting)
                p.continuedPending = r.bool(P.continuedPending)
                p.continuedBy = r.i32(P.continuedBy)
                p.dirtyState = r.u32(P.dirtyState)
                p.processType = r.u32(P.processType)
                p.processControl = r.u32(P.processControl)
                p.pidVersion = r.u32(P.pidVersion)
                p.exitReason = r.string(P.exitReason)
                p.qosClamp = Int(r.u64(P.qosClamp))
                p.darwinRole = r.u32(P.darwinRole)
                p.requestedDarwinBG = r.bool(P.requestedDarwinBG)
                if r.has(P.holdElapsed) { heldProcesses.append((p, r.string(P.holdLabel) ?? "", r.u64(P.holdElapsed))) }
                system.processes[pid] = p
                processes[id] = p

                let imageID = r.ref(P.image)
                guard imageID != 0, let image = fields[imageID] else { continue }
                typealias I = ST.Image
                // One root file system; the others are its copies, so every
                // process shares one socket namespace, as after spawns.
                let fs: DarwinFileSystem
                if let root = rootFileSystem { fs = root.makeChildCopy(newProcess: true) } else {
                    fs = makeFileSystem()
                    rootFileSystem = fs
                }
                let kernel = DarwinKernel(fileSystem: fs, pid: pid, system: system)
                kernel.pidVersion = image.u32(I.pidVersion)
                kernel.executableHostPath = image.string(I.executableHostPath)
                p.kernel = kernel
                kernels[imageID] = kernel
                plans.append(ImagePlan(recordID: imageID, kernel: kernel, pid: pid,
                                       executablePath: image.string(I.executablePath) ?? p.executablePath,
                                       hostExecutablePath: image.string(I.executableHostPath) ?? p.executablePath))
            }
            return plans
        } }
    }

    /// The process record of a restored image (to attach its launch handle).
    public func setLaunchedImage(_ image: any LaunchedImage, for kernel: DarwinKernel) {
        system.lock.withLock { system.record(of: kernel)?.image = image }
    }

    /// The shared memory object of a record (made empty on first use; the
    /// VMM fills its pages and maps it, §7 step 5).
    public func sharedObject(forRecord id: UInt64) throws -> SharedMemoryObject {
        // The VMM restores images' memory in parallel.
        sharedObjectsLock.lock()
        defer { sharedObjectsLock.unlock() }
        if let o = sharedObjects[id] { return o }
        guard let r = fields[id], records[id]?.knownKind == .sharedMemory else {
            throw SnapshotError("no shared memory record \(id)")
        }
        if r.bool(ST.SharedMemory.file) {
            // A shared view of a host file: map the file again (its bytes are in the file).
            typealias M = ST.SharedMemory
            guard let guestPath = r.string(M.guestPath), let fs = kernels.values.first?.fileSystem else {
                throw SnapshotError("shared memory \(id): a host-file view without its source")
            }
            let opener = DarwinFileSystem(prefixes: fs.prefixes, console: { _, _ in })
            opener.guestSymlinks = fs.guestSymlinks
            let fd: Int32
            do {
                fd = try openWritableAgain(opener, guestPath: guestPath, hostPath: r.string(M.hostPath))
            } catch {
                guard Self.lenient else { throw SnapshotError("shared memory \(id): \(guestPath): \(error)") }
                warnings.append("\(guestPath): gone; its shared view is plain shared memory (YCODE_RESTORE_LENIENT)")
                let o = try SharedMemoryObject(size: r.u64(ST.SharedMemory.size))
                sharedObjects[id] = o
                return o
            }
            defer { try? opener.close(fd) }
            guard let g = try opener.openFile(for: fd).guestFile,
                  let o = SharedMemoryObject(hostFile: g.hostFD, offset: r.u64(M.offset), size: r.u64(M.requested), fileSize: g.size) else {
                throw SnapshotError("shared memory \(id): cannot map \(guestPath) shared again")
            }
            o.snapshotFileSource = .init(guestPath: guestPath, hostPath: r.string(M.hostPath) ?? g.hostPath,
                                         offset: r.u64(M.offset), requestedSize: r.u64(M.requested))
            sharedObjects[id] = o
            return o
        }
        let o = try SharedMemoryObject(size: r.u64(ST.SharedMemory.size))
        sharedObjects[id] = o
        return o
    }

    /// The ids of every shared memory record.
    public var sharedObjectRecords: [UInt64] { ids(.sharedMemory) }

    // MARK: Step 6–7: every other object

    /// Restores every object. `memory`: each image's address space. Lock taken.
    public func restoreObjects(memory: (DarwinKernel) -> (any KernelGuestMemory)?) throws -> [ThreadPlan] {
        // No guest thread runs while objects are rebuilt, but the host
        // services do: their threads use the host task's ports and send to
        // guest ports under the port lock and the event locks alone
        // (`mach-ipc-locking.md` §4), not under L0. The rebuild therefore
        // holds every fine lock as well, as the capture does (§12.5: with
        // L0 alone, a host service's receive loop raced the rebuild of the
        // host task's name table and of the restored kqueues, and the
        // corrupted heap crashed the host later).
        let threadLocks = KernelThreadLocks.current
        let wasQuiesced = threadLocks.quiesced
        threadLocks.quiesced = true
        defer { threadLocks.quiesced = wasQuiesced }
        return try system.lock.withLock { try system.lock.withAllFineLocks {
            for (_, k) in kernels { if let m = memory(k) { memories[ObjectIdentifier(k)] = m } }
            try makeShells()
            try fillPorts()
            fillPortSets()
            try fillSpaces()
            try fillOpenFiles()
            let plans = try fillImages()
            restoreImportance()
            // Host service threads blocked on reused objects look again.
            for p in ports.values where reusedPorts.contains(ObjectIdentifier(p)) && !p.messages.isEmpty { p.receiveWaiters.wakeAll() }
            for s in portSets.values where reusedSets.contains(ObjectIdentifier(s)) { s.waiters.wakeAll() }
            // Counters last: the restore's own allocations came first.
            let s = f(KernelSnapshotCapture.systemID)
            system.mach.serialCounter = max(system.mach.serialCounter, s.u64(ST.System.serialCounter))
            system.mach.stampCounter = max(system.mach.stampCounter, s.u64(ST.System.stampCounter))
            system.mach.spaceCounter = max(system.mach.spaceCounter, s.u64(ST.System.spaceCounter))
            return plans
        } }
    }

    /// Importance (`scheduling-policy.md` §4.3) from the restored ports,
    /// messages and threads: each port's queued importance credits its
    /// target again, and each servicing thread's carried importance counts.
    /// Lock held.
    private func restoreImportance() {
        for p in processes.values { p.importanceBoosts = 0 }
        guard let ipc = spaces.values.first else { return }
        for p in ports.values {
            let n = p.messages.all.filter(\.importance).count
            guard n > 0 else { continue }
            p.importanceCount = n
            p.creditedProcess = ipc.importanceTarget(p)
            p.creditedProcess?.changeImportance(n)
        }
        for id in ids(.thread) {
            let r = f(id)
            guard r.has(ST.Thread.carriedImportancePID), let t = threads[id],
                  let proc = system.processes[r.i32(ST.Thread.carriedImportancePID)] else { continue }
            t.carriedImportance = proc
            proc.changeImportance(1)
        }
    }

    /// Phase 1: an empty object for every record.
    private func makeShells() throws {
        // Spaces: an image's space is the one its kernel made; a space without
        // an image (a dead task still named by a port) gets a detached one.
        for id in ids(.machSpace) {
            let r = f(id)
            let space: MachIPC
            if let k = kernels[r.ref(ST.Space.image)], let s = k.machIPC as? MachIPC {
                space = s
            } else if r.bool(ST.Space.isHostTask) || (r.ref(ST.Space.image) == 0 && r.u64(ST.Space.spaceID) == 1),
                      let host = system.mach.hostTask {
                // (Snapshots before the isHostTask flag: the host task is the first space made.)
                // The host task of the new run: its services already made
                // their ports, under the same names (they are made in the
                // same order). Those live objects stand for the recorded
                // ones, so the service threads blocked on them keep working.
                space = host.ipc
                for e in r.list(ST.Space.entries) {
                    let i = Int(e.u64(ST.Space.index))
                    guard i < space.entries.count, space.entries[i].inUse,
                          space.entries[i].generation == e.u32(ST.Space.generation) else { continue }
                    if let live = space.entries[i].port, e.ref(ST.Space.port) != 0, ports[e.ref(ST.Space.port)] == nil {
                        ports[e.ref(ST.Space.port)] = live
                        reusedPorts.insert(ObjectIdentifier(live))
                    }
                    if let live = space.entries[i].set, e.ref(ST.Space.set) != 0 {
                        portSets[e.ref(ST.Space.set)] = live
                        reusedSets.insert(ObjectIdentifier(live))
                    }
                }
            } else {
                space = MachIPC(lock: system.lock, pid: r.i32(ST.Space.pid), system: system.mach)
            }
            spaces[id] = space
            spaceIDMap[r.u64(ST.Space.spaceID)] = space.spaceID
            // The ports the space made at init stand for the recorded ones.
            ports[r.ref(ST.Space.taskPort)] = space.taskPort
            ports[r.ref(ST.Space.taskNamePort)] = space.taskNamePort
            ports[r.ref(ST.Space.mainThreadPort)] = space.mainThreadPort
        }
        ports[0] = nil
        for id in ids(.port) where ports[id] == nil {
            ports[id] = IPCPort(serial: f(id).u64(ST.Port.serial))
        }
        for id in ids(.portSet) where portSets[id] == nil {
            portSets[id] = IPCPortSet(serial: f(id).u64(ST.PortSet.serial))
        }
        for id in ids(.semaphore) {
            let s = KernelSemaphore(value: f(id).i32(ST.Semaphore.count))
            if f(id).bool(ST.Semaphore.destroyed) { s.destroy() }
            semaphores[id] = s
        }
        let opener = kernels.values.first.map {
            DarwinFileSystem(prefixes: $0.fileSystem.prefixes, console: { _, _ in })
        }
        for id in ids(.hostFile) {
            let r = f(id)
            typealias H = ST.HostFile
            let guestPath = r.string(H.guestPath) ?? "", hostPath = r.string(H.hostPath) ?? ""
            let file: GuestFile
            if r.bool(H.unlinked) {
                file = try Self.unlinkedCopy(guestPath: guestPath, bytes: r.bytes(H.content))
            } else if r.bool(H.writable), let opener {
                do {
                    let fd = try openWritableAgain(opener, guestPath: guestPath, hostPath: hostPath)
                    guard let g = try opener.openFile(for: fd).guestFile else { throw SnapshotError("\(guestPath): not a file") }
                    try opener.close(fd)
                    file = g
                } catch {
                    guard Self.lenient else { throw SnapshotError("\(guestPath): cannot open again: \(error)") }
                    warnings.append("\(guestPath): gone; an empty unlinked file stands for it (YCODE_RESTORE_LENIENT)")
                    file = try Self.unlinkedCopy(guestPath: guestPath, bytes: [])
                }
            } else {
                do {
                    file = try GuestFile.openReadOnly(hostPath: hostPath, guestPath: guestPath)
                } catch {
                    guard Self.lenient else {
                        throw SnapshotError("\(guestPath) (\(hostPath)): cannot open again: \(error)")
                    }
                    warnings.append("\(guestPath): gone; an empty unlinked file stands for it (YCODE_RESTORE_LENIENT)")
                    file = try Self.unlinkedCopy(guestPath: guestPath, bytes: [])
                }
            }
            if file.size != r.u64(H.size) || file.stat.mtime.sec != r.i64(H.mtime) {
                warnings.append("\(guestPath): changed since the snapshot (size \(r.u64(H.size)) -> \(file.size))")
            }
            hostFiles[id] = file
        }
        for id in ids(.pipe) {
            let r = f(id)
            typealias P = ST.Pipe
            let p = KernelPipe(lock: system.lock)
            p.buffer.append(contentsOf: r.bytes(P.buffer))
            p.readerOpen = r.bool(P.readerOpen)
            p.writerOpen = r.bool(P.writerOpen)
            p.accessTime = DarwinTimespec(sec: r.i64(P.atimeS), nsec: r.i64(P.atimeN))
            p.modifyTime = DarwinTimespec(sec: r.i64(P.mtimeS), nsec: r.i64(P.mtimeN))
            pipes[id] = p
        }
        for id in ids(.kqueue) {
            let r = f(id)
            typealias Q = ST.KQueue
            let kind: KQueue.Kind
            switch r.u64(Q.kind) {
            case 1: kind = .descriptor(r.i32(Q.fd))
            case 2: kind = .workq
            default: kind = .workloop
            }
            let q = KQueue(kind: kind, workloopID: r.u64(Q.workloopID))
            kqueues[id] = q
            for n in r.list(Q.knotes) {
                typealias N = ST.Knote
                let rec = KEventRecord(ident: n.u64(N.ident), filter: Int16(truncatingIfNeeded: n.i64(N.filter)),
                                       flags: UInt16(truncatingIfNeeded: n.u64(N.flags)), fflags: n.u32(N.fflags),
                                       data: n.i64(N.data), udata: n.u64(N.udata), qos: n.u32(N.qos), ext: n.u64s(N.ext))
                let kn = Knote(rec)
                kn.flags = UInt16(truncatingIfNeeded: n.u64(N.flags))
                knotes[n.u64(N.id)] = kn
            }
        }
        for id in ids(.unixSocket) {
            let r = f(id)
            let kind = UnixSocket.Kind(rawValue: r.i32(ST.Socket.kind)) ?? .stream
            sockets[id] = UnixSocket(kind: kind, lock: system.lock, creator: user(r.nested(ST.Socket.creator)))
        }
        for id in ids(.inetSocket) {
            let (sock, warning) = InetSocket.restored(f(id), lock: system.lock, user: { user($0) })
            inetSockets[id] = sock
            if let warning { warnings.append(warning) }
        }
        for id in ids(.posixShm) {
            let r = f(id)
            let seg = PosixShmSegment(name: r.string(1) ?? "", mode: UInt16(truncatingIfNeeded: r.u64(2)), uid: r.u32(3), gid: r.u32(4))
            if r.ref(5) != 0 { seg.object = try sharedObject(forRecord: r.ref(5)) }
            seg.length = r.u64(6)
            seg.sized = r.bool(7)
            shmSegments[id] = seg
        }
        for id in ids(.posixSem) {
            let r = f(id)
            posixSemaphores[id] = PosixSemaphore(name: r.string(1) ?? "", mode: UInt16(truncatingIfNeeded: r.u64(2)), count: r.i32(3))
        }
        for id in ids(.thread) {
            let r = f(id)
            typealias T = ST.Thread
            guard let k = kernels[r.ref(T.image)] else { continue }
            let kind: ThreadContext.Kind = [ThreadContext.Kind.main, .pthread, .workqueue][Int(min(r.u64(T.kind), 2))]
            let t: ThreadContext
            if r.bool(T.isMain) {
                t = k.mainThread
                k.threadsByPort[t.portName] = nil
                t.portName = r.u32(T.portName)
            } else {
                t = ThreadContext(threadID: r.u64(T.threadID), portName: r.u32(T.portName), vcpuIndex: 0, kind: kind,
                                  pthreadAddress: r.u64(T.pthreadAddress))
            }
            t.kernel = k
            threads[id] = t
        }
        // A main thread that had ended before the snapshot is not live.
        for (imageID, k) in kernels {
            let mainRecorded = ids(.thread).contains { f($0).ref(ST.Thread.image) == imageID && f($0).bool(ST.Thread.isMain) }
            if !mainRecorded { k.threadsByPort[k.mainThread.portName] = nil }
        }
        for id in ids(.openFile) {
            let r = f(id)
            typealias O = ST.OpenFile
            let node: DarwinOpenFile.Node
            switch r.u64(O.nodeKind) {
            case 1: node = .console(stream: r.i32(O.stream))
            case 2:
                guard let g = hostFiles[r.ref(O.file)] else { throw SnapshotError("open file \(id): no host file") }
                node = .file(g)
            case 3:
                guard let p = pipes[r.ref(O.object)] else { throw SnapshotError("open file \(id): no pipe") }
                let end = PipeEnd(pipe: p, isReadEnd: r.bool(O.readEnd))
                if end.isReadEnd { p.readEnd = end } else { p.writeEnd = end }
                node = .object(end)
            case 4:
                guard let q = kqueues[r.ref(O.object)], let k = kernelOwning(kqueue: r.ref(O.object)) else {
                    throw SnapshotError("open file \(id): no kqueue")
                }
                let o = KQueueObject(queue: q, kernel: k)
                q.object = o
                node = .object(o)
            case 5:
                guard let kind = DarwinDevice.Kind(rawValue: r.string(O.device) ?? "") else {
                    throw SnapshotError("open file \(id): unknown device")
                }
                node = .object(DarwinDevice(kind))
            case 6:
                guard let sock = sockets[r.ref(O.object)] else { throw SnapshotError("open file \(id): no socket") }
                node = .object(sock)
            case 9:
                guard let sock = inetSockets[r.ref(O.object)] else { throw SnapshotError("open file \(id): no IP socket") }
                node = .object(sock)
            case 10:
                node = .object(RouteSocket(proto: r.i32(O.stream), lock: system.lock))
            case 11:
                let c = KernelControlSocket(lock: system.lock)
                c.connectedID = r.u32(O.stream)
                node = .object(c)
            case 7:
                guard let seg = shmSegments[r.ref(O.object)] else { throw SnapshotError("open file \(id): no shm segment") }
                node = .object(PosixShmDescriptor(seg))
            case 8:
                guard let sem = posixSemaphores[r.ref(O.object)] else { throw SnapshotError("open file \(id): no semaphore") }
                node = .object(PosixSemDescriptor(sem))
            default:
                throw SnapshotError("open file \(id): unsupported node")
            }
            let o = DarwinOpenFile(node: node, statusFlags: r.i32(O.statusFlags))
            o.offset = r.u64(O.offset)
            o.noSigPipe = r.bool(O.noSigPipe)
            o.confinedToProcess = r.bool(O.confined)
            openFiles[id] = o
        }
    }

    /// `YCODE_RESTORE_LENIENT=1`: a host file that is gone is replaced (an
    /// empty file, anonymous shared memory) instead of failing the restore.
    public static let lenient = getenv("YCODE_RESTORE_LENIENT").map { String(cString: $0) == "1" } ?? false

    /// A host file with `bytes`, already unlinked (as the original was).
    /// Opens `guestPath` again for reading and writing, as the guest's
    /// description or shared view had it. The guest may have taken the
    /// file's write permission away after it opened or mapped the file
    /// (Spotlight makes its finished index files mode 0400 while they stay
    /// mapped shared and writable, §12.5), and then O_RDWR fails with
    /// EACCES although the guest's access is still read-write. For a file
    /// of this host user whose owner-write bit is clear, the bit is set for
    /// the open and the mode is put back at once; the open description
    /// keeps its access, as the guest's did. Nothing else runs during the
    /// restore, so no one sees the brief change. `restoredModes` counts it.
    func openWritableAgain(_ opener: DarwinFileSystem, guestPath: String, hostPath: String?) throws -> Int32 {
        do {
            return try opener.open(guestPath, flags: DarwinOpen.O_RDWR, mode: 0)
        } catch {
            var st = stat()
            guard let hostPath, !hostPath.isEmpty, stat(hostPath, &st) == 0, st.st_uid == getuid(),
                  st.st_mode & S_IFMT == S_IFREG, st.st_mode & S_IWUSR == 0 else { throw error }
            let mode = st.st_mode & 0o7777
            guard chmod(hostPath, mode | S_IWUSR) == 0 else { throw error }
            defer { chmod(hostPath, mode) }
            let fd = try opener.open(guestPath, flags: DarwinOpen.O_RDWR, mode: 0)
            readOnlyReopens += 1
            return fd
        }
    }

    static func unlinkedCopy(guestPath: String, bytes: [UInt8]) throws -> GuestFile {
        var template = Array((NSTemporaryDirectory() + "/ycode-snapshot-unlinked-XXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw SnapshotError("\(guestPath): cannot make an unlinked copy") }
        let path = String(cString: template)
        unlink(path)
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + done, bytes.count - done) }
            guard n > 0 else { close(fd); throw SnapshotError("\(guestPath): cannot write the unlinked copy") }
            done += n
        }
        let st = DarwinStat(mode: DarwinStat.S_IFREG | 0o600, nlink: 0, size: Int64(bytes.count))
        return GuestFile(guestPath: guestPath, hostPath: path, hostFD: fd, stat: st)
    }

    private func kernelOwning(kqueue id: UInt64) -> DarwinKernel? {
        kernels[f(id).ref(ST.KQueue.image)]
    }

    private func right(_ r: SnapshotFieldReader?) -> CarriedRight {
        guard let r else { return .null }
        let port = ports[r.ref(ST.Right.port)]
        switch r.u64(ST.Right.kind) {
        case 1: return .dead
        case 2: return port.map { .send($0) } ?? .dead
        case 3: return port.map { .sendOnce($0) } ?? .dead
        case 4: return port.map { .receive($0) } ?? .dead
        default: return .null
        }
    }

    private func dnKey(_ g: SnapshotFieldReader) -> DNKey {
        let old = g.u64(ST.Port.space)
        return DNKey(space: spaceIDMap[old] ?? old, name: g.u32(ST.Port.name))
    }

    private func fillPorts() throws {
        for id in ids(.port) {
            let r = f(id)
            typealias P = ST.Port
            guard let p = ports[id] else { continue }
            if r.has(P.kobjectKind) {
                let v = r.u64(P.kobjectValue)
                p.kernelObject = switch r.u64(P.kobjectKind) {
                case 1: .task
                case 2: .taskName
                case 3: .taskRead
                case 4: .taskInspect
                case 5: .thread(serial: v)
                case 6: .host
                case 7: .bootstrap
                case 8: .clock(id: Int32(truncatingIfNeeded: Int64(bitPattern: v)))
                case 9: .semaphore(serial: v)
                case 10: .fileport(serial: v)
                case 11: .memoryEntry(serial: v)
                case 12: .ioMain
                case 14: .workInterval(serial: v)
                default: .ioObject(serial: v)
                }
            } else {
                p.kernelObject = nil
            }
            p.semaphore = semaphores[r.ref(P.semaphore)]
            if r.has(P.workIntervalID) {
                let id = r.u64(P.workIntervalID)
                KernelWorkInterval.noteRestoredID(id)
                p.workInterval = KernelWorkInterval(id: id, createFlags: r.u32(P.workIntervalFlags),
                                                    creatorPID: Int32(truncatingIfNeeded: r.i64(P.workIntervalCreator)))
            } else {
                p.workInterval = nil
            }
            p.isSpecialReply = r.bool(P.specialReply)
            p.task = spaces[r.ref(P.task)]
            p.fileportFile = openFiles[r.ref(P.fileport)]
            p.active = r.bool(P.active)
            p.receiver = spaces[r.ref(P.receiver)]
            p.transitHolder = ports[r.ref(P.transitHolder)]
            p.srights = Int(r.i64(P.srights))
            p.sorights = Int(r.i64(P.sorights))
            p.mscount = r.u32(P.mscount)
            p.seqno = r.u32(P.seqno)
            p.qlimit = Int(r.i64(P.qlimit))
            p.context = r.u64(P.context)
            p.guarded = r.bool(P.guarded)
            p.strict = r.bool(P.strict)
            p.immovable = r.bool(P.immovable)
            p.pdRequest = ports[r.ref(P.pdRequest)]
            p.nsRequest = ports[r.ref(P.nsRequest)]
            p.dnRequests = [:]
            for g in r.list(P.dnRequests) { p.dnRequests[dnKey(g)] = ports[g.ref(P.port)] }
            p.spRequests = [:]
            for g in r.list(P.spRequests) { p.spRequests[dnKey(g)] = g.bool(P.armed) }
            p.deadNameNotified = Set(r.list(P.deadNameNotified).map(dnKey))
            p.sets = r.u64s(P.sets).compactMap { portSets[$0] }
            p.readyStamp = r.u64(P.readyStamp)
            if !reusedPorts.contains(ObjectIdentifier(p)) {
                p.changeStamp = r.u64(P.changeStamp)
                p.waitingReceivers = 0
            }
            _ = p.messages.removeAll()
            for m in r.list(P.messages) { p.messages.append(message(m)) }
            p.importanceDonation = r.bool(P.importanceDonation)
            p.tempOwner = r.bool(P.tempOwner)
            p.watchProcess = r.has(P.watchPID) ? system.processes[r.i32(P.watchPID)] : nil
            p.importanceCount = 0
            p.creditedProcess = nil
            if let e = r.nested(P.memoryEntry) {
                typealias M = ST.SharedMemory
                p.memoryEntry = MachMemoryEntry(object: try sharedObject(forRecord: e.ref(M.serial)), offset: e.u64(M.file),
                                                size: e.u64(M.size), protection: VMProtection(rawValue: e.u32(M.pages)))
            }
            if let t = r.nested(P.mkTimer) {
                let timer = MachTimer(port: p)
                timer.armedTicks = t.u64(P.timerTicks)
                if t.bool(P.timerArmed) { timer.deadline = rebased(t.i64(P.timerDeadline)) }
                p.mkTimer = timer
            } else {
                p.mkTimer = nil
            }
        }
    }

    private func message(_ g: SnapshotFieldReader) -> KMessage {
        typealias M = ST.Message
        var m = KMessage(complex: g.bool(M.complex), destination: right(g.nested(M.destination)),
                         destinationType: g.u32(M.destinationType), reply: right(g.nested(M.reply)),
                         replyType: g.u32(M.replyType), id: g.i32(M.id))
        m.voucherRaw = g.u32(M.voucher)
        m.items = g.list(M.items).map { h in
            switch h.u64(M.itemKind) {
            case 1: return .port(right(h.nested(M.right)), type: h.u32(M.type))
            case 2: return .ool(data: h.bytes(M.data), copy: UInt8(truncatingIfNeeded: h.u64(M.copy)), volatile: h.bool(M.volatile))
            case 3: return .oolPorts(h.list(M.rights).map { right($0) }, type: h.u32(M.type),
                                     copy: UInt8(truncatingIfNeeded: h.u64(M.copy)))
            default: return .guarded(right(h.nested(M.right)), flags: UInt16(truncatingIfNeeded: h.u64(M.flags)), type: h.u32(M.type))
            }
        }
        m.inline = g.bytes(M.inline)
        m.aux = g.bool(M.hasAux) ? g.bytes(M.aux) : nil
        m.fromKernel = g.bool(M.fromKernel)
        m.isTimerExpiry = g.bool(M.timerExpiry)
        m.importance = g.bool(M.importance)
        m.pushClass = g.has(M.pushClass) ? Int8(truncatingIfNeeded: g.i64(M.pushClass)) : -1
        if let s = g.nested(M.sender) {
            m.sender = MachSenderIdentity(uid: s.u32(M.uid), gid: s.u32(M.gid), pid: s.i32(M.pid),
                                          pidVersion: s.u32(M.pidVersion), auditSessionID: s.u32(M.asid))
        }
        return m
    }

    private func fillPortSets() {
        for id in ids(.portSet) {
            let r = f(id)
            guard let s = portSets[id] else { continue }
            s.name = r.u32(ST.PortSet.name)
            s.members = r.u64s(ST.PortSet.members).compactMap { ports[$0] }
            s.active = r.bool(ST.PortSet.active)
            if !reusedSets.contains(ObjectIdentifier(s)) {
                s.changeStamp = r.u64(ST.PortSet.changeStamp)
                s.waitingReceivers = 0
            }
        }
    }

    private func slots(_ g: SnapshotFieldReader?) -> TaskPortSlots {
        var s = TaskPortSlots()
        guard let g else { return s }
        typealias T = ST.Slots
        s.host = right(g.nested(T.host))
        s.bootstrap = right(g.nested(T.bootstrap))
        s.access = right(g.nested(T.access))
        s.debugControl = right(g.nested(T.debugControl))
        s.resourceNotify = right(g.nested(T.resourceNotify))
        s.registered = g.list(T.registered).map { right($0) }
        s.exceptions = g.list(T.exceptions).map(exceptionSlot)
        return s
    }

    private func exceptionSlot(_ g: SnapshotFieldReader) -> ExceptionSlot {
        ExceptionSlot(port: right(g.nested(ST.Slots.right)), behavior: g.u32(ST.Slots.behavior), flavor: g.u32(ST.Slots.flavor))
    }

    private func fillSpaces() throws {
        for id in ids(.machSpace) {
            let r = f(id)
            typealias S = ST.Space
            guard let s = spaces[id] else { continue }
            s.pid = r.i32(S.pid)
            s.pidVersion = r.u32(S.pidVersion)
            s.uid = r.u32(S.uid)
            s.gid = r.u32(S.gid)
            s.isTerminated = r.bool(S.terminated)
            let list = r.list(S.entries)
            let maxIndex = list.map { Int($0.u64(S.index)) }.max() ?? 0
            var entries = [IPCEntry](repeating: IPCEntry(), count: max(maxIndex + 1, Int(r.u64(S.nextFresh))))
            for e in list {
                let i = Int(e.u64(S.index))
                entries[i].generation = e.u32(S.generation)
                entries[i].inUse = e.bool(S.inUse)
                entries[i].bits = e.u32(S.bits)
                entries[i].urefs = e.u32(S.urefs)
                entries[i].port = ports[e.ref(S.port)]
                entries[i].set = portSets[e.ref(S.set)]
            }
            s.entries = entries
            s.freeList = r.u64s(S.freeList).map { Int($0) }
            s.nextFresh = Int(r.u64(S.nextFresh))
            s.reverse = [:]
            for i in entries.indices where entries[i].inUse {
                if let p = entries[i].port, entries[i].bits & (MachPortType.send | MachPortType.receive) != 0 {
                    s.reverse[ObjectIdentifier(p)] = s.nameOf(i)
                }
            }
            s.taskReadPort = ports[r.ref(S.taskReadPort)]
            s.taskInspectPort = ports[r.ref(S.taskInspectPort)]
            s.clockPorts = [:]
            let clocks = r.u64s(S.clockPorts)
            for i in stride(from: 0, to: clocks.count - 1, by: 2) {
                if let p = ports[clocks[i + 1]] { s.clockPorts[Int32(truncatingIfNeeded: Int64(bitPattern: clocks[i]))] = p }
            }
            s.slots = slots(r.nested(S.slots))
            s.ownedKernelPorts = r.u64s(S.ownedKernelPorts).compactMap { ports[$0] }
            s.specialReplyPorts = [:]
            let replies = r.u64s(S.specialReplyPorts)
            for i in stride(from: 0, to: replies.count - 1, by: 2) {
                if let p = ports[replies[i + 1]] { s.specialReplyPorts[replies[i]] = p }
            }
            s.threadExceptions = [:]
            for g in r.list(S.threadExceptions) {
                if let p = ports[g.ref(S.key)] { s.threadExceptions[ObjectIdentifier(p)] = g.list(S.slots).map(exceptionSlot) }
            }
        }
    }

    /// A recorded `DescriptorUser` (its kernel by pid).
    private func user(_ g: SnapshotFieldReader?) -> DescriptorUser {
        let pid = g?.i32(1) ?? 0
        return DescriptorUser(pid: pid, pidVersion: g?.u32(2) ?? 0, uid: g?.u32(3) ?? 0, gid: g?.u32(4) ?? 0,
                              kernel: system.processes[pid]?.kernel)
    }

    private func fileRefs(_ g: SnapshotFieldReader) -> [DarwinOpenFile]? {
        g.bool(3) ? g.u64s(2).compactMap { openFiles[$0] } : nil
    }

    private func fillOpenFiles() throws {
        // OFD and flock locks are released when their description goes.
        for id in ids(.openFile) where f(id).bool(ST.OpenFile.lockHandler) {
            guard let o = openFiles[id] else { continue }
            let key = ObjectIdentifier(o)
            o.lastCloseHandlers["locks"] = { [weak system] in
                guard let system else { return }
                let table = system.fileLocks
                table.unwatch(key)
                system.lock.wakeFileLockWaiters(table.release(owner: .description(key)))
            }
            _ = system.fileLocks.watch(key)
        }
        // Sockets.
        for id in ids(.unixSocket) {
            let r = f(id)
            typealias U = ST.Socket
            guard let sock = sockets[id] else { continue }
            sock.lastUser = user(r.nested(U.lastUser))
            sock.address = r.has(U.address) ? r.bytes(U.address) : nil
            sock.peer = sockets[r.ref(U.peer)]
            sock.logSink = r.string(U.logSink)
            let flags = r.u64(U.flags)
            func bit(_ b: Int) -> Bool { flags & (1 << UInt64(b)) != 0 }
            sock.isConnected = bit(0)
            sock.cantReceiveMore = bit(1)
            sock.cantSendMore = bit(2)
            sock.closed = bit(3)
            sock.isListening = bit(4)
            sock.noSigPipe = bit(5)
            sock.error = r.i32(U.error)
            sock.backlog = Int(r.i64(U.backlog))
            sock.pending = r.u64s(U.pending).compactMap { sockets[$0] }
            sock.listenUser = r.nested(U.listenUser).map { user($0) }
            sock.segments = r.list(U.segments).map { UnixSocket.Segment(bytes: $0.bytes(1), rights: fileRefs($0)) }
            sock.datagrams = r.list(U.datagrams).map { UnixSocket.Datagram(from: $0.bytes(4), bytes: $0.bytes(1), rights: fileRefs($0)) }
            sock.queuedBytes = sock.segments.reduce(0) { $0 + $1.remaining } + sock.datagrams.reduce(0) { $0 + $1.bytes.count }
            sock.connectedSenders = r.u64s(U.connectedSenders).compactMap { sockets[$0].map { WeakSocket(socket: $0) } }
            sock.sendBufferSize = Int(r.i64(U.sendBuffer))
            sock.receiveBufferSize = Int(r.i64(U.receiveBuffer))
            sock.sendLowWater = Int(r.i64(U.sendLowWater))
            sock.receiveLowWater = Int(r.i64(U.receiveLowWater))
            sock.receiveTimeout = r.optionalU64(U.receiveTimeout)
            sock.sendTimeout = r.optionalU64(U.sendTimeout)
            sock.linger = (r.i32(U.lingerOn), r.i32(U.lingerSeconds))
            sock.otherOptions = [:]
            for g in r.list(U.options) { sock.otherOptions[g.i32(1)] = g.bytes(2) }
            sock.peerCredentials = r.nested(U.peerCredentials).map { user($0) }
            if let path = r.string(U.boundPath), !sock.closed, let fs = rootFileSystem {
                do {
                    sock.boundPath = try fs.bindSocket(sock, path: path, umask: 0o022)
                } catch {
                    warnings.append("socket \(path): cannot bind again: \(error)")
                    sock.boundPath = path
                }
            }
        }
        // The host end of a DNS service connection cannot be restored: the
        // connection is reset (the guest's end reads EOF; the client
        // connects again).
        for id in ids(.unixSocket) where f(id).u64(ST.Socket.flags) & (1 << 6) != 0 {
            sockets[id]?.close()
        }
        // System tables: POSIX names, IOKit, file locks.
        let s = f(KernelSnapshotCapture.systemID)
        typealias S = ST.System
        system.posixShmSegments = [:]
        for g in s.list(S.shmNames) { if let seg = shmSegments[g.ref(2)] { system.posixShmSegments[g.string(1) ?? seg.name] = seg } }
        system.posixSemaphoreStorage = [:]
        for g in s.list(S.semNames) { if let sem = posixSemaphores[g.ref(2)] { system.posixSemaphoreStorage[g.string(1) ?? sem.name] = sem } }
        if let io = s.nested(S.ioKit) {
            system.mach.ioMain = ports[io.ref(1)]
            system.mach.ioRegistryPaths = [:]
            for g in io.list(2) { if let p = ports[g.ref(2)] { system.mach.ioRegistryPaths[g.string(1) ?? ""] = p } }
            system.mach.ioObjects = [:]
            for g in io.list(3) {
                let kind: IOKitObject.Kind
                switch g.u64(2) {
                case 1:
                    kind = .entry(className: g.string(3) ?? "", name: g.string(4) ?? "", path: g.string(5) ?? "",
                                  superclasses: g.list(6).compactMap { $0.string(1) }, entryID: g.u64(7))
                case 2: kind = .iterator(entries: g.u64s(8).compactMap { ports[$0] }, next: Int(g.i64(9)))
                case 3: kind = .notification
                default:
                    guard let service = ports[g.ref(10)] else { continue }
                    kind = .connection(service: service, type: g.u32(11))
                }
                system.mach.ioObjects[g.u64(1)] = IOKitObject(kind)
            }
        }
        if let locks = s.nested(S.fileLocks) {
            let table = system.fileLocks
            for g in locks.list(1) {
                let id = FileIdentity(DarwinStat(dev: g.u32(1), ino: g.u64(2)))
                table.state(id).locks = g.list(3).compactMap { k in
                    let owner: FileLockTable.Owner
                    if k.has(2) {
                        guard let o = openFiles[k.ref(2)] else { return nil }
                        owner = .description(ObjectIdentifier(o))
                    } else {
                        owner = .process(k.i32(1))
                        let pid = k.i32(1)
                        system.posixLockUsers.withLock { _ = $0.insert(pid) }
                    }
                    let kind: FileLockTable.Kind = [FileLockTable.Kind.posix, .ofd, .flock][Int(min(k.u64(3), 2))]
                    return FileLockTable.Lock(owner: owner, kind: kind, exclusive: k.bool(4), start: k.i64(5), end: k.i64(6))
                }
            }
            for g in locks.list(2) {
                table.protectionClasses[FileIdentity(DarwinStat(dev: g.u32(1), ino: g.u64(2)))] = g.i32(3)
            }
        }
    }

    private func fillImages() throws -> [ThreadPlan] {
        var plans: [ThreadPlan] = []
        for (imageID, k) in kernels.sorted(by: { $0.value.pid < $1.value.pid }) {
            let r = f(imageID)
            typealias I = ST.Image
            k.allImageInfosAddress = r.u64(I.allImageInfos)
            k.allImageInfosSize = r.u64(I.allImageInfosSize)
            k.mainStackTop = r.u64(I.mainStackTop)
            if let g = r.nested(I.registration) {
                typealias R = ST.Registration
                k.snapshotRestoreThreadRegistration(DarwinKernel.ThreadRegistration(
                    threadStart: g.u64(R.threadStart), startWorkqueueThread: g.u64(R.startWorkqueueThread),
                    pthreadSize: g.u32(R.pthreadSize), dispatchQueueOffset: g.u64(R.dispatchQueueOffset),
                    tsdOffset: g.u32(R.tsdOffset), returnToKernelOffset: g.u32(R.returnToKernelOffset),
                    machThreadSelfOffset: g.u32(R.machThreadSelfOffset), joinableOffsetBits: g.u32(R.joinableOffsetBits),
                    quantumExpiryOffset: g.u32(R.quantumExpiryOffset)))
            }
            k.nextActivityID = r.u64(I.nextActivityID)
            k.nextThreadID = r.u64(I.nextThreadID)
            k.purgeableStates = [:]
            let purgeable = r.u64s(I.purgeable)
            for i in stride(from: 0, to: purgeable.count - 1, by: 2) {
                k.purgeableStates[purgeable[i]] = Int32(truncatingIfNeeded: Int64(bitPattern: purgeable[i + 1]))
            }
            k.exitValue = r.has(I.exitValue) ? r.i32(I.exitValue) : nil
            k.deathSignal = r.has(I.deathSignal) ? r.i32(I.deathSignal) : nil
            k.sysctl = SysctlTable(entries: r.list(I.sysctl).map(sysctlEntry))
            if let x = r.nested(I.extended) { k.extended = try extended(x) }
            k.lastMemory = memories[ObjectIdentifier(k)]

            // Threads of this image.
            for id in ids(.thread) where f(id).ref(ST.Thread.image) == imageID {
                guard let t = threads[id] else { continue }
                let tr = f(id)
                typealias T = ST.Thread
                t.pthreadAddress = tr.u64(T.pthreadAddress)
                t.signalMask = tr.u32(T.signalMask)
                if let s = tr.nested(T.suspendedStart) {
                    t.suspendedStart = ThreadStartState(x: s.u64s(ST.Start.x), pc: s.u64(ST.Start.pc), sp: s.u64(ST.Start.sp),
                                                        tpidrro: s.u64(ST.Start.tpidrro), tpidr: s.u64(ST.Start.tpidr))
                }
                if let w = tr.nested(T.worker) {
                    typealias W = ST.Worker
                    let state = WorkerState(base: w.u64(W.base))
                    state.phase = [WorkerState.Phase.running, .idle, .exiting][Int(min(w.u64(W.phase), 2))]
                    state.firstRun = w.bool(W.firstRun)
                    state.qos = Int(w.i64(W.qos))
                    state.constrained = w.bool(W.constrained)
                    state.boundQueue = kqueues[w.ref(W.boundQueue)]
                    state.boundBucket = w.has(W.boundBucket) ? Int(w.i64(W.boundBucket)) : nil
                    state.keventRun = w.bool(W.keventRun)
                    state.delivered = w.u64s(W.delivered).compactMap { knotes[$0] }
                    t.worker = state
                    if w.bool(W.idle) { k.workqueue.workers[t.threadID] = t }
                }
                k.threadsByPort[t.portName] = t
                let kind = SnapshotThreadKind(rawValue: tr.u64(T.restoreKind)) ?? .suspended
                if kind == .unstarted, let s = tr.nested(T.mainStart) {
                    unstartedMains.append((k, SnapshotMainStart(pc: s.u64(ST.Start.pc), sp: s.u64(ST.Start.sp),
                                                                registers: s.u64s(ST.Start.x), tpidrro: s.u64(ST.Start.tpidrro),
                                                                tpidr: s.u64(ST.Start.tpidr))))
                } else if kind != .suspended && kind != .unstarted {
                    plans.append(ThreadPlan(kernel: k, context: t, kind: kind,
                                            frame: try TrapFrame(decoding: tr.bytes(T.frame)), fp: tr.bytes(T.fp),
                                            note: tr.string(T.note) ?? ""))
                }
            }

            // ulocks (no waiters).
            k.ulocks = [:]
            for g in r.list(I.ulocks) {
                let q = ULockQueue(opcode: g.u32(ST.ULock.opcode))
                q.owner = threads[g.ref(ST.ULock.owner)]
                k.ulocks[g.u64(ST.ULock.address)] = q
            }

            // The workqueue.
            if let w = r.nested(I.workqueue) {
                typealias W = ST.Workqueue
                k.workqueue.isOpen = w.bool(W.isOpen)
                k.workqueue.dispatchConfig = w.bool(W.hasDispatch)
                    ? (w.u32(W.dispatchVersion), w.u64(W.serialOffset), w.u64(W.labelOffset)) : nil
                k.workqueue.newSPIOffset = w.u32(W.newSPIOffset)
                k.workqueue.managerPriority = w.u32(W.managerPriority)
                k.workqueue.idle = w.u64s(W.idle).compactMap { threads[$0] }
                k.workqueue.plainPending = [:]
                for g in w.list(W.plainPending) {
                    k.workqueue.plainPending[.init(qos: Int(g.i64(W.qos)), overcommit: g.bool(W.overcommit))] = Int(g.i64(W.count))
                }
                k.workqueue.pendingWorkloops = w.u64s(W.pendingWorkloops).compactMap { kqueues[$0] }
                k.workqueue.idleTimeoutNanoseconds = w.u64(W.idleTimeout, default: k.workqueue.idleTimeoutNanoseconds)
            }

            // kqueues of this image.
            k.kevents.workq = kqueues[r.ref(I.workqKQueue)]
            k.kevents.machportIndex = nil
            k.kevents.workloops = [:]
            for id in r.u64s(I.workloops) {
                if let q = kqueues[id] { k.kevents.workloops[q.workloopID] = q }
            }
            k.kevents.descriptorQueues = [:]
            k.kevents.objectQueues = [:]
            let dq = r.u64s(I.descriptorQueues)
            for i in stride(from: 0, to: dq.count - 1, by: 2) {
                guard let q = kqueues[dq[i + 1]] else { continue }
                k.kevents.descriptorQueues[Int32(truncatingIfNeeded: Int64(bitPattern: dq[i]))] = q
                if let o = q.object { k.kevents.objectQueues[ObjectIdentifier(o)] = q }
            }
            k.kevents.mkTimers = [:]
            for id in r.u64s(I.mkTimers) {
                if let t = ports[id]?.mkTimer { k.kevents.mkTimers[ObjectIdentifier(t)] = t }
            }

            // Descriptors.
            k.fileSystem.closeAll()
            // The table's size first: a raised limit may hold high descriptors.
            k.fileSystem.maxDescriptors = r.i32(I.maxDescriptors, default: k.fileSystem.maxDescriptors)
            for g in r.list(I.descriptors) {
                typealias D = ST.Descriptor
                guard let file = openFiles[g.ref(D.file)] else { throw SnapshotError("pid \(k.pid): descriptor without a file") }
                let fd = g.i32(D.fd)
                do {
                    _ = try k.fileSystem.install(file, closeOnExec: g.bool(D.cloexec), at: fd)
                    if g.bool(D.clofork) { try k.fileSystem.setCloseOnFork(fd, true) }
                    if g.has(D.guardValue) {
                        try k.fileSystem.setGuard(fd, DescriptorGuard(value: g.u64(D.guardValue), flags: g.u32(D.guardFlags)))
                    }
                } catch {
                    throw SnapshotError("pid \(k.pid) fd \(fd) (limit \(k.fileSystem.maxDescriptors)): \(error)")
                }
            }
            if let cwd = r.string(I.cwd) { k.fileSystem.cwd = cwd }
        }
        try fillKQueues()
        for (_, k) in kernels where !k.kevents.timers.isEmpty || !k.kevents.mkTimers.isEmpty {
            k.startTimerThreadIfNeeded()
            k.kevents.timerWake.wakeAll()
        }
        return plans
    }

    private func sysctlEntry(_ g: SnapshotFieldReader) -> SysctlTable.Entry {
        typealias S = ST.Sysctl
        let value: SysctlTable.Value = switch g.u64(S.kind) {
        case 1: .integer(g.i64(S.int), size: Int(g.i64(S.size)))
        case 2: .string(String(decoding: g.bytes(S.bytes), as: UTF8.self))
        case 3: .error(g.i32(S.int))
        case 4: .quad(g.i64(S.int))
        default: .bytes(g.bytes(S.bytes))
        }
        return SysctlTable.Entry(name: g.string(S.name) ?? "", mib: g.u64s(S.mib).map { Int32(truncatingIfNeeded: Int64(bitPattern: $0)) },
                                 value: value)
    }

    private func extended(_ g: SnapshotFieldReader) throws -> ExtendedBSDState {
        typealias E = ST.Extended
        var x = ExtendedBSDState()
        x.signalMask = g.u32(E.signalMask)
        x.pendingSignals = g.u32(E.pendingSignals)
        for h in g.list(E.actions) {
            x.signalActions[h.i32(E.key)] = .init(handler: h.u64(E.a), mask: h.u32(E.b), flags: h.i32(E.c))
        }
        x.alternateStack = (g.u64(E.altSP), g.u64(E.altSize), g.i32(E.altFlags))
        for h in g.list(E.rlimits) { x.rlimits[h.i32(E.key)] = (h.u64(E.a), h.u64(E.b)) }
        x.umask = UInt16(truncatingIfNeeded: g.u64(E.umask))
        for h in g.list(E.cursors) {
            guard let file = hostFiles[h.ref(E.file)] else { continue }
            var c = ExtendedBSDState.DirectoryCursor(file: file, entries: h.list(E.names).map {
                ($0.string(E.key) ?? "", $0.u64(E.a), UInt8(truncatingIfNeeded: $0.u64(E.b)))
            })
            c.next = Int(h.u64(E.a))
            x.directoryCursors[h.i32(E.key)] = c
        }
        let io = g.u64s(E.ioPolicies)
        for i in stride(from: 0, to: io.count - 1, by: 2) {
            x.ioPolicies[Int32(truncatingIfNeeded: Int64(bitPattern: io[i]))] = Int32(truncatingIfNeeded: Int64(bitPattern: io[i + 1]))
        }
        for h in g.list(E.threadIOPolicies) {
            var policies: [Int32: Int32] = [:]
            let list = h.u64s(E.a)
            for i in stride(from: 0, to: list.count - 1, by: 2) {
                policies[Int32(truncatingIfNeeded: Int64(bitPattern: list[i]))] = Int32(truncatingIfNeeded: Int64(bitPattern: list[i + 1]))
            }
            x.threadIOPolicies[h.u64(E.key)] = policies
        }
        x.darwinBackgroundIOPolicy = g.i32(E.backgroundPolicy)
        return x
    }

    private func fillKQueues() throws {
        for id in ids(.kqueue) {
            let r = f(id)
            typealias Q = ST.KQueue
            guard let q = kqueues[id], let k = kernels[r.ref(Q.image)] else { continue }
            switch r.u64(Q.legacy) {
            case 1: q.legacyFormat = true
            case 2: q.legacyFormat = false
            default: q.legacyFormat = nil
            }
            q.buckets = [:]
            for g in r.list(Q.buckets) {
                q.buckets[Int(g.i64(Q.bucket))] = KQBucket(requested: g.bool(Q.requested), boundWorker: threads[g.ref(Q.boundWorker)])
            }
            q.servicer = threads[r.ref(Q.servicer)]
            q.owner = threads[r.ref(Q.owner)]
            q.requested = r.bool(Q.requested)
            if q.kind == .workloop { q.logRequest(.restored, thread: q.requested ? 1 : 0) }
            q.requestQoS = Int(r.i64(Q.requestQoS))
            q.requestOvercommit = r.bool(Q.overcommit)
            q.fixedPriority = r.bool(Q.fixedPriority)
            q.createReference = r.bool(Q.createReference)
            q.knotes = []
            k.kevents.machportIndex = nil
            k.descriptorKnoteCount.wrappingSubtract(q.descriptorKnotes, ordering: .relaxed)
            k.signalKnoteCount.wrappingSubtract(q.knotes.filter { $0.filter == EVFilter.signal }.count, ordering: .relaxed)
            q.descriptorKnotes = 0
            for n in r.list(Q.knotes) {
                typealias N = ST.Knote
                guard let kn = knotes[n.u64(N.id)] else { continue }
                let state = n.u64(N.state)
                func bit(_ b: Int) -> Bool { state & (1 << UInt64(b)) != 0 }
                kn.enabled = bit(0)
                kn.active = bit(1)
                kn.suppressed = bit(2)
                kn.deletePending = bit(3)
                kn.syntheticDelete = bit(4)
                kn.dropped = bit(5)
                kn.receiveGone = bit(6)
                kn.procExited = bit(7)
                kn.kq = q
                kn.bucket = Int(n.i64(N.bucket))
                kn.userFlags = n.u32(N.userFlags)
                kn.timerDeadline = n.has(N.timerDeadline) ? rebased(n.i64(N.timerDeadline)) : nil
                kn.timerInterval = n.u64(N.timerInterval)
                kn.timerFires = n.i64(N.timerFires)
                kn.procFired = n.u32(N.procFired)
                kn.procData = n.i64(N.procData)
                kn.signalCount = n.i64(N.signalCount)
                kn.hostDescriptor = n.bool(N.hostDescriptor)
                kn.requestsVanish = n.bool(N.requestsVanish)
                kn.syncWoken = n.bool(N.syncWoken)
                q.knotes.append(kn)
                if EVFilter.isReadiness(kn.filter) {
                    q.descriptorKnotes += 1
                    k.descriptorKnoteCount.wrappingAdd(1, ordering: .relaxed)
                }
                if DarwinKernel.isDescriptorWatch(kn.filter) {
                    k.noteDescriptorWatch(kn.ident, 1)
                }
                if kn.filter == EVFilter.signal { k.signalKnoteCount.wrappingAdd(1, ordering: .relaxed) }
                // Re-attach what the filter registered with other objects.
                if kn.timerDeadline != nil, kn.filter == EVFilter.timer {
                    // §5: a calendar-time timer is due by the wall clock,
                    // which moved on while the snapshot sat on disk.
                    if let d = k.wallClockTimerDeadline(fflags: kn.fflags, data: kn.data) {
                        kn.timerDeadline = d
                        wallClockTimers += 1
                    }
                    k.kevents.timers[ObjectIdentifier(kn)] = kn
                }
                if EVFilter.isReadiness(kn.filter),
                   let file = openFiles[n.ref(N.object)], let o = file.object as? KernelDescriptorObject {
                    kn.object = o
                    // The registration's observer: it takes the image's
                    // event lock (§12.5; this copy did not, and a socket's
                    // readiness change under L0 then changed the kqueue and
                    // the workqueue without it).
                    kn.observerToken = o.addReadinessObserver(k.readinessObserver(for: kn))
                }
                if kn.filter == EVFilter.proc, !kn.procExited, !kn.dropped,
                   let target = system.processes[Int32(truncatingIfNeeded: kn.ident)], target.state != .zombie {
                    target.watchers.append(ProcessWatch(knote: kn, kernel: k))
                }
                if kn.filter == EVFilter.vnode { k.reattachVnodeAfterRestore(kn) }
            }
        }
    }
}

extension DarwinKernel {
    /// After a restore, once the threads run (snapshot.md §7 step 10):
    /// issues every thread request that the restored knotes call for and
    /// hands pending requests to workers. A request that was issued before
    /// the snapshot but whose worker was not started yet, or an activation
    /// whose request the capture did not see, would otherwise wait for the
    /// next activation of the same bucket or workloop, which may never come
    /// (a reply that a client waits for sits in a queue nobody services).
    /// Kernel lock held.
    @discardableResult
    public func snapshotReissueThreadRequests() -> Int {
        guard termination == nil else { return 0 }
        // The kqueues and the workqueue are the event lock's (host services
        // deliver messages under it, not under L0: §12.5).
        return withEvents {
            // A workloop marked as requested that no queue holds would never
            // be requested again (`reevaluateRequests` issues a request only
            // when none is marked): it is requested afresh.
            let lost = lostWorkloopRequests()
            for kq in lost {
                kq.requested = false
                kq.logRequest(.repaired)
            }
            if let kq = kevents.workq { reevaluateRequests(kq, bucket: nil) }
            for kq in Array(kevents.workloops.values) { reevaluateRequests(kq, bucket: nil) }
            pumpWorkqueue(nil)
            return lost.count
        }
    }

    /// Workloops marked as having a thread request that is in no queue and
    /// has no servicer (diagnostics and the restore's repair, §12.5). Event
    /// lock (or every lock) held.
    func lostWorkloopRequests() -> [KQueue] {
        kevents.workloops.values.filter { kq in
            kq.requested && kq.servicer == nil && !workqueue.pendingWorkloops.contains { $0 === kq }
        }
    }

    /// `lostWorkloopRequests().count`, for a snapshot's report (every lock held).
    public var snapshotLostWorkloopRequestCount: Int { lostWorkloopRequests().count }
}
