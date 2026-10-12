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
        /// One of Ycode's host libraries called a function it does not
        /// implement yet (private trap `0x7963_0F00`, `host-libraries.md` §4).
        /// The frame is unchanged: the library stub fails in its own way
        /// after the trap, so the VMM may resume; in `--trace` mode it exits 73.
        case unimplementedLibraryFunction(name: String)
        /// The calling thread terminated (`bsdthread_terminate`, stage 4a).
        /// The VMM must not resume it: it parks the thread's vCPU and host
        /// thread in the pool for reuse.
        case threadExit
    }

    /// The VMM's exit status for an unimplemented trap in trace mode.
    public static let unimplementedExitStatus: Int32 = 72
    /// The VMM's exit status for an unimplemented host-library function in trace mode.
    public static let unimplementedLibraryFunctionExitStatus: Int32 = 73
    public static let abortExitStatus: Int32 = 134
    public static let exceptionExitStatus: Int32 = 70

    // MARK: Constants

    /// Darwin errno values used by the kernel.
    public enum Errno {
        public static let EPERM: Int32 = 1
        public static let ENOENT: Int32 = 2
        public static let ESRCH: Int32 = 3
        public static let EIO: Int32 = 5
        public static let ENOTDIR: Int32 = 20
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
            1: "EPERM", 2: "ENOENT", 3: "ESRCH", 4: "EINTR", 5: "EIO", 9: "EBADF", 12: "ENOMEM", 13: "EACCES", 14: "EFAULT",
            17: "EEXIST", 19: "ENODEV", 20: "ENOTDIR", 21: "EISDIR", 22: "EINVAL", 24: "EMFILE", 25: "ENOTTY",
            11: "EDEADLK", 38: "ENOTSOCK", 28: "ENOSPC", 29: "ESPIPE", 30: "EROFS", 34: "ERANGE", 35: "EAGAIN", 45: "ENOTSUP",
            60: "ETIMEDOUT", 62: "ELOOP",
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
        public static let aborted: UInt64 = 14
        public static let notWaiting: UInt64 = 24
        public static let terminated: UInt64 = 37
        public static let operationTimedOut: UInt64 = 49
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
            case aborted: "KERN_ABORTED"
            case notWaiting: "KERN_NOT_WAITING"
            case terminated: "KERN_TERMINATED"
            case operationTimedOut: "KERN_OPERATION_TIMED_OUT"
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
                          lstat64 = 340, getfsstat64 = 347, bsdthreadRegister = 366, fsgetpath = 427,
                          getattrlistbulk = 461, abortWithPayload = 521

        /// `_nocancel` call → the plain call it behaves like.
        public static let nocancelAliases: [Int: Int] = [
            396: read, 397: write, 398: open, 399: close, 406: fcntl, 414: pread,
            411: 120, 412: 121, 464: 463, 395: 394, 407: 93, 408: 95, 415: 154, 417: 230,
            542: 540, 543: 541, 413: 133,
        ]
    }

    /// Mach trap numbers handled here (negative x16).
    public enum Mach {
        public static let machAbsoluteTime = -3, machContinuousTime = -4, vmAllocate = -10, vmDeallocate = -12,
                          vmProtect = -14, portAllocate = -16, portDeallocate = -18, portInsertRight = -21,
                          portConstruct = -24, portDestruct = -25, replyPort = -26, threadSelf = -27,
                          taskSelf = -28, hostSelf = -29, machMsg = -31, threadSwitch = -61, timebaseInfo = -89,
                          vmMap = -15, portModRefs = -19, portGuard = -41, portUnguard = -42,
                          generateActivityID = -43, pidForTask = -46, threadGetSpecialReplyPort = -50,
                          portType = -76, portRequestNotification = -77, waitUntil = -90,
                          semaphoreSignal = -33, semaphoreSignalAll = -34, semaphoreSignalThread = -35,
                          semaphoreWait = -36, semaphoreWaitSignal = -37, semaphoreTimedwait = -38,
                          semaphoreTimedwaitSignal = -39, swtchPri = -59, swtch = -60
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
        /// A host-library stub for a function Ycode does not implement yet;
        /// `x0` = the NUL-terminated symbol name (`host-libraries.md` §4).
        public static let unimplementedLibraryFunction: UInt32 = 0x7963_0F00
        /// Mach routines served directly (`host-libraries.md` §10): `0x7963_2000 + n`.
        public static let hostGetClockService: UInt32 = 0x7963_2001
        public static let clockGetTime: UInt32 = 0x7963_2002
        public static let semaphoreCreate: UInt32 = 0x7963_2003
        public static let semaphoreDestroy: UInt32 = 0x7963_2004
        public static let taskGetSpecialPort: UInt32 = 0x7963_2005
        public static let taskSetSpecialPort: UInt32 = 0x7963_2006
        /// The Mach-routine range that `MachIPC` owns (stage4a-contract.md §8).
        public static let machRoutineRangeStart: UInt32 = 0x7963_2000
        public static let machRoutineRangeEnd: UInt32 = 0x7963_20FF
    }

    /// Mach traps the kernel keeps when a `MachIPC` is attached: the clocks,
    /// the VM calls, the semaphores, and `thread_switch`/`swtch_pri`
    /// (stage4a-contract.md §8).
    public static let kernelOwnedMachTraps: Set<Int> = [-3, -4, -10, -12, -14, -33, -34, -35, -36, -37, -38, -39, -59, -60, -61]

    /// The address that the shared-cache builder patches into a missing
    /// export's uses (`host-libraries.md` §6).
    public static let cachePatchPlaceholder: UInt64 = 0xbad4007

    /// True for a guest fault (kind 2) whose FAR or ELR lies within 16 bytes
    /// of `cachePatchPlaceholder`: a call through an export that one of the
    /// host libraries does not provide.
    public static func isCachePatchPlaceholderFault(_ frame: TrapFrame) -> Bool {
        guard frame.trapKind == .el0Synchronous else { return false }
        func near(_ a: UInt64) -> Bool {
            let d = a > cachePatchPlaceholder ? a - cachePatchPlaceholder : cachePatchPlaceholder - a
            return d <= 16
        }
        return near(frame.far) || near(frame.elr)
    }

    public static let cachePatchPlaceholderMessage = "missing host-library export (cache patch placeholder 0xbad4007)"

    // MARK: Thread registration

    /// What `bsdthread_register` (BSD 366) recorded (`host-library-init.md` §6.1).
    public struct ThreadRegistration: Equatable, Sendable {
        public var threadStart: UInt64
        public var startWorkqueueThread: UInt64
        public var pthreadSize: UInt32
        public var dispatchQueueOffset: UInt64
        public var tsdOffset: UInt32
        public var returnToKernelOffset: UInt32
        public var machThreadSelfOffset: UInt32
        public var joinableOffsetBits: UInt32
        public var quantumExpiryOffset: UInt32
    }

    /// The feature mask `bsdthread_register` returns: stage 4a adds KEVENT
    /// (0x40) and WORKLOOP (0x80) (`stage4a-contract.md` §5).
    public static let bsdthreadFeatures: UInt64 = 0x4000_00DF
    /// `main_qos` written back to the registration record: LEGACY QoS as a
    /// priority (`host-library-init.md` §5.3).
    public static let mainThreadQoS: UInt64 = 0x8FF
    /// The size of the registration record Ycode knows.
    static let registrationRecordSize = 56

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
    /// The main stack's top, for `bsdthread_register`'s stack hint.
    public var mainStackTop: UInt64 = Stage3Layout.userStack
    /// Set by the first successful `bsdthread_register`.
    public private(set) var threadRegistration: ThreadRegistration?
    /// The counter value at VM start (the system clock's epoch); the VMM sets it.
    public var bootCounter: UInt64 = 0
    /// Sleeps the host for `nanoseconds` (semaphore timed waits).
    public var sleep: (UInt64) -> Void = { ns in
        var ts = timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))
        _ = nanosleep(&ts, nil)
    }
    /// The last `mach_generate_activity_id` value.
    var nextActivityID: UInt64 = 0
    /// Bookkeeping for the stage-3b BSD calls (signals, rlimits, directory cursors).
    var extended = ExtendedBSDState()
    /// Random bytes for `getentropy` (default: the host's /dev/urandom).
    public var entropy: (Int) -> [UInt8] = DarwinKernel.hostEntropy

    // MARK: Stage-4a state (threads, workqueue, kevent)

    /// The one kernel lock of this VM (`KernelSync.swift`). `handle` holds it
    /// for the whole trap.
    public let lock = KernelLock()
    /// The in-process Mach IPC (`MachIPC`, attached by `init`). Mach traps
    /// (except the clock, VM, semaphore, and yield traps) and the private
    /// range `0x7963_2000…0x7963_20FF` go to it first.
    public var machIPC: (any MachIPCHandling)? {
        didSet { attachIPCHooks() }
    }
    /// The hypervisor's vCPU pool. Without it, new threads cannot start
    /// (`bsdthread_create` fails with EAGAIN; workqueue requests stay pending).
    public var threadHost: (any ThreadHost)?
    /// The process's first thread: id 1, port `0x203`, vCPU 0.
    public let mainThread: ThreadContext
    /// Live threads by port name.
    var threadsByPort: [UInt32: ThreadContext] = [:]
    var nextThreadID: UInt64 = 2
    /// What every later trap returns once the process is exiting.
    var termination: Outcome?
    /// ulock wait queues by address.
    var ulocks: [UInt64: ULockQueue] = [:]
    /// The process workqueue and the kevent engine.
    var workqueue = WorkqueueState()
    var kevents = KEventState()
    /// The address space of the last trap (for work started outside a trap).
    var lastMemory: (any KernelGuestMemory)?

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
        mainThread = ThreadContext(threadID: 1, portName: WellKnownPort.thread, vcpuIndex: 0, kind: .main)
        threadsByPort[mainThread.portName] = mainThread
        lock.blockingObserver = { [unowned self] context, blocking in
            self.threadBlockingChanged(context, blocking: blocking)
        }
        machIPC = MachIPC(kernel: self)
        attachIPCHooks()
    }

    private func attachIPCHooks() {
        machIPC?.messageQueuedHandler = { [unowned self] name in self.machPortMessageQueued(name) }
        (machIPC as? MachIPC)?.receiveRightGoneHandler = { [unowned self] name in self.machPortReceiveRightGone(name) }
    }

    /// The live thread whose port name is `port`.
    public func thread(port: UInt32) -> ThreadContext? {
        lock.withLock { threadsByPort[port] }
    }

    /// Every live thread.
    public var liveThreads: [ThreadContext] {
        lock.withLock { threadsByPort.values.sorted { $0.threadID < $1.threadID } }
    }

    /// The thread whose trap is being handled (the main thread outside a trap).
    var current: ThreadContext { lock.currentContext ?? mainThread }

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
    ///
    /// This form runs the trap on the main thread (stage-3 callers and tests).
    public func handle(_ frame: inout TrapFrame, memory: any KernelGuestMemory) -> Outcome {
        handle(&frame, context: mainThread, memory: memory)
    }

    /// Handles one trap of the guest thread `context`. Safe to call from many
    /// host threads at once: the whole trap runs under `lock`, and a blocking
    /// call releases it while it sleeps. A thread that blocks returns only
    /// when its call completes. `.threadExit` means the thread is gone (park
    /// its vCPU); once the process exits, every call returns the exit outcome.
    public func handle(_ frame: inout TrapFrame, context: ThreadContext, memory: any KernelGuestMemory) -> Outcome {
        lock.withLock(context: context) {
            if let termination { return termination }
            let outcome = handleLocked(&frame, memory: memory)
            switch outcome {
            case .exit, .fatal:
                // With other threads (or the timer thread) around, the exit
                // is final: blocked threads wake and every later trap returns
                // it. A lone thread's process just reports it (the VMM ends).
                if termination == nil, threadsByPort.count > 1 || kevents.timerThreadStarted {
                    termination = outcome
                    lock.terminate()
                    kevents.timerWake.wakeAll()
                }
                return outcome
            default:
                if let termination, outcome != .threadExit { return termination }
                return outcome
            }
        }
    }

    private func handleLocked(_ frame: inout TrapFrame, memory: any KernelGuestMemory) -> Outcome {
        guard frame.trapKind == .svc else {
            log("trap \(frame.trapKind?.description ?? "kind \(frame.kind)") fatal")
            if Self.isCachePatchPlaceholderFault(frame) {
                return .fatal(status: Self.exceptionExitStatus,
                              message: Self.cachePatchPlaceholderMessage + "\n" + frame.description)
            }
            return .fatal(status: Self.exceptionExitStatus, message: frame.description)
        }
        if frame.x.count < TrapFrame.registerCount {
            frame.x += [UInt64](repeating: 0, count: TrapFrame.registerCount - frame.x.count)
        }
        lastMemory = memory
        let generation = memory.generation
        let outcome = dispatch(&frame, memory: memory)
        if memory.generation != generation { frame.flushTLB = true }
        return outcome
    }

    private func dispatch(_ frame: inout TrapFrame, memory: any KernelGuestMemory) -> Outcome {
        let x16 = frame.x[16]
        let low = UInt32(truncatingIfNeeded: x16)
        if (Private.rangeStart...Private.rangeEnd).contains(low) {
            if (Private.machRoutineRangeStart...Private.machRoutineRangeEnd).contains(low), let ipc = machIPC,
               let outcome = ipc.handleTrap(x16: Int64(low), frame: &frame, context: current, memory: memory) {
                return outcome
            }
            return handlePrivate(low, &frame, memory)
        }
        if low == Self.platformCall {
            return handlePlatform(&frame)
        }
        let n = Int32(bitPattern: low)
        if n < 0 {
            if let outcome = handleSemaphoreTrap(Int(n), &frame) { return outcome }
            if let outcome = handleThreadSwitch(Int(n), &frame) { return outcome }
            if !Self.kernelOwnedMachTraps.contains(Int(n)), let ipc = machIPC,
               let outcome = ipc.handleTrap(x16: Int64(n), frame: &frame, context: current, memory: memory) {
                return outcome
            }
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

    enum BSDResult {
        case value(UInt64)
        case exit(Int32)
        case fatal(Int32, String)
        case unimplemented
        /// The calling thread terminated.
        case threadExit
        /// Restart the calling thread at a new EL0 state (workqueue upcalls).
        case restart(ThreadStartState)
    }

    func errno(of error: Error, default fallback: Int32) -> Int32 {
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
        case .threadExit:
            log("\(prefix) \(call) -> thread exit")
            return .threadExit
        case let .restart(start):
            start.apply(to: &frame)
            log("\(prefix) \(call) -> restart at \(hx(start.pc)) x0=\(hx(start.x[0])) x3=\(hx(start.x[3])) "
                + "x4=\(hx(start.x[4])) x5=\(hx(start.x[5])) sp=\(hx(start.sp))")
            return .resume
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
        // The `_nocancel` variants behave like their plain calls (no
        // cancellation in Ycode).
        let n = BSD.nocancelAliases[n] ?? n
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
            extended.directoryCursors[fd(0)] = nil
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

        case BSD.bsdthreadRegister:
            return .value(try bsdthreadRegister(a, &call, mem))

        case BSD.abortWithPayload:
            let reason = a[4] == 0 ? "" : ((try? readString(a[4], length: 4096, mem)) ?? "<unreadable>")
            call = "abort_with_payload(namespace=\(UInt32(truncatingIfNeeded: a[0])), code=\(hx(a[1])), "
                + "payload=\(hx(a[2])), size=\(UInt32(truncatingIfNeeded: a[3])), flags=\(hx(a[5])))"
            let message = "abort_with_payload: namespace \(UInt32(truncatingIfNeeded: a[0])) code \(hx(a[1])): \(reason)"
            return .fatal(Self.abortExitStatus, message)

        default:
            return try extendedBSDCall(n, a, &call, &fallback, mem) ?? .unimplemented
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

    // MARK: bsdthread_register

    /// BSD 366 (`host-library-init.md` §6.1): records the entry points and
    /// offsets, writes back the record's out fields, and returns the feature
    /// mask of `host-libraries.md` §7.4.
    private func bsdthreadRegister(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let size = UInt32(truncatingIfNeeded: a[2])
        let recordSize = UInt32(truncatingIfNeeded: a[4])
        call = "bsdthread_register(threadstart=\(hx(a[0])), wqthread=\(hx(a[1])), pthsize=\(hx(size)), "
            + "data=\(hx(a[3])), datasize=\(recordSize), offset=\(hx(a[5])))"
        guard size <= 64 << 10 else { throw Failure(errno: Errno.EINVAL) }
        guard threadRegistration == nil else { throw Failure(errno: Errno.EINVAL) }
        var registration = ThreadRegistration(
            threadStart: a[0], startWorkqueueThread: a[1], pthreadSize: size, dispatchQueueOffset: a[5],
            tsdOffset: 0, returnToKernelOffset: 0, machThreadSelfOffset: 0, joinableOffsetBits: 0,
            quantumExpiryOffset: 0)
        if a[3] != 0 {
            guard recordSize >= 8 else { throw Failure(errno: Errno.EINVAL) }
            let count = min(Int(recordSize), Self.registrationRecordSize)
            var record = try mem.read(va: a[3], count: count)
            guard record.readLE(UInt64.self, at: 0) == UInt64(recordSize) else { throw Failure(errno: Errno.EINVAL) }
            record += [UInt8](repeating: 0, count: Self.registrationRecordSize - count)
            registration.dispatchQueueOffset = record.readLE(UInt64.self, at: 8)
            // An offset that does not fit in the pthread_t is turned off.
            func offset(_ at: Int) -> UInt32 {
                let v = record.readLE(UInt32.self, at: at)
                let tsd = record.readLE(UInt32.self, at: 24)
                return Int64(v) < Int64(size) - 8 - Int64(tsd) ? v : 0
            }
            registration.tsdOffset = record.readLE(UInt32.self, at: 24)
            registration.returnToKernelOffset = offset(28)
            registration.machThreadSelfOffset = offset(32)
            registration.joinableOffsetBits = record.readLE(UInt32.self, at: 48)
            registration.quantumExpiryOffset = offset(52)
            // Out fields: version, main_qos, stack_addr_hint, mutex_default_policy.
            record.putLE(UInt64(Self.registrationRecordSize), at: 0)
            record.putLE(Self.mainThreadQoS, at: 16)
            record.putLE(mainStackTop & ~Self.pageMask, at: 36)
            record.putLE(UInt32(0), at: 44)
            try mem.write(va: a[3], bytes: Array(record[0..<count]))
            call += " [tsd_offset=\(registration.tsdOffset) dispatch_queue_offset=\(registration.dispatchQueueOffset)]"
        }
        threadRegistration = registration
        return Self.bsdthreadFeatures
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

        case Mach.timebaseInfo:
            call = "mach_timebase_info(info=\(hx(a[0])))"
            let tb = timebase
            var b: [UInt8] = []
            b.appendLE(tb.numer)
            b.appendLE(tb.denom)
            guard (try? mem.write(va: a[0], bytes: b)) != nil else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [\(tb.numer)/\(tb.denom)]")

        case Mach.vmMap:
            // target, *addr, size, mask, flags, cur_protection.
            call = "mach_vm_map(target=\(hx(port(0))), addr=\(hx(a[1])), size=\(hx(a[2])), mask=\(hx(a[3])), "
                + "flags=\(hx(a[4])), prot=\(protText(a[5])))"
            guard let requested = try? readU64(a[1], mem) else { return kr(KernReturn.invalidAddress) }
            guard a[2] != 0 else { return kr(KernReturn.invalidArgument) }
            let size = roundUp(a[2], to: Self.pageSize)
            let alignment = max(a[3] | Self.pageMask, Self.pageMask) &+ 1
            let prot = protection(a[5] & 7)
            let va: UInt64
            do {
                if a[4] & Self.vmFlagsAnywhere != 0 {
                    let hint = requested == 0 ? nil : requested & ~Self.pageMask
                    if alignment <= Self.pageSize {
                        va = try mem.mapAnonymous(at: nil, size: size, protection: prot, hint: hint)
                    } else {
                        // Over-allocate, then trim to the requested alignment.
                        let span = size + alignment
                        let raw = try mem.mapAnonymous(at: nil, size: span, protection: prot, hint: hint)
                        let aligned = roundUp(raw, to: alignment)
                        if aligned > raw { try mem.unmap(va: raw, size: aligned - raw) }
                        if raw + span > aligned + size { try mem.unmap(va: aligned + size, size: raw + span - aligned - size) }
                        va = aligned
                    }
                } else {
                    guard requested & Self.pageMask == 0 else { return kr(KernReturn.invalidArgument) }
                    if a[4] & Self.vmFlagsOverwrite == 0, overlapsMapping(requested, size, mem) {
                        return kr(KernReturn.noSpace)
                    }
                    va = try mem.mapAnonymous(at: requested, size: size, protection: prot, hint: nil)
                }
            } catch {
                return kr(KernReturn.noSpace)
            }
            guard (try? writeU64(a[1], va, mem)) != nil else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [addr=\(hx(va))]")

        case Mach.generateActivityID:
            call = "mach_generate_activity_id(target=\(hx(port(0))), count=\(port(1)), id=\(hx(a[2])))"
            nextActivityID &+= UInt64(max(port(1), 1))
            guard (try? writeU64(a[2], nextActivityID, mem)) != nil else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [\(hx(nextActivityID))]")

        case Mach.pidForTask:
            call = "pid_for_task(task=\(hx(port(0))), pid=\(hx(a[1])))"
            guard port(0) == WellKnownPort.task else { return kr(KernReturn.failure) }
            guard (try? writeU32(a[1], UInt32(bitPattern: pid), mem)) != nil else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success)

        case Mach.waitUntil:
            call = "mach_wait_until(deadline=\(hx(a[0])))"
            let result = WaitQueue().wait(on: lock, deadline: hostDeadline(machTicks: a[0]))
            return kr(result == .interrupted ? KernReturn.aborted : KernReturn.success)

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

        case Private.unimplementedLibraryFunction:
            let name = (try? readString(a[0], length: 256, mem)) ?? "<unreadable name at \(hx(a[0]))>"
            log("\(prefix) unimplemented libfunc \(name)")
            return .unimplementedLibraryFunction(name: name)

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
