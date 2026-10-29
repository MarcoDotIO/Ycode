import Foundation
import Synchronization
import YcodeDarwinABI

// BSD descriptor and lookup traps without the kernel lock L0
// (`specs/simulator/bsd-locking.md`).
//
// After the IPC traps left L0 (`mach-ipc-locking.md`), L0 was the lock of
// the BSD and VM traps, and its most frequent users were cheap descriptor
// and path calls that waited about 0.3 ms each for it. These run on the
// trapping thread's host thread with no kernel lock:
//
// | Trap | State used, and its lock |
// |---|---|
// | 5 `open`, 398, 463 `openat`, 464 | path resolution and the host open (already without L0, stage 6 §5.1); the new descriptor goes in under the descriptor-table lock |
// | 6 `close`, 399 | the table (removal under its lock) for a host file, the console or a device node; the close hook under L0 only when the image watches descriptors or ever used POSIX locks (§4.2) |
// | 3 `read`, 396, 153 `pread`, 414 | a regular host file: the table (one lookup), then the transfer under the description's offset lock (stage 6 §5.2) |
// | 4 `write`, 397, 154 `pwrite`, 415 | as read; not for a guarded descriptor (frame-profile.md §5) |
// | 199 `lseek` | the table (one lookup), the offset lock |
// | 339 `fstat64` | the table (one lookup); a host file, the console or a device node |
// | 92 `fcntl`, 406 | F_GETFD, F_SETFD, F_GETFL, F_GETPATH, F_GETPATH_NOFIRMLINK, the caching hints, F_CHECK_LV, F_ADDFILESIGS_RETURN, F_GETCONFINED: the table; F_SETFL of a host file, F_SETNOSIGPIPE, F_GETNOSIGPIPE: one word of the description; F_GETPROTECTIONCLASS, F_GETPROTECTIONLEVEL: the protection-class table's leaf lock (§12) |
// | 33 `access`, 466 `faccessat`, 469 `fstatat`, 470 `fstatat64` | path resolution and `stat` (a directory descriptor's path from the table) |
// | 202 `sysctl`, 274 `sysctlbyname` | the image's sysctl table (written only before the image runs and on restore); not `kern.proc.pid` |
// | 327 `issetugid` | nothing |
// | 336 `proc_info` | DIRTYCONTROL of the caller's own process: one atomic word (`ProcessDirtyState`); every other call on L0 |
// | 336 `proc_info` LISTPIDS/PIDINFO/PIDRUSAGE, 545 `proc_info_extended_id` (those calls), 169 `csops`, 170 `csops_audittoken`, 202 `kern.proc.pid` | the process table's leaf lock, then one record's (`bsd-locking.md` §13) |
// | 344 `getdirentries64`; the close of a directory | the descriptor table, the directory cursors' leaf lock (`bsd-locking.md` §14) |
// | 95 `fsync`, 187 `fdatasync`, 136 `mkdir`, 475 `mkdirat`, 58 `readlink`, 473 `readlinkat`, 345 `statfs64`, 346 `fstatfs64` | the descriptor table, path resolution and host calls (§12) |
// | 116 `gettimeofday`, 372 `thread_selfid`, 500 `getentropy`, 322 `iopolicysys` | the I/O policy table's leaf lock; the clocks (the commpage snapshot under a leaf lock), the caller's thread id, host random bytes |
//
// The answers (results, errors, carry) are the locked path's: the fast
// handlers call the same functions. A trap falls back to the locked path,
// having changed nothing, when it would touch L0 state: an object
// descriptor (pipe, socket, kqueue, shared memory), a guarded or directory
// descriptor's close, a file-lock or protection-class fcntl, `kern.proc`;
// and, as for the task-local traps, when tracing, when the image is
// ending, or when the thread is not bound to the image.

/// Thrown by shared code run on a BSD fast path when the call needs L0
/// (nothing was changed): the trap falls back to the locked path.
struct BSDFastDecline: Error {}

extension DarwinKernel {
    /// On by default; `YCODE_BSD_FAST=0` keeps every BSD trap on L0.
    nonisolated(unsafe) public static var bsdFastTrapsEnabled = getenv("YCODE_BSD_FAST").map { String(cString: $0) != "0" } ?? true

    /// Tests: the BSD fast paths also run for a traced image (they write no
    /// trace text). `YCODE_BSD_FAST_TESTS=1` or the IPC test switch.
    nonisolated(unsafe) public static var bsdFastForTests =
        (getenv("YCODE_BSD_FAST_TESTS").map { String(cString: $0) == "1" } ?? false) || DarwinSystem.splitForTests

    /// Diagnostics: `YCODE_BSD_FAST_EXCLUDE=<n>[,<n>…]` keeps these trap
    /// numbers on L0 (ablations).
    static let bsdFastExcluded: Set<Int32> = {
        guard let raw = getenv("YCODE_BSD_FAST_EXCLUDE") else { return [] }
        return Set(String(cString: raw).split(separator: ",").compactMap { Int32($0) })
    }()

    /// True for a trap number (`x16` as Int32) that `handleBSDFast` may serve.
    public static func isBSDFastTrap(_ number: Int32) -> Bool {
        if !bsdFastExcluded.isEmpty, bsdFastExcluded.contains(number) { return false }
        return switch number {
        case 5, 398, 463, 464, 6, 399, 3, 396, 153, 414, 4, 397, 154, 415, 199, 339, 92, 406, 33, 466, 469, 470, 202, 274, 327,
             220, 228, 476, 197, 515, 516, 544, 381, 41, 336: true
        case 116, 372, 500, 322, 95, 187, 136, 475, 58, 473, 345, 346: bsdFastMoreEnabled
        case 344: fastDirectoryEnabled
        case 169, 170, 545: procTableFastEnabled
        default: false
        }
    }

    /// On by default; `YCODE_BSD_FAST_MORE=0` keeps `gettimeofday`,
    /// `thread_selfid` and `getentropy` on L0 (`bsd-locking.md` §12).
    nonisolated(unsafe) public static var bsdFastMoreEnabled = getenv("YCODE_BSD_FAST_MORE").map { String(cString: $0) != "0" } ?? true

    /// On by default; `YCODE_CONSOLE_FAST=0` keeps console writes on L0 (§12).
    nonisolated(unsafe) public static var consoleFastEnabled = getenv("YCODE_CONSOLE_FAST").map { String(cString: $0) != "0" } ?? true

    /// On by default; `YCODE_FILE_LOCK_FAST=0` keeps every file-lock fcntl on
    /// L0 (`bsd-locking.md` §15).
    nonisolated(unsafe) public static var fileLockFastEnabled = getenv("YCODE_FILE_LOCK_FAST").map { String(cString: $0) != "0" } ?? true

    /// On by default; `YCODE_DIRECTORY_FAST=0` keeps `getdirentries64` and a
    /// directory's close on L0 (`bsd-locking.md` §14).
    nonisolated(unsafe) public static var fastDirectoryEnabled = getenv("YCODE_DIRECTORY_FAST").map { String(cString: $0) != "0" } ?? true

    /// Diagnostics: fcntl commands that fell back to L0, by command, and
    /// BSD fast traps that fell back, by trap number (fallback paths only).
    static let fcntlDeclinedByCommand = Mutex<[Int32: UInt64]>([:])
    static let bsdDeclinedByTrap = Mutex<[Int32: UInt64]>([:])
    static func countDecline(_ table: borrowing Mutex<[Int32: UInt64]>, _ key: Int32) {
        table.withLock { $0[key, default: 0] &+= 1 }
    }

    /// One line: the commands and traps that fell back most often.
    static var bsdDeclineReport: String {
        func top(_ table: [Int32: UInt64], _ n: Int) -> String {
            table.sorted { $0.value > $1.value }.prefix(n).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        }
        return "BSD fast fallbacks by trap: " + top(bsdDeclinedByTrap.withLock { $0 }, 12)
            + "; fcntl fallbacks by command: " + top(fcntlDeclinedByCommand.withLock { $0 }, 12)
    }

    /// Diagnostics: BSD traps served without L0, and those that fell back.
    public static let bsdFastServed = Atomic<UInt64>(0)
    /// Diagnostics: BSD fast traps that fell back to the locked path.
    public static let bsdFastDeclined = Atomic<UInt64>(0)
    /// Fast closes that ran the close hook under L0.
    public static let bsdFastCloseHooks = Atomic<UInt64>(0)
    /// … of which for a watched descriptor (the rest: POSIX locks).
    public static let bsdFastCloseHooksWatched = Atomic<UInt64>(0)

    /// Handles a BSD trap without the kernel lock, or returns nil when the
    /// caller must take the locked path (nothing was changed then). Call
    /// from the trapping thread's host thread with no kernel lock held.
    public func handleBSDFast(_ frame: inout TrapFrame, context: ThreadContext, memory: any KernelGuestMemory) -> Outcome? {
        guard Self.bsdFastTrapsEnabled, !tracing || Self.bsdFastForTests, frame.trapKind == .svc,
              frame.x.count >= TrapFrame.registerCount, context.kernel === self, !isTerminating else { return nil }
        let number = Int32(truncatingIfNeeded: frame.x[16])
        guard Self.isBSDFastTrap(number), !lock.isHeldByCurrentThread else { return nil }
        let threadLocks = KernelThreadLocks.current
        guard threadLocks.held.isEmpty, !threadLocks.isFast, !threadLocks.bsdFast else { return nil }
        threadLocks.bsdFast = true
        defer { threadLocks.bsdFast = false }
        let profile = lock.trapProfile
        let start = profile != nil ? KernelClock.now() : 0
        let generation = memory.tlbGeneration
        let a = frame.x.prefixArray(8)
        if number == 515 || number == 516 || number == 544 {
            return ulockFast(number, a, &frame, context: context, memory: memory, profileStart: start)
        }
        // Trace text only for a traced image in the tests (the VMM never
        // takes a fast path while tracing); the same lines as `handleBSD`.
        var call = CallText(tracing, TrapNames.describe(TrapNames.bsd(Int(number)), a))
        let result: UInt64?
        do {
            result = try fastBSDCall(Int(number), a, &call, context: context, memory)
        } catch is BSDFastDecline {
            Self.bsdFastDeclined.wrappingAdd(1, ordering: .relaxed)
            Self.countDecline(Self.bsdDeclinedByTrap, number)
            return nil
        } catch {
            let e = errno(of: error, default: Errno.EINVAL)
            frame.x[0] = UInt64(UInt32(bitPattern: e))
            frame.x[1] = 0
            frame.carry = true
            Self.bsdFastServed.wrappingAdd(1, ordering: .relaxed)
            if tracing { log("trap bsd \(number) \(call) -> error \(e) (\(Errno.name(e)))") }
            if let profile { profile.noteHandler(TrapProfile.filtered(Int64(number), kernel: self), KernelClock.now() &- start) }
            if memory.tlbGeneration != generation { frame.requestTLBInvalidation(memory.tlbRange(since: generation)) }
            return .resume
        }
        guard let value = result else {
            Self.bsdFastDeclined.wrappingAdd(1, ordering: .relaxed)
            Self.countDecline(Self.bsdDeclinedByTrap, number)
            return nil
        }
        frame.x[0] = value
        frame.x[1] = 0
        frame.carry = false
        Self.bsdFastServed.wrappingAdd(1, ordering: .relaxed)
        if tracing { log("trap bsd \(number) \(call) -> \(hx(value))") }
        if let profile { profile.noteHandler(TrapProfile.filtered(Int64(number), kernel: self), KernelClock.now() &- start) }
        if memory.tlbGeneration != generation { frame.requestTLBInvalidation(memory.tlbRange(since: generation)) }
        return .resume
    }

    /// `__ulock_wait`, `__ulock_wait2`, `__ulock_wake` under the image's
    /// event lock only (`bsd-locking.md` §5): with the lock split, and
    /// also with priority inheritance (`YCODE_SCHED_QOS`): its pushes have the
    /// thread's own lock (`scheduling-policy.md` §4.4; not with
    /// `YCODE_SCHED_CLASS_OFF_L0=0`). A wait sleeps on the event lock with no lock held.
    private func ulockFast(_ number: Int32, _ a: [UInt64], _ frame: inout TrapFrame, context: ThreadContext,
                           memory: any KernelGuestMemory, profileStart: UInt64) -> Outcome? {
        guard eventLock != nil, !SchedPolicy.qosEnabled || SchedPolicy.classOffL0 else {
            Self.bsdFastDeclined.wrappingAdd(1, ordering: .relaxed)
            return nil
        }
        var call = CallText(tracing, TrapNames.describe(TrapNames.bsd(Int(number)), a))
        var value: UInt64 = 0
        var failure: Int32?
        lock.withFastPath(context: context) {
            context.entryFrame = frame
            defer { context.entryFrame = nil }
            // (The ulock calls take the event lock themselves.)
            do {
                value = number == 516 ? try ulockWake(a, &call) : try ulockWait(Int(number), a, &call, memory)
            } catch {
                failure = errno(of: error, default: Errno.EINVAL)
            }
        }
        if let e = failure {
            frame.x[0] = UInt64(UInt32(bitPattern: e))
            frame.carry = true
            if tracing { log("trap bsd \(number) \(call) -> error \(e) (\(Errno.name(e)))") }
        } else {
            frame.x[0] = value
            frame.carry = false
            if tracing { log("trap bsd \(number) \(call) -> \(hx(value))") }
        }
        frame.x[1] = 0
        Self.bsdFastServed.wrappingAdd(1, ordering: .relaxed)
        if let profile = lock.trapProfile {
            profile.noteHandler(TrapProfile.filtered(Int64(number), kernel: self), KernelClock.now() &- profileStart)
        }
        return .resume
    }

    /// One fast BSD call: its value, nil to fall back, or a thrown error
    /// (the locked path's errno).
    private func fastBSDCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, context: ThreadContext,
                             _ mem: any KernelGuestMemory) throws -> UInt64? {
        let fs = fileSystem
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case 5, 398:
            // open: as BSD.open (path, then the host open, then the table).
            let path = try readPath(a[0], mem)
            call.set("open(\"\(path)\", flags=\(openFlagsText(int(1))), mode=0o\(String(a[2] & 0o7777, radix: 8)))")
            let newFD = try openUnlocked(path, flags: int(1), mode: UInt16(truncatingIfNeeded: a[2]))
            return UInt64(UInt32(bitPattern: newFD))

        case 463, 464:
            // openat: as BSD2.openat. (The locked path also drops a directory
            // cursor recorded for the new number; a cursor names the
            // description it belongs to, so a stale one is never used.)
            let path = try resolveAtPath(int(0), a[1], mem)
            call.set("openat(\(int(0)), \"\(path)\", flags=\(openFlagsText(int(2))), mode=0o\(String(a[3] & 0o7777, radix: 8)))")
            let newFD = try openUnlocked(path, flags: int(2), mode: UInt16(truncatingIfNeeded: a[3]))
            return UInt64(UInt32(bitPattern: newFD))

        case 336:
            // proc_info: the caller's own DIRTYCONTROL and the process-table
            // reads (ProcInfo.swift); the rest on L0.
            return try procInfoFast(a, &call, mem)

        case 545:
            // proc_info_extended_id: the process-table reads only.
            guard !system.isImplicit else { return nil }
            let callnum = Int32(truncatingIfNeeded: a[0])
            guard callnum == ProcInfoCall.listPIDs || callnum == ProcInfoCall.pidInfo || callnum == ProcInfoCall.pidRUsage
            else { return nil }
            return try procInfoExtendedID(a, &call, mem)

        case 169, 170:
            // csops, csops_audittoken: the target's image through the process
            // table (its identity and signature do not change while it runs).
            guard !system.isImplicit else { return nil }
            call.set("\(n == 170 ? "csops_audittoken" : "csops")(pid=\(int(0)), ops=\(int(1)), addr=\(hx(a[2])), size=\(a[3]))")
            return try csopsCall(n == 170, a, &call, mem)

        case 6, 399:
            call.set("close(\(int(0)))")
            return try fastClose(int(0), context: context) ? 0 : nil

        case 3, 396, 153, 414:
            // read / pread of a regular host file (bsdCall's path after
            // `objectIO` declined): one table lookup, then the transfer.
            let isPread = n == 153 || n == 414
            call.set(isPread ? "pread(fd=\(int(0)), buf=\(hx(a[1])), len=\(hx(a[2])), off=\(hx(a[3])))"
                : "read(fd=\(int(0)), buf=\(hx(a[1])), len=\(hx(a[2])))")
            guard let io = try? hostFileIO(int(0), writing: false) else { return nil }
            let count = Int(min(a[2], UInt64(Int32.max)))
            let bytes = try readUnlocked(io, count: count, offset: isPread ? a[3] : nil)
            if !bytes.isEmpty { try mem.write(va: a[1], bytes: bytes) }
            return UInt64(bytes.count)

        case 4, 397, 154, 415:
            // write / pwrite of a regular host file (the locked path's
            // route for one: `bsdCall` and `descriptorCall` after
            // `objectIO` declined): one table lookup, then the host write
            // under the description's offset lock (stage 6 §5.2). A guarded
            // descriptor, an object, the console or a device node falls
            // back (the guard exception is reported there).
            let isPwrite = n == 154 || n == 415
            call.set(isPwrite ? "pwrite(fd=\(int(0)), buf=\(hx(a[1])), len=\(hx(a[2])), off=\(hx(a[3])))"
                : "write(fd=\(int(0)), buf=\(hx(a[1])), len=\(hx(a[2])))")
            guard a[2] <= UInt64(Int32.max), !isPwrite || Int64(bitPattern: a[3]) >= 0 else { return nil }
            if let flags = fs.guardFlags(int(0)), flags & DarwinGuard.write != 0 { return nil }
            guard let io = try? hostFileIO(int(0), writing: true, guardChecked: true) else {
                // The console (the host's standard output or error, a write
                // the host serializes): without L0, so a slow host stream
                // never holds the kernel lock (§12). Not for pwrite.
                guard Self.bsdFastMoreEnabled, Self.consoleFastEnabled, !isPwrite, let file = try? fs.openFile(for: int(0)),
                      case .console = file.node else { return nil }
                let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
                return UInt64(try fs.write(int(0), bytes, guardChecked: true))
            }
            let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            return UInt64(try isPwrite ? io.pwrite(bytes, offset: a[3]) : io.write(bytes))

        case 199:
            // lseek (`lseekCall`): the target is checked once; the offset
            // moves under its own lock.
            call.set("lseek(fd=\(int(0)), offset=\(Int64(bitPattern: a[1])), whence=\(int(2)))")
            let target = try fs.lseekTarget(int(0))
            return try target.seek(offset: Int64(bitPattern: a[1]), whence: int(2))!

        case 339:
            // fstat64 of a host file, the console or a device node.
            call.set("fstat64(fd=\(int(0)), buf=\(hx(a[1])))")
            let file = try fs.openFile(for: int(0))
            if let object = file.object, !(object is DarwinDevice) { return nil }
            try mem.write(va: a[1], bytes: fs.fstat(of: file).encodedStat64())
            return 0

        case 92, 406:
            return try fastFcntl(a, &call, mem)

        case 33, 466:
            // access / faccessat: as BSD2.access.
            let isAt = n == 466
            let path = try resolveAtPath(isAt ? int(0) : Self.atFDCWD, isAt ? a[1] : a[0], mem)
            let mode = isAt ? int(2) : int(1)
            call.set(isAt ? "faccessat(\(int(0)), \"\(path)\", mode=\(mode), flag=\(hx(a[3])))" : "access(\"\(path)\", mode=\(mode))")
            let follow = !isAt || int(3) & Self.atSymlinkNofollow == 0
            let st = try statUnlocked(path, followSymlinks: follow)
            if let denied = accessDenied(st, path: path, read: mode & 4 != 0, write: mode & 2 != 0, execute: mode & 1 != 0) {
                throw Failure(errno: denied)
            }
            return 0

        case 469, 470:
            // fstatat / fstatat64: as BSD2.fstatat.
            let path = try resolveAtPath(int(0), a[1], mem)
            call.set("fstatat64(\(int(0)), \"\(path)\", buf=\(hx(a[2])), flag=\(hx(a[3])))")
            let st = try statUnlocked(path, followSymlinks: int(3) & Self.atSymlinkNofollow == 0)
            try mem.write(va: a[2], bytes: st.encodedStat64())
            return 0

        case 202:
            // sysctl (MIB form) without kern.proc (the process table is L0 state).
            // kern.proc.pid.<pid> reads the process table under its lock
            // (bsd-locking.md §13); any other kern.proc name falls back.
            let count = Int(UInt32(truncatingIfNeeded: a[1]))
            if count >= 2, count <= 12 {
                let raw = try mem.read(va: a[0], count: count >= 3 ? 12 : 8)
                if raw.readLE(Int32.self, at: 0) == 1, raw.readLE(Int32.self, at: 4) == 14,
                   !(Self.procTableFastEnabled && !system.isImplicit && count == 4 && raw.readLE(Int32.self, at: 8) == 1) {
                    return nil
                }
            }
            return try sysctlMIB(a, &call, mem)

        case 274:
            let name = try readString(a[0], length: Int(min(a[1], 1024)), mem)
            call.set("sysctlbyname(\"\(name)\", old=\(hx(a[2])), oldlenp=\(hx(a[3])), new=\(hx(a[4])), newlen=\(hx(a[5])))")
            return try sysctlRead(sysctl.lookup(name: name), name: name,
                                  old: a[2], oldlenp: a[3], new: a[4], newlen: a[5], mem)

        case 327:
            call.set("issetugid()")
            return 0

        case 116:
            call.set("gettimeofday(tp=\(hx(a[0])), tzp=\(hx(a[1])), mach_time=\(hx(a[2])))")
            return try gettimeofdayCall(a, mem)

        case 372:
            // thread_selfid: the caller's own thread id.
            call.set("thread_selfid()")
            return context.threadID

        case 95, 187:
            // fsync, fdatasync: Ycode's writes reach the host file before
            // the write returns; the call checks the descriptor (FileLocks.swift).
            return try syncCall(n, int(0), &call)

        case 136, 475:
            // mkdir, mkdirat: the host directory; the umask is one word.
            return try mkdirCall(n, a, &call, mem)

        case 58, 473:
            // readlink, readlinkat.
            return try readlinkCall(n, a, &call, mem)

        case 345, 346:
            // statfs64, fstatfs64.
            return try statfsCall(n, a, &call, mem)

        case 322:
            // iopolicysys: the image's I/O policy table (a leaf lock).
            return try ioPolicyCall(a, thread: context.threadID, &call, mem)

        case 344:
            // getdirentries64: the descriptor table, then the image's
            // directory cursors under their own lock (§14).
            return try getdirentries64(a, &call, mem)

        case 500:
            // getentropy: host random bytes (ExtendedBSD `BSD2.getentropy`).
            call.set("getentropy(buf=\(hx(a[0])), size=\(a[1]))")
            guard a[1] <= 256 else { throw Failure(errno: Errno.EINVAL) }
            if a[1] > 0 {
                var bytes = entropy(Int(a[1]))
                if bytes.count < Int(a[1]) { bytes += [UInt8](repeating: 0, count: Int(a[1]) - bytes.count) }
                try mem.write(va: a[0], bytes: Array(bytes.prefix(Int(a[1]))))
            }
            return 0

        case 41:
            // dup: one table operation (a guarded descriptor falls back: its
            // guard violation is reported under L0).
            call.set("dup(\(int(0)))")
            if (try? fs.guardState(of: int(0))) != nil { return nil }
            return UInt64(UInt32(bitPattern: try fs.dup(int(0))))

        case 381:
            // __mac_syscall: the Sandbox policy's check calls (2, 12) allow,
            // its extension calls as `metadataCall`, any other policy is
            // ENOPOLICY.
            let policy = (try? readString(a[0], length: 64, mem)) ?? "?"
            call.set("__mac_syscall(\"\(policy)\", \(int(1)), \(hx(a[2])))")
            if policy == "Sandbox" {
                if int(1) == 2 || int(1) == 12 { return 0 }
                // The extension calls (issue, consume, release) are stateless
                // (a token from the path's stat; consume checks the form;
                // `bsd-locking.md` §12).
                guard Self.bsdFastMoreEnabled else { return nil }
                if let value = try sandboxExtensionCall(int(1), arg: a[2], mem) { return value }
            }
            throw Failure(errno: MetadataBSD.enoPolicy)

        case 220, 228, 476:
            // getattrlist, fgetattrlist, getattrlistat: path resolution,
            // host stat and extended attributes, the object-path index and
            // the protection classes (each with its own lock).
            return try attributeListCall(n, a, &call, mem)

        case 197:
            // mmap: the address space (L1) and the descriptor table; a POSIX
            // shared memory object declines (`BSDFastDecline`).
            var fallback = Errno.EINVAL
            do {
                return try mmap(a, &call, &fallback, mem, fast: true)
            } catch is BSDFastDecline {
                throw BSDFastDecline()
            } catch {
                throw Failure(errno: errno(of: error, default: fallback))
            }

        default:
            return nil
        }
    }

    /// `close` without L0 (`bsd-locking.md` §4.2). Returns false (nothing
    /// changed) for a descriptor whose close needs L0: an object other than
    /// a device node, a guarded descriptor (and a directory with
    /// `YCODE_DIRECTORY_FAST=0`), and for a descriptor that is not open (the
    /// locked path answers EBADF; rare, and its trace line is kept).
    private func fastClose(_ fd: Int32, context: ThreadContext) throws -> Bool {
        guard let file = try? fileSystem.removeIf(fd, { file, guarded in
            guard !guarded else { return false }
            switch file.node {
            case .console: return true
            case let .file(f): return !f.isDirectory || Self.fastDirectoryEnabled
            case let .object(o): return o is DarwinDevice
            }
        }) else { return false }
        // A directory's cursor goes with its descriptor (its table has a
        // leaf lock, §14). A getdirentries64 that looked the descriptor up
        // before the removal may make a cursor afterwards: it names the old
        // description and is replaced at the number's next use.
        if case let .file(f) = file.node, f.isDirectory { extended.directoryCursors[fd] = nil }
        // The removal is ordered before these reads (the table lock, then
        // the watch and lock-user leaf locks); a knote or a POSIX lock that
        // looked the descriptor up before the removal was counted before
        // that lookup, so it is seen here.
        let watched = isDescriptorWatched(fd)
        let pid = self.pid
        let posixLocks = system.posixLockUsers.withLock { $0.contains(pid) }
        if watched || posixLocks {
            Self.bsdFastCloseHooks.wrappingAdd(1, ordering: .relaxed)
            if watched { Self.bsdFastCloseHooksWatched.wrappingAdd(1, ordering: .relaxed) }
            lock.withLock(context: context) {
                descriptorWasClosed(fd)
                releasePOSIXLocksOnClose(file)
            }
        }
        // `file` is released here, with no lock held: the last close of a
        // description with OFD or flock locks takes L0 itself.
        return true
    }

    /// The fcntl commands that touch only the descriptor table (the
    /// locked path's answers, `DarwinKernel.fcntl`); nil for the others.
    private func fastFcntl(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64? {
        let fs = fileSystem
        let fd = Int32(truncatingIfNeeded: a[0])
        let cmd = Int32(truncatingIfNeeded: a[1])
        let arg = a[2]
        call.set("fcntl(fd=\(fd), \(Self.fcntlNames[cmd] ?? "cmd \(cmd)"), arg=\(hx(arg)))")
        switch cmd {
        case Fcntl.getfd:
            return (try fs.closeOnExec(fd) ? 1 : 0) | (try fs.closeOnFork(fd) ? 2 : 0)
        case Fcntl.setfd:
            try fs.setCloseOnExec(fd, arg & 1 != 0)
            try fs.setCloseOnFork(fd, arg & 2 != 0)
            return 0
        case Fcntl.getfl:
            return UInt64(UInt32(bitPattern: try fs.statusFlags(fd)))
        case Fcntl.getpath, Fcntl.getpathNoFirmlink:
            let path = try fs.path(for: fd)
            let bytes = cString(path)
            call += " [\(path)]"
            guard bytes.count <= DarwinFileSystem.maxPathLength else { throw Failure(errno: Errno.ENAMETOOLONG) }
            try mem.write(va: arg, bytes: bytes)
            return 0
        case Fcntl.checkLV:
            return 0
        case Fcntl.addFileSigsReturn:
            let size = try fs.file(for: fd).size
            var b: [UInt8] = []
            b.appendLE(size)
            try mem.write(va: arg, bytes: b)
            return 0
        case 0, 67:
            // F_DUPFD, F_DUPFD_CLOEXEC (`descriptorFcntl`): one table operation.
            call.set("fcntl(fd=\(fd), \(cmd == 67 ? "F_DUPFD_CLOEXEC" : "F_DUPFD"), arg=\(Int32(truncatingIfNeeded: arg)))")
            if (try? fs.guardState(of: fd)) != nil { return nil }
            _ = try fs.openFile(for: fd)  // EBADF first
            return UInt64(try fs.dup(fd, minimum: Int32(truncatingIfNeeded: arg), closeOnExec: cmd == 67))
        case Fcntl.getConfined:
            return try fs.openFile(for: fd).confinedToProcess ? 1 : 0
        case let c where Fcntl.hints.contains(c):
            _ = try fs.openFile(for: fd)
            return 0
        case DescriptorControl.setfl where Self.bsdFastMoreEnabled:
            // F_SETFL of a description without an object (a host file, the
            // console): one store of the flags word, whose settable bits it
            // replaces (the access mode never changes), so no update is lost
            // without L0. An object's readiness may change: L0 (§12).
            call.set("fcntl(fd=\(fd), F_SETFL, arg=\(hx(UInt32(truncatingIfNeeded: arg))))")
            guard try fs.openFile(for: fd).object == nil else { return nil }
            try fs.setStatusFlags(fd, Int32(truncatingIfNeeded: arg))
            return 0
        case DescriptorControl.setNoSigPipe where Self.bsdFastMoreEnabled:
            call.set("fcntl(fd=\(fd), F_SETNOSIGPIPE, arg=\(Int32(truncatingIfNeeded: arg)))")
            try fs.openFile(for: fd).noSigPipe = Int32(truncatingIfNeeded: arg) != 0
            return 0
        case DescriptorControl.getNoSigPipe where Self.bsdFastMoreEnabled:
            call.set("fcntl(fd=\(fd), F_GETNOSIGPIPE)")
            return try fs.openFile(for: fd).noSigPipe ? 1 : 0
        case FileLockControl.getlk, FileLockControl.setlk, FileLockControl.ofdGetlk, FileLockControl.ofdSetlk
            where Self.fileLockFastEnabled:
            // The non-blocking record and OFD lock calls: the file-lock
            // table's leaf lock; waiters woken under L0, taken holding
            // nothing (§15). The waiting forms stay on L0.
            return try fileLockFcntl(fd, cmd, arg, &call, mem, fast: true)
        case Fcntl.getProtectionClass, Fcntl.getProtectionLevel:
            // The protection-class table has a leaf lock (§4.4); setting a
            // class stays on L0.
            guard Self.bsdFastMoreEnabled else { return nil }
            return try protectionFcntl(fd, cmd, arg, &call)
        default:
            Self.countDecline(Self.fcntlDeclinedByCommand, cmd)
            return nil
        }
    }
}
