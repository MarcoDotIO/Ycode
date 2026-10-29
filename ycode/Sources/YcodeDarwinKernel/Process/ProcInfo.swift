import Foundation
import Synchronization
import YcodeDarwinABI

// `proc_info` (BSD 336) for stage 4b: `specs/simulator/processes.md` §2.11
// and §6 item 11 (LISTPIDS, PIDINFO 3/4/11/13/17/18/19/21/30, TERMINATE,
// DIRTYCONTROL, PIDRUSAGE). Every guest process has the same uid, so the
// "same user" checks never deny. Owner: agent P.

extension DarwinKernel {
    enum ProcInfoCall {
        static let listPIDs: Int32 = 1, pidInfo: Int32 = 2, terminate: Int32 = 7, dirtyControl: Int32 = 8,
                   pidRUsage: Int32 = 9
    }

    enum ProcInfoFlavor {
        static let tbsdInfo: Int32 = 3, taskInfo: Int32 = 4, pathInfo: Int32 = 11, shortBSDInfo: Int32 = 13,
                   uniqueIdentifierInfo: Int32 = 17, bsdInfoWithUniqueID: Int32 = 18, archInfo: Int32 = 19,
                   noteExit: Int32 = 21, exitReasonInfo: Int32 = 24, exitReasonBasicInfo: Int32 = 25,
                   platformInfo: Int32 = 30
    }

    /// Dirty-tracking bits as `PROC_DIRTYCONTROL_GET` reports them.
    enum DirtyState {
        static let tracked: UInt32 = 0x1, allowIdleExit: UInt32 = 0x2, isDirty: UInt32 = 0x4,
                   launchInProgress: UInt32 = 0x8
    }

    static let EOVERFLOW: Int32 = 84

    func procInfo(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let callnum = Int32(truncatingIfNeeded: a[0]), target = Int32(truncatingIfNeeded: a[1])
        let flavor = Int32(truncatingIfNeeded: a[2]), arg = a[3], buffer = a[4]
        let size = Int32(truncatingIfNeeded: a[5])
        call.set("proc_info(callnum=\(callnum), pid=\(target), flavor=\(flavor), arg=\(hx(arg)), buffer=\(hx(buffer)), buffersize=\(size))")
        switch callnum {
        case ProcInfoCall.listPIDs:
            return try listPIDs(type: target, typeInfo: flavor, buffer: buffer, size: size, mem)
        case ProcInfoCall.pidInfo:
            return try pidInfo(target, flavor: flavor, arg: arg, buffer: buffer, size: size, mem)
        case ProcInfoCall.terminate:
            guard target != pid else { throw Failure(errno: Errno.EPERM) }
            guard let p = system.processes[target], p.state != .zombie, p.pid != DarwinSystem.initPID else {
                throw Failure(errno: Errno.ESRCH)
            }
            let clean = p.dirtyState & DirtyState.tracked != 0 && p.dirtyState & DirtyState.isDirty == 0
            let sig = clean ? Signal.sigkill : Signal.sigterm
            p.kernel?.postSignal(sig, thread: nil, sender: pid)
            call += " [\(Signal.name(sig))]"
            return UInt64(sig)
        case ProcInfoCall.dirtyControl:
            return try dirtyControl(target, flavor: flavor, arg: UInt32(truncatingIfNeeded: arg))
        case ProcInfoCall.pidRUsage:
            guard let record = system.processRecord(target), record.pid != DarwinSystem.initPID else {
                throw Failure(errno: Errno.ESRCH)
            }
            let p = ProcessView(pid: record.pid, uniqueID: record.uniqueID, f: record.view())
            let sizes: [Int32: Int] = [0: 96, 1: 144, 2: 160, 3: 232, 4: 296, 5: 304, 6: 464]
            guard let n = sizes[flavor] else { throw Failure(errno: Errno.EINVAL) }
            // struct rusage_info_v0 prefix (sys/resource.h): uuid[16], user,
            // system, pkg_idle_wkups, interrupt_wkups, pageins, wired_size,
            // resident_size, phys_footprint, then ri_proc_start_abstime @80
            // and ri_proc_exit_abstime @88 (launchd's run time and throttle).
            var b = [UInt8](repeating: 0, count: n)
            b.put(p.executableUUID, at: 0)
            b.putLE(p.startAbsTime, at: 80)
            b.putLE(p.exitAbsTime, at: 88)
            try mem.write(va: buffer, bytes: b)
            return 0
        default:
            trace("note: proc_info call \(callnum) is not supported")
            throw Failure(errno: Errno.EINVAL)
        }
    }

    /// LISTPIDS: live processes first, then zombies; returns bytes written.
    private func listPIDs(type: Int32, typeInfo: Int32, buffer: UInt64, size: Int32, _ mem: any KernelGuestMemory) throws -> UInt64 {
        // One consistent copy of each record (this may run without L0).
        let all = system.processes.values.map { (pid: $0.pid, f: $0.view()) }
            .sorted { ($0.f.isZombie ? 1 : 0, $0.pid) < ($1.f.isZombie ? 1 : 0, $1.pid) }
        let hint = all.count + 20
        if buffer == 0 { return UInt64(hint * 4) }
        guard size >= 4 else { throw Failure(errno: Errno.ENOMEM) }
        let matching: [(pid: Int32, f: DarwinProcess.Fields)]
        switch type {
        case 1: matching = all
        case 2: matching = all.filter { $0.f.pgid == typeInfo }
        case 4, 5: matching = UInt32(bitPattern: typeInfo) == DarwinFileSystem.guestUID ? all.filter { $0.pid != 1 } : []
        case 6: matching = all.filter { $0.f.ppid == typeInfo }
        case 3, 7: matching = []
        default: throw Failure(errno: Errno.EINVAL)
        }
        let n = min(matching.count, Int(size) / 4, hint)
        var b: [UInt8] = []
        for p in matching.prefix(n) { b.appendLE(p.pid) }
        if !b.isEmpty { try mem.write(va: buffer, bytes: b) }
        return UInt64(b.count)
    }

    private func pidInfo(_ target: Int32, flavor: Int32, arg: UInt64, buffer: UInt64, size: Int32,
                         _ mem: any KernelGuestMemory) throws -> UInt64 {
        guard target > 0, let record = system.processRecord(target) else { throw Failure(errno: Errno.ESRCH) }
        // One consistent copy of the record (this may run without L0).
        let p = ProcessView(pid: record.pid, uniqueID: record.uniqueID, f: record.view())
        func need(_ n: Int, zombieOK: Bool) throws {
            if p.isZombie && !zombieOK { throw Failure(errno: Errno.ESRCH) }
            guard Int(size) >= n else { throw Failure(errno: Errno.ENOMEM) }
        }
        let bytes: [UInt8]
        switch flavor {
        case ProcInfoFlavor.tbsdInfo:
            try need(136, zombieOK: arg != 0)
            bytes = bsdInfo(p)
        case ProcInfoFlavor.taskInfo:
            try need(96, zombieOK: false)
            var b = [UInt8](repeating: 0, count: 96)
            let threads = Int32(p.kernel.map { k in k.withEvents { k.threadsByPort.count } } ?? 0)
            b.putLE(threads, at: 84)
            b.putLE(threads, at: 88)
            b.putLE(Int32(31), at: 92)
            bytes = b
        case ProcInfoFlavor.pathInfo:
            if p.isZombie || p.pid == DarwinSystem.initPID { throw Failure(errno: Errno.ESRCH) }
            guard size >= 1024 else { throw Failure(errno: Errno.ENOMEM) }
            guard size <= 4096 else { throw Failure(errno: Self.EOVERFLOW) }
            var b = Array(p.executablePath.utf8.prefix(Int(size) - 1))
            b += [UInt8](repeating: 0, count: Int(size) - b.count)
            try mem.write(va: buffer, bytes: b)
            return 0
        case ProcInfoFlavor.shortBSDInfo:
            try need(64, zombieOK: arg != 0)
            var b = [UInt8](repeating: 0, count: 64)
            b.putLE(p.pid, at: 0)
            b.putLE(p.ppid, at: 4)
            b.putLE(p.pgid, at: 8)
            b.putLE(statusCode(p), at: 12)
            b.put(Array(p.comm.utf8.prefix(15)), at: 16)
            b.putLE(bsdFlags(p), at: 32)
            for (i, v) in [DarwinFileSystem.guestUID, DarwinFileSystem.guestGID, DarwinFileSystem.guestUID,
                           DarwinFileSystem.guestGID, DarwinFileSystem.guestUID, DarwinFileSystem.guestGID].enumerated() {
                b.putLE(v, at: 36 + 4 * i)
            }
            bytes = b
        case ProcInfoFlavor.uniqueIdentifierInfo:
            try need(56, zombieOK: arg != 0)
            bytes = uniqueIdentifierInfo(p)
        case ProcInfoFlavor.bsdInfoWithUniqueID:
            try need(192, zombieOK: arg != 0)
            bytes = bsdInfo(p) + uniqueIdentifierInfo(p)
        case ProcInfoFlavor.archInfo:
            try need(8, zombieOK: false)
            var b: [UInt8] = []
            b.appendLE(UInt32(0x0100_000C))
            b.appendLE(UInt32(0))
            bytes = b
        case ProcInfoFlavor.noteExit:
            guard p.ppid == pid else { throw Failure(errno: Self.EACCES) }
            try need(4, zombieOK: true)
            var b: [UInt8] = []
            let status = UInt32(arg) & NoteProc.exitStatus != 0 && p.isZombie ? UInt32(bitPattern: p.status) & 0xF_FFFF : 0
            b.appendLE(status)
            bytes = b
        case ProcInfoFlavor.exitReasonInfo, ProcInfoFlavor.exitReasonBasicInfo:
            // xnu proc_pidexitreasoninfo (bsd/kern/proc_info.c): the parent
            // only (EACCES); a process without an exit reason (Ycode records
            // none: exit(), signals) is ENOENT. Sizes 40 / 24 (ENOMEM).
            guard Int(size) >= (flavor == ProcInfoFlavor.exitReasonInfo ? 40 : 24) else { throw Failure(errno: Errno.ENOMEM) }
            guard p.ppid == pid else { throw Failure(errno: Self.EACCES) }
            throw Failure(errno: Errno.ENOENT)
        case ProcInfoFlavor.platformInfo:
            try need(4, zombieOK: true)
            var b: [UInt8] = []
            b.appendLE(Self.simulatorPlatform)  // PLATFORM_IOSSIMULATOR (7) or PLATFORM_XROSSIMULATOR (12)
            bytes = b
        default:
            trace("note: proc_info PIDINFO flavor \(flavor) is not supported")
            throw Failure(errno: Errno.EINVAL)
        }
        try mem.write(va: buffer, bytes: bytes)
        return UInt64(bytes.count)
    }

    /// `struct kinfo_proc` (648 bytes) for sysctl KERN_PROC_PID. Offsets from
    /// the public <sys/sysctl.h> and <sys/proc.h> (arm64): extern_proc
    /// p_starttime @0, p_flag @32 (P_LP64 0x4 | P_EXEC 0x4000), p_stat @36,
    /// p_pid @40, p_oppid @44, p_priority @240, p_comm[17] @243, p_xstat @280;
    /// eproc p_ruid/svuid/rgid/svgid @392…404, cr_uid @420, cr_ngroups @424,
    /// cr_groups @428, e_ppid @560, e_pgid @564, e_tdev @572 (NODEV −1),
    /// e_tpgid @576.
    func kinfoProc(_ pid: Int32) -> [UInt8]? {
        guard pid > 0, let record = system.processRecord(pid) else { return nil }
        let p = ProcessView(pid: record.pid, uniqueID: record.uniqueID, f: record.view())
        var b = [UInt8](repeating: 0, count: 648)
        b.putLE(UInt64(bitPattern: p.startTime.seconds), at: 0)
        b.putLE(Int32(truncatingIfNeeded: p.startTime.microseconds), at: 8)
        b.putLE(UInt32(0x4 | 0x4000), at: 32)
        b[36] = UInt8(truncatingIfNeeded: statusCode(p))
        b.putLE(p.pid, at: 40)
        b.putLE(p.ppid, at: 44)
        b[240] = 31
        b.put(Array(p.comm.utf8.prefix(16)), at: 243)
        if p.isZombie { b.putLE(UInt16(truncatingIfNeeded: p.status), at: 280) }
        let uid = DarwinFileSystem.guestUID, gid = DarwinFileSystem.guestGID
        for (i, v) in [uid, uid, gid, gid].enumerated() { b.putLE(v, at: 392 + 4 * i) }
        b.putLE(uid, at: 420)
        b.putLE(Int16(1), at: 424)
        b.putLE(gid, at: 428)
        b.putLE(p.ppid, at: 560)
        b.putLE(p.pgid, at: 564)
        b.putLE(Int32(-1), at: 572)
        return b
    }

    private func statusCode(_ p: ProcessView) -> UInt32 {
        switch p.state {
        case .running: 2
        case .stopped: 4
        case .zombie: 5
        }
    }

    /// `pbi_flags`: LP64 | has exec'd, plus session leader (`processes.md` §2.11).
    private func bsdFlags(_ p: ProcessView) -> UInt32 {
        var f: UInt32 = 0x10 | 0x4000
        if p.sid == p.pid { f |= 0x20 }
        if p.pid == DarwinSystem.initPID { f |= 0x1 }
        if p.exiting { f |= 0x4 }
        return f
    }

    /// `struct proc_bsdinfo` (136 bytes).
    private func bsdInfo(_ p: ProcessView) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 136)
        b.putLE(bsdFlags(p), at: 0)
        b.putLE(statusCode(p), at: 4)
        b.putLE(p.isZombie ? UInt32(bitPattern: p.status) : 0, at: 8)
        b.putLE(p.pid, at: 12)
        b.putLE(p.ppid, at: 16)
        for (i, v) in [DarwinFileSystem.guestUID, DarwinFileSystem.guestGID, DarwinFileSystem.guestUID,
                       DarwinFileSystem.guestGID, DarwinFileSystem.guestUID, DarwinFileSystem.guestGID].enumerated() {
            b.putLE(v, at: 20 + 4 * i)
        }
        b.put(Array(p.comm.utf8.prefix(15)), at: 48)
        b.put(Array(p.name.utf8.prefix(31)), at: 64)
        b.putLE(UInt32(p.kernel?.fileSystem.openDescriptors.count ?? 0), at: 96)
        b.putLE(p.pgid, at: 100)
        b.putLE(UInt32(0xFFFF_FFFF), at: 108)  // e_tdev: no terminal
        b.putLE(UInt64(bitPattern: p.startTime.seconds), at: 120)
        b.putLE(UInt64(bitPattern: p.startTime.microseconds), at: 128)
        return b
    }

    /// `struct proc_uniqidentifierinfo` (56 bytes).
    private func uniqueIdentifierInfo(_ p: ProcessView) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 56)
        b.put(p.executableUUID, at: 0)
        b.putLE(p.uniqueID, at: 16)
        b.putLE(p.parentUniqueID, at: 24)
        b.putLE(p.pidVersion, at: 32)
        b.putLE(p.originalParentPIDVersion, at: 36)
        return b
    }

    /// DIRTYCONTROL (`processes.md` §2.11): 1 TRACK, 2 SET, 3 GET, 4 CLEAR.
    private func dirtyControl(_ target: Int32, flavor: Int32, arg: UInt32) throws -> UInt64 {
        guard let p = system.processes[target], p.pid != DarwinSystem.initPID else { throw Failure(errno: Errno.ESRCH) }
        switch flavor {
        case 1:
            guard p.state != .zombie else { throw Failure(errno: Errno.ESRCH) }
            guard p.pid == pid || p.ppid == pid else { throw Failure(errno: Errno.EPERM) }
        case 2, 4:
            guard p.state != .zombie else { throw Failure(errno: Errno.ESRCH) }
            guard canSignal(p) else { throw Failure(errno: Errno.EPERM) }
        case 3:
            break
        default:
            throw Failure(errno: Errno.EINVAL)
        }
        return p.dirty.control(flavor: flavor, arg: arg)
    }

    /// Diagnostics: DIRTYCONTROL calls served without L0.
    public static let dirtyControlFast = Atomic<UInt64>(0)
    /// The platform proc_info's platform flavor reports for every process:
    /// the runtime's (iOS simulator 7; a visionOS runtime sets 12,
    /// visionos.md §2.2). Set once before the first process starts.
    nonisolated(unsafe) public static var simulatorPlatform: UInt32 = 7
    /// On by default; `YCODE_DIRTY_FAST=0` keeps every `proc_info` call on L0.
    nonisolated(unsafe) public static var dirtyControlFastEnabled = getenv("YCODE_DIRTY_FAST").map { String(cString: $0) != "0" } ?? true

    /// Diagnostics: `proc_info` reads (LISTPIDS, PIDINFO, PIDRUSAGE) served
    /// without L0 (`bsd-locking.md` §13).
    public static let procInfoReadFast = Atomic<UInt64>(0)
    /// On by default; `YCODE_PROC_TABLE_FAST=0` keeps the process-table reads
    /// (`proc_info` LISTPIDS/PIDINFO/PIDRUSAGE, `proc_info_extended_id`,
    /// `csops`, `csops_audittoken`, `kern.proc.pid`) on L0.
    nonisolated(unsafe) public static var procTableFastEnabled = getenv("YCODE_PROC_TABLE_FAST").map { String(cString: $0) != "0" } ?? true

    /// `proc_info` (336) without L0: DIRTYCONTROL on the caller's own
    /// process (a running image's process is neither a zombie nor pseudo-init,
    /// and may always signal itself, so the locked path's checks pass); the
    /// reads of the process table (LISTPIDS, PIDINFO, PIDRUSAGE) under its
    /// leaf lock and each record's (`bsd-locking.md` §13), with the locked
    /// path's functions. Nil for any other call: the locked path.
    func procInfoFast(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64? {
        let callnum = Int32(truncatingIfNeeded: a[0]), target = Int32(truncatingIfNeeded: a[1])
        let flavor = Int32(truncatingIfNeeded: a[2])
        if Self.procTableFastEnabled, !system.isImplicit,
           callnum == ProcInfoCall.listPIDs || callnum == ProcInfoCall.pidInfo || callnum == ProcInfoCall.pidRUsage {
            let r = try procInfo(a, &call, mem)
            Self.procInfoReadFast.wrappingAdd(1, ordering: .relaxed)
            return r
        }
        guard Self.dirtyControlFastEnabled, callnum == ProcInfoCall.dirtyControl, (1...4).contains(flavor), target == pid,
              target != DarwinSystem.initPID, let dirty = processDirtyLink.withLock({ $0 }) else { return nil }
        call.set("proc_info(callnum=\(callnum), pid=\(target), flavor=\(flavor), arg=\(hx(a[3])), buffer=\(hx(a[4])), buffersize=\(Int32(truncatingIfNeeded: a[5])))")
        Self.dirtyControlFast.wrappingAdd(1, ordering: .relaxed)
        return dirty.control(flavor: flavor, arg: UInt32(truncatingIfNeeded: a[3]))
    }

}

/// One consistent copy of a process record's fields (`DarwinProcess.view`),
/// read by `proc_info` and the `kern.proc` sysctls with or without L0.
@dynamicMemberLookup
struct ProcessView {
    let pid: Int32
    let uniqueID: UInt64
    let f: DarwinProcess.Fields
    subscript<T>(dynamicMember path: KeyPath<DarwinProcess.Fields, T>) -> T { f[keyPath: path] }
}

/// A process's dirty-tracking bits (`proc_info` DIRTYCONTROL): one atomic
/// word, changed by the locked path (L0) and by the process's own calls on
/// the fast path, so each change is one atomic operation.
final class ProcessDirtyState: Sendable {
    let bits = Atomic<UInt32>(0)

    /// The change of one DIRTYCONTROL call whose checks passed: 1 TRACK,
    /// 2 SET, 3 GET (the bits), 4 CLEAR; 0 for the others.
    func control(flavor: Int32, arg: UInt32) -> UInt64 {
        typealias D = DarwinKernel.DirtyState
        switch flavor {
        case 1:
            var add: UInt32 = 0
            if arg & 0x1 != 0 { add |= D.tracked }
            if arg & 0x2 != 0 { add |= D.allowIdleExit }
            if arg & 0x8 != 0 { add |= D.launchInProgress }
            var old = bits.load(ordering: .relaxed)
            while true {
                let (done, seen) = bits.compareExchange(expected: old, desired: (old & D.isDirty) | add,
                                                        ordering: .acquiringAndReleasing)
                if done { break }
                old = seen
            }
        case 2:
            if arg != 0 { bits.bitwiseOr(D.isDirty, ordering: .acquiringAndReleasing) }
            else { bits.bitwiseAnd(~D.isDirty, ordering: .acquiringAndReleasing) }
        case 3:
            return UInt64(bits.load(ordering: .acquiring))
        case 4:
            if arg & 0x8 != 0 { bits.bitwiseAnd(~D.launchInProgress, ordering: .acquiringAndReleasing) }
        default:
            break
        }
        return 0
    }
}
