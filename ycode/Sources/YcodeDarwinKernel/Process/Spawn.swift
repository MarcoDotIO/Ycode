import Foundation
import YcodeDarwinABI

// posix_spawn (BSD 244), execve (59), and __mac_execve (380): stage 4b,
// `specs/simulator/processes.md` §1 and `stage4b-contract.md` §4 items 3–4.
// Owner: agent P.
//
// Ordinary spawn makes a new process (new pid, new kernel, new VM through the
// launcher). SETEXEC and execve make a new kernel for the same pid; once the
// launcher has started the new image, the old one ends with
// `Outcome.imageReplaced`. A failure before that point leaves the caller (and
// the process table) unchanged.

/// The kernel-read part of `struct _posix_spawnattr` (`processes.md` §1.4).
struct SpawnAttributes: Equatable {
    var flags: UInt16 = 0
    var sigdefault: UInt32 = 0
    var sigmask: UInt32 = 0
    var pgroup: Int32 = 0
    var binprefs: [UInt32] = [0, 0, 0, 0]
    var subcpuprefs: [UInt32] = [UInt32.max, UInt32.max, UInt32.max, UInt32.max]
    var pcontrol: UInt32 = 0
    var apptype: UInt32 = 0
    /// `psa_qos_clamp` and `psa_darwin_role` (`processes.md` §1.6).
    var qosClamp: UInt64 = 0
    var darwinRole: UInt32 = 0

    static let blockSize = 192

    init() {}

    init(decoding b: [UInt8]) {
        flags = b.readLE(UInt16.self, at: 0)
        sigdefault = b.readLE(UInt32.self, at: 4)
        sigmask = b.readLE(UInt32.self, at: 8)
        pgroup = b.readLE(Int32.self, at: 12)
        binprefs = (0..<4).map { b.readLE(UInt32.self, at: 16 + 4 * $0) }
        pcontrol = b.readLE(UInt32.self, at: 32)
        apptype = b.readLE(UInt32.self, at: 36)
        qosClamp = b.readLE(UInt64.self, at: 80)
        darwinRole = b.readLE(UInt32.self, at: 88)
        subcpuprefs = (0..<4).map { b.readLE(UInt32.self, at: 112 + 4 * $0) }
    }
}

/// `psa_flags` bits (`processes.md` §1.5).
enum SpawnFlag {
    static let resetIDs: UInt16 = 0x0001
    static let setPGroup: UInt16 = 0x0002
    static let setSigDefault: UInt16 = 0x0004
    static let setSigMask: UInt16 = 0x0008
    static let setExec: UInt16 = 0x0040
    static let startSuspended: UInt16 = 0x0080
    static let disableASLR: UInt16 = 0x0100
    static let nanoAllocator: UInt16 = 0x0200
    static let setSID: UInt16 = 0x0400
    static let cloexecDefault: UInt16 = 0x4000
}

/// One 1040-byte file action (`processes.md` §1.7).
struct SpawnFileAction: Equatable {
    enum Kind: Int32 {
        case open = 0, close = 1, dup2 = 2, inherit = 3, fileportDup2 = 4, chdir = 5, fchdir = 6
    }

    var type: Int32
    var fd: Int32
    var oflag: Int32 = 0
    var mode: UInt16 = 0
    var newfd: Int32 = 0
    var path: String = ""

    static let recordSize = 1040

    init(type: Int32, fd: Int32, oflag: Int32 = 0, mode: UInt16 = 0, newfd: Int32 = 0, path: String = "") {
        self.type = type
        self.fd = fd
        self.oflag = oflag
        self.mode = mode
        self.newfd = newfd
        self.path = path
    }

    init(decoding b: [UInt8], at o: Int) {
        type = b.readLE(Int32.self, at: o)
        fd = b.readLE(Int32.self, at: o + 4)
        func cString(_ start: Int, _ max: Int) -> String {
            let bytes = b[(o + start)..<(o + start + max)]
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        switch Kind(rawValue: type) {
        case .open:
            oflag = b.readLE(Int32.self, at: o + 8)
            mode = b.readLE(UInt16.self, at: o + 12)
            path = cString(14, 1024)
        case .dup2, .fileportDup2:
            newfd = b.readLE(Int32.self, at: o + 8)
        case .chdir:
            path = cString(8, 1024)
        default:
            break
        }
    }
}

/// Everything one spawn or exec needs, parsed and validated.
struct SpawnRequest {
    var path: String
    var argv: [String]
    var envp: [String]
    var attributes = SpawnAttributes()
    var fileActions: [SpawnFileAction] = []
    var portActions: [SpawnPortAction] = []
    var setExec: Bool { attributes.flags & SpawnFlag.setExec != 0 }
}

extension DarwinKernel {
    /// `NCARGS`: the limit on path + argv + envp (with pointer slots).
    static let argumentSpaceLimit = 1 << 20
    static let E2BIG: Int32 = 7
    static let ENOEXEC: Int32 = 8
    static let EBADARCH: Int32 = 86

    // MARK: posix_spawn (244)

    func posixSpawn(_ me: DarwinProcess, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        let path = try readPath(a[1], mem)
        call.set("posix_spawn(pid=\(hx(a[0])), \"\(path)\", adesc=\(hx(a[2])), argv=\(hx(a[3])), envp=\(hx(a[4])))")
        var request = SpawnRequest(path: path, argv: [], envp: [])
        if a[2] != 0 {
            let d = try mem.read(va: a[2], count: 144)
            func pair(_ i: Int) -> (size: UInt64, pointer: UInt64) {
                (d.readLE(UInt64.self, at: 16 * i), d.readLE(UInt64.self, at: 16 * i + 8))
            }
            let attr = pair(0)
            if attr.size != 0 {
                request.attributes = SpawnAttributes(decoding: try mem.read(va: attr.pointer, count: SpawnAttributes.blockSize))
            }
            let setExec = request.attributes.flags & SpawnFlag.setExec != 0
            let fa = pair(1)
            if fa.size != 0 {
                let nofile = UInt64(extended.rlimits[RLimit.nofile]?.cur ?? 256)
                let minimum = UInt64(8 + SpawnFileAction.recordSize)
                guard fa.size >= minimum, fa.size <= 8 + UInt64(SpawnFileAction.recordSize) * nofile else {
                    throw Failure(errno: Errno.EINVAL)
                }
                let b = try mem.read(va: fa.pointer, count: Int(fa.size))
                let count = b.readLE(Int32.self, at: 4)
                guard count >= 0, fa.size == 8 + UInt64(SpawnFileAction.recordSize) * UInt64(count) else {
                    throw Failure(errno: Errno.EINVAL)
                }
                request.fileActions = (0..<Int(count)).map { SpawnFileAction(decoding: b, at: 8 + $0 * SpawnFileAction.recordSize) }
            }
            let pa = pair(2)
            if pa.size != 0 {
                guard pa.size >= 8 + UInt64(SpawnPortAction.recordSize), pa.size <= Self.pageSize else {
                    throw Failure(errno: Errno.EINVAL)
                }
                let b = try mem.read(va: pa.pointer, count: Int(pa.size))
                let count = b.readLE(Int32.self, at: 4)
                guard count >= 0, pa.size == 8 + UInt64(SpawnPortAction.recordSize) * UInt64(count) else {
                    throw Failure(errno: Errno.EINVAL)
                }
                request.portActions = try SpawnPortAction.parseBlock(b)
            }
            // MAC extensions (3), coalitions (4), the subsystem root (7, needs
            // an entitlement), and the conclave id (8) are accepted and ignored.
            let persona = pair(5)
            if persona.size != 0 {
                guard persona.size == 88 else { throw Failure(errno: Errno.ERANGE) }
                if setExec { throw Failure(errno: Errno.ENOTSUP) }
            }
            let cred = pair(6)
            if cred.size != 0 {
                guard cred.size == 340 else { throw Failure(errno: Errno.ERANGE) }
                if setExec { throw Failure(errno: Errno.ENOTSUP) }
                guard DarwinFileSystem.guestUID == 0 else { throw Failure(errno: Errno.EPERM) }
            }
        }
        // The driver process type needs an entitlement (`processes.md` §1.6).
        if request.attributes.apptype & 0xF00 == 0x700 { throw Failure(errno: Errno.EPERM) }
        var budget = Self.argumentSpaceLimit - (path.utf8.count + 1)
        request.argv = try readStringArray(a[3], budget: &budget, mem)
        request.envp = try readStringArray(a[4], budget: &budget, mem)
        call += " [\(request.setExec ? "SETEXEC " : "")argv \(request.argv.count) envp \(request.envp.count) "
            + "file actions \(request.fileActions.count) port actions \(request.portActions.count) "
            + "flags \(hx(request.attributes.flags))]"
        if request.setExec { return try execImage(me, request, &call) }
        let child = try spawnChild(me, request)
        call += " [pid \(child)]"
        if a[0] != 0 { try? writeU32(a[0], UInt32(bitPattern: child), mem) }
        return .value(0)
    }

    // MARK: execve (59) / __mac_execve (380)

    func execve(_ me: DarwinProcess, _ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        let path = try readPath(a[0], mem)
        call.set("\(n == ProcBSD.execve ? "execve" : "__mac_execve")(\"\(path)\", argv=\(hx(a[1])), envp=\(hx(a[2])))")
        var budget = Self.argumentSpaceLimit - (path.utf8.count + 1)
        var request = SpawnRequest(path: path, argv: try readStringArray(a[1], budget: &budget, mem),
                                   envp: try readStringArray(a[2], budget: &budget, mem))
        request.attributes.flags = SpawnFlag.setExec
        return try execImage(me, request, &call)
    }

    /// Reads a NULL-terminated array of string pointers (NULL array = empty),
    /// charging each string and pointer slot to `budget` (E2BIG when spent).
    func readStringArray(_ va: UInt64, budget: inout Int, _ mem: any KernelGuestMemory) throws -> [String] {
        guard va != 0 else { return [] }
        var out: [String] = []
        var cursor = va
        while true {
            let p = try readU64(cursor, mem)
            budget -= 8
            if p == 0 { break }
            guard budget > 0 else { throw Failure(errno: Self.E2BIG) }
            let s = try readString(p, length: min(budget, 256 << 10) + 1, mem)
            budget -= s.utf8.count + 1
            guard budget >= 0 else { throw Failure(errno: Self.E2BIG) }
            out.append(s)
            cursor += 8
        }
        return out
    }

    // MARK: Building an image

    /// Applies spawn file actions to `fs` in order (`processes.md` §1.7);
    /// returns the descriptors CLOEXEC_DEFAULT keeps. The first failure fails.
    func applyFileActions(_ actions: [SpawnFileAction], to fs: DarwinFileSystem) throws -> Set<Int32> {
        var marked = Set<Int32>()
        for action in actions {
            switch SpawnFileAction.Kind(rawValue: action.type) {
            case .open:
                let mode = action.mode & ~extended.umask & 0o777
                let opened = try fs.open(action.path, flags: action.oflag, mode: mode)
                if opened != action.fd {
                    do {
                        try fs.dup2(opened, action.fd)
                    } catch {
                        try? fs.close(opened)
                        throw error
                    }
                    try fs.close(opened)
                }
                marked.insert(action.fd)
            case .close:
                try fs.close(action.fd)
            case .dup2:
                try fs.dup2(action.fd, action.newfd)
                try fs.setCloseOnExec(action.newfd, false)
                marked.insert(action.newfd)
            case .inherit:
                try fs.setCloseOnExec(action.fd, false)
                marked.insert(action.fd)
            case .fileportDup2:
                guard let ipc = machIPC as? MachIPC,
                      let file = withPorts({ ipc.fileportFile(named: UInt32(bitPattern: action.fd)) }) else {
                    throw Failure(errno: Errno.EINVAL)
                }
                guard action.newfd >= 0, action.newfd < fs.maxDescriptors else { throw Failure(errno: Errno.EBADF) }
                try fs.install(file, closeOnExec: false, at: action.newfd)
                marked.insert(action.newfd)
            case .chdir:
                try fs.chdir(action.path)
            case .fchdir:
                try fs.fchdir(action.fd)
            case nil:
                throw Failure(errno: Errno.EINVAL)
            }
        }
        return marked
    }

    /// Checks that `hostPath` is an image this machine can run
    /// (`stage4b-contract.md` §2 item 8): a 64-bit arm64 `MH_EXECUTE`
    /// Mach-O (thin, or the arm64 slice of a fat file) for a simulator
    /// platform, honoring the architecture preferences (`processes.md` §1.6).
    /// ENOEXEC for anything that is not Mach-O, EBADARCH for the wrong
    /// architecture or platform.
    static func checkExecutable(hostPath: String, attributes: SpawnAttributes) throws {
        guard let handle = FileHandle(forReadingAtPath: hostPath) else { throw Failure(errno: Errno.ENOENT) }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) -> [UInt8] {
            do {
                try handle.seek(toOffset: offset)
                return Array(try handle.read(upToCount: count) ?? Data())
            } catch {
                return []
            }
        }
        func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
            UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
        }
        let arm64: UInt32 = 0x0100_000C
        let head = read(0, 4096)
        guard head.count >= 8 else { throw Failure(errno: Self.ENOEXEC) }
        var sliceOffset: UInt64 = 0
        let fatMagic = be32(head, 0)
        if fatMagic == 0xCAFE_BABE || fatMagic == 0xCAFE_BABF {
            let is64 = fatMagic == 0xCAFE_BABF
            let count = Int(be32(head, 4))
            let entrySize = is64 ? 32 : 20
            guard count > 0, count < 64, head.count >= 8 + count * entrySize else { throw Failure(errno: Self.ENOEXEC) }
            var slices: [(cpu: UInt32, sub: UInt32, offset: UInt64)] = []
            for i in 0..<count {
                let o = 8 + i * entrySize
                let offset = is64 ? UInt64(be32(head, o + 8)) << 32 | UInt64(be32(head, o + 12)) : UInt64(be32(head, o + 8))
                slices.append((be32(head, o), be32(head, o + 4), offset))
            }
            var chosen: UInt64?
            if attributes.binprefs[0] != 0 {
                for (i, pref) in attributes.binprefs.enumerated() {
                    if pref == 0 { throw Failure(errno: Self.EBADARCH) }
                    if pref == UInt32.max { break }
                    if let s = slices.first(where: { $0.cpu == pref && Self.subtypeMatches(attributes.subcpuprefs[i], $0.sub) }) {
                        chosen = s.offset
                        break
                    }
                }
            }
            if chosen == nil { chosen = slices.first { $0.cpu == arm64 }?.offset }
            guard let chosen else { throw Failure(errno: Self.EBADARCH) }
            sliceOffset = chosen
        }
        let header = sliceOffset == 0 ? head : read(sliceOffset, 4096)
        guard header.count >= 32 else { throw Failure(errno: Self.ENOEXEC) }
        let magic = header.readLE(UInt32.self, at: 0)
        if magic == 0xFEED_FACE { throw Failure(errno: Self.EBADARCH) }  // 32-bit Mach-O
        guard magic == 0xFEED_FACF else { throw Failure(errno: Self.ENOEXEC) }
        let cpu = header.readLE(UInt32.self, at: 4), sub = header.readLE(UInt32.self, at: 8)
        guard cpu == arm64 else { throw Failure(errno: Self.EBADARCH) }
        if sliceOffset == 0, attributes.binprefs[0] != 0 {
            var accepted = false
            for (i, pref) in attributes.binprefs.enumerated() {
                if pref == 0 { break }
                if pref == UInt32.max || (pref == cpu && Self.subtypeMatches(attributes.subcpuprefs[i], sub)) {
                    accepted = true
                    break
                }
            }
            guard accepted else { throw Failure(errno: Self.EBADARCH) }
        }
        guard header.readLE(UInt32.self, at: 12) == 2 else { throw Failure(errno: Self.ENOEXEC) }  // MH_EXECUTE
        // LC_BUILD_VERSION: a simulator platform (iOS 7, tvOS 8, watchOS 9, visionOS 12).
        let ncmds = Int(header.readLE(UInt32.self, at: 16)), sizeofcmds = Int(header.readLE(UInt32.self, at: 20))
        let commands = 32 + sizeofcmds <= header.count ? header : read(sliceOffset, 32 + min(sizeofcmds, 1 << 20))
        var at = 32
        for _ in 0..<ncmds {
            guard at + 8 <= commands.count else { break }
            let cmd = commands.readLE(UInt32.self, at: at), size = Int(commands.readLE(UInt32.self, at: at + 4))
            if cmd == 0x32, at + 12 <= commands.count {
                let platform = commands.readLE(UInt32.self, at: at + 8)
                guard [7, 8, 9, 12].contains(platform) else { throw Failure(errno: Self.EBADARCH) }
            }
            guard size >= 8 else { break }
            at += size
        }
    }

    private static func subtypeMatches(_ pref: UInt32, _ sub: UInt32) -> Bool {
        pref == UInt32.max || pref & 0x00FF_FFFF == sub & 0x00FF_FFFF
    }

    /// Copies what a new image inherits from this one (`processes.md`
    /// §1.11): limits, umask, the sysctl table, signal actions after the
    /// exec reset, the calling thread's mask, then SETSIGDEF/SETSIGMASK.
    func inheritProcessState(into k: DarwinKernel, attributes: SpawnAttributes, isExec: Bool) {
        k.sysctl = sysctl
        k.entropy = entropy
        k.sleep = sleep
        k.bootCounter = bootCounter
        k.allImageInfosAddress = allImageInfosAddress
        k.allImageInfosSize = allImageInfosSize
        k.mainStackTop = mainStackTop
        k.extended.rlimits = extended.rlimits
        k.extended.umask = extended.umask
        // Caught signals revert to the default (a default "ignore" becomes
        // ignored, except SIGCONT); ignored ones stay ignored.
        var actions: [Int32: ExtendedBSDState.SignalAction] = [:]
        for (sig, action) in extended.signalActions {
            if action.handler == 1 {
                actions[sig] = ExtendedBSDState.SignalAction(handler: 1)
            } else if action.handler > 1, Signal.ignoredByDefault.contains(sig), sig != Signal.sigcont {
                actions[sig] = ExtendedBSDState.SignalAction(handler: 1)
            }
        }
        if attributes.flags & SpawnFlag.setSigDefault != 0 {
            for sig in Int32(1)...31 where attributes.sigdefault & (1 << UInt32(sig - 1)) != 0 { actions[sig] = nil }
        }
        k.extended.signalActions = actions
        let ctx = current
        var mask = ctx.kind == .workqueue ? ctx.signalMask : extended.signalMask
        if attributes.flags & SpawnFlag.setSigMask != 0 { mask = attributes.sigmask }
        mask &= ~SignalConstant.unblockable
        k.extended.signalMask = mask
        k.mainThread.signalMask = mask
        if isExec { k.extended.pendingSignals = extended.pendingSignals }
    }

    private func makeRequest(_ request: SpawnRequest, guestPath: String, hostPath: String) -> ProcessImageRequest {
        var apple: [String] = []
        if request.attributes.flags & SpawnFlag.nanoAllocator != 0 { apple.append("MallocNanoZone=1") }
        var image = ProcessImageRequest(executablePath: guestPath, hostExecutablePath: hostPath, argv: request.argv,
                                        envp: request.envp, apple: apple,
                                        startSuspended: request.attributes.flags & SpawnFlag.startSuspended != 0)
        image.apple += system.kernelAppleStrings(for: image)
        return image
    }

    /// Steps 2–7 shared by spawn and exec: the descriptor table, the
    /// executable, the new kernel with its inherited ports. Nothing in the
    /// process table changes. On failure everything made is released.
    private func buildImage(_ request: SpawnRequest, pid newPID: Int32, isExec: Bool)
        throws -> (kernel: DarwinKernel, guestPath: String, hostPath: String) {
        let fs = fileSystem.makeChildCopy(newProcess: !isExec)
        let guestPath: String, hostPath: String
        let marked: Set<Int32>
        do {
            marked = try applyFileActions(request.fileActions, to: fs)
            (guestPath, hostPath) = try fs.hostPathForExec(request.path)
            try Self.checkExecutable(hostPath: hostPath, attributes: request.attributes)
        } catch {
            fs.closeAll()
            throw error
        }
        let k = DarwinKernel(fileSystem: fs, pid: newPID, system: system, log: log, counter: counter,
                             counterFrequency: counterFrequency, wallClock: wallClock)
        k.executableHostPath = hostPath
        inheritProcessState(into: k, attributes: request.attributes, isExec: isExec)
        if let mine = machIPC as? MachIPC, let theirs = k.machIPC as? MachIPC {
            withPorts { theirs.inheritTaskPorts(from: mine) }
            do {
                try withPorts { try theirs.applySpawnPortActions(request.portActions, from: mine) }
            } catch {
                k.discardUnlaunchedImage()
                throw error
            }
        }
        // Image activation: close-on-exec (and CLOEXEC_DEFAULT) closing.
        fs.closeOnExecDescriptors(keepOnly: request.attributes.flags & SpawnFlag.cloexecDefault != 0 ? marked : nil)
        return (k, guestPath, hostPath)
    }

    /// A kernel that never ran: release its ports and descriptors.
    func discardUnlaunchedImage() {
        termination = .imageReplaced
        withPorts { (machIPC as? MachIPC)?.terminateTask() }
        fileSystem.closeAll()
    }

    /// On by default; `YCODE_SPAWN_UNLOCKED_BUILD=0` builds new images with
    /// the kernel lock held, as before (`bsd-locking.md` §7).
    nonisolated(unsafe) public static var unlockedImageBuild =
        getenv("YCODE_SPAWN_UNLOCKED_BUILD").map { String(cString: $0) != "0" } ?? true

    /// Builds the new image's VM (`ProcessLauncher.prepare`) with the
    /// kernel lock released (`bsd-locking.md` §7): `kernel` is not yet
    /// visible to any other thread. nil when the launcher has no two-step
    /// form, the switch is off, or the caller cannot give the lock up.
    /// When this image ended meanwhile the prepared image is discarded and
    /// the call fails with EINTR. Kernel lock held on entry and return.
    private func prepareUnlocked(_ launcher: any ProcessLauncher, _ request: ProcessImageRequest,
                                 kernel: DarwinKernel) throws -> (any PreparedImage)? {
        guard Self.unlockedImageBuild, lock.isHeldByCurrentThread else { return nil }
        let prepared = try lock.unlocked { try launcher.prepare(request, kernel: kernel) }
        if let prepared, isTerminating {
            launcher.discard(prepared)
            throw Failure(errno: 4)
        }
        return prepared
    }

    /// Ordinary spawn (`processes.md` §1.10): returns the child's pid.
    func spawnChild(_ me: DarwinProcess, _ request: SpawnRequest) throws -> Int32 {
        guard let launcher = system.launcher else {
            trace("note: posix_spawn: no process launcher; ENOSYS")
            throw Failure(errno: Errno.ENOSYS)
        }
        let childPID = try system.allocatePID()
        let (child, guestPath, hostPath) = try buildImage(request, pid: childPID, isExec: false)
        // The image's VM, loaded executables and stack, built without L0.
        var prepared: (any PreparedImage)?
        do {
            prepared = try prepareUnlocked(launcher, makeRequest(request, guestPath: guestPath, hostPath: hostPath), kernel: child)
        } catch {
            child.discardUnlaunchedImage()
            throw error
        }
        let record = DarwinProcess(pid: childPID, ppid: pid, pgid: me.pgid, sid: me.sid, uniqueID: system.makeUniqueID(),
                                   executablePath: guestPath, startTime: DarwinSystem.now())
        record.kernel = child
        record.startAbsTime = counter()
        record.parentUniqueID = me.uniqueID
        record.originalParentPIDVersion = pidVersion
        record.processType = request.attributes.apptype
        record.processControl = request.attributes.pcontrol
        record.pidVersion = system.makePIDVersion()
        child.pidVersion = record.pidVersion
        system.processes[childPID] = record
        me.children.append(childPID)
        func undo() {
            if let p = prepared {
                launcher.discard(p)
                prepared = nil
            }
            system.reap(record)
            child.discardUnlaunchedImage()
        }
        // Scheduling policy (`scheduling-policy.md` §4.1, §4.2): the type,
        // clamp and role, the watch ports, and the start hold.
        child.applySpawnPolicy(request.attributes, record: record, isExec: false)
        var boostSenders: [Int32] = []
        // Messages already queued on the watch ports: a client sent to the
        // job and is waiting for it (an on-demand start, §4.2).
        var queuedAtSpawn = 0
        if let ipc = child.machIPC as? MachIPC { withPorts {
            queuedAtSpawn = ipc.pendingWatchPorts.reduce(0) { $0 + ($1.active ? $1.messages.count : 0) }
            if SchedPolicy.importanceEnabled {
                ipc.bindImportanceWatchPorts(ipc.pendingWatchPorts, to: record)
                if SchedPolicy.holdTrace, record.importanceBoosts > 0 {
                    boostSenders = ipc.pendingWatchPorts.flatMap { $0.messages.all.filter(\.importance).compactMap { $0.sender?.pid } }
                }
            }
            ipc.pendingWatchPorts = []
        } }
        let suspended = request.attributes.flags & SpawnFlag.startSuspended != 0
        let holdable = SchedPolicy.holdEnabled && !suspended && record.importanceBoosts == 0
            && (record.typeCode == ProcessTypeCode.daemonAdaptive || record.typeCode == ProcessTypeCode.daemonBackground)
        // An on-demand start is not held, with or without importance on the
        // client's message (scheduling-policy.md §4.2, "demand").
        let demand = holdable && SchedPolicy.holdSkipsDemand && queuedAtSpawn > 0
        let hold = holdable && !demand
        do {
            // Step 9 (as the child itself): SETPGROUP, then SETSID.
            if request.attributes.flags & SpawnFlag.setPGroup != 0 {
                try setpgid(caller: record, pid: 0, pgid: request.attributes.pgroup)
            }
            if request.attributes.flags & SpawnFlag.setSID != 0 { try setsid(record) }
            var image = makeRequest(request, guestPath: guestPath, hostPath: hostPath)
            if hold { image.startSuspended = true }
            if let p = prepared {
                prepared = nil  // activate disposes of it on failure
                record.image = try launcher.activate(p, startSuspended: image.startSuspended)
            } else {
                record.image = try launcher.launch(image, kernel: child)
            }
        } catch {
            undo()
            throw error
        }
        let label = request.argv.count > 1 && GuestPath.lastComponent(guestPath).hasPrefix("xpcproxy")
            ? request.argv[1] : GuestPath.lastComponent(guestPath)
        if hold {
            system.startHold(record, label: label)
        } else if demand {
            system.schedStats.demandStarts += 1
            system.holdLog?("pid \(childPID) \(label): not held (\(ProcessTypeCode.name(record.processType)), on demand: "
                + "\(queuedAtSpawn) messages queued at spawn)")
        } else if SchedPolicy.holdTrace, record.isImportanceReceiver || record.typeCode == ProcessTypeCode.daemonBackground {
            system.holdLog?("pid \(childPID) \(label): not held (\(ProcessTypeCode.name(record.processType)), "
                + "\(record.importanceBoosts) boosts at spawn from pids \(boostSenders))")
        }
        if SchedPolicy.importanceEnabled || SchedPolicy.qosEnabled {
            trace("note: sched: pid \(childPID) type \(ProcessTypeCode.name(record.processType)) clamp \(record.qosClamp) "
                + "role \(record.darwinRole) boosts \(record.importanceBoosts)\(hold ? " held" : "")")
        }
        if request.attributes.flags & SpawnFlag.startSuspended != 0 { record.state = .stopped }
        // Step 12: NOTE_FORK to the parent's watchers.
        system.postProcessEvent(me, NoteProc.fork)
        trace("note: spawned pid \(childPID) \(guestPath)")
        return childPID
    }

    /// SETEXEC spawn and execve (`processes.md` §1.3, §1.11, §4.7): the
    /// process continues as a new image under the same pid.
    func execImage(_ me: DarwinProcess, _ request: SpawnRequest, _ call: inout CallText) throws -> BSDResult {
        guard let launcher = system.launcher else {
            trace("note: exec: no process launcher; ENOSYS")
            throw Failure(errno: Errno.ENOSYS)
        }
        let (next, guestPath, hostPath) = try buildImage(request, pid: pid, isExec: true)
        next.pidVersion = system.makePIDVersion()
        let image: any LaunchedImage
        do {
            let imageRequest = makeRequest(request, guestPath: guestPath, hostPath: hostPath)
            // The VM is built without L0 (the new image is not visible yet);
            // EINTR when this image ended meanwhile (another thread's exec,
            // exit or a fatal signal).
            if let prepared = try prepareUnlocked(launcher, imageRequest, kernel: next) {
                image = try launcher.activate(prepared, startSuspended: imageRequest.startSuspended)
            } else {
                image = try launcher.launch(imageRequest, kernel: next)
            }
        } catch {
            next.discardUnlaunchedImage()
            throw error
        }
        // Step 8: the commit point. From here on a failure kills the process.
        me.kernel = next
        me.image = image
        me.pidVersion = next.pidVersion
        me.setImagePath(guestPath)
        me.hasExeced = true
        next.applySpawnPolicy(request.attributes, record: me, isExec: true)
        if let ipc = next.machIPC as? MachIPC { withPorts {
            if SchedPolicy.importanceEnabled { ipc.bindImportanceWatchPorts(ipc.pendingWatchPorts, to: me) }
            ipc.pendingWatchPorts = []
        } }
        if request.attributes.flags & SpawnFlag.startSuspended != 0 { me.state = .stopped }
        // The old image ends quietly: its other threads stop, its port
        // space dies (§4.6), its descriptor table goes (the new one shares
        // the descriptions it kept).
        endImage(.imageReplaced)
        tearDownKEvents()
        withPorts { (machIPC as? MachIPC)?.terminateTask() }
        fileSystem.closeAll()
        do {
            if request.attributes.flags & SpawnFlag.setPGroup != 0 {
                try next.setpgid(caller: me, pid: 0, pgid: request.attributes.pgroup)
            }
            if request.attributes.flags & SpawnFlag.setSID != 0 { try next.setsid(me) }
        } catch {
            trace("note: exec: SETPGROUP/SETSID failed after the commit point; SIGKILL")
            next.terminateBySignal(Signal.sigkill)
        }
        system.postProcessEvent(me, NoteProc.exec)
        call += " [image replaced: pid \(pid) now runs \(guestPath), pid version \(next.pidVersion)]"
        return .outcome(.imageReplaced)
    }
}
