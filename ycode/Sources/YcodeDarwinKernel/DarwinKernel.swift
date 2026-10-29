import Foundation
import Synchronization
import YcodeDarwinABI

/// Diagnostics A/B (X11 speed exploration): `YCODE_X11_EAGER=1` makes trace
/// text eager again, as before this change, so the formatting cost of one
/// build can be measured against itself. Off by default.
let forceEagerTraceText: Bool = getenv("YCODE_X11_EAGER").map { String(cString: $0) == "1" } ?? false

/// Whether trace text is built at all: the kernel is tracing, or the eager
/// A/B switch is on.
@inline(__always) func traceTextWanted(_ tracing: Bool) -> Bool { tracing || forceEagerTraceText }

/// The one-line description of a trap's call (`write(fd=…)`), built only when
/// trace text is wanted. Its arguments are autoclosures, so a trap with
/// tracing off formats nothing (no hex strings, no guest-memory reads for
/// the description).
public struct CallText: CustomStringConvertible {
    private(set) var text: String
    let enabled: Bool

    init(_ tracing: Bool, _ initial: @autoclosure () -> String = "") {
        enabled = traceTextWanted(tracing)
        text = enabled ? initial() : ""
    }

    /// Replaces the description (`call = …`).
    @inline(__always) mutating func set(_ make: @autoclosure () -> String) {
        if enabled { text = make() }
    }

    /// Appends to the description (`call += …`).
    @inline(__always) static func += (lhs: inout CallText, rhs: @autoclosure () -> String) {
        if lhs.enabled { lhs.text += rhs() }
    }

    public var description: String { text }
}

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

    /// What `handle(_:memory:)` tells the VMM to do once a trap returns.
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
        /// The process replaced its image (`execve`, `posix_spawn` with
        /// `POSIX_SPAWN_SETEXEC`; stage 4b, `stage4b-contract.md` §3). The
        /// new image already runs in its own VM under the same pid. The VMM
        /// tears this VM down quietly: this is not a process exit.
        case imageReplaced
    }

    /// The VMM's exit status for an unimplemented trap in trace mode.
    public static let unimplementedExitStatus: Int32 = 72
    /// The VMM's exit status for an unimplemented host-library function in trace mode.
    public static let unimplementedLibraryFunctionExitStatus: Int32 = 73
    /// The VMM's exit status for `abort_with_payload`.
    public static let abortExitStatus: Int32 = 134
    /// The VMM's exit status for a guest exception that is not an SVC.
    public static let exceptionExitStatus: Int32 = 70
    /// Diagnostics: `YCODE_DEBUG_PRIVATE_SHARED_FILES=1` maps MAP_SHARED
    /// files private, as Ycode did before shared file views.
    static let debugPrivateSharedFiles = getenv("YCODE_DEBUG_PRIVATE_SHARED_FILES").map { String(cString: $0) == "1" } ?? false

    // MARK: Constants

    /// Darwin errno values used by the kernel: each constant is the `sys/errno.h`
    /// number of the error it names, returned in `x0` with carry set.
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

        /// The `E*` name of `e` for trace lines, or `errno N` when the table lacks it.
        public static func name(_ e: Int32) -> String { names[e] ?? "errno \(e)" }
    }

    /// `kern_return_t` values the kernel's own Mach traps return in `x0`; each
    /// constant is the `KERN_*` code its name spells.
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

    /// BSD call numbers handled here: the low 16 bits of `x16` for the Darwin
    /// call each name spells.
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
            // Stage 4b (process layer): wait4_nocancel, waitid_nocancel.
            400: 7, 416: 173,
            // Stage 6: sem_wait_nocancel.
            420: 271,
        ]
    }

    /// Mach trap numbers handled here (negative x16), one per trap its name
    /// spells (`machMsg` is `mach_msg_trap`, −31).
    public enum Mach {
        public static let machAbsoluteTime = -3, machContinuousTime = -4, vmAllocate = -10, vmPurgableControl = -11, vmDeallocate = -12,
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
    ///
    /// Every private trap lies in `rangeStart...rangeEnd` (inclusive). The
    /// `0x7963_00xx` traps stand in for the library routine each name spells.
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
        /// The last trap number of that range (inclusive).
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

    /// The fatal message for a fault that `isCachePatchPlaceholderFault(_:)` matches.
    public static let cachePatchPlaceholderMessage = "missing host-library export (cache patch placeholder 0xbad4007)"

    // MARK: Thread registration

    /// What `bsdthread_register` (BSD 366) recorded (`host-library-init.md` §6.1).
    ///
    /// `threadStart` and `startWorkqueueThread` are the guest entry points from
    /// `x0`/`x1`, `pthreadSize` is `PTHREAD_SIZE` in bytes, and the other fields
    /// are the same-named byte offsets from the registration record.
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

    /// The `x16` value of the platform call; its sub-selector is in `x3`.
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
        public static let preallocate: Int32 = 42
        public static let getProtectionClass: Int32 = 63, setProtectionClass: Int32 = 64
        public static let getProtectionLevel: Int32 = 77
        public static let getpathNoFirmlink: Int32 = 102
        public static let setConfined: Int32 = 95, getConfined: Int32 = 96
        /// F_RDADVISE 44, F_RDAHEAD 45, F_NOCACHE 48, F_FULLFSYNC 51,
        /// F_GLOBAL_NOCACHE 55, F_NODIRECT 62, F_SINGLE_WRITER 76,
        /// F_BARRIERFSYNC 85, F_SPECULATIVE_READ 101 (sys/fcntl.h).
        public static let hints: Set<Int32> = [44, 45, 48, 51, 55, 62, 76, 85, 101]
    }

    /// The guest page size in bytes (16 KiB).
    public static let pageSize: UInt64 = 0x4000
    static let pageMask: UInt64 = pageSize - 1
    /// `VM_FLAGS_ANYWHERE`, `VM_FLAGS_OVERWRITE`, `VM_PROT_COPY`.
    static let vmFlagsAnywhere: UInt64 = 0x1
    static let vmFlagsOverwrite: UInt64 = 0x4000
    static let vmProtCopy: UInt64 = 0x10
    /// `TASK_DYLD_INFO` and its count in `natural_t` units.
    static let taskDyldInfo: UInt64 = 17
    static let taskDyldInfoCount: UInt32 = 5
    static let taskAuditToken: UInt64 = 15

    // MARK: State

    /// The guest file system and descriptor table that this image's BSD calls use.
    public let fileSystem: DarwinFileSystem
    /// The table that `sysctl` and `sysctlbyname` read and write.
    public var sysctl = SysctlTable.standard
    /// Diagnostics (`KernelLock.profileProcesses`, `YCODE_BOOT_PROFILE`):
    /// kernel-lock time held and waited for on behalf of this image's
    /// threads, and the acquisitions. Changed with the kernel lock held.
    public internal(set) var profileLockHeldNanoseconds: UInt64 = 0
    /// Diagnostics: kernel-lock wait time for this image's threads (ns).
    public internal(set) var profileLockWaitNanoseconds: UInt64 = 0
    /// Diagnostics: kernel-lock acquisitions for this image's threads.
    public internal(set) var profileLockAcquisitions: UInt64 = 0
    /// The process ID of the guest task this kernel serves.
    public var pid: Int32
    /// The dirty-tracking word of this image's process record, set when the
    /// record takes the image (a leaf lock: read by the `proc_info` fast path).
    let processDirtyLink = Mutex<ProcessDirtyState?>(nil)
    /// Diagnostics (`YCODE_TRAP_PROFILE_PROGRAM`): this image's traps are
    /// counted in the trap profile (set by the launcher per image).
    public var trapProfileSelected = false
    /// Receives one line (without a newline) per trap.
    public var log: (String) -> Void
    /// Whether trap descriptions are built and passed to `log` at all. Off,
    /// no trace text is formatted (most of a cheap trap's time under the
    /// kernel lock went into building strings nobody printed; agent I4).
    public var tracing = true
    /// `log(line)` when tracing; `line` is not evaluated otherwise.
    @inline(__always) func trace(_ line: @autoclosure () -> String) {
        // A fast path (only when a test lets one run for a traced image)
        // writes no trace: the log sink is serialized by L0.
        if tracing, eventLock == nil || lock.isHeldByCurrentThread, !KernelThreadLocks.current.bsdFast { log(line()) }
    }
    /// The guest's `CNTVCT_EL0` (mach_absolute_time ticks).
    public var counter: () -> UInt64
    /// `CNTFRQ_EL0` in Hz.
    public var counterFrequency: UInt64
    /// The process's CPU time so far (user, system; ns), for
    /// `getrusage(RUSAGE_SELF)`. nil: zero.
    public var processCPUTimes: (() -> (user: UInt64, system: UInt64))?
    /// Calendar time for `gettimeofday`.
    public var wallClock: () -> (seconds: Int64, nanoseconds: Int64)
    /// `fast-traps.md` §4: called (under the kernel lock) after each
    /// `gettimeofday` trap with a fresh (mach time, calendar time) pair, to
    /// store the commpage's `NEWTIMEOFDAY_DATA` snapshot. nil: no snapshot.
    public var timeOfDayPublisher: ((_ tick: UInt64, _ seconds: Int64, _ nanoseconds: Int64) -> Void)?
    /// Serializes `timeOfDayPublisher` calls (a leaf, `bsd-locking.md` §12).
    let timeOfDayLock = DescriptorTableLock(name: "time-of-day snapshot")
    /// What `TASK_DYLD_INFO` reports.
    public var allImageInfosAddress: UInt64 = HostPageLayout.allImageInfos
    /// The size in bytes that `TASK_DYLD_INFO` reports.
    public var allImageInfosSize = UInt64(DyldAllImageInfos.byteCount)
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
    var nextActivityID: UInt64 {
        get { activityIDs.load(ordering: .relaxed) }
        set { activityIDs.store(newValue, ordering: .relaxed) }
    }
    /// An atomic: `mach_generate_activity_id` is a task-local trap (`bsd-locking.md` §12).
    let activityIDs = Atomic<UInt64>(0)
    /// `YCODE_DEBUG_SEMAPHORES` lines printed for this process.
    let debugSemaphoreLines = Atomic<Int>(0)
    /// Bookkeeping for the stage-3b BSD calls (signals, rlimits, directory cursors).
    var extended = ExtendedBSDState()
    /// Random bytes for `getentropy` (default: the host's /dev/urandom).
    public var entropy: (Int) -> [UInt8] = DarwinKernel.hostEntropy

    // MARK: Stage-4a state (threads, workqueue, kevent)

    /// The one kernel lock of this VM (`KernelSync.swift`). `handle` holds it
    /// for the whole trap.
    public let lock: KernelLock
    /// The lock split (`mach-ipc-locking.md` §4): this image's event lock L_P,
    /// which guards its kevent engine and workqueue on fast paths. Nil
    /// without the split.
    public let eventLock: KernelLock?
    /// The lock that kevent and workqueue waits use: L_P with the split, else L0.
    var eventWaitLock: KernelLock { eventLock ?? lock }
    /// The system this process belongs to (process table, shared Mach state,
    /// the launcher; stage 4b). Every process of one system shares its lock.
    public let system: DarwinSystem
    /// The pid version (audit-token word 7): changes on every exec
    /// (`processes.md` §2.1).
    public internal(set) var pidVersion: UInt32 = 0
    /// The host path of this image's executable (csops reads its signature).
    var executableHostPath: String?
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
    /// The task's suspend count (`task_suspend`/`task_resume`,
    /// threads-and-events.md §1.6). While it is above zero no thread of the
    /// image runs guest code. Lock held.
    var taskSuspendCount = 0
    /// The main thread waits for the task's suspend count to reach zero
    /// before its first instruction (a `POSIX_SPAWN_START_SUSPENDED` image).
    /// Lock held.
    var mainStartPending = false
    /// What every later trap returns once the process is exiting.
    var termination: Outcome? {
        didSet { terminatingFlag.store(termination != nil, ordering: .releasing) }
    }
    /// `termination != nil`, readable without the kernel lock (fast paths).
    let terminatingFlag = Atomic<Bool>(false)
    /// The first non-SVC trap (fault, BRK) that ended the image, as it
    /// arrived: the VMM's fault report describes it even when another thread
    /// of the process returns the fatal outcome. Lock held.
    public private(set) var faultFrame: TrapFrame?
    /// Contract-pinned (stage 4b §3.4): true once this image is ending (exit,
    /// kill, exec). The VMM reads it without the lock before re-entering a vCPU.
    public var isTerminating: Bool { terminatingFlag.load(ordering: .acquiring) }
    /// ulock wait queues by address.
    var ulocks: [UInt64: ULockQueue] = [:]
    /// The process record of this image (`schedProcess`).
    weak var schedProcessCache: DarwinProcess?
    /// Senders blocked on a full queue of a port this image receives, 16
    /// bits per class (class c at bit 16·c): the send push of
    /// `scheduling-policy.md` §4.6. Changed by the senders without L0.
    let sendPushCounts = Atomic<UInt64>(0)
    /// `vm_purgable_control` states by page address (Ycode never purges).
    /// Its own leaf lock: the call is a task-local trap (`bsd-locking.md` §6).
    var purgeableStates: [UInt64: Int32] {
        get { purgeableStore.withLock { $0 } }
        set { purgeableStore.withLock { $0 = newValue } }
    }
    let purgeableStore = Mutex<[UInt64: Int32]>([:])
    /// The process workqueue and the kevent engine.
    var workqueue = WorkqueueState()
    var kevents = KEventState()
    /// EVFILT_READ/EVFILT_WRITE and EVFILT_SIGNAL knotes of this image
    /// (atomics: L0 code checks them without the event lock; such knotes are
    /// added only under L0, `mach-ipc-locking.md` §4.2).
    let descriptorKnoteCount = Atomic<Int>(0)
    /// EVFILT_READ, EVFILT_WRITE and EVFILT_VNODE knotes of this image
    /// (the ones a descriptor's close drops), by ident, counted from before
    /// their descriptor is looked up; may count too many (a dropped kqueue),
    /// never too few. A close without L0 runs the close hook under L0 only
    /// when its descriptor is here (`bsd-locking.md` §4.2). A leaf lock.
    let descriptorWatches = Mutex<[UInt64: Int]>([:])
    let signalKnoteCount = Atomic<Int>(0)
    /// The address space of the last trap (for work started outside a trap).
    var lastMemory: (any KernelGuestMemory)?

    // MARK: Stage-4b state (processes)

    /// Threads in `sigsuspend`: a posted signal they do not block wakes them.
    let signalWaiters = WaitQueue()
    /// The full value given to `exit` (for `waitid`'s 32-bit status).
    var exitValue: Int32?
    /// The signal that ends this process, when one does.
    var deathSignal: Int32?
    /// The main executable's LC_UUID (16 bytes), set by the launcher before
    /// the image runs. `proc_info` UNIQIDENTIFIERINFO `p_uuid`, rusage
    /// `ri_uuid` and `LOCAL_PEERUUID` report it (`processes.md` §2.11);
    /// logd attributes a client's log messages by it.
    public var executableUUID: [UInt8]?

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
        system: DarwinSystem? = nil,
        log: @escaping (String) -> Void = { _ in },
        counter: @escaping () -> UInt64 = MachTimebase.now,
        counterFrequency: UInt64 = MachTimebase.frequency,
        wallClock: @escaping () -> (seconds: Int64, nanoseconds: Int64) = DarwinKernel.hostWallClock
    ) {
        self.fileSystem = fileSystem
        self.pid = pid
        fileSystem.ownerPID = pid
        let system = system ?? DarwinSystem(implicit: true)
        self.system = system
        self.lock = system.lock
        eventLock = system.lock.splitEnabled ? KernelLock(fineLockOf: system.lock, level: 1, name: "event lock (pid \(pid))") : nil
        // kern.bootsessionuuid: this boot's session UUID (libsystem_trace's
        // logd aborts without it; xnu bsd/kern/kern_sysctl.c, a string).
        sysctl.entries.append(.init(name: "kern.bootsessionuuid", mib: [1, 1006], value: .string(system.bootSessionUUID)))
        self.log = log
        self.counter = counter
        self.counterFrequency = counterFrequency
        self.wallClock = wallClock
        mainThread = ThreadContext(threadID: 1, portName: WellKnownPort.thread, vcpuIndex: 0, kind: .main)
        threadsByPort[mainThread.portName] = mainThread
        mainThread.kernel = self
        machIPC = MachIPC(kernel: self)
        attachIPCHooks()
        // Every close (close, dup2 over an open fd, exec, exit) drops the
        // knotes and directory cursor of that descriptor (stage 4b).
        // Stage 6: and the process's POSIX record locks on that file.
        fileSystem.descriptorClosed = { [weak self] fd, file in
            self?.descriptorWasClosed(fd)
            self?.lock.withLock { self?.releasePOSIXLocksOnClose(file) }
        }
    }

    /// SNAPSHOT hook (agent SNAP, specs/simulator/snapshot.md §7 step 6):
    /// a restored image gets its `bsdthread_register` result back. Lock held.
    func snapshotRestoreThreadRegistration(_ registration: ThreadRegistration?) {
        threadRegistration = registration
    }

    private func attachIPCHooks() {
        machIPC?.messageQueuedHandler = { [weak self] name in self?.machPortMessageQueued(name) }
        (machIPC as? MachIPC)?.receiveRightGoneHandler = { [weak self] name in self?.machPortReceiveRightGone(name) }
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
    var current: ThreadContext {
        // A fast path (`mach-ipc-locking.md` §4.3) runs without L0: its
        // thread is the one this host thread serves.
        // Without L0 (a fast path or its deferred work) L0's context belongs
        // to another thread and must not be read.
        if eventLock != nil, !lock.isHeldByCurrentThread {
            return KernelThreadLocks.current.inheritedContext ?? mainThread
        }
        return lock.currentContext ?? mainThread
    }

    /// The host's calendar time since 1970 (the default `wallClock`).
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
    /// `tlbGeneration` changes, `frame.flushTLB` is set.
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
    ///
    /// `beforeTrap`, when given, runs first inside the same lock acquisition,
    /// on the frame as it arrived: the VMM's pre-trap bookkeeping (image
    /// attribution, the libSystem milestone, the shared-cache mmap record)
    /// shares the trap's one acquisition instead of taking a second one.
    public func handle(_ frame: inout TrapFrame, context: ThreadContext, memory: any KernelGuestMemory,
                       beforeTrap: (TrapFrame) -> Void = { _ in }) -> Outcome {
        // Diagnostics (`YCODE_TRAP_PROFILE`): handler time per trap number.
        if let profile = lock.trapProfile {
            let key = TrapProfile.filtered(frame.x.count > 16 ? Int64(Int32(truncatingIfNeeded: frame.x[16])) : 0,
                                           kernel: self)
            let start = KernelClock.now()
            defer {
                profile.noteHandler(key, KernelClock.now() &- start)
                if HostSched.backend != .none { HostSched.apply(max(context.schedClass, sendPushClass)) }
            }
            return handleTrap(&frame, context: context, memory: memory, beforeTrap: beforeTrap)
        }
        let outcome = handleTrap(&frame, context: context, memory: memory, beforeTrap: beforeTrap)
        // The host priority follows the class (scheduling-policy.md §4.7), outside the lock.
        if HostSched.backend != .none { HostSched.apply(max(context.schedClass, sendPushClass)) }
        return outcome
    }

    private func handleTrap(_ frame: inout TrapFrame, context: ThreadContext, memory: any KernelGuestMemory,
                            beforeTrap: (TrapFrame) -> Void) -> Outcome {
        lock.withLock(context: context) {
            beforeTrap(frame)
            if TrapFrame.peelLevel == 4, frame.kind == TrapFrame.Kind.svc.rawValue, TrapFrame.peels(at: 4, x16: frame.x[16]) {
                frame.answerPeeled()   // diagnostics (guest-cpu.md §5)
                return .resume
            }
            if context.kernel == nil { context.kernel = self }
            if let termination { return termination }
            context.entryFrame = frame
            defer { context.entryFrame = nil }
            let outcome = handleLocked(&frame, memory: memory)
            switch outcome {
            case .exit, .fatal:
                // Stage 4b: the image of a process in the table runs the
                // exit sequence (`processes.md` §2.4) and ends for good.
                if termination == nil, let p = system.record(of: self) {
                    let (status, high) = waitStatus(for: outcome)
                    system.exitProcess(p, waitStatus: status, highBits: high, outcome: outcome)
                    return outcome
                }
                // With other threads (or the timer thread) around, the exit
                // is final: blocked threads wake and every later trap returns
                // it. A lone thread's process just reports it (the VMM ends).
                if termination == nil, threadsByPort.count > 1 || withEvents({ kevents.timerThreadStarted }) {
                    termination = outcome
                    lock.terminate()
                    withEvents { kevents.timerWake.wakeAll() }
                }
                return outcome
            default:
                if let termination, outcome != .threadExit { return termination }
                return outcome
            }
        }
    }

    /// Ends this image (stage 4b): every wait of its threads ends, every
    /// later trap returns `outcome`, and its running vCPUs are kicked out.
    /// Other processes sharing the lock are not affected. Lock held.
    func endImage(_ outcome: Outcome) {
        if termination == nil { termination = outcome }
        if system.isImplicit { lock.terminate() } else { lock.terminate(kernel: self) }
        withEvents { kevents.timerWake.wakeAll() }
        signalWaiters.wakeAll()
        threadHost?.stopAllThreads()
    }

    /// The wait status word (`processes.md` §2.3) and `p_xhighbits` for an
    /// ending outcome: `exit(v)` → `(v & 0xFF) << 8`; a fatal outcome or a
    /// signal → the signal number (never a core flag).
    func waitStatus(for outcome: Outcome) -> (status: Int32, highBits: Int32) {
        switch outcome {
        case let .exit(status):
            let v = exitValue ?? status
            return ((v & 0xFF) << 8, (v >> 24) & 0xFF)
        case let .fatal(status, _):
            if let deathSignal { return (deathSignal, 0) }
            switch status {
            case 129...159: return (status - 128, 0)
            case Self.exceptionExitStatus: return (faultFrame.map(Self.faultSignal) ?? Signal.sigsegv, 0)
            default: return (Signal.sigkill, 0)
            }
        default:
            return (Signal.sigkill, 0)
        }
    }

    /// The signal that ends a process after a fatal hardware exception
    /// (`processes.md` §2.3.1): the Mach exception the arm64 Darwin kernel
    /// raises for the exception class, mapped as `ux_exception` maps it.
    /// BRK and debug exceptions → EXC_BREAKPOINT → SIGTRAP; an undefined or
    /// illegal instruction → EXC_BAD_INSTRUCTION → SIGILL; a floating-point
    /// trap → EXC_ARITHMETIC → SIGFPE; a translation, access-flag or
    /// address-size fault → KERN_INVALID_ADDRESS → SIGSEGV; a permission or
    /// alignment fault, or PC/SP misalignment → SIGBUS. Anything else: SIGSEGV.
    public static func faultSignal(_ frame: TrapFrame) -> Int32 {
        let syndrome = frame.syndrome
        guard let ec = syndrome.exceptionClass else { return Signal.sigsegv }
        switch ec {
        case .brk, .breakpointLowerEL, .breakpointSameEL, .softwareStepLowerEL, .softwareStepSameEL,
             .watchpointLowerEL, .watchpointSameEL:
            return Signal.sigtrap
        case .unknown, .illegalExecutionState:
            return Signal.sigill
        // An EL0 instruction the CPU traps to EL1 because this kernel does
        // not enable it (system instructions with SCTLR_EL1 enables clear,
        // e.g. CFP RCTX; SVE and SME with CPACR_EL1.ZEN/SMEN clear; PAC
        // traps): EXC_BAD_INSTRUCTION, as for an undefined instruction
        // (cpu-features.md §7.1, hidden features fail cleanly).
        case .trappedSystemRegister, .trappedSVE, .trappedSME, .trappedSIMDorFP, .pointerAuthenticationTrap:
            return Signal.sigill
        case .floatingPoint:
            return Signal.sigfpe
        case .pcAlignment, .spAlignment:
            return Signal.sigbus
        case .instructionAbortLowerEL, .instructionAbortSameEL, .dataAbortLowerEL, .dataAbortSameEL:
            let fsc = syndrome.faultStatusCode ?? 0x04
            switch fsc {
            case 0x0C...0x0F, 0x21: return Signal.sigbus
            default: return Signal.sigsegv
            }
        default:
            return Signal.sigsegv
        }
    }

    private func handleLocked(_ frame: inout TrapFrame, memory: any KernelGuestMemory) -> Outcome {
        guard frame.trapKind == .svc else {
            // The first touch of a page of a lazy anonymous mapping
            // (`GuestAddressSpace.lazyAnonymousThreshold`): give it backing
            // and run the instruction again.
            let syndrome = frame.syndrome
            if let ec = syndrome.exceptionClass, ec == .dataAbortLowerEL || ec == .instructionAbortLowerEL,
               let fsc = syndrome.faultStatusCode, (0x04...0x07).contains(fsc) {
                let tlb = memory.tlbGeneration
                if memory.resolveTranslationFault(va: frame.far) {
                    // New entries only: no flush unless the change also removed one.
                    if memory.tlbGeneration != tlb { frame.requestTLBInvalidation(memory.tlbRange(since: tlb)) }
                    return .resume
                }
            }
            trace("trap \(frame.trapKind?.description ?? "kind \(frame.kind)") fatal")
            if faultFrame == nil { faultFrame = frame }
            if Self.isCachePatchPlaceholderFault(frame) {
                return .fatal(status: Self.exceptionExitStatus,
                              message: Self.cachePatchPlaceholderMessage + "\n" + frame.description)
            }
            return .fatal(status: Self.exceptionExitStatus, message: frame.description)
        }
        lastMemory = memory
        let generation = memory.tlbGeneration
        let outcome = dispatch(&frame, memory: memory)
        if memory.tlbGeneration != generation { frame.requestTLBInvalidation(memory.tlbRange(since: generation)) }
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
        var args = frame.x.prefixArray(8)
        // The trace prefix is built only when trace text is wanted.
        let wantText = traceTextWanted(tracing)
        var prefix = wantText ? "trap bsd \(number)" : ""
        if number == 0 {
            number = Int(frame.x[0] & 0xFFFF)
            args = Array(frame.x[1...8])
            prefix = wantText ? "trap bsd 0 (indirect \(number))" : ""
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
            trace("trap platform set_tsd_base(\(hx(base))) -> tpidrro=\(hx(frame.tpidrro))")
        case 3:
            frame.x[0] = frame.tpidrro
            trace("trap platform get_tsd_base() -> \(hx(frame.tpidrro))")
        default:
            trace("trap platform selector \(selector) -> no-op")
        }
        return .resume
    }

    // MARK: BSD

    /// A BSD failure carrying a Darwin errno.
    struct Failure: Error { var errno: Int32 }

    enum BSDResult {
        case value(UInt64)
        /// Two result registers, x0 and x1, carry clear (stage 4b: `pipe`).
        case values(UInt64, UInt64)
        case exit(Int32)
        case fatal(Int32, String)
        case unimplemented
        /// The calling thread terminated.
        case threadExit
        /// Restart the calling thread at a new EL0 state (workqueue upcalls).
        case restart(ThreadStartState)
        /// Any other outcome, passed through unchanged (stage 4b: exec).
        case outcome(Outcome)
    }

    func errno(of error: Error, default fallback: Int32) -> Int32 {
        if let f = error as? Failure { return f.errno }
        if let d = error as? DarwinErrnoError { return d.errno }
        if error is GuestMemoryError { return Errno.EFAULT }
        return fallback
    }

    /// `gettimeofday(tp, tzp, mach_time)`: the calendar time, a zero
    /// timezone, the counter; then the commpage snapshot is refreshed
    /// (fast-traps.md §4: the library traps here only when its snapshot is
    /// stale). Needs no kernel lock: the publish is serialized by a leaf lock
    /// (two threads may refresh at once, on and off L0; `bsd-locking.md` §12).
    func gettimeofdayCall(_ a: [UInt64], _ mem: any KernelGuestMemory) throws -> UInt64 {
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
        if let publish = timeOfDayPublisher {
            timeOfDayLock.withLock {
                let tick = counter()
                let (s2, ns2) = wallClock()
                publish(tick, s2, ns2)
            }
        }
        return 0
    }

    private func handleBSD(_ n: Int, _ a: [UInt64], prefix: String, _ frame: inout TrapFrame,
                           _ mem: any KernelGuestMemory) -> Outcome {
        var call = CallText(tracing, TrapNames.describe(TrapNames.bsd(n), a))
        var fallback = Errno.EINVAL
        let result: BSDResult
        do {
            if n == BSD.stat64 && Self.isLoaderHelper(pc: frame.elr) {
                // The loader's stat helper: no cache-only image files.
                let path = try readPath(a[0], mem)
                call.set("stat64(\"\(path)\", buf=\(hx(a[1]))) [loader helper]")
                let fs = fileSystem
                let st = try lock.unlocked { try fs.stat(path, followSymlinks: true, cacheImages: false) }
                try mem.write(va: a[1], bytes: st.encodedStat64())
                result = .value(0)
            } else {
                result = try bsdCall(n, a, &call, &fallback, mem)
            }
        } catch {
            let e = errno(of: error, default: fallback)
            frame.x[0] = UInt64(UInt32(bitPattern: e))
            frame.x[1] = 0
            frame.carry = true
            trace("\(prefix) \(call) -> error \(e) (\(Errno.name(e)))")
            return .resume
        }
        switch result {
        case let .value(v):
            frame.x[0] = v
            frame.x[1] = 0
            frame.carry = false
            trace("\(prefix) \(call) -> \(hx(v))")
            return .resume
        case let .values(v0, v1):
            frame.x[0] = v0
            frame.x[1] = v1
            frame.carry = false
            trace("\(prefix) \(call) -> \(hx(v0)), \(hx(v1))")
            return .resume
        case let .exit(status):
            trace("\(prefix) \(call) -> exit \(status)")
            return .exit(status: status)
        case let .fatal(status, message):
            trace("\(prefix) \(call) -> fatal \(status)")
            return .fatal(status: status, message: message)
        case .threadExit:
            trace("\(prefix) \(call) -> thread exit")
            return .threadExit
        case let .outcome(o):
            trace("\(prefix) \(call) -> \(o)")
            return o
        case let .restart(start):
            start.apply(to: &frame)
            trace("\(prefix) \(call) -> restart at \(hx(start.pc)) x0=\(hx(start.x[0])) x3=\(hx(start.x[3])) "
                + "x4=\(hx(start.x[4])) x5=\(hx(start.x[5])) sp=\(hx(start.sp))")
            return .resume
        case .unimplemented:
            frame.x[0] = UInt64(Errno.ENOSYS)
            frame.x[1] = 0
            frame.carry = true
            // The frame is not described here: the VMM prints it once on the
            // trace path, and the summary key stops at the call text.
            trace("\(prefix) \(call) -> unimplemented")
            // Without trace text the summary key is the call's name.
            return .unimplemented(description: "unimplemented bsd \(n) " + (call.enabled ? call.description : TrapNames.bsd(n).name))
        }
    }

    private func bsdCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ fallback: inout Int32,
                         _ mem: any KernelGuestMemory) throws -> BSDResult {
        let fs = fileSystem
        // The `_nocancel` variants behave like their plain calls (no
        // cancellation in Ycode).
        let n = BSD.nocancelAliases[n] ?? n
        // Stage-4b hooks (`stage4b-contract.md` §2): descriptors (pipes,
        // sockets, dup) first, then processes (spawn, wait, signals). Each
        // returns nil for a call it does not own.
        if let r = try descriptorCall(n, a, &call, &fallback, mem) { return r }
        if let r = try processCall(n, a, &call, &fallback, mem) { return r }
        func fd(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }

        switch n {
        case BSD.exit:
            call.set("exit(\(int(0)))")
            return .exit(Int32(a[0] & 0xFF))

        case BSD.read, BSD.pread:
            let isPread = n == BSD.pread
            call.set(isPread ? "pread(fd=\(fd(0)), buf=\(hx(a[1])), len=\(hx(a[2])), off=\(hx(a[3])))"
                : "read(fd=\(fd(0)), buf=\(hx(a[1])), len=\(hx(a[2])))")
            let count = Int(min(a[2], UInt64(Int32.max)))
            let bytes: [UInt8]
            if let io = try hostFileIO(fd(0), writing: false) {
                bytes = try readUnlocked(io, count: count, offset: isPread ? a[3] : nil)
            } else {
                bytes = isPread ? try fs.pread(fd(0), count: count, offset: a[3]) : try fs.read(fd(0), count: count)
            }
            if !bytes.isEmpty { try mem.write(va: a[1], bytes: bytes) }
            return .value(UInt64(bytes.count))

        case BSD.write:
            call.set("write(fd=\(fd(0)), buf=\(hx(a[1])), len=\(hx(a[2])))")
            guard a[2] <= UInt64(Int32.max) else { throw Failure(errno: Errno.EINVAL) }
            let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            if let io = try hostFileIO(fd(0), writing: true) {
                return .value(UInt64(try writeUnlocked(io, bytes, offset: nil)))
            }
            return .value(UInt64(try fs.write(fd(0), bytes)))

        case BSD.open:
            let path = try readPath(a[0], mem)
            call.set("open(\"\(path)\", flags=\(openFlagsText(int(1))), mode=0o\(String(a[2] & 0o7777, radix: 8)))")
            let newFD = try openUnlocked(path, flags: int(1), mode: UInt16(truncatingIfNeeded: a[2]))
            return .value(UInt64(UInt32(bitPattern: newFD)))

        case BSD.close:
            call.set("close(\(fd(0)))")
            try fs.close(fd(0))
            extended.directoryCursors[fd(0)] = nil
            return .value(0)

        case BSD.getpid:
            call.set("getpid()")
            return .value(UInt64(UInt32(bitPattern: pid)))
        case BSD.getuid, BSD.geteuid:
            call.set(n == BSD.getuid ? "getuid()" : "geteuid()")
            return .value(UInt64(DarwinFileSystem.guestUID))
        case BSD.getgid, BSD.getegid:
            call.set(n == BSD.getgid ? "getgid()" : "getegid()")
            return .value(UInt64(DarwinFileSystem.guestGID))

        case BSD.ioctl:
            call.set("ioctl(fd=\(fd(0)), request=\(hx(a[1])), arg=\(hx(a[2])))")
            throw Failure(errno: Errno.ENOTTY)

        case BSD.mmap:
            return .value(try mmap(a, &call, &fallback, mem))

        case BSD.munmap:
            call.set("munmap(addr=\(hx(a[0])), len=\(hx(a[1])))")
            guard a[0] & Self.pageMask == 0, a[1] > 0 else { throw Failure(errno: Errno.EINVAL) }
            try mem.unmap(va: a[0], size: roundUp(a[1], to: Self.pageSize))
            return .value(0)

        case BSD.mprotect:
            let prot = protection(a[2])
            call.set("mprotect(addr=\(hx(a[0])), len=\(hx(a[1])), prot=\(protText(a[2])))")
            let start = a[0] & ~Self.pageMask
            let size = roundUp(a[1] + (a[0] - start), to: Self.pageSize)
            if size > 0 { try mem.protect(va: start, size: size, protection: prot) }
            return .value(0)

        case BSD.madvise:
            // Also posix_madvise (an alias on Darwin). Advice 0…11 (MADV_NORMAL
            // … MADV_ZERO, sys/mman.h) is accepted; only MADV_ZERO (11) changes
            // memory: the range reads as zeros afterwards (xnu VM_BEHAVIOR_ZERO,
            // level 1). The others are hints or allow lazy discard, so keeping
            // the pages is correct. Other values are EINVAL (the madvise(2)
            // manual page: "the value of advice is incorrect"; level 1).
            call.set("madvise(addr=\(hx(a[0])), len=\(hx(a[1])), advice=\(int(2)))")
            guard (0...11).contains(int(2)) else { throw Failure(errno: Errno.EINVAL) }
            if int(2) == 11, a[1] > 0 {
                let end = a[0].addingReportingOverflow(a[1])
                guard !end.overflow else { throw Failure(errno: Errno.EINVAL) }
                let zeros = [UInt8](repeating: 0, count: Int(min(a[1], 1 << 20)))
                var at = a[0]
                while at < end.partialValue {
                    let n = Int(min(UInt64(zeros.count), end.partialValue - at))
                    do { try mem.write(va: at, bytes: n == zeros.count ? zeros : Array(zeros[0..<n])) } catch {
                        throw Failure(errno: Errno.ENOMEM)
                    }
                    at += UInt64(n)
                }
            }
            return .value(0)

        case BSD.fcntl:
            return .value(try fcntl(a, &call, mem))

        case BSD.gettimeofday:
            call.set("gettimeofday(tp=\(hx(a[0])), tzp=\(hx(a[1])), mach_time=\(hx(a[2])))")
            return .value(try gettimeofdayCall(a, mem))

        case BSD.sysctl:
            return .value(try sysctlMIB(a, &call, mem))

        case BSD.sysctlbyname:
            let name = try readString(a[0], length: Int(min(a[1], 1024)), mem)
            call.set("sysctlbyname(\"\(name)\", old=\(hx(a[2])), oldlenp=\(hx(a[3])), new=\(hx(a[4])), newlen=\(hx(a[5])))")
            return .value(try sysctlRead(sysctl.lookup(name: name), name: name,
                                         old: a[2], oldlenp: a[3], new: a[4], newlen: a[5], mem))

        case BSD.getattrlist, 228, 476:
            return .value(try attributeListCall(n, a, &call, mem))

        case 221, 229, 524:  // setattrlist, fsetattrlist, setattrlistat
            return .value(try setAttributeListCall(n, a, &call, mem))

        case BSD.getattrlistbulk:
            return .value(try attributeListBulkCall(a, &call, mem))

        case BSD.fsgetpath, 217:  // fsgetpath, fsgetpath_ext
            return .value(try fsGetPathCall(n, a, &call, mem))

        case 479:  // openbyid_np
            return .value(try openByIDCall(a, &call, mem))

        case BSD.issetugid:
            call.set("issetugid()")
            return .value(0)

        case BSD.stat64, BSD.lstat64:
            let path = try readPath(a[0], mem)
            call.set("\(n == BSD.stat64 ? "stat64" : "lstat64")(\"\(path)\", buf=\(hx(a[1])))")
            let st = try statUnlocked(path, followSymlinks: n == BSD.stat64)
            try mem.write(va: a[1], bytes: st.encodedStat64())
            return .value(0)

        case BSD.fstat64:
            call.set("fstat64(fd=\(fd(0)), buf=\(hx(a[1])))")
            try mem.write(va: a[1], bytes: fs.fstat(fd(0)).encodedStat64())
            return .value(0)

        case 341, 342, 343:
            // stat64_extended / lstat64_extended / fstat64_extended: stat64
            // plus the file's ACL (filesec); Ycode files carry none, so the
            // size out-parameter is 0 (xnu vfs_syscalls.c stat2/fstat1).
            let st: DarwinStat
            if n == 343 {
                call.set("fstat64_extended(fd=\(fd(0)), buf=\(hx(a[1])), xsec=\(hx(a[2])), xsize=\(hx(a[3])))")
                st = try fs.fstat(fd(0))
            } else {
                let path = try readPath(a[0], mem)
                call.set("\(n == 341 ? "stat64_extended" : "lstat64_extended")(\"\(path)\", buf=\(hx(a[1])))")
                st = try statUnlocked(path, followSymlinks: n == 341)
            }
            try mem.write(va: a[1], bytes: st.encodedStat64())
            if a[3] != 0 { try mem.write(va: a[3], bytes: [UInt8](repeating: 0, count: 8)) }
            return .value(0)

        case BSD.getfsstat64:
            call.set("getfsstat64(buf=\(hx(a[0])), bufsize=\(int(1)), flags=\(int(2)))")
            return .value(try fileSystemStatList(buffer: a[0], size: a[1], &call, mem))

        case BSD.bsdthreadRegister:
            return .value(try bsdthreadRegister(a, &call, mem))

        case BSD.abortWithPayload:
            let reason = a[4] == 0 ? "" : ((try? readString(a[4], length: 4096, mem)) ?? "<unreadable>")
            call.set("abort_with_payload(namespace=\(UInt32(truncatingIfNeeded: a[0])), code=\(hx(a[1])), "
                + "payload=\(hx(a[2])), size=\(UInt32(truncatingIfNeeded: a[3])), flags=\(hx(a[5])))")
            let message = "abort_with_payload: namespace \(UInt32(truncatingIfNeeded: a[0])) code \(hx(a[1])): \(reason)"
            return .fatal(Self.abortExitStatus, message)

        default:
            if let result = try posixShmCall(n, a, &call, mem) { return result }
            if PosixSemBSD.all.contains(n) { return try posixSemCall(n, a, &call, mem) }
            if SystemControlBSD.all.contains(n) { return try systemControlCall(n, a, &call, mem) }
            return try extendedBSDCall(n, a, &call, &fallback, mem) ?? .unimplemented
        }
    }

    // MARK: mmap

    /// `fast` (a BSD fast path, `bsd-locking.md` §4.5): a POSIX shared
    /// memory object (L0 state) throws `BSDFastDecline` before anything
    /// changes.
    func mmap(_ a: [UInt64], _ call: inout CallText, _ fallback: inout Int32,
              _ mem: any KernelGuestMemory, fast: Bool = false) throws -> UInt64 {
        let addr = a[0], len = a[1]
        let flags = Int32(truncatingIfNeeded: a[3])
        let fd = Int32(truncatingIfNeeded: a[4])
        let pos = a[5]
        call.set("mmap(addr=\(hx(addr)), len=\(hx(len)), prot=\(protText(a[2])), flags=\(mapFlagsText(flags)), "
            + "fd=\(fd), off=\(hx(pos)))")
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
        } else if let open = try? fileSystem.openFile(for: fd), let shm = open.object as? PosixShmDescriptor {
            if fast { throw BSDFastDecline() }
            guard pageOffset == 0 else { throw Failure(errno: Errno.EINVAL) }
            va = try mapPosixShm(shm, file: open, flags: flags, prot: prot, offset: pos, size: size, at: at, hint: hint, mem)
        } else {
            // (`file(for:)` looks the descriptor up again: a descriptor that
            // became a shared memory object meanwhile is ENODEV, as any
            // object; the guest raced its own close or dup2.)
            let file = try fileSystem.file(for: fd)
            let shared = flags & MapFlag.shared != 0 && flags & MapFlag.private == 0
            // MAP_SHARED of a file open for writing: a view of the host
            // file's pages, so writes reach the file and every other view
            // (IconServices' store is written through one mapping and read
            // through another; chronod's mapped-file allocator; SQLite's
            // shared-memory index). A read-only MAP_SHARED view of a file
            // under a writable prefix is a view too, so it sees later
            // writes (SpotlightIndex reads its index files through such
            // views while it appends to them; service-fidelity.md §10).
            // Otherwise a private view.
            let readOnlyView = !prot.contains(.write) && fileSystem.writable(guestPath: file.guestPath)
            if shared, !Self.debugPrivateSharedFiles,
               let object = SharedMemoryObject(hostFile: file.hostFD, offset: pos - pageOffset, size: size,
                                               fileSize: file.size, reopenReadOnly: readOnlyView) {
                call += " [shared file view]"
                // SNAPSHOT hook (agent SNAP, snapshot.md §2.1): what to map again on restore.
                object.snapshotFileSource = .init(guestPath: file.guestPath, hostPath: file.hostPath,
                                                  offset: pos - pageOffset, requestedSize: size)
                va = try mem.mapShared(object, offset: 0, at: at, size: size, protection: prot, hint: hint)
            } else {
                if shared { trace("note: MAP_SHARED file mapping of \(file.guestPath) is mapped private") }
                va = try mem.mapFile(file, offset: pos - pageOffset, at: at, size: size, protection: prot, hint: hint)
            }
        }
        return va + pageOffset
    }

    // MARK: bsdthread_register

    /// BSD 366 (`host-library-init.md` §6.1): records the entry points and
    /// offsets, writes back the record's out fields, and returns the feature
    /// mask of `host-libraries.md` §7.4.
    private func bsdthreadRegister(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let size = UInt32(truncatingIfNeeded: a[2])
        let recordSize = UInt32(truncatingIfNeeded: a[4])
        call.set("bsdthread_register(threadstart=\(hx(a[0])), wqthread=\(hx(a[1])), pthsize=\(hx(size)), "
            + "data=\(hx(a[3])), datasize=\(recordSize), offset=\(hx(a[5])))")
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

    // MARK: Host file-system I/O without the kernel lock (stage6-contract.md §5.1)

    /// `stat` of a guest path with the kernel lock released for the host I/O.
    func statUnlocked(_ path: String, followSymlinks: Bool) throws -> DarwinStat {
        let fs = fileSystem
        return try lock.unlocked { try fs.stat(path, followSymlinks: followSymlinks) }
    }

    /// Diagnostics A/B: `YCODE_FS_LOCKED_IO=1` keeps regular-file reads,
    /// writes and renames under the kernel lock (as before §5.2).
    static let lockedFileIO = getenv("YCODE_FS_LOCKED_IO").map { String(cString: $0) == "1" } ?? false

    /// The `HostFileIO` of a regular host file (checks made now, with the
    /// lock), or nil: the plain call handles the descriptor.
    func hostFileIO(_ fd: Int32, writing: Bool, guardChecked: Bool = false) throws -> HostFileIO? {
        guard !Self.lockedFileIO else { return nil }
        return try fileSystem.hostFileIO(fd, writing: writing, guardChecked: guardChecked)
    }

    /// A regular-file read (`offset` nil: at the description's offset): from
    /// the page cache with the lock held when it is all there, otherwise
    /// with the kernel lock released for the host I/O (§5.2).
    ///
    /// After the lock is taken again only the image is checked (EINTR when
    /// it ended meanwhile, as for `openUnlocked`): the descriptor is not
    /// looked up again, because the transfer belongs to the description it
    /// started on, and the caller copies the data into guest memory with
    /// the lock held.
    func readUnlocked(_ io: HostFileIO, count: Int, offset: UInt64?) throws -> [UInt8] {
        if let offset {
            if let cached = io.preadIfCached(count: count, offset: offset) { return cached }
        } else if let cached = io.readIfCached(count: count) {
            return cached
        }
        let bytes = try lock.unlocked { try offset.map { try io.pread(count: count, offset: $0) } ?? io.read(count: count) }
        guard !isTerminating else { throw Failure(errno: 4) }
        return bytes
    }

    /// A regular-file write (`offset` nil: at the description's offset, or
    /// at the end with O_APPEND) with the kernel lock released for the host
    /// I/O (§5.2). The bytes were copied from guest memory with the lock
    /// held; nothing is revalidated afterwards (the result goes to the
    /// guest only).
    func writeUnlocked(_ io: HostFileIO, _ bytes: [UInt8], offset: UInt64?) throws -> Int {
        try lock.unlocked { try offset.map { try io.pwrite(bytes, offset: $0) } ?? io.write(bytes) }
    }

    /// `open`: resolve and open the host file without the kernel lock, then
    /// install the descriptor with it (EINTR if the image ended meanwhile).
    func openUnlocked(_ path: String, flags: Int32, mode: UInt16) throws -> Int32 {
        let fs = fileSystem
        let prepared = try lock.unlocked { try fs.prepareOpen(path, flags: flags, mode: mode) }
        guard !isTerminating else { throw Failure(errno: 4) }
        return try fs.install(prepared)
    }

    // MARK: fcntl

    /// fcntl command names for trace text.
    static let fcntlNames: [Int32: String] = [1: "F_GETFD", 2: "F_SETFD", 3: "F_GETFL", 50: "F_GETPATH",
                                              42: "F_PREALLOCATE", 44: "F_RDADVISE", 45: "F_RDAHEAD", 48: "F_NOCACHE",
                                              51: "F_FULLFSYNC", 63: "F_GETPROTECTIONCLASS", 64: "F_SETPROTECTIONCLASS", 77: "F_GETPROTECTIONLEVEL",
                                              85: "F_BARRIERFSYNC", 102: "F_GETPATH_NOFIRMLINK", 95: "F_SETCONFINED", 96: "F_GETCONFINED",
                                              97: "F_ADDFILESIGS_RETURN", 98: "F_CHECK_LV"]

    private func fcntl(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let fs = fileSystem
        let fd = Int32(truncatingIfNeeded: a[0])
        let cmd = Int32(truncatingIfNeeded: a[1])
        let arg = a[2]
        call.set("fcntl(fd=\(fd), \(Self.fcntlNames[cmd] ?? "cmd \(cmd)"), arg=\(hx(arg)))")
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
        case Fcntl.getpathNoFirmlink:
            let path = try fs.path(for: fd)
            let bytes = cString(path)
            guard bytes.count <= DarwinFileSystem.maxPathLength else { throw Failure(errno: Errno.ENAMETOOLONG) }
            try mem.write(va: arg, bytes: bytes)
            call += " [\(path)]"
            return 0
        case let c where Fcntl.hints.contains(c):
            // Caching and ordering hints (F_NOCACHE, F_FULLFSYNC, F_BARRIERFSYNC,
            // F_RDAHEAD, ...): accepted on any open descriptor; Ycode's
            // writes reach the host file before the call returns.
            _ = try fs.openFile(for: fd)
            return 0
        case Fcntl.getProtectionClass, Fcntl.setProtectionClass, Fcntl.getProtectionLevel:
            // Data-protection classes as the simulator's host volume keeps
            // them (FileLocks.swift; level 3).
            return try protectionFcntl(fd, cmd, arg, &call)
        case Fcntl.preallocate:
            // fstore_t: fst_flags u32 @0, fst_posmode i32 @4, fst_offset @8,
            // fst_length @16, fst_bytesalloc @24 (sys/fcntl.h). xnu
            // (kern_descrip.c) needs a descriptor open for writing (EBADF),
            // F_PEOFPOSMODE 3 or F_VOLPOSMODE 4, and a length > 0 (EINVAL).
            _ = try fs.openFile(for: fd)
            guard try fs.statusFlags(fd) & 0x3 != 0 else { throw Failure(errno: Errno.EBADF) }
            let store = try mem.read(va: arg, count: 32)
            let posmode = store.readLE(Int32.self, at: 4), length = store.readLE(Int64.self, at: 16)
            guard posmode == 3 || posmode == 4, length > 0 else { throw Failure(errno: Errno.EINVAL) }
            var allocated: [UInt8] = []
            allocated.appendLE(store.readLE(Int64.self, at: 16))
            try mem.write(va: arg + 24, bytes: allocated)
            return 0
        case Fcntl.setfd:
            try fs.setCloseOnExec(fd, arg & 1 != 0)
            try fs.setCloseOnFork(fd, arg & 2 != 0)
            return 0
        case Fcntl.getfd:
            return (try fs.closeOnExec(fd) ? 1 : 0) | (try fs.closeOnFork(fd) ? 2 : 0)
        case Fcntl.setConfined:
            // F_SETCONFINED / F_GETCONFINED (xnu bsd/sys/fcntl.h, kern_descrip.c).
            try fs.setConfined(fd, arg != 0)
            return 0
        case Fcntl.getConfined:
            return try fs.openFile(for: fd).confinedToProcess ? 1 : 0
        case Fcntl.getfl:
            return UInt64(UInt32(bitPattern: try fs.statusFlags(fd)))
        default:
            throw Failure(errno: Errno.EINVAL)
        }
    }

    // MARK: sysctl

    func sysctlMIB(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let count = Int(UInt32(truncatingIfNeeded: a[1]))
        call.set("sysctl(name=\(hx(a[0])), namelen=\(count), old=\(hx(a[2])), oldlenp=\(hx(a[3])), "
            + "new=\(hx(a[4])), newlen=\(hx(a[5])))")
        guard count >= 1, count <= 12 else { throw Failure(errno: Errno.EINVAL) }
        let raw = try mem.read(va: a[0], count: 4 * count)
        let mib = (0..<count).map { raw.readLE(Int32.self, at: 4 * $0) }
        call.set("sysctl([\(mib.map(String.init).joined(separator: ","))], old=\(hx(a[2])), oldlenp=\(hx(a[3])), "
            + "new=\(hx(a[4])), newlen=\(hx(a[5])))")
        if mib == [0, 3] {
            // name2oid: the name is the new value; the OID is returned in old.
            var nameBytes = try mem.read(va: a[4], count: Int(min(a[5], 1024)))
            while nameBytes.last == 0 { nameBytes.removeLast() }
            let name = String(decoding: nameBytes, as: UTF8.self)
            call += " [name2oid \"\(name)\"]"
            guard let entry = sysctl.lookup(name: name) else {
                trace("note: sysctl name \"\(name)\" is not known")
                throw Failure(errno: Errno.ENOENT)
            }
            var oid: [UInt8] = []
            for v in entry.mib { oid.appendLE(v) }
            return try copyOut(oid, old: a[2], oldlenp: a[3], mem)
        }
        if mib.count == 4, mib[0] == 1, mib[1] == 14, mib[2] == 1 {
            // kern.proc.pid.<pid>: one struct kinfo_proc; an unknown pid
            // returns no data and no error (xnu sysctl_prochandle).
            call += " [kern.proc.pid.\(mib[3])]"
            if a[4] != 0 && a[5] != 0 { throw Failure(errno: Errno.EPERM) }
            return try copyOut(kinfoProc(mib[3]) ?? [], old: a[2], oldlenp: a[3], mem)
        }
        if mib.count >= 5, mib[0] == 4, mib[1] == 17, let table = NetworkInterfaces.routingSysctl(mib) {
            // net.route (PF_ROUTE): interfaces and routes (networking-ycode.md §3).
            call += " [net.route, \(table.count) bytes]"
            if a[4] != 0 && a[5] != 0 { throw Failure(errno: Errno.EPERM) }
            return try copyOut(table, old: a[2], oldlenp: a[3], mem)
        }
        let entry = sysctl.lookup(mib: mib)
        if let entry { call += " [\(entry.name)]" }
        return try sysctlRead(entry, name: mib.map(String.init).joined(separator: "."),
                              old: a[2], oldlenp: a[3], new: a[4], newlen: a[5], mem)
    }

    func sysctlRead(_ entry: SysctlTable.Entry?, name: String, old: UInt64, oldlenp: UInt64,
                    new: UInt64, newlen: UInt64, _ mem: any KernelGuestMemory) throws -> UInt64 {
        guard let entry else {
            trace("note: sysctl \"\(name)\" is not known")
            throw Failure(errno: Errno.ENOENT)
        }
        if case let .error(e) = entry.value { throw Failure(errno: e) }
        if new != 0, newlen != 0 { throw Failure(errno: Errno.EPERM) }
        var oldLength: UInt64?
        if old != 0, oldlenp != 0 { oldLength = try readU64(oldlenp, mem) }
        switch entry.value.answer(forBufferOf: oldLength) {
        case let .bytes(b):
            return try copyOut(b, old: old, oldlenp: oldlenp, mem)
        case let .failure(e, length):
            if let length { try writeU64(oldlenp, length, mem) }
            throw Failure(errno: e)
        }
    }

    /// Returns `bytes` the sysctl way: a size query when `old` is NULL;
    /// when the buffer is too small, what fits is copied and the call fails
    /// with ENOMEM (xnu `SYSCTL_OUT`; cpu-features.md §4.5).
    private func copyOut(_ bytes: [UInt8], old: UInt64, oldlenp: UInt64, _ mem: any KernelGuestMemory) throws -> UInt64 {
        if old == 0 {
            if oldlenp != 0 { try writeU64(oldlenp, UInt64(bytes.count), mem) }
            return 0
        }
        guard oldlenp != 0 else { throw Failure(errno: Errno.EINVAL) }
        let capacity = try readU64(oldlenp, mem)
        guard capacity >= UInt64(bytes.count) else {
            if capacity > 0 { try mem.write(va: old, bytes: Array(bytes.prefix(Int(capacity)))) }
            throw Failure(errno: Errno.ENOMEM)
        }
        try mem.write(va: old, bytes: bytes)
        try writeU64(oldlenp, UInt64(bytes.count), mem)
        return 0
    }

    // MARK: Mach

    /// `mach_vm_map(target, *addr, size, mask, flags, cur_protection)` of
    /// anonymous memory: the kern_return_t and the address. Address-space
    /// changes only (L1; a fixed placement checks and maps as one change), so
    /// it is also a task-local trap (`bsd-locking.md` §12).
    func vmMapAnonymous(_ a: [UInt64], _ mem: any KernelGuestMemory) -> (UInt64, UInt64?) {
        guard let requested = try? readU64(a[1], mem) else { return (KernReturn.invalidAddress, nil) }
        guard a[2] != 0 else { return (KernReturn.invalidArgument, nil) }
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
                guard requested & Self.pageMask == 0 else { return (KernReturn.invalidArgument, nil) }
                let placed: UInt64? = try mem.atomically {
                    if a[4] & Self.vmFlagsOverwrite == 0, overlapsMapping(requested, size, mem) { return nil }
                    return try mem.mapAnonymous(at: requested, size: size, protection: prot, hint: nil)
                }
                guard let placed else { return (KernReturn.noSpace, nil) }
                va = placed
            }
        } catch {
            return (KernReturn.noSpace, nil)
        }
        guard (try? writeU64(a[1], va, mem)) != nil else { return (KernReturn.invalidAddress, nil) }
        return (KernReturn.success, va)
    }

    /// `mach_generate_activity_id(target, count, &id)`: the last of `count`
    /// new ids (one atomic add), written to `id`; nil when it cannot be.
    func generateActivityID(_ a: [UInt64], _ mem: any KernelGuestMemory) -> UInt64? {
        let id = activityIDs.wrappingAdd(UInt64(max(UInt32(truncatingIfNeeded: a[1]), 1)), ordering: .relaxed).newValue
        return (try? writeU64(a[2], id, mem)) != nil ? id : nil
    }

    private func handleMach(_ n: Int, _ frame: inout TrapFrame, _ mem: any KernelGuestMemory) -> Outcome {
        let a = frame.x.prefixArray(8)
        var call = CallText(tracing, TrapNames.describe(TrapNames.mach(n), a))
        let prefix = traceTextWanted(tracing) ? "trap mach \(n)" : ""
        func port(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: a[i]) }
        func kr(_ value: UInt64, _ extra: String = "") -> Outcome {
            frame.x[0] = value
            trace("\(prefix) \(call) -> \(KernReturn.name(value))\(extra)")
            return .resume
        }
        func portResult(_ name: UInt32) -> Outcome {
            frame.x[0] = UInt64(name)
            trace("\(prefix) \(call) -> \(hx(name))")
            return .resume
        }

        switch n {
        case Mach.machAbsoluteTime, Mach.machContinuousTime:
            let t = counter()
            frame.x[0] = t
            trace("\(prefix) \(n == Mach.machAbsoluteTime ? "mach_absolute_time" : "mach_continuous_time")() -> \(hx(t))")
            return .resume

        case Mach.vmAllocate:
            call.set("vm_allocate(target=\(hx(port(0))), addr=\(hx(a[1])), size=\(hx(a[2])), flags=\(hx(a[3])))")
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
                    // Check and map as one address-space change (task-local
                    // traps may map concurrently; boot-profile.md §3.6).
                    let placed: UInt64? = try mem.atomically {
                        if a[3] & Self.vmFlagsOverwrite == 0, overlapsMapping(requested, size, mem) { return nil }
                        return try mem.mapAnonymous(at: requested, size: size, protection: [.read, .write], hint: nil)
                    }
                    guard let placed else { return kr(KernReturn.noSpace) }
                    va = placed
                }
            } catch {
                return kr(KernReturn.noSpace)
            }
            guard (try? writeU64(a[1], va, mem)) != nil else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [addr=\(hx(va))]")

        case Mach.vmPurgableControl:
            // xnu osfmk/mach/vm_purgable.h: control 0 SET_STATE (in: new
            // state, out: old), 1 GET_STATE, 2 PURGE_ALL. Ycode memory is
            // never purged, so a volatile region keeps its contents and
            // reports VOLATILE, never EMPTY (2).
            call.set("vm_purgable_control(target=\(hx(port(0))), addr=\(hx(a[1])), control=\(Int32(truncatingIfNeeded: a[2])), state=\(hx(a[3])))")
            return kr(purgeableControl(a, mem))

        case Mach.vmDeallocate:
            call.set("vm_deallocate(target=\(hx(port(0))), addr=\(hx(a[1])), size=\(hx(a[2])))")
            guard a[2] != 0 else { return kr(KernReturn.success) }
            let start = a[1] & ~Self.pageMask
            let size = roundUp(a[2] + (a[1] - start), to: Self.pageSize)
            do { try mem.unmap(va: start, size: size) } catch { return kr(KernReturn.invalidArgument) }
            return kr(KernReturn.success)

        case Mach.vmProtect:
            let protBits = a[4] & ~Self.vmProtCopy
            call.set("vm_protect(target=\(hx(port(0))), addr=\(hx(a[1])), size=\(hx(a[2])), set_max=\(a[3] & 1), "
                + "prot=\(protText(a[4]))\(a[4] & Self.vmProtCopy != 0 ? "|COPY" : ""))")
            if a[3] & 0xFFFF_FFFF != 0 { return kr(KernReturn.success, " [maximum protection not tracked]") }
            guard a[2] != 0 else { return kr(KernReturn.success) }
            let start = a[1] & ~Self.pageMask
            let size = roundUp(a[2] + (a[1] - start), to: Self.pageSize)
            do { try mem.protect(va: start, size: size, protection: protection(protBits)) } catch {
                return kr(KernReturn.invalidAddress)
            }
            return kr(KernReturn.success)

        case Mach.timebaseInfo:
            call.set("mach_timebase_info(info=\(hx(a[0])))")
            let tb = timebase
            var b: [UInt8] = []
            b.appendLE(tb.numer)
            b.appendLE(tb.denom)
            guard (try? mem.write(va: a[0], bytes: b)) != nil else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [\(tb.numer)/\(tb.denom)]")

        case Mach.vmMap:
            // target, *addr, size, mask, flags, cur_protection.
            call.set("mach_vm_map(target=\(hx(port(0))), addr=\(hx(a[1])), size=\(hx(a[2])), mask=\(hx(a[3])), "
                + "flags=\(hx(a[4])), prot=\(protText(a[5])))")
            let (result, va) = vmMapAnonymous(a, mem)
            return kr(result, va.map { " [addr=\(hx($0))]" } ?? "")

        case Mach.generateActivityID:
            call.set("mach_generate_activity_id(target=\(hx(port(0))), count=\(port(1)), id=\(hx(a[2])))")
            let id = generateActivityID(a, mem)
            guard let id else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success, " [\(hx(id))]")

        case Mach.pidForTask:
            call.set("pid_for_task(task=\(hx(port(0))), pid=\(hx(a[1])))")
            guard port(0) == WellKnownPort.task else { return kr(KernReturn.failure) }
            guard (try? writeU32(a[1], UInt32(bitPattern: pid), mem)) != nil else { return kr(KernReturn.invalidAddress) }
            return kr(KernReturn.success)

        case Mach.waitUntil:
            call.set("mach_wait_until(deadline=\(hx(a[0])))")
            let result = WaitQueue().wait(on: lock, deadline: hostDeadline(machTicks: a[0]))
            return kr(result == .interrupted ? KernReturn.aborted : KernReturn.success)

        default:
            if let v = mkTimerTrap(n, a, &call, mem) {
                return n == Self.mkTimerCreate ? portResult(UInt32(truncatingIfNeeded: v)) : kr(v)
            }
            let entry = TrapNames.mach(n)
            frame.x[0] = entry.name == "kern_invalid" || !isPortReturning(n) ? KernReturn.failure : 0
            trace("\(prefix) \(call) -> unimplemented")
            return .unimplemented(description: "unimplemented mach \(n) " + (call.enabled ? call.description : entry.name))
        }
    }

    private func isPortReturning(_ n: Int) -> Bool { [-26, -27, -28, -29, -50, -91].contains(n) }

    private func overlapsMapping(_ va: UInt64, _ size: UInt64, _ mem: any KernelGuestMemory) -> Bool {
        !mem.regions(overlapping: va..<max(va, va &+ size)).isEmpty
    }

    // MARK: Private traps

    private func handlePrivate(_ number: UInt32, _ frame: inout TrapFrame, _ mem: any KernelGuestMemory) -> Outcome {
        let a = frame.x.prefixArray(8)
        let wantText = traceTextWanted(tracing)
        let prefix = wantText ? "trap yc \(hx(number & 0xFFFF))" : ""
        var call = CallText(tracing, "private \(hx(number))")
        // BSD-style result.
        func ok(_ v: UInt64, _ extra: String = "") -> Outcome {
            frame.x[0] = v
            frame.x[1] = 0
            frame.carry = false
            trace("\(prefix) \(call) -> \(hx(v))\(extra)")
            return .resume
        }
        func fail(_ error: Error) -> Outcome {
            let e = errno(of: error, default: Errno.EINVAL)
            frame.x[0] = UInt64(UInt32(bitPattern: e))
            frame.x[1] = 0
            frame.carry = true
            trace("\(prefix) \(call) -> error \(e) (\(Errno.name(e)))")
            return .resume
        }
        // Mach-style result.
        func kr(_ value: UInt64, _ extra: String = "") -> Outcome {
            frame.x[0] = value
            frame.carry = false
            trace("\(prefix) \(call) -> \(KernReturn.name(value))\(extra)")
            return .resume
        }

        if (Private.threadSuspend...Private.taskResume).contains(number) {
            return handleThreadControl(number, &frame, mem)
        }
        switch number {
        case Private.vlog:
            call.set("vlog(fmt=\(hx(a[0])), va_list=\(hx(a[1])))")
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
            call.set("realpath(path=\(hx(a[0])), out=\(hx(a[1])))")
            do {
                let path = try readPath(a[0], mem)
                call.set("realpath(\"\(path)\", out=\(hx(a[1])))")
                let resolved = try fileSystem.realpath(path)
                let bytes = cString(resolved)
                guard bytes.count <= DarwinFileSystem.maxPathLength else { throw Failure(errno: Errno.ENAMETOOLONG) }
                try mem.write(va: a[1], bytes: bytes)
                return ok(a[1], " [\(resolved)]")
            } catch {
                return fail(error)
            }

        case Private.getcwd:
            call.set("getcwd(buf=\(hx(a[0])), size=\(a[1]))")
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
            call.set("vm_copy(target=\(hx(a[0])), src=\(hx(a[1])), size=\(hx(a[2])), dst=\(hx(a[3])))")
            guard a[2] <= UInt64(Int32.max) else { return kr(KernReturn.invalidArgument) }
            do {
                let bytes = try mem.read(va: a[1], count: Int(a[2]))
                try mem.write(va: a[3], bytes: bytes)
            } catch {
                return kr(KernReturn.invalidAddress)
            }
            return kr(KernReturn.success)

        case Private.procRegionFilename:
            call.set("proc_regionfilename(pid=\(Int32(truncatingIfNeeded: a[0])), addr=\(hx(a[1])), buf=\(hx(a[2])), "
                + "size=\(UInt32(truncatingIfNeeded: a[3])))")
            guard let region = mem.region(containing: a[1]), case let .file(path, _, _) = region.backing else {
                return ok(0, " [no file]")
            }
            let bytes = Array(Array(path.utf8).prefix(Int(UInt32(truncatingIfNeeded: a[3]))))
            do { try mem.write(va: a[2], bytes: bytes) } catch { return fail(error) }
            return ok(UInt64(bytes.count), " [\(path)]")

        case Private.taskInfo:
            call.set("task_info(task=\(hx(a[0])), flavor=\(a[1] & 0xFFFF_FFFF), info=\(hx(a[2])), count=\(hx(a[3])))")
            if a[1] & 0xFFFF_FFFF == Self.taskAuditToken {
                // TASK_AUDIT_TOKEN (15, 8 words; osfmk/mach/task_info.h): the
                // task's token, as its messages carry it. task_info takes a
                // task_name_t (xnu osfmk/mach/task.defs; level 1), so any task
                // flavor port works: control, name, read, inspect, of this
                // task or another live one (runningboardd reads its clients'
                // tokens through task_name_for_pid).
                let target: DarwinKernel
                if UInt32(truncatingIfNeeded: a[0]) == WellKnownPort.task {
                    target = self
                } else {
                    guard let ipc = machIPC as? MachIPC,
                          let (port, object) = withPorts({ ipc.kernelObject(named: UInt32(truncatingIfNeeded: a[0])) }) else {
                        return kr(KernReturn.invalidArgument, " [not a task port]")
                    }
                    switch object {
                    case .task, .taskName, .taskRead, .taskInspect: break
                    default: return kr(KernReturn.invalidArgument, " [not a task port]")
                    }
                    guard port.active, let task = port.task, !task.isTerminated, let k = task.kernel, !k.isTerminating else {
                        return kr(KernReturn.invalidArgument, " [task ended]")
                    }
                    target = k
                }
                do {
                    let count = try mem.read(va: a[3], count: 4).readLE(UInt32.self, at: 0)
                    guard count >= 8 else { return kr(KernReturn.invalidArgument) }
                    try mem.write(va: a[2], bytes: target.descriptorAuditToken)
                    try writeU32(a[3], 8, mem)
                } catch {
                    return kr(KernReturn.invalidAddress)
                }
                return kr(KernReturn.success, " [TASK_AUDIT_TOKEN pid \(target.pid)]")
            }
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
            call.set("thread_info(thread=\(hx(a[0])), flavor=\(a[1] & 0xFFFF_FFFF), info=\(hx(a[2])), count=\(hx(a[3])))")
            return kr(KernReturn.invalidArgument, " [flavor not supported]")

        case Private.machMsgDestroy:
            call.set("mach_msg_destroy(header=\(hx(a[0])))")
            return ok(0)

        case Private.sysctlbyname:
            call.set("sysctlbyname(name=\(hx(a[0])), old=\(hx(a[1])), oldlenp=\(hx(a[2])), new=\(hx(a[3])), newlen=\(hx(a[4])))")
            do {
                let name = try readString(a[0], length: 1024, mem)
                call.set("sysctlbyname(\"\(name)\", old=\(hx(a[1])), oldlenp=\(hx(a[2])), new=\(hx(a[3])), newlen=\(hx(a[4])))")
                return ok(try sysctlRead(sysctl.lookup(name: name), name: name,
                                         old: a[1], oldlenp: a[2], new: a[3], newlen: a[4], mem))
            } catch {
                return fail(error)
            }

        case Private.notifyImageListChanges:
            let count = Int(UInt32(truncatingIfNeeded: a[1]))
            call.set("notifyMonitorOfImageListChanges(unloading=\(a[0] & 0xFF), count=\(count), "
                + "addrs=\(hx(a[2])), paths=\(hx(a[3])))")
            var images: [String] = []
            // Only the description reads these: skip the guest reads untraced.
            for i in 0..<min(count, 256) where traceTextWanted(tracing) {
                let base = (try? readU64(a[2] + UInt64(8 * i), mem)) ?? 0
                let pathPointer = (try? readU64(a[3] + UInt64(8 * i), mem)) ?? 0
                let path = pathPointer == 0 ? "?" : ((try? readString(pathPointer, length: 1024, mem)) ?? "?")
                images.append("\(hx(base)) \(path)")
            }
            if !images.isEmpty { call += " [" + images.joined(separator: "; ") + "]" }
            return ok(0)

        case Private.notifyMainCalled:
            call.set("notifyMonitorOfMainCalled()")
            return ok(0)

        case Private.notifyBeforeInitializers:
            call.set("notifyMonitorOfDyldBeforeInitializers()")
            return ok(0)

        case Private.unimplementedLibraryFunction:
            let name = (try? readString(a[0], length: 256, mem)) ?? "<unreadable name at \(hx(a[0]))>"
            trace("\(prefix) unimplemented libfunc \(name)")
            return .unimplementedLibraryFunction(name: name)

        default:
            frame.x[0] = UInt64(Errno.ENOSYS)
            frame.x[1] = 0
            frame.carry = true
            trace("\(prefix) \(call) -> unimplemented")
            return .unimplemented(description: "unimplemented private \(hx(number))")
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

    func protection(_ bits: UInt64) -> VMProtection {
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
