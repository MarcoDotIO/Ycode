import Foundation
import YcodeDarwinABI

/// The guest memory the kernel works on: EL0-checked reads and writes plus
/// the mapping operations (`GuestAddressSpace` implements both).
public typealias KernelGuestMemory = GuestVirtualMemory

/// The Darwin kernel personality of stage 3a (`specs/simulator/stage3-contract.md`
/// §5 private traps, §8 trap coverage). One instance serves one guest task.
///
/// `handle(_:memory:)` decodes `x16` in this order: the Ycode-private range
/// `0x7963_0000…0x7963_FFFF`, the platform call `0x8000_0000` (sub-selector
/// in `x3`), Mach traps (negative), then BSD calls (low 16 bits; `x16 = 0`
/// is the indirect call). BSD failures set carry, `x0` = errno, `x1` = 0.
/// Mach traps return a `kern_return_t` (or a port name) in `x0` and leave
/// carry alone. Every trap produces exactly one log line.
public final class DarwinKernel {
    // MARK: Outcome

    public enum Outcome: Equatable, Sendable {
        /// Re-enter the vCPU with the edited frame.
        case resume
        /// The guest called `exit`; the VMM exits with `status`.
        case exit(status: Int32)
        /// A fatal guest condition (`abort_with_payload` = 134, a non-SVC
        /// exception = 70). `message` is the decoded report.
        case fatal(status: Int32, message: String)
        /// A trap Ycode does not implement. The frame already holds a failure
        /// result (ENOSYS with carry for BSD, `KERN_FAILURE` or a null port
        /// for Mach), so the VMM may resume; in `--trace` mode it exits 72.
        case unimplemented(description: String)
    }

    /// The VMM's exit status for an unimplemented trap in trace mode.
    public static let unimplementedExitStatus: Int32 = 72
    public static let abortExitStatus: Int32 = 134
    public static let exceptionExitStatus: Int32 = 70

    // MARK: Constants

    /// Darwin errno values used by the kernel.
    public enum Errno {
        public static let EPERM: Int32 = 1
        public static let ENOENT: Int32 = 2
        public static let EBADF: Int32 = 9
        public static let ENOMEM: Int32 = 12
        public static let EFAULT: Int32 = 14
        public static let EINVAL: Int32 = 22
        public static let ENOTTY: Int32 = 25
        public static let ERANGE: Int32 = 34
        public static let ENOTSUP: Int32 = 45
        public static let ENAMETOOLONG: Int32 = 63
        public static let ENOSYS: Int32 = 78

        static let names: [Int32: String] = [
            1: "EPERM", 2: "ENOENT", 4: "EINTR", 5: "EIO", 9: "EBADF", 12: "ENOMEM", 13: "EACCES", 14: "EFAULT",
            17: "EEXIST", 19: "ENODEV", 20: "ENOTDIR", 21: "EISDIR", 22: "EINVAL", 24: "EMFILE", 25: "ENOTTY",
            28: "ENOSPC", 29: "ESPIPE", 30: "EROFS", 34: "ERANGE", 35: "EAGAIN", 45: "ENOTSUP", 62: "ELOOP",
            63: "ENAMETOOLONG", 66: "ENOTEMPTY", 78: "ENOSYS", 84: "EOVERFLOW",
        ]

        public static func name(_ e: Int32) -> String { names[e] ?? "errno \(e)" }
    }

    /// `kern_return_t` values.
    public enum KernReturn {
        public static let success: UInt64 = 0
        public static let invalidAddress: UInt64 = 1
        public static let protectionFailure: UInt64 = 2
        public static let noSpace: UInt64 = 3
        public static let invalidArgument: UInt64 = 4
        public static let failure: UInt64 = 5
        public static let invalidName: UInt64 = 15
        /// `MACH_SEND_INVALID_DEST`, what `mach_msg` returns in stage 3a.
        public static let sendInvalidDest: UInt64 = 0x1000_0003

        static func name(_ k: UInt64) -> String {
            switch k {
            case success: "KERN_SUCCESS"
            case invalidAddress: "KERN_INVALID_ADDRESS"
            case protectionFailure: "KERN_PROTECTION_FAILURE"
            case noSpace: "KERN_NO_SPACE"
            case invalidArgument: "KERN_INVALID_ARGUMENT"
            case failure: "KERN_FAILURE"
            case invalidName: "KERN_INVALID_NAME"
            case sendInvalidDest: "MACH_SEND_INVALID_DEST"
            default: hx(k)
            }
        }
    }

    /// BSD call numbers handled here.
    public enum BSD {
        public static let exit = 1, read = 3, write = 4, open = 5, close = 6, getpid = 20, getuid = 24,
                          geteuid = 25, getegid = 43, getgid = 47, ioctl = 54, munmap = 73, mprotect = 74,
                          madvise = 75, fcntl = 92, gettimeofday = 116, pread = 153, mmap = 197, sysctl = 202,
                          getattrlist = 220, sysctlbyname = 274, issetugid = 327, stat64 = 338, fstat64 = 339,
                          lstat64 = 340, getfsstat64 = 347, fsgetpath = 427, getattrlistbulk = 461,
                          abortWithPayload = 521
    }

    /// Mach trap numbers handled here (negative x16).
    public enum Mach {
        public static let machAbsoluteTime = -3, machContinuousTime = -4, vmAllocate = -10, vmDeallocate = -12,
                          vmProtect = -14, portAllocate = -16, portDeallocate = -18, portInsertRight = -21,
                          portConstruct = -24, portDestruct = -25, replyPort = -26, threadSelf = -27,
                          taskSelf = -28, hostSelf = -29, machMsg = -31, threadSwitch = -61, timebaseInfo = -89
    }

    /// Ycode-private trap numbers (`x16`, stage3-contract.md §5).
    public enum Private {
        public static let rangeStart: UInt32 = 0x7963_0000
        public static let rangeEnd: UInt32 = 0x7963_FFFF
        public static let vlog: UInt32 = 0x7963_0001
        public static let realpath: UInt32 = 0x7963_0002
        public static let getcwd: UInt32 = 0x7963_0003
        public static let vmCopy: UInt32 = 0x7963_0004
        public static let procRegionFilename: UInt32 = 0x7963_0005
        public static let taskInfo: UInt32 = 0x7963_0006
        public static let threadInfo: UInt32 = 0x7963_0007
        public static let machMsgDestroy: UInt32 = 0x7963_0008
        public static let sysctlbyname: UInt32 = 0x7963_0009
        public static let notifyImageListChanges: UInt32 = 0x7963_0010
        public static let notifyMainCalled: UInt32 = 0x7963_0011
        public static let notifyBeforeInitializers: UInt32 = 0x7963_0012
    }

    public static let platformCall: UInt32 = 0x8000_0000

    /// Darwin `mmap` flag bits.
    public enum MapFlag {
        public static let shared: Int32 = 0x1
        public static let `private`: Int32 = 0x2
        public static let fixed: Int32 = 0x10
        public static let anonymous: Int32 = 0x1000
    }

    /// `fcntl` commands.
    public enum Fcntl {
        public static let getfd: Int32 = 1
        public static let setfd: Int32 = 2
        public static let getfl: Int32 = 3
        public static let getpath: Int32 = 50
        public static let addFileSigsReturn: Int32 = 97
        public static let checkLV: Int32 = 98
    }

    public static let pageSize: UInt64 = 0x4000
    static let pageMask: UInt64 = pageSize - 1
    /// `VM_FLAGS_ANYWHERE`, `VM_FLAGS_OVERWRITE`, `VM_PROT_COPY`.
    static let vmFlagsAnywhere: UInt64 = 0x1
    static let vmFlagsOverwrite: UInt64 = 0x4000
    static let vmProtCopy: UInt64 = 0x10
    /// `TASK_DYLD_INFO` and its count in `natural_t` units.
    static let taskDyldInfo: UInt64 = 17
    static let taskDyldInfoCount: UInt32 = 5

    // MARK: State

    public let fileSystem: DarwinFileSystem
    public var ports = MachPortTable()
    public var sysctl = SysctlTable.standard
    public var pid: Int32
    /// Receives one line (without a newline) per trap.
    public var log: (String) -> Void
    /// The guest's `CNTVCT_EL0` (mach_absolute_time ticks).
    public var counter: () -> UInt64
    /// `CNTFRQ_EL0` in Hz.
    public var counterFrequency: UInt64
    /// Calendar time for `gettimeofday`.
    public var wallClock: () -> (seconds: Int64, nanoseconds: Int64)
    /// What `TASK_DYLD_INFO` reports.
    public var allImageInfosAddress: UInt64 = HostPageLayout.allImageInfos
    public var allImageInfosSize: UInt64 = UInt64(DyldAllImageInfos.byteCount)

    /// - Parameters:
    ///   - fileSystem: the guest VFS.
    ///   - pid: what `getpid` returns.
    ///   - log: the trace sink, one line per trap.
    ///   - counter, counterFrequency: the guest counter and its frequency
    ///     (the defaults model the stage-2 24 MHz timebase from host time).
    ///   - wallClock: calendar time (default: the host clock).
    public init(
        fileSystem: DarwinFileSystem,
        pid: Int32 = VMLayout.guestPID,
        log: @escaping (String) -> Void = { _ in },
        counter: @escaping () -> UInt64 = MachTimebase.now,
        counterFrequency: UInt64 = MachTimebase.frequency,
        wallClock: @escaping () -> (seconds: Int64, nanoseconds: Int64) = DarwinKernel.hostWallClock
    ) {
        self.fileSystem = fileSystem
        self.pid = pid
        self.log = log
        self.counter = counter
        self.counterFrequency = counterFrequency
        self.wallClock = wallClock
    }

    public static func hostWallClock() -> (seconds: Int64, nanoseconds: Int64) {
        let t = Date().timeIntervalSince1970
        let s = t.rounded(.down)
        return (Int64(s), Int64((t - s) * 1e9))
    }

    /// `mach_timebase_info`: 10⁹ / frequency, reduced.
    public var timebase: (numer: UInt32, denom: UInt32) {
        let f = max(counterFrequency, 1)
        let g = gcd(1_000_000_000, f)
        return (UInt32(truncatingIfNeeded: 1_000_000_000 / g), UInt32(truncatingIfNeeded: f / g))
    }

    // MARK: Dispatch

    /// Handles one trap. The frame is edited in place; `ELR` is left alone
    /// (it already points after the `svc`). When the address space's
    /// `generation` changes, `frame.flushTLB` is set.
    public func handle(_ frame: inout TrapFrame, memory: any KernelGuestMemory) -> Outcome {
        guard frame.trapKind == .svc else {
            log("trap \(frame.trapKind?.description ?? "kind \(frame.kind)") fatal")
            return .fatal(status: Self.exceptionExitStatus, message: frame.description)
        }
        if frame.x.count < TrapFrame.registerCount {
            frame.x += [UInt64](repeating: 0, count: TrapFrame.registerCount - frame.x.count)
        }
        let generation = memory.generation
        let outcome = dispatch(&frame, memory: memory)
        if memory.generation != generation { frame.flushTLB = true }
        return outcome
    }

    private func dispatch(_ frame: inout TrapFrame, memory: any KernelGuestMemory) -> Outcome {
        let x16 = frame.x[16]
        let low = UInt32(truncatingIfNeeded: x16)
        if (Private.rangeStart...Private.rangeEnd).contains(low) {
            return handlePrivate(low, &frame, memory)
        }
        if low == Self.platformCall {
            return handlePlatform(&frame)
        }
        let n = Int32(bitPattern: low)
        if n < 0 {
            return handleMach(Int(n), &frame, memory)
        }
        var number = Int(low & 0xFFFF)
        var args = Array(frame.x[0..<8])
        var prefix = "trap bsd \(number)"
        if number == 0 {
            number = Int(frame.x[0] & 0xFFFF)
            args = Array(frame.x[1...8])
            prefix = "trap bsd 0 (indirect \(number))"
        }
        return handleBSD(number, args, prefix: prefix, &frame, memory)
    }

    // MARK: Platform call

    private func handlePlatform(_ frame: inout TrapFrame) -> Outcome {
        let selector = UInt32(truncatingIfNeeded: frame.x[3])
        switch selector {
        case 2:
            let base = frame.x[0]
            // A base above the user VA limit stores 0.
            frame.tpidrro = base < (1 << VMLayout.virtualAddressBits) ? base : 0
            log("trap platform set_tsd_base(\(hx(base))) -> tpidrro=\(hx(frame.tpidrro))")
        case 3:
            frame.x[0] = frame.tpidrro
            log("trap platform get_tsd_base() -> \(hx(frame.tpidrro))")
        default:
            log("trap platform selector \(selector) -> no-op")
        }
        return .resume
    }

    // MARK: BSD

    /// A BSD failure carrying a Darwin errno.
    struct Failure: Error { var errno: Int32 }

    private enum BSDResult {
        case value(UInt64)
        case exit(Int32)
        case fatal(Int32, String)
        case unimplemented
    }

    private func errno(of error: Error, default fallback: Int32) -> Int32 {
        if let f = error as? Failure { return f.errno }
        if let d = error as? DarwinErrnoError { return d.errno }
        if error is GuestMemoryError { return Errno.EFAULT }
        return fallback
    }

    private func handleBSD(_ n: Int, _ a: [UInt64], prefix: String, _ frame: inout TrapFrame,
                           _ mem: any KernelGuestMemory) -> Outcome {
        var call = TrapNames.describe(TrapNames.bsd(n), a)
        var fallback = Errno.EINVAL
        let result: BSDResult
        do {
            result = try bsdCall(n, a, &call, &fallback, mem)
        } catch {
            let e = errno(of: error, default: fallback)
            frame.x[0] = UInt64(UInt32(bitPattern: e))
            frame.x[1] = 0
            frame.carry = true
            log("\(prefix) \(call) -> error \(e) (\(Errno.name(e)))")
            return .resume
        }
        switch result {
        case let .value(v):
            frame.x[0] = v
            frame.x[1] = 0
            frame.carry = false
            log("\(prefix) \(call) -> \(hx(v))")
            return .resume
        case let .exit(status):
            log("\(prefix) \(call) -> exit \(status)")
            return .exit(status: status)
        case let .fatal(status, message):
            log("\(prefix) \(call) -> fatal \(status)")
            return .fatal(status: status, message: message)
        case .unimplemented:
            frame.x[0] = UInt64(Errno.ENOSYS)
            frame.x[1] = 0
            frame.carry = true
            let text = "unimplemented bsd \(n) \(call)"
            log("\(prefix) \(call) -> unimplemented")
            return .unimplemented(description: text + "\n" + frame.description)
        }
    }

    private func bsdCall(_ n: Int, _ a: [UInt64], _ call: inout String, _ fallback: inout Int32,
                         _ mem: any KernelGuestMemory) throws -> BSDResult {
        let fs = fileSystem
        func fd(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }

        switch n {
        case BSD.exit:
            call = "exit(\(int(0)))"
            return .exit(Int32(a[0] & 0xFF))

        case BSD.read, BSD.pread:
            let isPread = n == BSD.pread
            call = isPread ? "pread(fd=\(fd(0)), buf=\(hx(a[1])), len=\(hx(a[2])), off=\(hx(a[3])))"
                : "read(fd=\(fd(0)), buf=\(hx(a[1])), len=\(hx(a[2])))"
            let count = Int(min(a[2], UInt64(Int32.max)))
            let bytes = isPread ? try fs.pread(fd(0), count: count, offset: a[3]) : try fs.read(fd(0), count: count)
            if !bytes.isEmpty { try mem.write(va: a[1], bytes: bytes) }
            return .value(UInt64(bytes.count))

        case BSD.write:
            call = "write(fd=\(fd(0)), buf=\(hx(a[1])), len=\(hx(a[2])))"
            guard a[2] <= UInt64(Int32.max) else { throw Failure(errno: Errno.EINVAL) }
            let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            return .value(UInt64(try fs.write(fd(0), bytes)))

        case BSD.open:
            let path = try readPath(a[0], mem)
            call = "open(\"\(path)\", flags=\(openFlagsText(int(1))), mode=0o\(String(a[2] & 0o7777, radix: 8)))"
            let newFD = try fs.open(path, flags: int(1), mode: UInt16(truncatingIfNeeded: a[2]))
            return .value(UInt64(UInt32(bitPattern: newFD)))

        case BSD.close:
            call = "close(\(fd(0)))"
            try fs.close(fd(0))
            return .value(0)

        case BSD.getpid:
            call = "getpid()"
            return .value(UInt64(UInt32(bitPattern: pid)))
        case BSD.getuid, BSD.geteuid:
            call = n == BSD.getuid ? "getuid()" : "geteuid()"
            return .value(UInt64(DarwinFileSystem.guestUID))
        case BSD.getgid, BSD.getegid:
            call = n == BSD.getgid ? "getgid()" : "getegid()"
            return .value(UInt64(DarwinFileSystem.guestGID))

        case BSD.ioctl:
            call = "ioctl(fd=\(fd(0)), request=\(hx(a[1])), arg=\(hx(a[2])))"
            throw Failure(errno: Errno.ENOTTY)

        case BSD.mmap:
            return .value(try mmap(a, &call, &fallback, mem))

        case BSD.munmap:
            call = "munmap(addr=\(hx(a[0])), len=\(hx(a[1])))"
            guard a[0] & Self.pageMask == 0, a[1] > 0 else { throw Failure(errno: Errno.EINVAL) }
            try mem.unmap(va: a[0], size: roundUp(a[1], to: Self.pageSize))
            return .value(0)

        case BSD.mprotect:
            let prot = protection(a[2])
            call = "mprotect(addr=\(hx(a[0])), len=\(hx(a[1])), prot=\(protText(a[2])))"
            let start = a[0] & ~Self.pageMask
            let size = roundUp(a[1] + (a[0] - start), to: Self.pageSize)
            if size > 0 { try mem.protect(va: start, size: size, protection: prot) }
            return .value(0)

        case BSD.madvise:
            call = "madvise(addr=\(hx(a[0])), len=\(hx(a[1])), advice=\(int(2)))"
            return .value(0)

        case BSD.fcntl:
            return .value(try fcntl(a, &call, mem))

        case BSD.gettimeofday:
            call = "gettimeofday(tp=\(hx(a[0])), tzp=\(hx(a[1])), mach_time=\(hx(a[2])))"
            let (sec, nsec) = wallClock()
            if a[0] != 0 {
                var tv: [UInt8] = []
                tv.appendLE(sec)
                tv.appendLE(Int32(truncatingIfNeeded: nsec / 1000))
                tv.appendLE(Int32(0))
                try mem.write(va: a[0], bytes: tv)
            }
            if a[1] != 0 { try mem.write(va: a[1], bytes: [UInt8](repeating: 0, count: 8)) }
            if a[2] != 0 {
                var t: [UInt8] = []
                t.appendLE(counter())
                try mem.write(va: a[2], bytes: t)
            }
            return .value(0)

        case BSD.sysctl:
            return .value(try sysctlMIB(a, &call, mem))

        case BSD.sysctlbyname:
            let name = try readString(a[0], length: Int(min(a[1], 1024)), mem)
            call = "sysctlbyname(\"\(name)\", old=\(hx(a[2])), oldlenp=\(hx(a[3])), new=\(hx(a[4])), newlen=\(hx(a[5])))"
            return .value(try sysctlRead(sysctl.lookup(name: name), name: name,
                                         old: a[2], oldlenp: a[3], new: a[4], newlen: a[5], mem))

        case BSD.getattrlist, BSD.fsgetpath, BSD.getattrlistbulk:
            throw Failure(errno: Errno.ENOTSUP)

        case BSD.issetugid:
            call = "issetugid()"
            return .value(0)

        case BSD.stat64, BSD.lstat64:
            let path = try readPath(a[0], mem)
            call = "\(n == BSD.stat64 ? "stat64" : "lstat64")(\"\(path)\", buf=\(hx(a[1])))"
            let st = try fs.stat(path, followSymlinks: n == BSD.stat64)
            try mem.write(va: a[1], bytes: st.encodedStat64())
            return .value(0)

        case BSD.fstat64:
            call = "fstat64(fd=\(fd(0)), buf=\(hx(a[1])))"
            try mem.write(va: a[1], bytes: fs.fstat(fd(0)).encodedStat64())
            return .value(0)

        case BSD.getfsstat64:
            call = "getfsstat64(buf=\(hx(a[0])), bufsize=\(int(1)), flags=\(int(2)))"
            return .value(0)

        case BSD.abortWithPayload:
            let reason = a[4] == 0 ? "" : ((try? readString(a[4], length: 4096, mem)) ?? "<unreadable>")
            call = "abort_with_payload(namespace=\(UInt32(truncatingIfNeeded: a[0])), code=\(hx(a[1])), "
                + "payload=\(hx(a[2])), size=\(UInt32(truncatingIfNeeded: a[3])), flags=\(hx(a[5])))"
            let message = "abort_with_payload: namespace \(UInt32(truncatingIfNeeded: a[0])) code \(hx(a[1])): \(reason)"
            return .fatal(Self.abortExitStatus, message)

        default:
            return .unimplemented
        }
    }

    // MARK: mmap

    private func mmap(_ a: [UInt64], _ call: inout String, _ fallback: inout Int32,
                      _ mem: any KernelGuestMemory) throws -> UInt64 {
        let addr = a[0], len = a[1]
        let flags = Int32(truncatingIfNeeded: a[3])
        let fd = Int32(truncatingIfNeeded: a[4])
        let pos = a[5]
        call = "mmap(addr=\(hx(addr)), len=\(hx(len)), prot=\(protText(a[2])), flags=\(mapFlagsText(flags)), "
            + "fd=\(fd), off=\(hx(pos)))"
        fallback = Errno.ENOMEM
        guard len > 0 else { throw Failure(errno: Errno.EINVAL) }
        let anonymous = flags & MapFlag.anonymous != 0
        let fixed = flags & MapFlag.fixed != 0
        // A file offset inside a page moves the mapping start down by the same amount.
        let pageOffset = anonymous ? 0 : pos & Self.pageMask
        let (total, overflow) = len.addingReportingOverflow(pageOffset)
        guard !overflow else { throw Failure(errno: Errno.EINVAL) }
        let size = roundUp(total, to: Self.pageSize)
        var at: UInt64?
        var hint: UInt64?
        if fixed {
            guard addr >= pageOffset, (addr - pageOffset) & Self.pageMask == 0 else { throw Failure(errno: Errno.EINVAL) }
            at = addr - pageOffset
        } else if addr != 0 {
            hint = addr & ~Self.pageMask
        }
        let prot = protection(a[2])
        let va: UInt64
        if anonymous {
            va = try mem.mapAnonymous(at: at, size: size, protection: prot, hint: hint)
        } else {
            let file = try fileSystem.file(for: fd)
            if flags & MapFlag.shared != 0 && flags & MapFlag.private == 0 {
                log("note: MAP_SHARED file mapping of \(file.guestPath) is mapped private")
            }
            va = try mem.mapFile(file, offset: pos - pageOffset, at: at, size: size, protection: prot, hint: hint)
        }
        return va + pageOffset
    }

    // MARK: fcntl

    private func fcntl(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let fs = fileSystem
        let fd = Int32(truncatingIfNeeded: a[0])
        let cmd = Int32(truncatingIfNeeded: a[1])
        let arg = a[2]
        let names: [Int32: String] = [1: "F_GETFD", 2: "F_SETFD", 3: "F_GETFL", 50: "F_GETPATH",
                                      97: "F_ADDFILESIGS_RETURN", 98: "F_CHECK_LV"]
        call = "fcntl(fd=\(fd), \(names[cmd] ?? "cmd \(cmd)"), arg=\(hx(arg)))"
        switch cmd {
        case Fcntl.getpath:
            let path = try fs.path(for: fd)
            let bytes = cString(path)
            guard bytes.count <= DarwinFileSystem.maxPathLength else { throw Failure(errno: Errno.ENAMETOOLONG) }
            try mem.write(va: arg, bytes: bytes)
            call += " [\(path)]"
            return 0
        case Fcntl.addFileSigsReturn:
            // fsignatures: fs_file_start off_t @0, fs_blob_start ptr @8, fs_blob_size size_t @16.
            let size = try fs.file(for: fd).size
            var b: [UInt8] = []
            b.appendLE(size)
            try mem.write(va: arg, bytes: b)
            call += " [fs_file_start=\(hx(size))]"
            return 0
        case Fcntl.checkLV:
            return 0
        case Fcntl.setfd:
            try fs.setCloseOnExec(fd, arg & 1 != 0)
            return 0
        case Fcntl.getfd:
            return try fs.closeOnExec(fd) ? 1 : 0
        case Fcntl.getfl:
            return UInt64(UInt32(bitPattern: try fs.statusFlags(fd)))
        default:
            throw Failure(errno: Errno.EINVAL)
        }
    }

    // MARK: sysctl

    private func sysctlMIB(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let count = Int(UInt32(truncatingIfNeeded: a[1]))
        call = "sysctl(name=\(hx(a[0])), namelen=\(count), old=\(hx(a[2])), oldlenp=\(hx(a[3])), "
            + "new=\(hx(a[4])), newlen=\(hx(a[5])))"
        guard count >= 1, count <= 12 else { throw Failure(errno: Errno.EINVAL) }
        let raw = try mem.read(va: a[0], count: 4 * count)
        let mib = (0..<count).map { raw.readLE(Int32.self, at: 4 * $0) }
        call = "sysctl([\(mib.map(String.init).joined(separator: ","))], old=\(hx(a[2])), oldlenp=\(hx(a[3])), "
            + "new=\(hx(a[4])), newlen=\(hx(a[5])))"
        if mib == [0, 3] {
            // name2oid: the name is the new value; the OID is returned in old.
            var nameBytes = try mem.read(va: a[4], count: Int(min(a[5], 1024)))
            while nameBytes.last == 0 { nameBytes.removeLast() }
            let name = String(decoding: nameBytes, as: UTF8.self)
            call += " [name2oid \"\(name)\"]"
            guard let entry = sysctl.lookup(name: name) else {
                log("note: sysctl name \"\(name)\" is not known")
                throw Failure(errno: Errno.ENOENT)
            }
            var oid: [UInt8] = []
            for v in entry.mib { oid.appendLE(v) }
            return try copyOut(oid, old: a[2], oldlenp: a[3], mem)
        }
        let entry = sysctl.lookup(mib: mib)
        if let entry { call += " [\(entry.name)]" }
        return try sysctlRead(entry, name: mib.map(String.init).joined(separator: "."),
                              old: a[2], oldlenp: a[3], new: a[4], newlen: a[5], mem)
    }

    private func sysctlRead(_ entry: SysctlTable.Entry?, name: String, old: UInt64, oldlenp: UInt64,
                            new: UInt64, newlen: UInt64, _ mem: any KernelGuestMemory) throws -> UInt64 {
        guard let entry else {
            log("note: sysctl \"\(name)\" is not known")
            throw Failure(errno: Errno.ENOENT)
        }
        if case let .error(e) = entry.value { throw Failure(errno: e) }
        if new != 0, newlen != 0 { throw Failure(errno: Errno.EPERM) }
        var oldLength: UInt64?
        if old != 0, oldlenp != 0 { oldLength = try readU64(oldlenp, mem) }
        return try copyOut(entry.value.bytes(forBufferOf: oldLength), old: old, oldlenp: oldlenp, mem)
    }

    /// Returns `bytes` the sysctl way: a size query when `old` is NULL,
    /// ENOMEM when the buffer is too small.
    private func copyOut(_ bytes: [UInt8], old: UInt64, oldlenp: UInt64, _ mem: any KernelGuestMemory) throws -> UInt64 {
        if old == 0 {
            if oldlenp != 0 { try writeU64(oldlenp, UInt64(bytes.count), mem) }
            return 0
        }
        guard oldlenp != 0 else { throw Failure(errno: Errno.EINVAL) }
        let capacity = try readU64(oldlenp, mem)
        guard capacity >= UInt64(bytes.count) else { throw Failure(errno: Errno.ENOMEM) }
        try mem.write(va: old, bytes: bytes)
        try writeU64(oldlenp, UInt64(bytes.count), mem)
        return 0
    }

    // MARK: Mach

    private func handleMach(_ n: Int, _ frame: inout TrapFrame, _ mem: any KernelGuestMemory) -> Outcome {
        let a = Array(frame.x[0..<8])
        var call = TrapNames.describe(TrapNames.mach(n), a)
        let prefix = "trap mach \(n)"
        func port(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: a[i]) }
        func kr(_ value: UInt64, _ extra: String = "") -> Outcome {
            frame.x[0] = value
            log("\(prefix) \(call) -> \(KernReturn.name(value))\(extra)")
            return .resume
        }
        func portResult(_ name: UInt32) -> Outcome {
            frame.x[0] = UInt64(name)
            log("\(prefix) \(call) -> \(hx(name))")
            return .resume
        }

        switch n {
        case Mach.machAbsoluteTime, Mach.machContinuousTime:
            let t = counter()
            frame.x[0] = t
            log("\(prefix) \(n == Mach.machAbsoluteTime ? "mach_absolute_time" : "mach_continuous_time")() -> \(hx(t))")
            return .resume

        case Mach.vmAllocate:
            call = "vm_allocate(target=\(hx(port(0))), addr=\(hx(a[1])), size=\(hx(a[2])), flags=\(hx(a[3])))"
            let anywhere = a[3] & Self.vmFlagsAnywhere != 0
            guard let requested = try? readU64(a[1], mem) else { return kr(KernReturn.invalidAddress) }
            if a[2] == 0 {
                guard (try? writeU64(a[1], 0, mem)) != nil else { return kr(KernReturn.invalidAddress) }
                return kr(KernReturn.success, " [addr=0x0]")
            }
            let size = roundUp(a[2], to: Self.pageSize)
            let va: UInt64
            do {
                if anywhere {
                    va = try mem.mapAnonymous(at: nil, size: size, protection: [.read, .write],
                                              hint: requested == 0 ? nil : requested & ~Self.pageMask)
                } else {
                    guard requested & Self.pageMask == 0 else { return kr(KernReturn.invalidArgument) }
                    if a[3] & Self.vmFlagsOverwrite == 0, overlapsMapping(requested, size, mem) {
                        return kr(KernReturn.noSpace)
                    }
                    va = try mem.mapAnonymous(at: requested, size: size, protection: [.read, .write], hint: nil)
                }
            } catch {
                return kr(KernReturn.noSpace)
            }
            guard (try? writeU64(a[1], va, mem)) != nil else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [addr=\(hx(va))]")

        case Mach.vmDeallocate:
            call = "vm_deallocate(target=\(hx(port(0))), addr=\(hx(a[1])), size=\(hx(a[2])))"
            guard a[2] != 0 else { return kr(KernReturn.success) }
            let start = a[1] & ~Self.pageMask
            let size = roundUp(a[2] + (a[1] - start), to: Self.pageSize)
            do { try mem.unmap(va: start, size: size) } catch { return kr(KernReturn.invalidArgument) }
            return kr(KernReturn.success)

        case Mach.vmProtect:
            let protBits = a[4] & ~Self.vmProtCopy
            call = "vm_protect(target=\(hx(port(0))), addr=\(hx(a[1])), size=\(hx(a[2])), set_max=\(a[3] & 1), "
                + "prot=\(protText(a[4]))\(a[4] & Self.vmProtCopy != 0 ? "|COPY" : ""))"
            if a[3] & 0xFFFF_FFFF != 0 { return kr(KernReturn.success, " [maximum protection not tracked]") }
            guard a[2] != 0 else { return kr(KernReturn.success) }
            let start = a[1] & ~Self.pageMask
            let size = roundUp(a[2] + (a[1] - start), to: Self.pageSize)
            do { try mem.protect(va: start, size: size, protection: protection(protBits)) } catch {
                return kr(KernReturn.invalidAddress)
            }
            return kr(KernReturn.success)

        case Mach.portAllocate:
            call = "mach_port_allocate(target=\(hx(port(0))), right=\(port(1)), name=\(hx(a[2])))"
            let name = ports.allocate(.allocated(right: port(1)))
            guard (try? writeU32(a[2], name, mem)) != nil else { ports.remove(name); return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [name=\(hx(name))]")

        case Mach.portDeallocate:
            call = "mach_port_deallocate(target=\(hx(port(0))), name=\(hx(port(1))))"
            let name = port(1)
            guard name == 0 || name == UInt32.max || ports.contains(name) else { return kr(KernReturn.invalidName) }
            return kr(KernReturn.success)

        case Mach.portInsertRight:
            call = "mach_port_insert_right(target=\(hx(port(0))), name=\(hx(port(1))), poly=\(hx(port(2))), "
                + "type=\(port(3)))"
            return kr(ports.contains(port(1)) ? KernReturn.success : KernReturn.invalidName)

        case Mach.portConstruct:
            call = "mach_port_construct(target=\(hx(port(0))), options=\(hx(a[1])), context=\(hx(a[2])), name=\(hx(a[3])))"
            let name = ports.allocate(.constructed)
            guard (try? writeU32(a[3], name, mem)) != nil else { ports.remove(name); return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [name=\(hx(name))]")

        case Mach.portDestruct:
            call = "mach_port_destruct(target=\(hx(port(0))), name=\(hx(port(1))), srdelta=\(Int32(truncatingIfNeeded: a[2])), "
                + "guard=\(hx(a[3])))"
            return kr(ports.remove(port(1)) ? KernReturn.success : KernReturn.invalidName)

        case Mach.replyPort:
            call = "mach_reply_port()"
            return portResult(ports.allocate(.reply))
        case Mach.threadSelf:
            call = "thread_self_trap()"
            return portResult(WellKnownPort.thread)
        case Mach.taskSelf:
            call = "task_self_trap()"
            return portResult(WellKnownPort.task)
        case Mach.hostSelf:
            call = "host_self_trap()"
            return portResult(WellKnownPort.host)

        case Mach.machMsg:
            call = "mach_msg(msg=\(hx(a[0])), option=\(hx(a[1])), send_size=\(port(2)), rcv_size=\(port(3)), "
                + "rcv_name=\(hx(port(4))), timeout=\(port(5)))"
            if let h = try? mem.read(va: a[0], count: 24) {
                call += " [bits=\(hx(h.readLE(UInt32.self, at: 0))) size=\(h.readLE(UInt32.self, at: 4)) "
                    + "remote=\(hx(h.readLE(UInt32.self, at: 8))) local=\(hx(h.readLE(UInt32.self, at: 12))) "
                    + "voucher=\(hx(h.readLE(UInt32.self, at: 16))) id=\(h.readLE(Int32.self, at: 20))]"
            } else {
                call += " [header unreadable]"
            }
            return kr(KernReturn.sendInvalidDest)

        case Mach.threadSwitch:
            call = "thread_switch(thread=\(hx(port(0))), option=\(Int32(truncatingIfNeeded: a[1])), time=\(port(2)))"
            return kr(KernReturn.success)

        case Mach.timebaseInfo:
            call = "mach_timebase_info(info=\(hx(a[0])))"
            let tb = timebase
            var b: [UInt8] = []
            b.appendLE(tb.numer)
            b.appendLE(tb.denom)
            guard (try? mem.write(va: a[0], bytes: b)) != nil else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [\(tb.numer)/\(tb.denom)]")

        default:
            let entry = TrapNames.mach(n)
            frame.x[0] = entry.name == "kern_invalid" || !isPortReturning(n) ? KernReturn.failure : 0
            log("\(prefix) \(call) -> unimplemented")
            return .unimplemented(description: "unimplemented mach \(n) \(call)\n" + frame.description)
        }
    }

    private func isPortReturning(_ n: Int) -> Bool { [-26, -27, -28, -29, -50, -91].contains(n) }

    private func overlapsMapping(_ va: UInt64, _ size: UInt64, _ mem: any KernelGuestMemory) -> Bool {
        mem.regions.contains { r in r.va < va + size && va < r.va + r.size }
    }

    // MARK: Private traps

    private func handlePrivate(_ number: UInt32, _ frame: inout TrapFrame, _ mem: any KernelGuestMemory) -> Outcome {
        let a = Array(frame.x[0..<8])
        let prefix = "trap yc \(hx(number & 0xFFFF))"
        var call = "private \(hx(number))"
        // BSD-style result.
        func ok(_ v: UInt64, _ extra: String = "") -> Outcome {
            frame.x[0] = v
            frame.x[1] = 0
            frame.carry = false
            log("\(prefix) \(call) -> \(hx(v))\(extra)")
            return .resume
        }
        func fail(_ error: Error) -> Outcome {
            let e = errno(of: error, default: Errno.EINVAL)
            frame.x[0] = UInt64(UInt32(bitPattern: e))
            frame.x[1] = 0
            frame.carry = true
            log("\(prefix) \(call) -> error \(e) (\(Errno.name(e)))")
            return .resume
        }
        // Mach-style result.
        func kr(_ value: UInt64, _ extra: String = "") -> Outcome {
            frame.x[0] = value
            frame.carry = false
            log("\(prefix) \(call) -> \(KernReturn.name(value))\(extra)")
            return .resume
        }

        switch number {
        case Private.vlog:
            call = "vlog(fmt=\(hx(a[0])), va_list=\(hx(a[1])))"
            do {
                let fmt = try readString(a[0], length: 4096, mem)
                let text = vlogFormat(fmt, vaList: a[1], mem)
                var bytes = Array(text.utf8)
                if bytes.last != UInt8(ascii: "\n") { bytes.append(UInt8(ascii: "\n")) }
                _ = try? fileSystem.write(2, bytes)
                return ok(0, " [\(text.trimmingCharacters(in: .newlines))]")
            } catch {
                return fail(error)
            }

        case Private.realpath:
            call = "realpath(path=\(hx(a[0])), out=\(hx(a[1])))"
            do {
                let path = try readPath(a[0], mem)
                call = "realpath(\"\(path)\", out=\(hx(a[1])))"
                let resolved = try fileSystem.realpath(path)
                let bytes = cString(resolved)
                guard bytes.count <= DarwinFileSystem.maxPathLength else { throw Failure(errno: Errno.ENAMETOOLONG) }
                try mem.write(va: a[1], bytes: bytes)
                return ok(a[1], " [\(resolved)]")
            } catch {
                return fail(error)
            }

        case Private.getcwd:
            call = "getcwd(buf=\(hx(a[0])), size=\(a[1]))"
            do {
                guard a[1] > 0 else { throw Failure(errno: Errno.EINVAL) }
                let bytes = cString(fileSystem.cwd)
                guard UInt64(bytes.count) <= a[1] else { throw Failure(errno: Errno.ERANGE) }
                try mem.write(va: a[0], bytes: bytes)
                return ok(a[0], " [\(fileSystem.cwd)]")
            } catch {
                return fail(error)
            }

        case Private.vmCopy:
            call = "vm_copy(target=\(hx(a[0])), src=\(hx(a[1])), size=\(hx(a[2])), dst=\(hx(a[3])))"
            guard a[2] <= UInt64(Int32.max) else { return kr(KernReturn.invalidArgument) }
            do {
                let bytes = try mem.read(va: a[1], count: Int(a[2]))
                try mem.write(va: a[3], bytes: bytes)
            } catch {
                return kr(KernReturn.invalidAddress)
            }
            return kr(KernReturn.success)

        case Private.procRegionFilename:
            call = "proc_regionfilename(pid=\(Int32(truncatingIfNeeded: a[0])), addr=\(hx(a[1])), buf=\(hx(a[2])), "
                + "size=\(UInt32(truncatingIfNeeded: a[3])))"
            guard let region = mem.region(containing: a[1]), case let .file(path, _, _) = region.backing else {
                return ok(0, " [no file]")
            }
            let bytes = Array(Array(path.utf8).prefix(Int(UInt32(truncatingIfNeeded: a[3]))))
            do { try mem.write(va: a[2], bytes: bytes) } catch { return fail(error) }
            return ok(UInt64(bytes.count), " [\(path)]")

        case Private.taskInfo:
            call = "task_info(task=\(hx(a[0])), flavor=\(a[1] & 0xFFFF_FFFF), info=\(hx(a[2])), count=\(hx(a[3])))"
            guard a[1] & 0xFFFF_FFFF == Self.taskDyldInfo else {
                return kr(KernReturn.invalidArgument, " [flavor not supported]")
            }
            do {
                let count = try mem.read(va: a[3], count: 4).readLE(UInt32.self, at: 0)
                guard count >= Self.taskDyldInfoCount else { return kr(KernReturn.invalidArgument) }
                var b: [UInt8] = []
                b.appendLE(allImageInfosAddress)
                b.appendLE(allImageInfosSize)
                b.appendLE(Int32(1))  // TASK_DYLD_ALL_IMAGE_INFO_64
                try mem.write(va: a[2], bytes: b)
                try writeU32(a[3], Self.taskDyldInfoCount, mem)
            } catch {
                return kr(KernReturn.invalidAddress)
            }
            return kr(KernReturn.success, " [TASK_DYLD_INFO \(hx(allImageInfosAddress))]")

        case Private.threadInfo:
            call = "thread_info(thread=\(hx(a[0])), flavor=\(a[1] & 0xFFFF_FFFF), info=\(hx(a[2])), count=\(hx(a[3])))"
            return kr(KernReturn.invalidArgument, " [flavor not supported]")

        case Private.machMsgDestroy:
            call = "mach_msg_destroy(header=\(hx(a[0])))"
            return ok(0)

        case Private.sysctlbyname:
            call = "sysctlbyname(name=\(hx(a[0])), old=\(hx(a[1])), oldlenp=\(hx(a[2])), new=\(hx(a[3])), newlen=\(hx(a[4])))"
            do {
                let name = try readString(a[0], length: 1024, mem)
                call = "sysctlbyname(\"\(name)\", old=\(hx(a[1])), oldlenp=\(hx(a[2])), new=\(hx(a[3])), newlen=\(hx(a[4])))"
                return ok(try sysctlRead(sysctl.lookup(name: name), name: name,
                                         old: a[1], oldlenp: a[2], new: a[3], newlen: a[4], mem))
            } catch {
                return fail(error)
            }

        case Private.notifyImageListChanges:
            let count = Int(UInt32(truncatingIfNeeded: a[1]))
            call = "notifyMonitorOfImageListChanges(unloading=\(a[0] & 0xFF), count=\(count), "
                + "addrs=\(hx(a[2])), paths=\(hx(a[3])))"
            var images: [String] = []
            for i in 0..<min(count, 256) {
                let base = (try? readU64(a[2] + UInt64(8 * i), mem)) ?? 0
                let pathPointer = (try? readU64(a[3] + UInt64(8 * i), mem)) ?? 0
                let path = pathPointer == 0 ? "?" : ((try? readString(pathPointer, length: 1024, mem)) ?? "?")
                images.append("\(hx(base)) \(path)")
            }
            if !images.isEmpty { call += " [" + images.joined(separator: "; ") + "]" }
            return ok(0)

        case Private.notifyMainCalled:
            call = "notifyMonitorOfMainCalled()"
            return ok(0)

        case Private.notifyBeforeInitializers:
            call = "notifyMonitorOfDyldBeforeInitializers()"
            return ok(0)

        default:
            frame.x[0] = UInt64(Errno.ENOSYS)
            frame.x[1] = 0
            frame.carry = true
            log("\(prefix) \(call) -> unimplemented")
            return .unimplemented(description: "unimplemented private \(hx(number))\n" + frame.description)
        }
    }

    /// Formats a `vlog` message from the guest's `va_list` (8-byte stack slots).
    func vlogFormat(_ fmt: String, vaList: UInt64, _ mem: any KernelGuestMemory) -> String {
        VLogFormatter(
            slot: { [unowned self] i in try self.readU64(vaList + UInt64(8 * i), mem) },
            string: { [unowned self] p in try self.readString(p, length: 4096, mem) }
        ).format(fmt)
    }

    // MARK: Guest memory helpers

    func readU64(_ va: UInt64, _ mem: any KernelGuestMemory) throws -> UInt64 {
        try mem.read(va: va, count: 8).readLE(UInt64.self, at: 0)
    }

    func writeU64(_ va: UInt64, _ v: UInt64, _ mem: any KernelGuestMemory) throws {
        var b: [UInt8] = []
        b.appendLE(v)
        try mem.write(va: va, bytes: b)
    }

    func writeU32(_ va: UInt64, _ v: UInt32, _ mem: any KernelGuestMemory) throws {
        var b: [UInt8] = []
        b.appendLE(v)
        try mem.write(va: va, bytes: b)
    }

    /// Reads a NUL-terminated string of at most `length` bytes (unterminated
    /// strings are cut at `length`). Reads never cross into the next page
    /// before they need to.
    func readString(_ va: UInt64, length: Int, _ mem: any KernelGuestMemory) throws -> String {
        guard va != 0 else { throw Failure(errno: Errno.EFAULT) }
        var bytes: [UInt8] = []
        var cursor = va
        while bytes.count < length {
            let inPage = Int(Self.pageSize - (cursor & Self.pageMask))
            let chunk = try mem.read(va: cursor, count: min(inPage, length - bytes.count))
            if let nul = chunk.firstIndex(of: 0) {
                bytes += chunk[..<nul]
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes += chunk
            cursor += UInt64(chunk.count)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads a path argument: ENAMETOOLONG when it has no NUL within `MAXPATHLEN`.
    func readPath(_ va: UInt64, _ mem: any KernelGuestMemory) throws -> String {
        let max = DarwinFileSystem.maxPathLength
        let s = try readString(va, length: max + 1, mem)
        guard s.utf8.count < max else { throw Failure(errno: Errno.ENAMETOOLONG) }
        return s
    }

    // MARK: Formatting

    private func protection(_ bits: UInt64) -> VMProtection {
        VMProtection(rawValue: VMProtection.RawValue(truncatingIfNeeded: bits & 7))
    }

    func protText(_ bits: UInt64) -> String {
        (bits & 1 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + (bits & 4 != 0 ? "x" : "-")
    }

    func mapFlagsText(_ flags: Int32) -> String {
        var parts: [String] = []
        if flags & MapFlag.shared != 0 { parts.append("SHARED") }
        if flags & MapFlag.private != 0 { parts.append("PRIVATE") }
        if flags & MapFlag.fixed != 0 { parts.append("FIXED") }
        if flags & MapFlag.anonymous != 0 { parts.append("ANON") }
        let rest = flags & ~(MapFlag.shared | MapFlag.private | MapFlag.fixed | MapFlag.anonymous)
        if rest != 0 { parts.append(hx(UInt32(bitPattern: rest))) }
        return parts.isEmpty ? "0" : parts.joined(separator: "|")
    }

    func openFlagsText(_ flags: Int32) -> String {
        var parts = [["O_RDONLY", "O_WRONLY", "O_RDWR", "O_ACCMODE"][Int(flags & 3)]]
        let known: [(Int32, String)] = [(0x4, "O_NONBLOCK"), (0x8, "O_APPEND"), (0x100, "O_NOFOLLOW"),
                                        (0x200, "O_CREAT"), (0x400, "O_TRUNC"), (0x800, "O_EXCL"),
                                        (0x10_0000, "O_DIRECTORY"), (0x100_0000, "O_CLOEXEC")]
        var rest = flags & ~3
        for (bit, name) in known where flags & bit != 0 {
            parts.append(name)
            rest &= ~bit
        }
        if rest != 0 { parts.append(hx(UInt32(bitPattern: rest))) }
        return parts.joined(separator: "|")
    }
}
