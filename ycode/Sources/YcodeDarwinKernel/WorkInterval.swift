import Foundation
import Synchronization
import YcodeDarwinABI

// Work intervals, the kernel objects behind os_workgroup (specs/simulator/
// work-intervals.md). Semantics from xnu's open source (level 1):
// bsd/kern/sys_work_interval.c (the `work_interval_ctl` call),
// osfmk/kern/work_interval.c (objects, ports, join), bsd/sys/work_interval.h
// (operations, flags, records) and libsyscall/wrappers/work_interval.c (what
// the library sends).
//
// Ycode's scope is what a guest needs to use a workgroup someone else made:
// the host's audio service hands an IO thread the port of a joinable work
// interval (audio-host.md §10), and the guest's libdispatch asks for its
// flags (GET_FLAGS) and joins it (JOIN, and JOIN with a null port to leave).
// The kernel schedules nothing by work intervals, so a join only records
// the thread's interval. Guests cannot create work intervals (CREATE2 keeps
// the earlier "not implemented" answer, ENOSYS).

/// One work interval: an ID, the flags it was created with, and its creator.
/// Joinable ones are reached through a kernel-object port
/// (`MachKernelObject.workInterval`); the port's send rights keep it.
public final class KernelWorkInterval: @unchecked Sendable, Equatable {
    /// The system-wide work interval ID (never 0).
    public let id: UInt64
    /// The `WORK_INTERVAL_FLAG_*` and type bits it was created with.
    public let createFlags: UInt32
    /// The pid of the creating process (0: the host).
    public let creatorPID: Int32

    /// Makes an interval; take `id` from `nextID()`.
    public init(id: UInt64, createFlags: UInt32, creatorPID: Int32) {
        self.id = id
        self.createFlags = createFlags
        self.creatorPID = creatorPID
    }

    /// Identity: two intervals are equal only if they are the same object.
    public static func == (a: KernelWorkInterval, b: KernelWorkInterval) -> Bool { a === b }

    private static let counter = Mutex<UInt64>(1)
    /// A new ID: as in xnu, a system-wide counter that starts at 1 and is
    /// incremented before use (0 is never an ID).
    public static func nextID() -> UInt64 { counter.withLock { $0 += 1; return $0 } }
    /// After a restore: IDs above every restored one.
    static func noteRestoredID(_ id: UInt64) { counter.withLock { $0 = max($0, id) } }
}

/// `sys/work_interval.h` (level 1): the BSD call number, its operations,
/// the create flags and type field, and structure sizes in bytes
/// (`work-intervals.md` §2).
public enum WorkIntervalABI {
    public static let syscall = 499
    public static let operationCreate: UInt32 = 1, operationDestroy: UInt32 = 2, operationNotify: UInt32 = 3
    public static let operationCreate2: UInt32 = 4, operationJoin: UInt32 = 5, operationGetFlags: UInt32 = 9
    public static let flagJoinable: UInt32 = 0x1, flagGroup: UInt32 = 0x2, flagUnrestricted: UInt32 = 0x4
    public static let flagEnableAutoJoin: UInt32 = 0x8, flagEnableDeferredFinish: UInt32 = 0x10
    public static let flagIgnored: UInt32 = 0x20
    public static let typeMask: UInt32 = 0xF000_0000
    public static let typeDefault: UInt32 = 0, typeCoreAudio: UInt32 = 0x1000_0000
    /// `struct work_interval_create_params`: u64 wicp_id, u32 wicp_port,
    /// u32 wicp_create_flags.
    public static let createParamsSize = 16
    /// `struct work_interval_notification`: four u64 times, u32 notify
    /// flags, u32 create flags.
    public static let notificationSize = 40

    static func operationName(_ op: UInt32) -> String {
        switch op {
        case operationCreate: "create"
        case operationDestroy: "destroy"
        case operationNotify: "notify"
        case operationCreate2: "create2"
        case operationJoin: "join"
        case operationGetFlags: "get_flags"
        default: "op\(op)"
        }
    }
}

extension MachIPC {
    /// A new joinable work interval's port with one send right named in
    /// this space (what xnu's create gives the creator). Lock held.
    func makeWorkIntervalName(flags: UInt32, creatorPID: Int32) -> (KernelWorkInterval, UInt32)? {
        let wi = KernelWorkInterval(id: KernelWorkInterval.nextID(), createFlags: flags, creatorPID: creatorPID)
        guard let (p, name) = makeKernelObjectName(.workInterval(serial: nextSerial())) else { return nil }
        p.workInterval = wi
        return (wi, name)
    }

    /// The work interval a send right of this space names (xnu
    /// `port_name_to_work_interval`): nil for a name that is not a send
    /// right to a live work-interval port. Lock held.
    func workInterval(named name: UInt32) -> KernelWorkInterval? {
        guard let (p, object) = kernelObject(named: name), case .workInterval = object, p.active else { return nil }
        return p.workInterval
    }
}

extension MachHostTask {
    /// A joinable work interval of the host (creator pid 0) with `flags`
    /// (`WorkIntervalABI`; JOINABLE is added), as one send right named in
    /// the host task. Handing a copy of it to a guest gives the guest a
    /// workgroup port it can join (audio-host.md §10). Returns its name.
    public func makeWorkIntervalPort(flags: UInt32) throws -> UInt32 {
        try lock.withLock {
            guard let (_, name) = ipc.makeWorkIntervalName(flags: flags | WorkIntervalABI.flagJoinable, creatorPID: 0) else {
                throw MachHostError(MachKern.noSpace)
            }
            return name
        }
    }

    /// The work interval a host-task name sends to (tests, logs).
    public func workInterval(named name: UInt32) -> KernelWorkInterval? {
        lock.withLock { ipc.workInterval(named: name) }
    }
}

extension DarwinKernel {
    /// Diagnostics (`YCODE_DEBUG_WORK_INTERVALS=1`): one stderr line per
    /// `work_interval_ctl` call (process, operation, result).
    static let debugWorkIntervals = getenv("YCODE_DEBUG_WORK_INTERVALS").map { String(cString: $0) == "1" } ?? false

    /// BSD 499 `__work_interval_ctl(operation, work_interval_id, arg, len)`.
    func workIntervalCtl(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let op = UInt32(truncatingIfNeeded: a[0])
        call.set("work_interval_ctl(\(WorkIntervalABI.operationName(op)), id=\(hx(a[1])), arg=\(hx(a[2])), len=\(a[3]))")
        do {
            let note = try workIntervalOperation(op, id: a[1], arg: a[2], len: a[3], mem)
            call += " [\(note)]"
            if Self.debugWorkIntervals { debugWorkInterval(op, a, "ok: \(note)") }
            return 0
        } catch let f as Failure {
            if Self.debugWorkIntervals { debugWorkInterval(op, a, Errno.name(f.errno)) }
            throw f
        }
    }

    private func debugWorkInterval(_ op: UInt32, _ a: [UInt64], _ result: String) {
        FileHandle.standardError.write(Data(("ycode-work-interval: pid \(pid) (\(processRecord?.comm ?? "?")) thread "
            + "\(current.threadID) \(WorkIntervalABI.operationName(op)) id=\(hx(a[1])) -> \(result)\n").utf8))
    }

    private func workIntervalOperation(_ op: UInt32, id: UInt64, arg: UInt64, len: UInt64,
                                       _ mem: any KernelGuestMemory) throws -> String {
        let thread = current
        switch op {
        case WorkIntervalABI.operationCreate:
            throw Failure(errno: Errno.ENOTSUP)

        case WorkIntervalABI.operationCreate2:
            // Not modeled: guests make no work intervals of their own. The
            // answer is the one every operation had before (ENOSYS).
            throw Failure(errno: Errno.ENOSYS)

        case WorkIntervalABI.operationGetFlags:
            // The id argument is a port name; the record's port field echoes
            // it, its id field is 0.
            guard arg != 0, len >= UInt64(WorkIntervalABI.createParamsSize) else { throw Failure(errno: Errno.EINVAL) }
            let name = UInt32(truncatingIfNeeded: id)
            guard MachPortName.isValid(name), let wi = try lookUpWorkInterval(name) else { throw Failure(errno: Errno.EINVAL) }
            var record: [UInt8] = []
            record.appendLE(UInt64(0))
            record.appendLE(name)
            record.appendLE(wi.createFlags)
            try mem.write(va: arg, bytes: record)
            return "flags \(hx(UInt64(wi.createFlags)))"

        case WorkIntervalABI.operationJoin:
            guard arg == 0 else { throw Failure(errno: Errno.EINVAL) }
            let name = UInt32(truncatingIfNeeded: id)
            if name == 0 {
                let left = thread.workInterval
                thread.workInterval = nil
                return left.map { "left #\($0.id)" } ?? "left (none)"
            }
            guard MachPortName.isValid(name), let wi = try lookUpWorkInterval(name) else { throw Failure(errno: Errno.EINVAL) }
            thread.workInterval = wi
            return "joined #\(wi.id)"

        case WorkIntervalABI.operationDestroy:
            guard arg == 0, id != 0 else { throw Failure(errno: Errno.EINVAL) }
            guard let wi = thread.workInterval, wi.id == id else { throw Failure(errno: Errno.EINVAL) }
            thread.workInterval = nil
            return "left #\(wi.id)"

        case WorkIntervalABI.operationNotify:
            guard arg != 0, id != 0, len >= UInt64(WorkIntervalABI.notificationSize) else {
                throw Failure(errno: Errno.EINVAL)
            }
            _ = try mem.read(va: arg, count: WorkIntervalABI.notificationSize)
            // Only a thread that joined the interval, in the creating
            // process, may notify it. Nothing is scheduled by it.
            guard let wi = thread.workInterval, wi.id == id, wi.creatorPID == pid else { throw Failure(errno: Errno.EINVAL) }
            return "noted"

        default:
            throw Failure(errno: Errno.ENOTSUP)
        }
    }

    private func lookUpWorkInterval(_ name: UInt32) throws -> KernelWorkInterval? {
        guard let ipc = machIPC as? MachIPC else { return nil }
        return withPorts { ipc.workInterval(named: name) }
    }
}
