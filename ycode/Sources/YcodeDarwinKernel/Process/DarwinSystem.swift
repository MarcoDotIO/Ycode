import Foundation
import Synchronization
import YcodeDarwinABI

/// One guest process (`specs/simulator/processes.md` §2.1). The record
/// survives exec (a new image = a new `DarwinKernel` under the same pid) and
/// lives on as a zombie until it is reaped. Every member is read and changed
/// with the system lock held.
public final class DarwinProcess: @unchecked Sendable, CustomStringConvertible {
    public enum State: Equatable, Sendable {
        /// Running guest code (or blocked in the kernel).
        case running
        /// Stopped (`POSIX_SPAWN_START_SUSPENDED`), not yet continued.
        case stopped
        /// Exited, not yet reaped.
        case zombie
    }

    public let pid: Int32
    /// `p_uniqueid`: fresh per process, kept across exec.
    public let uniqueID: UInt64

    /// The members that `proc_info`, `csops` and the `kern.proc` sysctls
    /// read without the kernel lock (`bsd-locking.md` §13): written with L0
    /// held (as every member), each read and write under `fieldsLock`, a
    /// leaf. A reader without L0 takes one consistent copy (`view`).
    struct Fields {
        var ppid: Int32
        var pgid: Int32
        var sid: Int32
        var state: State
        var status: Int32 = 0
        var kernel: DarwinKernel?
        var executablePath: String
        var comm: String
        var name: String
        var startTime: (seconds: Int64, microseconds: Int64)
        var startAbsTime: UInt64 = 0
        var exitAbsTime: UInt64 = 0
        var parentUniqueID: UInt64 = 0
        var originalParentPIDVersion: UInt32 = 0
        var exiting = false
        var pidVersion: UInt32 = 0
        var zombieExecutableUUID: [UInt8]?
    }
    private let fieldsLock = DescriptorTableLock(name: "process record")
    nonisolated(unsafe) private var fields: Fields

    /// One consistent copy of the fields (any thread).
    func view() -> Fields { fieldsLock.withLock { fields } }

    public internal(set) var ppid: Int32 {
        get { fieldsLock.withLock { fields.ppid } }
        set { fieldsLock.withLock { fields.ppid = newValue } }
    }
    public internal(set) var pgid: Int32 {
        get { fieldsLock.withLock { fields.pgid } }
        set { fieldsLock.withLock { fields.pgid = newValue } }
    }
    public internal(set) var sid: Int32 {
        get { fieldsLock.withLock { fields.sid } }
        set { fieldsLock.withLock { fields.sid = newValue } }
    }
    public internal(set) var state: State {
        get { fieldsLock.withLock { fields.state } }
        set { fieldsLock.withLock { fields.state = newValue } }
    }
    /// The wait status word once exited (`processes.md` §2.3).
    public internal(set) var status: Int32 {
        get { fieldsLock.withLock { fields.status } }
        set { fieldsLock.withLock { fields.status = newValue } }
    }
    /// `p_xhighbits`: bits 24…31 of an `exit` value (for `waitid`).
    var exitHighBits: Int32 = 0
    /// The current image. Nil for pid 1 (pseudo-init) and for zombies.
    public internal(set) var kernel: DarwinKernel? {
        get { fieldsLock.withLock { fields.kernel } }
        set {
            // The old image is released after the leaf lock (its deinit may take locks).
            let old = fieldsLock.withLock { () -> DarwinKernel? in
                let old = fields.kernel
                fields.kernel = newValue
                return old
            }
            withExtendedLifetime(old) {}
            // The image's own `proc_info` dirty control runs without L0 (ProcInfo.swift).
            newValue?.processDirtyLink.withLock { $0 = dirty }
        }
    }
    /// What the launcher returned for the current image.
    var image: (any LaunchedImage)?
    /// Children, in creation order (wait scans them in this order).
    var children: [Int32] = []
    /// The guest path of the current image.
    public internal(set) var executablePath: String {
        get { fieldsLock.withLock { fields.executablePath } }
        set { fieldsLock.withLock { fields.executablePath = newValue } }
    }
    /// `p_comm` (≤ 15 bytes) and `p_name` (≤ 31 bytes).
    var comm: String {
        get { fieldsLock.withLock { fields.comm } }
        set { fieldsLock.withLock { fields.comm = newValue } }
    }
    var name: String {
        get { fieldsLock.withLock { fields.name } }
        set { fieldsLock.withLock { fields.name = newValue } }
    }
    /// `P_EXEC`: an image was activated (every spawned process). `setpgid`
    /// on such a child fails with EACCES.
    var hasExeced = true
    /// Start time (`pbi_start_tv*`).
    var startTime: (seconds: Int64, microseconds: Int64) {
        get { fieldsLock.withLock { fields.startTime } }
        set { fieldsLock.withLock { fields.startTime = newValue } }
    }
    /// mach_absolute_time at start and at exit (0 while running), for
    /// `proc_pid_rusage` (ri_proc_start_abstime / ri_proc_exit_abstime).
    var startAbsTime: UInt64 {
        get { fieldsLock.withLock { fields.startAbsTime } }
        set { fieldsLock.withLock { fields.startAbsTime = newValue } }
    }
    var exitAbsTime: UInt64 {
        get { fieldsLock.withLock { fields.exitAbsTime } }
        set { fieldsLock.withLock { fields.exitAbsTime = newValue } }
    }
    /// The parent's unique id (`puniqueid`) and pid version at creation.
    var parentUniqueID: UInt64 {
        get { fieldsLock.withLock { fields.parentUniqueID } }
        set { fieldsLock.withLock { fields.parentUniqueID = newValue } }
    }
    var originalParentPIDVersion: UInt32 {
        get { fieldsLock.withLock { fields.originalParentPIDVersion } }
        set { fieldsLock.withLock { fields.originalParentPIDVersion = newValue } }
    }
    /// The exit sequence has started.
    var exiting: Bool {
        get { fieldsLock.withLock { fields.exiting } }
        set { fieldsLock.withLock { fields.exiting = newValue } }
    }
    /// EVFILT_PROC knotes watching this pid.
    var watchers: [ProcessWatch] = []
    /// Threads of this process blocked in `wait4`/`waitid`.
    let childWaiters = WaitQueue()
    /// Continued since the last report (`WCONTINUED`), and by whom.
    var continuedPending = false
    var continuedBy: Int32 = 0
    /// Dirty tracking (`proc_info` DIRTYCONTROL): 0x1 tracked, 0x2 allows
    /// idle exit, 0x4 dirty, 0x8 launch in progress.
    var dirtyState: UInt32 {
        get { dirty.bits.load(ordering: .acquiring) }
        set { dirty.bits.store(newValue, ordering: .releasing) }
    }
    /// The word behind `dirtyState`: an atomic, so the process's own
    /// DIRTYCONTROL calls change it without L0 (`bsd-locking.md` §4).
    let dirty = ProcessDirtyState()
    /// `psa_apptype`, `psa_pcontrol` (recorded only).
    var processType: UInt32 = 0
    var processControl: UInt32 = 0
    /// Scheduling policy (`scheduling-policy.md` §4.1): the spawn's QoS
    /// clamp (0 none, 1 utility, 2 background, 3 maintenance) and darwin
    /// role, `setpriority(PRIO_DARWIN_PROCESS)`, the importance assertions
    /// held for it, and its start hold (host monotonic ns at the start).
    var qosClamp = 0
    var darwinRole: UInt32 = 0
    var requestedDarwinBG = false
    /// Importance assertions (port-lock state with the lock split).
    var importanceBoosts = 0
    var holdStart: UInt64? {
        didSet { holdActive.store(holdStart != nil, ordering: .releasing) }
    }
    /// `holdStart != nil`, readable without the kernel lock (the port lock's
    /// importance code checks it; `mach-ipc-locking.md` §4.5).
    let holdActive = Atomic<Bool>(false)
    var holdLabel = ""
    /// The pid version of the current image (audit token word 7).
    var pidVersion: UInt32 {
        get { fieldsLock.withLock { fields.pidVersion } }
        set { fieldsLock.withLock { fields.pidVersion = newValue } }
    }
    /// The last image's executable UUID, kept for the zombie.
    var zombieExecutableUUID: [UInt8]? {
        get { fieldsLock.withLock { fields.zombieExecutableUUID } }
        set { fieldsLock.withLock { fields.zombieExecutableUUID = newValue } }
    }
    /// The current image's main-executable LC_UUID, or 16 zero bytes when
    /// none is known (`processes.md` §2.11).
    var executableUUID: [UInt8] { view().executableUUID }
    /// `terminate_with_payload` reason, kept for diagnostics.
    var exitReason: String?

    init(pid: Int32, ppid: Int32, pgid: Int32, sid: Int32, uniqueID: UInt64, executablePath: String,
         startTime: (Int64, Int64)) {
        self.pid = pid
        self.uniqueID = uniqueID
        let last = GuestPath.lastComponent(executablePath)
        fields = Fields(ppid: ppid, pgid: pgid, sid: sid, state: .running, executablePath: executablePath,
                        comm: String(decoding: Array(last.utf8.prefix(15)), as: UTF8.self),
                        name: String(decoding: Array(last.utf8.prefix(31)), as: UTF8.self),
                        startTime: startTime)
    }

    public var isZombie: Bool { state == .zombie }

    public var description: String {
        "pid \(pid) ppid \(ppid) pgid \(pgid) sid \(sid) \(state)\(state == .zombie ? " status \(hx(UInt32(bitPattern: status)))" : "") \(executablePath)"
    }

    func setImagePath(_ path: String) {
        let last = GuestPath.lastComponent(path)
        let comm = String(decoding: Array(last.utf8.prefix(15)), as: UTF8.self)
        let name = String(decoding: Array(last.utf8.prefix(31)), as: UTF8.self)
        fieldsLock.withLock {
            fields.executablePath = path
            fields.comm = comm
            fields.name = name
        }
    }
}

/// One EVFILT_PROC registration: the knote and the kernel whose kqueue holds it.
final class ProcessWatch {
    weak var knote: Knote?
    weak var kernel: DarwinKernel?

    init(knote: Knote, kernel: DarwinKernel) {
        self.knote = knote
        self.kernel = kernel
    }
}

/// All guest processes of one simulated device (stage 4b,
/// `specs/simulator/stage4b-contract.md` §3). One `DarwinSystem` owns the
/// kernel lock every process shares, the process table, the shared Mach
/// state, and the launcher that turns a spawn request into a running VM.
///
/// Owner: agent P (process layer). Contract-pinned members are marked.
public final class DarwinSystem: @unchecked Sendable {
    /// Contract-pinned: the one kernel lock of the whole system.
    public let lock: KernelLock
    /// Contract-pinned: Mach state shared by every task (agent M).
    public let mach: MachIPCSystem
    /// Contract-pinned: builds VMs for new images (agent V).
    public weak var launcher: (any ProcessLauncher)?

    /// Made by a `DarwinKernel` that was given no system: the stage-4a
    /// one-process machine. Such a system never has a process table entry
    /// for its kernel, and the kernel keeps its stage-4a behavior.
    let isImplicit: Bool

    /// The process table: live processes and zombies by pid. Pid 1 is the
    /// pseudo-init (`processes.md` §2.1): it has no image and reaps orphans.
    ///
    /// Written with L0 held, each read and write under `processTableLock`
    /// (a leaf), so `proc_info`, `csops` and the `kern.proc` sysctls read it
    /// without L0 (`bsd-locking.md` §13). Writes copy the dictionary (spawn
    /// and exit only).
    var processes: [Int32: DarwinProcess] {
        get { processTableLock.withLock { processTable } }
        set {
            // A removed record is released after the leaf lock (its image's deinit may take locks).
            let old = processTableLock.withLock { () -> [Int32: DarwinProcess] in
                let old = processTable
                processTable = newValue
                return old
            }
            withExtendedLifetime(old) {}
        }
    }
    private let processTableLock = DescriptorTableLock(name: "process table")
    nonisolated(unsafe) private var processTable: [Int32: DarwinProcess] = [:]

    /// A process record by pid, without L0 (any thread).
    func processRecord(_ pid: Int32) -> DarwinProcess? { processTableLock.withLock { processTable[pid] } }
    /// POSIX shared memory names (shm_open), system-wide.
    var posixShmSegments: [String: PosixShmSegment] = [:]
    /// POSIX named semaphores (`PosixSem.swift`).
    var posixSemaphoreStorage: [String: PosixSemaphore] = [:]
    /// Advisory file locks and data-protection classes (`fileLocks`).
    var fileLockStorage: FileLockTable?
    /// Guards the creation of `fileLockStorage` (`fileLocks`).
    let fileLockCreation = Mutex<Void>(())
    /// Pids that ever set or cleared a process-owned (POSIX) file lock: a
    /// close without L0 (`bsd-locking.md` §4.2) releases that process's
    /// locks on the file under L0 only for these. Sticky; its own leaf lock
    /// (read without L0). A pid is added before the lock call looks up its
    /// descriptor.
    let posixLockUsers = Mutex<Set<Int32>>([])
    /// Object id → path, for fsgetpath and openbyid_np (internally locked).
    let objectPaths = ObjectPathIndex()
    /// Scheduling policy (`SchedPolicy.swift`): processes in their start
    /// hold, the hold thread, its wakeup, counters, and the hold log sink.
    var heldProcesses: [DarwinProcess] = []
    var holdThreadRunning = false
    let holdWake = WaitQueue()
    public internal(set) var schedStats = SchedStats()
    public var holdLog: ((String) -> Void)?
    /// The last pid handed out (`processes.md` §2.1, `stage4b-contract.md` §2 item 7).
    var lastPID: Int32 = VMLayout.guestPID
    var nextPIDVersion: UInt32 = 0x100
    var nextUniqueID: UInt64 = 1
    /// This boot's salt and session UUID (`executable_boothash=`,
    /// `darwin-process-start.md` §1.4 row 10).
    public var bootSalt = UInt32.random(in: 0...UInt32.max)
    public var bootSessionUUID: String = UUID().uuidString
    /// The pseudo-init's pid.
    public static let initPID: Int32 = 1
    /// `PID_MAX`: pids wrap from here to 100.
    public static let maxPID: Int32 = 99_999
    public static let firstWrappedPID: Int32 = 100

    public convenience init() {
        self.init(implicit: false)
    }

    /// A system with or without the IPC lock split (`mach-ipc-locking.md` §4).
    public convenience init(ipcLocks: Bool) {
        self.init(implicit: false, ipcLocks: ipcLocks)
    }

    /// The lock split for every new system (`mach-ipc-locking.md` §4): on by
    /// default; `YCODE_IPC_LOCKS=0` turns it off. One-process (implicit)
    /// systems never have it.
    nonisolated(unsafe) public static var ipcLocksDefault = getenv("YCODE_IPC_LOCKS").map { String(cString: $0) != "0" } ?? true

    /// Tests: `YCODE_IPC_LOCKS_TESTS=1` gives every system the lock split,
    /// one-process (implicit) systems included, so that the whole kernel
    /// suite runs with it (the test helpers then try the fast paths first).
    nonisolated(unsafe) public static var splitForTests = getenv("YCODE_IPC_LOCKS_TESTS").map { String(cString: $0) == "1" } ?? false

    init(implicit: Bool, ipcLocks: Bool = DarwinSystem.ipcLocksDefault || DarwinSystem.splitForTests) {
        let split = ipcLocks && (!implicit || Self.splitForTests)
        lock = KernelLock(ipcLocks: split)
        mach = MachIPCSystem()
        if split { mach.portLock = KernelLock(fineLockOf: lock, level: 2, name: "port lock (G)") }
        isImplicit = implicit
        // A blocking guest thread frees its workqueue slot in its own process.
        lock.blockingObserver = { context, blocking in
            context.kernel?.threadBlockingChanged(context, blocking: blocking)
        }
        let initRecord = DarwinProcess(pid: Self.initPID, ppid: 0, pgid: Self.initPID, sid: Self.initPID, uniqueID: 0,
                                       executablePath: "/sbin/launchd", startTime: Self.now())
        processes[Self.initPID] = initRecord
    }

    /// Contract-pinned (§3.2): called (lock held) when a process exits for
    /// good, with its wait status (`processes.md` §2.3).
    public var processExited: ((_ pid: Int32, _ status: Int32) -> Void)?

    /// The environment a spawned or executed image gets, from its guest
    /// executable path and the environment the caller passed (the device's
    /// camera layer goes into apps this way; camera.md "Ycode
    /// implementation"). Called with the kernel lock held; nil: unchanged.
    public var imageEnvironment: (@Sendable (_ executable: String, _ envp: [String]) -> [String])?

    // MARK: Lookups

    /// Contract-pinned: the live (not zombie) kernel of `pid`'s current image.
    public func kernel(forPID pid: Int32) -> DarwinKernel? {
        lock.withLock {
            guard let p = processes[pid], p.state != .zombie else { return nil }
            return p.kernel
        }
    }

    /// The record of `pid` (live or zombie).
    public func process(pid: Int32) -> DarwinProcess? {
        lock.withLock { processes[pid] }
    }

    /// Every process except pid 1, by pid (for the VMM's summary).
    public var allProcesses: [DarwinProcess] {
        lock.withLock { processes.values.filter { $0.pid != Self.initPID }.sorted { $0.pid < $1.pid } }
    }

    /// The record whose current image is `kernel`, if any.
    func record(of kernel: DarwinKernel) -> DarwinProcess? {
        guard let p = processes[kernel.pid], p.kernel === kernel else { return nil }
        return p
    }

    static func now() -> (Int64, Int64) {
        let t = Date().timeIntervalSince1970
        let s = t.rounded(.down)
        return (Int64(s), Int64((t - s) * 1e6))
    }

    // MARK: Identifiers

    /// True while `n` is a live or zombie pid, a process group id, or a session id.
    func numberInUse(_ n: Int32) -> Bool {
        if processes[n] != nil { return true }
        return processes.values.contains { $0.pgid == n || $0.sid == n }
    }

    /// The next free pid (`processes.md` §2.1): last + 1, wrapping at
    /// 99999 to 100, skipping numbers in use. EAGAIN when none is free.
    func allocatePID() throws -> Int32 {
        var candidate = lastPID
        for _ in 0..<Int(Self.maxPID) {
            candidate = candidate >= Self.maxPID ? Self.firstWrappedPID : candidate + 1
            if !numberInUse(candidate) {
                lastPID = candidate
                return candidate
            }
        }
        throw DarwinErrnoError(DarwinErrnoCode.EAGAIN)
    }

    /// A pid version that differs from every one handed out before.
    func makePIDVersion() -> UInt32 {
        nextPIDVersion &+= 1
        if nextPIDVersion == 0 { nextPIDVersion = 1 }
        return nextPIDVersion
    }

    func makeUniqueID() -> UInt64 {
        defer { nextUniqueID += 1 }
        return nextUniqueID
    }

    /// True when some process (live or zombie) is in group `pgid`.
    func groupExists(_ pgid: Int32) -> Bool {
        processes.values.contains { $0.pgid == pgid && $0.pid != Self.initPID }
    }

    // MARK: The root process

    /// Contract-pinned (§3.2): makes the root process (pid 100, ppid 1, the
    /// leader of its own session and group, `processes.md` §2.10), its
    /// kernel, and launches it through `launcher`.
    ///
    /// With `exitedChildEnvironmentKey` (`stage4c-contract.md` §8.3), the
    /// root also gets a child that already exited with status 0 and was not
    /// reaped (a zombie with no image), and `KEY=<that child's pid>` is
    /// appended to the root's environment. The root reaps it with
    /// `wait4`/`waitpid` as usual (launchd_sim's
    /// `XPC_SIMULATOR_HOLDING_TANK_HACK`, `bootstrap-wire.md` §5.4).
    public func spawnInitialProcess(_ request: ProcessImageRequest, fileSystem: DarwinFileSystem,
                                    exitedChildEnvironmentKey: String? = nil) throws -> DarwinKernel {
        var request = request
        request.apple += kernelAppleStrings(for: request)
        return try lock.withLock {
            guard let launcher else { throw DarwinErrnoError(DarwinErrnoCode.ENOSYS) }
            let pid = numberInUse(VMLayout.guestPID) ? try allocatePID() : VMLayout.guestPID
            let kernel = DarwinKernel(fileSystem: fileSystem, pid: pid, system: self)
            let record = DarwinProcess(pid: pid, ppid: Self.initPID, pgid: pid, sid: pid, uniqueID: makeUniqueID(),
                                       executablePath: request.executablePath, startTime: Self.now())
            record.kernel = kernel
            record.pidVersion = makePIDVersion()
            kernel.pidVersion = record.pidVersion
            kernel.executableHostPath = request.hostExecutablePath
            processes[pid] = record
            processes[Self.initPID]?.children.append(pid)
            var zombie: DarwinProcess?
            if let key = exitedChildEnvironmentKey {
                let childPID = try allocatePID()
                let child = DarwinProcess(pid: childPID, ppid: pid, pgid: pid, sid: pid, uniqueID: makeUniqueID(),
                                          executablePath: request.executablePath, startTime: Self.now())
                child.state = .zombie
                child.status = 0
                child.parentUniqueID = record.uniqueID
                child.pidVersion = makePIDVersion()
                processes[childPID] = child
                record.children.append(childPID)
                request.envp.append("\(key)=\(childPID)")
                zombie = child
            }
            do {
                record.image = try launcher.launch(request, kernel: kernel)
            } catch {
                if let zombie { processes[zombie.pid] = nil }
                processes[pid] = nil
                processes[Self.initPID]?.children.removeAll { $0 == pid }
                kernel.withPorts { (kernel.machIPC as? MachIPC)?.terminateTask() }
                throw error
            }
            if request.startSuspended {
                record.state = .stopped
                kernel.startedSuspended()
            }
            return kernel
        }
    }

    /// The `apple[]` strings the kernel adds for an image: the code-signing
    /// hashes when the executable is signed (and the request does not
    /// already carry them).
    func kernelAppleStrings(for request: ProcessImageRequest) -> [String] {
        guard !request.apple.contains(where: { $0.hasPrefix("executable_boothash=") }) else { return [] }
        return CodeSignature.appleStrings(hostPath: request.hostExecutablePath, bootSalt: bootSalt,
                                          bootSessionUUID: bootSessionUUID)
    }

    // MARK: Exit and reaping

    /// Removes a zombie (or a failed half-built child) from the table.
    func reap(_ p: DarwinProcess) {
        processes[p.pid] = nil
        processes[p.ppid]?.children.removeAll { $0 == p.pid }
    }

    /// True when `parent` does not keep zombies: pid 1, SIGCHLD set to
    /// SIG_IGN, or `SA_NOCLDWAIT` (`processes.md` §2.4 step 7).
    func reapsChildrenAtOnce(_ parent: DarwinProcess?) -> Bool {
        guard let parent, parent.pid != Self.initPID, let k = parent.kernel else { return true }
        let action = k.extended.signalActions[DarwinKernel.Signal.sigchld]
        return action?.handler == 1 || (action?.flags ?? 0) & DarwinKernel.Signal.saNoCldWait != 0
    }

    /// The exit sequence (`processes.md` §2.4, `stage4b-contract.md` §4
    /// item 5). `outcome` is what the image's threads see from now on. Lock held.
    func exitProcess(_ p: DarwinProcess, waitStatus: Int32, highBits: Int32 = 0, outcome: DarwinKernel.Outcome) {
        guard !p.exiting, p.state != .zombie, p.pid != Self.initPID else { return }
        p.exiting = true
        if let k = p.kernel {
            p.exitAbsTime = k.counter()
            // 1. Other threads end; 2. Mach teardown; 3. descriptors.
            k.endImage(outcome)
            k.tearDownKEvents()
            k.withPorts { (k.machIPC as? MachIPC)?.terminateTask() }
            k.fileSystem.closeAll()
            lock.wakeFileLockWaiters(fileLocks.release(owner: .process(p.pid)))
            k.log("note: process \(p.pid) exited, wait status \(hx(UInt32(bitPattern: waitStatus)))")
        }
        p.zombieExecutableUUID = p.kernel?.executableUUID
        p.image = nil
        p.kernel = nil
        p.status = waitStatus
        p.exitHighBits = highBits
        p.state = .zombie
        // 5. Children: zombies are reaped, live ones go to pid 1.
        let initRecord = processes[Self.initPID]
        for c in p.children {
            guard let child = processes[c] else { continue }
            if child.state == .zombie {
                processes[c] = nil
            } else {
                child.ppid = Self.initPID
                initRecord?.children.append(c)
            }
        }
        p.children = []
        // 7 (first half). The parent keeps a zombie unless it ignores children.
        let parent = processes[p.ppid]
        let reapNow = reapsChildrenAtOnce(parent)
        if reapNow { reap(p) }
        // 6. NOTE_EXIT (after the zombie is visible, `processes.md` §2.4 Ycode note).
        postProcessEvent(p, NoteProc.exit, data: Int64(waitStatus & 0xF_FFFF))
        p.watchers.removeAll()
        // 7. SIGCHLD and wait4 wakeups.
        if let parent {
            if !reapNow { parent.kernel?.postSignal(DarwinKernel.Signal.sigchld) }
            parent.childWaiters.wakeAll()
        }
        processExited?(p.pid, waitStatus)
    }

    /// Ends every live process with SIGKILL (the VMM's shutdown). Lock taken.
    public func terminateAllProcesses() {
        lock.withLock {
            for p in processes.values.sorted(by: { $0.pid > $1.pid }) where p.pid != Self.initPID && p.state != .zombie {
                exitProcess(p, waitStatus: DarwinKernel.Signal.sigkill,
                            outcome: .fatal(status: 128 + DarwinKernel.Signal.sigkill, message: "terminated by the VMM"))
            }
        }
    }

    /// Posts an EVFILT_PROC event to every watcher of `p`.
    func postProcessEvent(_ p: DarwinProcess, _ event: UInt32, data: Int64 = 0) {
        p.watchers.removeAll { $0.knote == nil || $0.kernel == nil || $0.knote!.dropped }
        for w in p.watchers {
            guard let kn = w.knote, let k = w.kernel, !k.isTerminating else { continue }
            k.processEventFired(kn, event: event, data: data)
        }
    }
}

extension DarwinProcess.Fields {
    var isZombie: Bool { state == .zombie }
    /// As `DarwinProcess.executableUUID`.
    var executableUUID: [UInt8] {
        let u = kernel?.executableUUID ?? zombieExecutableUUID ?? []
        return u.count == 16 ? u : [UInt8](repeating: 0, count: 16)
    }
}
