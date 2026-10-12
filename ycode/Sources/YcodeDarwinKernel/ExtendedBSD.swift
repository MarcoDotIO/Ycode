import Foundation
import YcodeDarwinABI

// Stage-3b BSD calls that libc and the host libraries issue once
// `libsystem_kernel` has real wrappers: vectored I/O, user-space locks,
// entropy, signal and resource-limit bookkeeping, code-signing queries,
// directory enumeration, and the `*at` path calls. Numbers and argument
// orders come from `specs/simulator/data/bsd-syscalls.json`; structure
// layouts are the public Darwin ones (`sys/uio.h`, `sys/signal.h`,
// `sys/resource.h`, `sys/dirent.h`). There is one thread and no signal
// delivery yet: signal state is recorded, never acted on.

/// Bookkeeping behind the stage-3b calls.
struct ExtendedBSDState {
    struct SignalAction: Equatable {
        var handler: UInt64 = 0
        var mask: UInt32 = 0
        var flags: Int32 = 0
    }

    struct DirectoryCursor {
        var file: GuestFile
        var entries: [(name: String, ino: UInt64, type: UInt8)]
        var next = 0
    }

    var signalMask: UInt32 = 0
    /// Signals posted while a guest handler was installed (stage 4b: no
    /// delivery yet, `stage4b-contract.md` §2 item 5).
    var pendingSignals: UInt32 = 0
    var signalActions: [Int32: SignalAction] = [:]
    var alternateStack: (sp: UInt64, size: UInt64, flags: Int32) = (0, 0, DarwinKernel.SignalConstant.ssDisable)
    var rlimits: [Int32: (cur: UInt64, max: UInt64)] = [
        DarwinKernel.RLimit.stack: (8 << 20, 64 << 20),
        // As a simulator process sees on the Mac (level 3): soft 256, hard
        // unlimited; NPROC 6000/9000.
        DarwinKernel.RLimit.nofile: (256, DarwinKernel.RLimit.infinity),
        DarwinKernel.RLimit.nproc: (6000, 9000),
        DarwinKernel.RLimit.core: (0, DarwinKernel.RLimit.infinity),
    ]
    var umask: UInt16 = 0o022
    var directoryCursors: [Int32: DirectoryCursor] = [:]
}

extension DarwinKernel {
    /// Extra BSD numbers handled in this file.
    public enum BSD2 {
        public static let getppid = 39, sigaction = 46, sigprocmask = 48, sigaltstack = 53, umask = 60,
                          getrusage = 117, readv = 120, writev = 121, csops = 169, csopsAudittoken = 170,
                          getrlimit = 194, setrlimit = 195, access = 33, pthreadSigmask = 329, procInfo = 336,
                          getdirentries64 = 344, kevent = 363, kevent64 = 369, threadSelfid = 372,
                          keventQos = 374, keventId = 375, openat = 463, faccessat = 466, fstatat = 469,
                          fstatat64 = 470, getentropy = 500, ulockWait = 515, ulockWake = 516,
                          terminateWithPayload = 520, osFaultWithPayload = 529, ulockWait2 = 544,
                          kill = 37, pthreadKill = 328, semwaitSignal = 334, semwaitSignalNocancel = 423,
                          statfs64 = 345, fstatfs64 = 346, workqOpen = 367, workqKernreturn = 368, sendto = 133,
                          bsdthreadCreate = 360, bsdthreadTerminate = 361, bsdthreadCtl = 478,
                          kqueueWorkloopCtl = 530, disableThreadsignal = 331,
                          sigsuspend = 111, sigsuspendNocancel = 410,
                          getxattr = 234, fgetxattr = 235, setxattr = 236, fsetxattr = 237,
                          removexattr = 238, fremovexattr = 239, listxattr = 240, flistxattr = 241,
                          gettid = 286, openDprotectedNp = 216, openatDprotectedNp = 218
        /// psynch calls that wait (can never be woken on one thread).
        public static let psynchWaits: [Int: String] = [
            297: "psynch_rw_longrdlock", 298: "psynch_rw_yieldwrlock", 300: "psynch_rw_upgrade",
            301: "psynch_mutexwait", 305: "psynch_cvwait", 306: "psynch_rw_rdlock", 307: "psynch_rw_wrlock",
        ]
        /// psynch calls that wake or release (nobody ever waits).
        public static let psynchWakes: [Int: String] = [
            299: "psynch_rw_downgrade", 302: "psynch_mutexdrop", 303: "psynch_cvbroad", 304: "psynch_cvsignal",
            308: "psynch_rw_unlock", 309: "psynch_rw_unlock2", 312: "psynch_cvclrprepost",
        ]
    }

    /// `sys/resource.h`.
    public enum RLimit {
        public static let cpu: Int32 = 0, fsize: Int32 = 1, data: Int32 = 2, stack: Int32 = 3, core: Int32 = 4,
                          rss: Int32 = 5, memlock: Int32 = 6, nproc: Int32 = 7, nofile: Int32 = 8
        public static let infinity: UInt64 = 0x7FFF_FFFF_FFFF_FFFF
        /// `_RLIMIT_POSIX_FLAG`, or-ed into `which` by the POSIX-conforming wrappers.
        static let posixFlag: Int32 = 0x1000
    }

    public enum SignalConstant {
        public static let sigBlock: Int32 = 1, sigUnblock: Int32 = 2, sigSetmask: Int32 = 3
        public static let sigkill: Int32 = 9, sigstop: Int32 = 17
        public static let ssDisable: Int32 = 4
        /// Signals that can never be blocked.
        static let unblockable: UInt32 = (1 << 8) | (1 << 16)  // bits of SIGKILL and SIGSTOP
    }

    /// `__ulock_*` operation word.
    public enum ULock {
        public static let opMask: UInt32 = 0xFF
        public static let compareAndWait: UInt32 = 1
        public static let unfairLock: UInt32 = 2
        public static let compareAndWaitShared: UInt32 = 3
        public static let unfairLock64Shared: UInt32 = 4
        public static let compareAndWait64: UInt32 = 5
        public static let compareAndWait64Shared: UInt32 = 6
        public static let noErrno: UInt32 = 0x0100_0000
    }

    public static let atFDCWD: Int32 = -2
    static let atSymlinkNofollow: Int32 = 0x20
    static let ETIMEDOUT: Int32 = 60
    /// `ENOATTR` (sys/errno.h): the extended attribute does not exist.
    static let ENOATTR: Int32 = 93
    static let ENOTSOCK: Int32 = 38
    static let EDEADLK: Int32 = 11

    /// `getentropy` bytes from the host's /dev/urandom.
    public static func hostEntropy(_ count: Int) -> [UInt8] {
        if let h = FileHandle(forReadingAtPath: "/dev/urandom") {
            defer { try? h.close() }
            if let d = try? h.read(upToCount: count), d.count == count { return Array(d) }
        }
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }

    // MARK: Dispatch

    /// Handles the stage-3b calls; nil = not handled here.
    private func extendedAttributeCall(_ n: Int, _ a: [UInt64], _ call: inout String,
                                       _ mem: any KernelGuestMemory) throws -> UInt64 {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        let byDescriptor = [BSD2.fgetxattr, BSD2.fsetxattr, BSD2.fremovexattr, BSD2.flistxattr].contains(n)
        let options: Int32
        switch n {
        case BSD2.getxattr, BSD2.fgetxattr, BSD2.setxattr, BSD2.fsetxattr: options = int(5)
        case BSD2.removexattr, BSD2.fremovexattr: options = int(2)
        default: options = int(3)
        }
        let target: DarwinFileSystem.XattrTarget
        let subject: String
        if byDescriptor {
            target = .descriptor(int(0))
            subject = "fd \(int(0))"
        } else {
            let path = try readPath(a[0], mem)
            target = .path(path, followSymlinks: options & 0x1 == 0)
            subject = "\"\(path)\""
        }
        let fs = fileSystem
        switch n {
        case BSD2.listxattr, BSD2.flistxattr:
            call = "\(byDescriptor ? "flistxattr" : "listxattr")(\(subject), buf=\(hx(a[1])), size=\(a[2]))"
            let names = try fs.listExtendedAttributes(target)
            let bytes: [UInt8] = names.flatMap { name -> [UInt8] in Array(name.utf8) + [0] }
            if a[1] == 0 { return UInt64(bytes.count) }
            guard UInt64(bytes.count) <= a[2] else { throw Failure(errno: Errno.ERANGE) }
            if !bytes.isEmpty { try mem.write(va: a[1], bytes: bytes) }
            return UInt64(bytes.count)
        default:
            let name = try readString(a[1], length: 256, mem)
            switch n {
            case BSD2.getxattr, BSD2.fgetxattr:
                call = "\(byDescriptor ? "fgetxattr" : "getxattr")(\(subject), \"\(name)\", size=\(a[3]))"
                guard a[4] == 0 else { throw Failure(errno: Errno.EINVAL) }
                let value = try fs.getExtendedAttribute(target, name: name)
                if a[2] == 0 { return UInt64(value.count) }
                guard UInt64(value.count) <= a[3] else { throw Failure(errno: Errno.ERANGE) }
                if !value.isEmpty { try mem.write(va: a[2], bytes: value) }
                return UInt64(value.count)
            case BSD2.setxattr, BSD2.fsetxattr:
                call = "\(byDescriptor ? "fsetxattr" : "setxattr")(\(subject), \"\(name)\", size=\(a[3]), options=\(hx(UInt32(bitPattern: options))))"
                guard a[4] == 0, a[3] <= 1 << 26 else { throw Failure(errno: Errno.EINVAL) }
                let value: [UInt8] = a[3] == 0 ? [] : try mem.read(va: a[2], count: Int(a[3]))
                try fs.setExtendedAttribute(target, name: name, value: value, create: options & 0x2 != 0,
                                            replace: options & 0x4 != 0)
                return 0
            default:
                call = "\(byDescriptor ? "fremovexattr" : "removexattr")(\(subject), \"\(name)\")"
                try fs.removeExtendedAttribute(target, name: name)
                return 0
            }
        }
    }

    func extendedBSDCall(_ n: Int, _ a: [UInt64], _ call: inout String, _ fallback: inout Int32,
                         _ mem: any KernelGuestMemory) throws -> BSDResult? {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case BSD2.readv, BSD2.writev:
            return .value(try vectoredIO(write: n == BSD2.writev, a, &call, mem))

        case BSD2.ulockWait, BSD2.ulockWait2:
            return .value(try ulockWait(n, a, &call, mem))
        case BSD2.ulockWake:
            return .value(try ulockWake(a, &call))

        case BSD2.getentropy:
            call = "getentropy(buf=\(hx(a[0])), size=\(a[1]))"
            guard a[1] <= 256 else { throw Failure(errno: Errno.EINVAL) }
            if a[1] > 0 {
                var bytes = entropy(Int(a[1]))
                if bytes.count < Int(a[1]) { bytes += [UInt8](repeating: 0, count: Int(a[1]) - bytes.count) }
                try mem.write(va: a[0], bytes: Array(bytes.prefix(Int(a[1]))))
            }
            return .value(0)

        case BSD2.sigprocmask, BSD2.pthreadSigmask:
            call = "\(n == BSD2.sigprocmask ? "sigprocmask" : "__pthread_sigmask")(how=\(int(0)), set=\(hx(a[1])), oset=\(hx(a[2])))"
            let old = extended.signalMask
            if a[1] != 0 {
                let set = try mem.read(va: a[1], count: 4).readLE(UInt32.self, at: 0)
                switch int(0) {
                case SignalConstant.sigBlock: extended.signalMask |= set
                case SignalConstant.sigUnblock: extended.signalMask &= ~set
                case SignalConstant.sigSetmask: extended.signalMask = set
                default: throw Failure(errno: Errno.EINVAL)
                }
                extended.signalMask &= ~SignalConstant.unblockable
                call += " [mask \(hx(extended.signalMask))]"
            }
            if a[2] != 0 { try writeU32(a[2], old, mem) }
            return .value(0)

        case BSD2.sigaction:
            return .value(try sigaction(a, &call, mem))

        case BSD2.sigaltstack:
            call = "sigaltstack(nss=\(hx(a[0])), oss=\(hx(a[1])))"
            let old = extended.alternateStack
            if a[0] != 0 {
                let b = try mem.read(va: a[0], count: 24)
                extended.alternateStack = (b.readLE(UInt64.self, at: 0), b.readLE(UInt64.self, at: 8),
                                           b.readLE(Int32.self, at: 16))
            }
            if a[1] != 0 {
                var b: [UInt8] = []
                b.appendLE(old.sp)
                b.appendLE(old.size)
                b.appendLE(old.flags)
                b.appendLE(Int32(0))
                try mem.write(va: a[1], bytes: b)
            }
            return .value(0)

        case BSD2.getrlimit, BSD2.setrlimit:
            let which = int(0) & ~RLimit.posixFlag
            let isGet = n == BSD2.getrlimit
            call = "\(isGet ? "getrlimit" : "setrlimit")(which=\(which), rlp=\(hx(a[1])))"
            guard (0...8).contains(which) else { throw Failure(errno: Errno.EINVAL) }
            if isGet {
                let l = extended.rlimits[which] ?? (RLimit.infinity, RLimit.infinity)
                var b: [UInt8] = []
                b.appendLE(l.cur)
                b.appendLE(l.max)
                try mem.write(va: a[1], bytes: b)
                call += " [cur \(hx(l.cur)) max \(hx(l.max))]"
            } else {
                let b = try mem.read(va: a[1], count: 16)
                let cur = b.readLE(UInt64.self, at: 0), max = b.readLE(UInt64.self, at: 8)
                guard cur <= max else { throw Failure(errno: Errno.EINVAL) }
                let old = extended.rlimits[which] ?? (RLimit.infinity, RLimit.infinity)
                guard max <= old.max else { throw Failure(errno: Errno.EPERM) }
                extended.rlimits[which] = (cur, max)
                if which == RLimit.nofile { fileSystem.maxDescriptors = Int32(min(cur, 10240)) }
                call += " [cur \(hx(cur)) max \(hx(max))]"
            }
            return .value(0)

        case BSD2.csops, BSD2.csopsAudittoken:
            call = "\(n == BSD2.csops ? "csops" : "csops_audittoken")(pid=\(int(0)), ops=\(int(1)), addr=\(hx(a[2])), size=\(a[3]))"
            return .value(try csopsCall(n == BSD2.csopsAudittoken, a, &call, mem))

        case BSD2.procInfo:
            call = "proc_info(callnum=\(int(0)), pid=\(int(1)), flavor=\(int(2)), arg=\(hx(a[3])), buffer=\(hx(a[4])), "
                + "buffersize=\(int(5)))"
            log("note: proc_info call \(int(0)) flavor \(int(2)) is not supported")
            throw Failure(errno: Errno.ENOTSUP)

        case BSD2.getdirentries64:
            return .value(try getdirentries64(a, &call, mem))

        case BSD2.kevent, BSD2.kevent64, BSD2.keventQos, BSD2.keventId:
            return .value(try keventCall(n, a, &call, mem))

        case BSD2.kqueueWorkloopCtl:
            return .value(try kqueueWorkloopCtl(a, &call, mem))

        case BSD2.bsdthreadCreate:
            return try bsdthreadCreate(a, &call, mem)
        case BSD2.bsdthreadTerminate:
            return try bsdthreadTerminate(a, &call, mem)
        case BSD2.bsdthreadCtl:
            return .value(try bsdthreadCtl(a, &call, mem))

        case BSD2.kill, BSD2.pthreadKill:
            let isKill = n == BSD2.kill
            let sig = int(1)
            let target = UInt32(truncatingIfNeeded: a[0])
            call = isKill ? "kill(pid=\(int(0)), sig=\(sig), posix=\(int(2)))" : "__pthread_kill(thread=\(hx(target)), sig=\(sig))"
            if isKill {
                guard int(0) == pid || int(0) == 0 || int(0) == -1 || int(0) == -pid else { throw Failure(errno: Errno.ESRCH) }
            } else {
                guard let thread = threadsByPort[target] else { throw Failure(errno: Errno.ESRCH) }
                guard (0...31).contains(sig) else { throw Failure(errno: Errno.EINVAL) }
                if sig == 0 { return .value(0) }
                if thread !== current {
                    log("note: __pthread_kill(\(sig)) to \(thread): no cross-thread signal delivery in stage 4a; dropped")
                    call += " [dropped]"
                    return .value(0)
                }
            }
            guard (0...31).contains(sig) else { throw Failure(errno: Errno.EINVAL) }
            if sig == 0 { return .value(0) }
            return signalSelf(sig, &call)

        case BSD2.sigsuspend, BSD2.sigsuspendNocancel:
            // Replace the mask, wait until a signal is deliverable to this
            // thread (none can be in stage 4a: only `KernelLock.interrupt`
            // or the process ending wakes it), restore the mask. Always EINTR.
            let mask = UInt32(truncatingIfNeeded: a[0])
            call = "\(n == BSD2.sigsuspend ? "sigsuspend" : "__sigsuspend_nocancel")(mask=\(hx(mask)))"
            let old = extended.signalMask
            extended.signalMask = mask & ~SignalConstant.unblockable
            // Stage 4b: a pending signal the new mask lets through ends the
            // wait (its handler is not run; the signal is consumed).
            var result = WaitResult.woken
            while extended.pendingSignals & ~extended.signalMask == 0 {
                result = signalWaiters.wait(on: lock, deadline: nil)
                if result == .interrupted { break }
            }
            extended.pendingSignals &= extended.signalMask
            extended.signalMask = old
            call += " [\(result == .interrupted ? "interrupted" : "woken")]"
            throw Failure(errno: Self.EINTR)

        case BSD2.disableThreadsignal:
            call = "__disable_threadsignal(\(int(0)))"
            return .value(0)

        case BSD2.semwaitSignal, BSD2.semwaitSignalNocancel:
            call = "__semwait_signal(cond=\(hx(UInt32(truncatingIfNeeded: a[0]))), mutex=\(hx(UInt32(truncatingIfNeeded: a[1]))), "
                + "timeout=\(int(2)), relative=\(int(3)), sec=\(Int64(bitPattern: a[4])), nsec=\(int(5)))"
            return .value(try semwaitSignal(a, &call))

        case let n where BSD2.psynchWaits[n] != nil:
            let name = BSD2.psynchWaits[n]!
            call = "\(name)(\(hx(a[0])), \(hx(a[1])), \(hx(a[2])), \(hx(a[3])), \(hx(a[4])))"
            log("DEADLOCK?: \(name) on \(hx(a[0])) would block the only thread; returning ENOTSUP")
            throw Failure(errno: Errno.ENOTSUP)

        case let n where BSD2.psynchWakes[n] != nil:
            call = "\(BSD2.psynchWakes[n]!)(\(hx(a[0])), \(hx(a[1])), \(hx(a[2])), \(hx(a[3])), \(hx(a[4])))"
            call += " [no waiters on one thread]"
            return .value(0)

        case BSD2.workqOpen:
            call = "workq_open()"
            guard threadRegistration != nil else { throw Failure(errno: Errno.EINVAL) }
            workqueue.isOpen = true
            return .value(0)
        case BSD2.workqKernreturn:
            return try workqKernreturn(a, &call, mem)

        case BSD2.statfs64, BSD2.fstatfs64:
            let path: String
            if n == BSD2.statfs64 {
                path = try fileSystem.realpath(try readPath(a[0], mem))
                call = "statfs64(\"\(path)\", buf=\(hx(a[1])))"
            } else {
                path = try fileSystem.path(for: int(0))
                call = "fstatfs64(fd=\(int(0)), buf=\(hx(a[1]))) [\(path)]"
            }
            let st = n == BSD2.statfs64 ? try fileSystem.stat(path, followSymlinks: true) : try fileSystem.fstat(int(0))
            try mem.write(va: a[1], bytes: statfs64Bytes(guestPath: path, dev: st.dev))
            return .value(0)

        case BSD2.threadSelfid:
            call = "thread_selfid()"
            return .value(current.threadID)

        case BSD2.getppid:
            call = "getppid()"
            return .value(1)

        case BSD2.umask:
            call = "umask(0o\(String(a[0] & 0o777, radix: 8)))"
            let old = extended.umask
            extended.umask = UInt16(a[0] & 0o777)
            return .value(UInt64(old))

        case BSD2.getrusage:
            call = "getrusage(who=\(int(0)), rusage=\(hx(a[1])))"
            try mem.write(va: a[1], bytes: [UInt8](repeating: 0, count: 144))
            return .value(0)

        case BSD2.access, BSD2.faccessat:
            let isAt = n == BSD2.faccessat
            let path = try resolveAtPath(isAt ? int(0) : Self.atFDCWD, isAt ? a[1] : a[0], mem)
            let mode = isAt ? int(2) : int(1)
            call = isAt ? "faccessat(\(int(0)), \"\(path)\", mode=\(mode), flag=\(hx(a[3])))" : "access(\"\(path)\", mode=\(mode))"
            let follow = !isAt || int(3) & Self.atSymlinkNofollow == 0
            _ = try statUnlocked(path, followSymlinks: follow)
            return .value(0)

        // Extended attributes (sys/xattr.h, getxattr(2), setxattr(2),
        // listxattr(2), removexattr(2)): kept as host extended attributes
        // (`DarwinFileSystem` "Extended attributes"). options: XATTR_NOFOLLOW
        // 0x1, XATTR_CREATE 0x2, XATTR_REPLACE 0x4; `position` (resource
        // forks) must be 0.
        case BSD2.getxattr, BSD2.fgetxattr, BSD2.setxattr, BSD2.fsetxattr,
             BSD2.removexattr, BSD2.fremovexattr, BSD2.listxattr, BSD2.flistxattr:
            return .value(try extendedAttributeCall(n, a, &call, mem))

        // gettid (pthread_getugid_np): a thread without an override identity
        // (every Ycode thread) gets ESRCH (xnu bsd/kern/kern_prot.c).
        case BSD2.gettid:
            call = "gettid(uidp=\(hx(a[0])), gidp=\(hx(a[1])))"
            throw Failure(errno: Errno.ESRCH)

        case BSD2.fstatat, BSD2.fstatat64:
            let path = try resolveAtPath(int(0), a[1], mem)
            call = "fstatat64(\(int(0)), \"\(path)\", buf=\(hx(a[2])), flag=\(hx(a[3])))"
            let st = try statUnlocked(path, followSymlinks: int(3) & Self.atSymlinkNofollow == 0)
            try mem.write(va: a[2], bytes: st.encodedStat64())
            return .value(0)

        case BSD2.openat:
            let path = try resolveAtPath(int(0), a[1], mem)
            call = "openat(\(int(0)), \"\(path)\", flags=\(openFlagsText(int(2))), mode=0o\(String(a[3] & 0o7777, radix: 8)))"
            let newFD = try openUnlocked(path, flags: int(2), mode: UInt16(truncatingIfNeeded: a[3]))
            extended.directoryCursors[newFD] = nil
            return .value(UInt64(UInt32(bitPattern: newFD)))

        // open_dprotected_np / openat_dprotected_np (sys/fcntl.h): an open
        // that also names a data-protection class, which a newly created
        // file gets (FileLocks.swift); the dpflags as on the simulator's
        // host volume (checkDataProtectionOpen).
        case BSD2.openDprotectedNp, BSD2.openatDprotectedNp:
            let at = n == BSD2.openatDprotectedNp
            let path = try resolveAtPath(at ? int(0) : Self.atFDCWD, at ? a[1] : a[0], mem)
            let base = at ? 2 : 1
            let flags = int(base), dpclass = int(base + 1), dpflags = int(base + 2)
            call = "\(at ? "openat_dprotected_np(\(int(0)), " : "open_dprotected_np(")\"\(path)\", "
                + "flags=\(openFlagsText(flags)), class=\(dpclass), dpflags=\(hx(UInt64(UInt32(bitPattern: dpflags)))), "
                + "mode=0o\(String(a[base + 3] & 0o7777, radix: 8)))"
            try checkDataProtectionOpen(flags: flags, dpflags: dpflags)
            let created = (try? fileSystem.stat(path, followSymlinks: true)) == nil
            let newFD = try fileSystem.open(path, flags: flags, mode: UInt16(truncatingIfNeeded: a[base + 3]))
            if created { noteCreatedWithClass(newFD, dpclass) }
            extended.directoryCursors[newFD] = nil
            return .value(UInt64(UInt32(bitPattern: newFD)))

        case BSD2.terminateWithPayload:
            let reason = a[5] == 0 ? "" : ((try? readString(a[5], length: 4096, mem)) ?? "<unreadable>")
            call = "terminate_with_payload(pid=\(int(0)), namespace=\(int(1)), code=\(hx(a[2])))"
            return .fatal(Self.abortExitStatus, "terminate_with_payload: namespace \(int(1)) code \(hx(a[2])): \(reason)")

        case BSD2.osFaultWithPayload:
            let reason = a[4] == 0 ? "" : ((try? readString(a[4], length: 4096, mem)) ?? "<unreadable>")
            call = "os_fault_with_payload(namespace=\(int(0)), code=\(hx(a[1]))) [\(reason)]"
            return .value(0)

        default:
            return nil
        }
    }

    // MARK: __semwait_signal

    /// Signals `mutex` (when non-zero), then waits on the semaphore `cond`
    /// (or just sleeps when `cond` is 0) until signalled, the timeout, or an
    /// interruption.
    private func semwaitSignal(_ a: [UInt64], _ call: inout String) throws -> UInt64 {
        let cond = UInt32(truncatingIfNeeded: a[0]), mutex = UInt32(truncatingIfNeeded: a[1])
        var deadline: UInt64?
        if Int32(truncatingIfNeeded: a[2]) != 0 {
            let sec = Int64(bitPattern: a[4]), nsec = Int64(Int32(truncatingIfNeeded: a[5]))
            guard sec >= 0, (0..<1_000_000_000).contains(nsec) else { throw Failure(errno: Errno.EINVAL) }
            var ns = sec.multipliedReportingOverflow(by: 1_000_000_000).overflow ? Int64.max : sec * 1_000_000_000 + nsec
            if Int32(truncatingIfNeeded: a[3]) == 0 {
                // Absolute: calendar time.
                let w = wallClock()
                ns -= w.seconds * 1_000_000_000 + w.nanoseconds
            }
            deadline = KernelClock.deadline(afterNanoseconds: UInt64(max(0, ns)))
        }
        if mutex != 0 {
            guard let m = semaphore(named: mutex) else { throw Failure(errno: Errno.EINVAL) }
            m.signal()
        }
        let result: WaitResult
        if cond != 0 {
            guard let c = semaphore(named: cond) else { throw Failure(errno: Errno.EINVAL) }
            switch c.wait(lock: lock, deadline: deadline) {
            case KernReturn.success: return 0
            case KernReturn.operationTimedOut: result = .timedOut
            default: result = .interrupted
            }
        } else {
            result = WaitQueue().wait(on: lock, deadline: deadline)
        }
        switch result {
        case .timedOut: throw Failure(errno: Self.ETIMEDOUT)
        case .interrupted: throw Failure(errno: Self.EINTR)
        case .woken: return 0
        }
    }

    // MARK: statfs64

    /// `struct statfs` (64-bit inode form, 2168 bytes) for the VFS prefix
    /// that serves `guestPath`: a local file system, read-only unless the
    /// prefix is writable.
    func statfs64Bytes(guestPath: String, dev: UInt32) -> [UInt8] {
        let prefix = fileSystem.prefixes
            .filter { guestPath == $0.guestPath || guestPath.hasPrefix($0.guestPath == "/" ? "/" : $0.guestPath + "/") }
            .max { $0.guestPath.count < $1.guestPath.count }
        let mountPoint = prefix?.guestPath ?? "/"
        let readOnly = !(prefix?.writable ?? false)
        // Sizes and free space are the host volume's (as on the Mac, where a
        // read-only system volume still reports its container's free space;
        // level 3: a simulator process's statfs of "/"). Fallback: fixed values.
        var blocks: UInt64 = 1 << 24, free: UInt64 = 1 << 23, files: UInt64 = 1 << 20, ffree: UInt64 = 1 << 19
        var vfs = statvfs()
        if statvfs(prefix?.hostPath ?? "/", &vfs) == 0, vfs.f_frsize > 0 {
            // In 4096-byte blocks (f_bsize), whatever the host's fragment size.
            let unit = UInt64(vfs.f_frsize)
            blocks = UInt64(vfs.f_blocks).multipliedReportingOverflow(by: unit).partialValue / 4096
            free = UInt64(vfs.f_bavail).multipliedReportingOverflow(by: unit).partialValue / 4096
            files = UInt64(vfs.f_files)
            ffree = UInt64(vfs.f_ffree)
        }
        var b = [UInt8](repeating: 0, count: 2168)
        b.putLE(UInt32(4096), at: 0)                // f_bsize
        b.putLE(Int32(1 << 20), at: 4)              // f_iosize
        b.putLE(blocks, at: 8)                      // f_blocks
        b.putLE(free, at: 16)                       // f_bfree
        b.putLE(free, at: 24)                       // f_bavail
        b.putLE(files, at: 32)                      // f_files
        b.putLE(ffree, at: 40)                      // f_ffree
        // f_fsid {dev, type}, as getattrlist's ATTR_CMN_FSID; the synthetic
        // "/" (no host file, dev 0) reports the system volume's device.
        let fsDev = dev != 0 ? dev : (try? fileSystem.stat(prefix?.guestPath ?? "/System", followSymlinks: true).dev) ?? 1
        b.putLE(fsDev, at: 48)                      // f_fsid.val[0]
        b.putLE(UInt32(0x1A), at: 52)               // f_fsid.val[1]
        b.putLE(UInt32(0), at: 56)                  // f_owner
        b.putLE(UInt32(0x1A), at: 60)               // f_type
        // MNT_RDONLY, MNT_LOCAL, MNT_ROOTFS for "/", MNT_DOVOLFS, MNT_JOURNALED.
        b.putLE(UInt32((readOnly ? 0x1 : 0) | 0x1000 | (mountPoint == "/" ? 0x4000 : 0) | 0x8000 | 0x80_0000), at: 64)
        b.putLE(UInt32(1), at: 68)                  // f_fssubtype (as the Mac's APFS volumes)
        b.put(Array("apfs".utf8), at: 72)           // f_fstypename[16]
        b.put(Array(mountPoint.utf8.prefix(1023)), at: 88)       // f_mntonname[1024]
        b.put(Array("ycode-vfs".utf8), at: 1112)    // f_mntfromname[1024]
        return b
    }

    // MARK: Signals to the process itself

    /// No delivery yet: an ignored signal is dropped, a default action ends
    /// the guest (status 128 + signal, as a shell reports it), and a caught
    /// signal is logged and dropped.
    private func signalSelf(_ sig: Int32, _ call: inout String) -> BSDResult {
        let names: [Int32: String] = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
                                      8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE", 14: "SIGALRM",
                                      15: "SIGTERM"]
        let name = names[sig] ?? "signal \(sig)"
        let handler = extended.signalActions[sig]?.handler ?? 0
        // Signals whose default action is to ignore them.
        let ignoredByDefault: Set<Int32> = [16, 18, 20, 23, 28, 29]
        if handler == 1 || (handler == 0 && ignoredByDefault.contains(sig)) {
            call += " [\(name) ignored]"
            return .value(0)
        }
        if handler == 0 || sig == SignalConstant.sigkill || sig == SignalConstant.sigstop {
            call += " [\(name): default action, the guest terminates]"
            return .fatal(128 + sig, "guest terminated by \(name) (no signal delivery yet; default action)")
        }
        log("note: \(name) has a handler at \(hx(handler)); signal delivery is not implemented, dropped")
        call += " [\(name) caught by \(hx(handler)); dropped]"
        return .value(0)
    }

    // MARK: readv / writev

    private func vectoredIO(write: Bool, _ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let fd = Int32(truncatingIfNeeded: a[0])
        let count = Int32(truncatingIfNeeded: a[2])
        call = "\(write ? "writev" : "readv")(fd=\(fd), iov=\(hx(a[1])), iovcnt=\(count))"
        guard count > 0, count <= 1024 else { throw Failure(errno: Errno.EINVAL) }
        let raw = try mem.read(va: a[1], count: 16 * Int(count))
        var iov: [(base: UInt64, length: UInt64)] = []
        var total: UInt64 = 0
        for i in 0..<Int(count) {
            let base = raw.readLE(UInt64.self, at: 16 * i), length = raw.readLE(UInt64.self, at: 16 * i + 8)
            total += length
            guard total <= UInt64(Int32.max) else { throw Failure(errno: Errno.EINVAL) }
            iov.append((base, length))
        }
        if write {
            var bytes: [UInt8] = []
            for v in iov where v.length > 0 { bytes += try mem.read(va: v.base, count: Int(v.length)) }
            return UInt64(try fileSystem.write(fd, bytes))
        }
        let data = try fileSystem.read(fd, count: Int(total))
        var offset = 0
        for v in iov where offset < data.count && v.length > 0 {
            let n = min(Int(v.length), data.count - offset)
            try mem.write(va: v.base, bytes: Array(data[offset..<(offset + n)]))
            offset += n
        }
        return UInt64(data.count)
    }

    // MARK: sigaction

    private func sigaction(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let signum = Int32(truncatingIfNeeded: a[0])
        call = "sigaction(\(signum), nsa=\(hx(a[1])), osa=\(hx(a[2])))"
        guard (1...31).contains(signum) else { throw Failure(errno: Errno.EINVAL) }
        let old = extended.signalActions[signum] ?? ExtendedBSDState.SignalAction()
        if a[1] != 0 {
            guard signum != SignalConstant.sigkill, signum != SignalConstant.sigstop else {
                throw Failure(errno: Errno.EINVAL)
            }
            // struct __sigaction: handler, trampoline, mask (u32), flags (i32).
            let b = try mem.read(va: a[1], count: 24)
            let action = ExtendedBSDState.SignalAction(handler: b.readLE(UInt64.self, at: 0),
                                                       mask: b.readLE(UInt32.self, at: 16),
                                                       flags: b.readLE(Int32.self, at: 20))
            extended.signalActions[signum] = action
            // SIG_IGN (or SIG_DFL of a signal ignored by default) discards pending instances.
            if action.handler == 1 || (action.handler == 0 && Signal.ignoredByDefault.contains(signum)) {
                extended.pendingSignals &= ~(1 << UInt32(signum - 1))
            }
            call += " [handler \(hx(action.handler)) flags \(hx(UInt32(bitPattern: action.flags)))]"
        }
        if a[2] != 0 {
            // struct sigaction: handler, mask (u32), flags (i32).
            var b: [UInt8] = []
            b.appendLE(old.handler)
            b.appendLE(old.mask)
            b.appendLE(old.flags)
            try mem.write(va: a[2], bytes: b)
        }
        return 0
    }

    // MARK: Paths relative to a directory descriptor

    func resolveAtPath(_ dirfd: Int32, _ pointer: UInt64, _ mem: any KernelGuestMemory) throws -> String {
        let path = try readPath(pointer, mem)
        if path.hasPrefix("/") || dirfd == Self.atFDCWD { return path }
        guard !path.isEmpty else { throw Failure(errno: Errno.ENOENT) }
        let base = try fileSystem.path(for: dirfd)
        guard try fileSystem.fstat(dirfd).isDirectory else { throw Failure(errno: Errno.ENOTDIR) }
        return base == "/" ? "/" + path : base + "/" + path
    }

    // MARK: getdirentries64

    /// `struct dirent` (64-bit inodes): d_ino u64, d_seekoff u64, d_reclen
    /// u16, d_namlen u16, d_type u8, d_name (NUL-terminated); records are
    /// 8-byte aligned. With a buffer of at least 1024 bytes the last 4 bytes
    /// carry the flags word (bit 0 = end of directory), as the libc reader
    /// expects. `*position` receives the offset before the read.
    private func getdirentries64(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let fd = Int32(truncatingIfNeeded: a[0])
        let bufferSize = Int(min(a[2], 1 << 20))
        call = "getdirentries64(fd=\(fd), buf=\(hx(a[1])), bufsize=\(a[2]), position=\(hx(a[3])))"
        let file = try fileSystem.file(for: fd)
        guard file.isDirectory else { throw Failure(errno: Errno.ENOTDIR) }
        if extended.directoryCursors[fd].map({ $0.file !== file }) ?? true {
            extended.directoryCursors[fd] = .init(file: file, entries: try listDirectory(fd: fd, file: file))
        }
        var cursor = extended.directoryCursors[fd]!
        let extendedBuffer = bufferSize >= 1024
        let capacity = extendedBuffer ? bufferSize - 4 : bufferSize
        let start = cursor.next
        var out: [UInt8] = []
        while cursor.next < cursor.entries.count {
            let e = cursor.entries[cursor.next]
            let name = Array(e.name.utf8)
            let length = (21 + name.count + 1 + 7) & ~7
            if out.count + length > capacity { break }
            var r: [UInt8] = []
            r.appendLE(e.ino)
            r.appendLE(UInt64(cursor.next + 1))
            r.appendLE(UInt16(length))
            r.appendLE(UInt16(name.count))
            r.append(e.type)
            r += name
            r += [UInt8](repeating: 0, count: length - r.count)
            out += r
            cursor.next += 1
        }
        if out.isEmpty && cursor.next < cursor.entries.count { throw Failure(errno: Errno.EINVAL) }
        extended.directoryCursors[fd] = cursor
        if !out.isEmpty { try mem.write(va: a[1], bytes: out) }
        if extendedBuffer {
            let eof: UInt32 = cursor.next >= cursor.entries.count ? 1 : 0
            try writeU32(a[1] + UInt64(bufferSize - 4), eof, mem)
        }
        if a[3] != 0 { try writeU64(a[3], UInt64(start), mem) }
        call += " [\(cursor.next - start) entries]"
        return UInt64(out.count)
    }

    /// The entries of an open directory. The descriptor is read with the
    /// kernel lock; the host listing and the per-entry stats run without it
    /// (stage6-contract.md §5.1).
    private func listDirectory(fd: Int32, file: GuestFile) throws -> [(name: String, ino: UInt64, type: UInt8)] {
        let selfStat = try fileSystem.fstat(fd)
        let fileSystem = self.fileSystem
        return try lock.unlocked { try Self.listDirectory(file: file, selfStat: selfStat, fileSystem: fileSystem) }
    }

    private static func listDirectory(file: GuestFile, selfStat: DarwinStat,
                                      fileSystem: DarwinFileSystem) throws -> [(name: String, ino: UInt64, type: UInt8)] {
        let dir = file.guestPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: file.hostPath) else {
            throw Failure(errno: Errno.EIO)
        }
        var entries: [(name: String, ino: UInt64, type: UInt8)] = []
        entries.append((".", selfStat.ino, 4))
        let parent = (dir as NSString).deletingLastPathComponent
        let parentIno = (try? fileSystem.stat(parent.isEmpty ? "/" : parent, followSymlinks: true).ino) ?? selfStat.ino
        entries.append(("..", parentIno, 4))
        for name in names.sorted() {
            guard let st = try? fileSystem.stat(dir == "/" ? "/" + name : dir + "/" + name, followSymlinks: false) else { continue }
            let type: UInt8 = switch st.fileType {
            case DarwinStat.S_IFDIR: 4
            case DarwinStat.S_IFREG: 8
            case DarwinStat.S_IFLNK: 10
            case DarwinStat.S_IFCHR: 2
            case DarwinStat.S_IFBLK: 6
            case DarwinStat.S_IFIFO: 1
            case DarwinStat.S_IFSOCK: 12
            default: 0
            }
            entries.append((name, st.ino, type))
        }
        return entries
    }
}
