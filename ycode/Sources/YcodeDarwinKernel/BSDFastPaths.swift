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
// | 92 `fcntl`, 406 | F_GETFD, F_SETFD, F_GETFL, F_GETPATH, F_GETPATH_NOFIRMLINK, the caching hints, F_CHECK_LV, F_ADDFILESIGS_RETURN, F_GETCONFINED: the table |
// | 33 `access`, 466 `faccessat`, 469 `fstatat`, 470 `fstatat64` | path resolution and `stat` (a directory descriptor's path from the table) |
// | 202 `sysctl`, 274 `sysctlbyname` | the image's sysctl table (written only before the image runs and on restore); not `kern.proc.pid` |
// | 327 `issetugid` | nothing |
// | 336 `proc_info` | DIRTYCONTROL of the caller's own process: one atomic word (`ProcessDirtyState`); every other call on L0 |
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
        default: false
        }
    }

    /// Diagnostics: BSD traps served without L0, and those that fell back.
    public static let bsdFastServed = Atomic<UInt64>(0)
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
        let generation = memory.generation
        let a = Array(frame.x[0..<8])
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
            return nil
        } catch {
            let e = errno(of: error, default: Errno.EINVAL)
            frame.x[0] = UInt64(UInt32(bitPattern: e))
            frame.x[1] = 0
            frame.carry = true
            Self.bsdFastServed.wrappingAdd(1, ordering: .relaxed)
            if tracing { log("trap bsd \(number) \(call) -> error \(e) (\(Errno.name(e)))") }
            if let profile { profile.noteHandler(TrapProfile.filtered(Int64(number), kernel: self), KernelClock.now() &- start) }
            if memory.generation != generation { frame.flushTLB = true }
            return .resume
        }
        guard let value = result else {
            Self.bsdFastDeclined.wrappingAdd(1, ordering: .relaxed)
            return nil
        }
        frame.x[0] = value
        frame.x[1] = 0
        frame.carry = false
        Self.bsdFastServed.wrappingAdd(1, ordering: .relaxed)
        if tracing { log("trap bsd \(number) \(call) -> \(hx(value))") }
        if let profile { profile.noteHandler(TrapProfile.filtered(Int64(number), kernel: self), KernelClock.now() &- start) }
        if memory.generation != generation { frame.flushTLB = true }
        return .resume
    }

    /// `__ulock_wait`, `__ulock_wait2`, `__ulock_wake` under the image's
    /// event lock only (`bsd-locking.md` §5): with the lock split, and
    /// without priority inheritance (`YCODE_SCHED_QOS`, whose pushes are
    /// L0 state). A wait sleeps on the event lock with no lock held.
    private func ulockFast(_ number: Int32, _ a: [UInt64], _ frame: inout TrapFrame, context: ThreadContext,
                           memory: any KernelGuestMemory, profileStart: UInt64) -> Outcome? {
        guard eventLock != nil, !SchedPolicy.qosEnabled else {
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
            // proc_info: the caller's own DIRTYCONTROL (ProcInfo.swift); the rest on L0.
            return procInfoFast(a, &call)

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
            guard let io = try? hostFileIO(int(0), writing: true, guardChecked: true) else { return nil }
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
            let count = Int(UInt32(truncatingIfNeeded: a[1]))
            if count >= 2, count <= 12 {
                let raw = try mem.read(va: a[0], count: 8)
                if raw.readLE(Int32.self, at: 0) == 1, raw.readLE(Int32.self, at: 4) == 14 { return nil }
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

        case 41:
            // dup: one table operation (a guarded descriptor falls back: its
            // guard violation is reported under L0).
            call.set("dup(\(int(0)))")
            if (try? fs.guardState(of: int(0))) ?? nil != nil { return nil }
            return UInt64(UInt32(bitPattern: try fs.dup(int(0))))

        case 381:
            // __mac_syscall: the Sandbox policy's check calls (2, 12) allow,
            // any other policy is ENOPOLICY; the Sandbox extension calls
            // fall back (`metadataCall`).
            let policy = (try? readString(a[0], length: 64, mem)) ?? "?"
            call.set("__mac_syscall(\"\(policy)\", \(int(1)), \(hx(a[2])))")
            if policy == "Sandbox" {
                guard int(1) == 2 || int(1) == 12 else { return nil }
                return 0
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
    /// a device node, a directory (its getdirentries cursor), a guarded
    /// descriptor, and for a descriptor that is not open (the locked path
    /// answers EBADF; rare, and its trace line is kept).
    private func fastClose(_ fd: Int32, context: ThreadContext) throws -> Bool {
        guard let file = try? fileSystem.removeIf(fd, { file, guarded in
            guard !guarded else { return false }
            switch file.node {
            case .console: return true
            case let .file(f): return !f.isDirectory
            case let .object(o): return o is DarwinDevice
            }
        }) ?? nil else { return false }
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
            if (try? fs.guardState(of: fd)) ?? nil != nil { return nil }
            _ = try fs.openFile(for: fd)  // EBADF first
            return UInt64(try fs.dup(fd, minimum: Int32(truncatingIfNeeded: arg), closeOnExec: cmd == 67))
        case Fcntl.getConfined:
            return try fs.openFile(for: fd).confinedToProcess ? 1 : 0
        case let c where Fcntl.hints.contains(c):
            _ = try fs.openFile(for: fd)
            return 0
        default:
            return nil
        }
    }
}
