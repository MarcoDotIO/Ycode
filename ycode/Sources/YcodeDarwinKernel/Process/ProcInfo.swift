import Foundation
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
                   noteExit: Int32 = 21, platformInfo: Int32 = 30
    }

    /// Dirty-tracking bits as `PROC_DIRTYCONTROL_GET` reports them.
    enum DirtyState {
        static let tracked: UInt32 = 0x1, allowIdleExit: UInt32 = 0x2, isDirty: UInt32 = 0x4,
                   launchInProgress: UInt32 = 0x8
    }

    static let EOVERFLOW: Int32 = 84

    func procInfo(_ me: DarwinProcess, _ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let callnum = Int32(truncatingIfNeeded: a[0]), target = Int32(truncatingIfNeeded: a[1])
        let flavor = Int32(truncatingIfNeeded: a[2]), arg = a[3], buffer = a[4]
        let size = Int32(truncatingIfNeeded: a[5])
        call = "proc_info(callnum=\(callnum), pid=\(target), flavor=\(flavor), arg=\(hx(arg)), buffer=\(hx(buffer)), buffersize=\(size))"
        switch callnum {
        case ProcInfoCall.listPIDs:
            return try listPIDs(type: target, typeInfo: flavor, buffer: buffer, size: size, mem)
        case ProcInfoCall.pidInfo:
            return try pidInfo(target, flavor: flavor, arg: arg, buffer: buffer, size: size, me: me, mem)
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
            return try dirtyControl(target, flavor: flavor, arg: UInt32(truncatingIfNeeded: arg), me: me)
        case ProcInfoCall.pidRUsage:
            guard let p = system.processes[target], p.pid != DarwinSystem.initPID else { throw Failure(errno: Errno.ESRCH) }
            let sizes: [Int32: Int] = [0: 96, 1: 144, 2: 160, 3: 232, 4: 296, 5: 304, 6: 464]
            guard let n = sizes[flavor] else { throw Failure(errno: Errno.EINVAL) }
            try mem.write(va: buffer, bytes: [UInt8](repeating: 0, count: n))
            return 0
        default:
            log("note: proc_info call \(callnum) is not supported")
            throw Failure(errno: Errno.EINVAL)
        }
    }

    /// LISTPIDS: live processes first, then zombies; returns bytes written.
    private func listPIDs(type: Int32, typeInfo: Int32, buffer: UInt64, size: Int32, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let all = system.processes.values.sorted { ($0.isZombie ? 1 : 0, $0.pid) < ($1.isZombie ? 1 : 0, $1.pid) }
        let hint = all.count + 20
        if buffer == 0 { return UInt64(hint * 4) }
        guard size >= 4 else { throw Failure(errno: Errno.ENOMEM) }
        let matching: [DarwinProcess]
        switch type {
        case 1: matching = all
        case 2: matching = all.filter { $0.pgid == typeInfo }
        case 4, 5: matching = UInt32(bitPattern: typeInfo) == DarwinFileSystem.guestUID ? all.filter { $0.pid != 1 } : []
        case 6: matching = all.filter { $0.ppid == typeInfo }
        case 3, 7: matching = []
        default: throw Failure(errno: Errno.EINVAL)
        }
        let n = min(matching.count, Int(size) / 4, hint)
        var b: [UInt8] = []
        for p in matching.prefix(n) { b.appendLE(p.pid) }
        if !b.isEmpty { try mem.write(va: buffer, bytes: b) }
        return UInt64(b.count)
    }

    private func pidInfo(_ target: Int32, flavor: Int32, arg: UInt64, buffer: UInt64, size: Int32, me: DarwinProcess,
                         _ mem: any KernelGuestMemory) throws -> UInt64 {
        guard target > 0, let p = system.processes[target] else { throw Failure(errno: Errno.ESRCH) }
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
            let threads = Int32(p.kernel?.threadsByPort.count ?? 0)
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
        case ProcInfoFlavor.platformInfo:
            try need(4, zombieOK: true)
            var b: [UInt8] = []
            b.appendLE(UInt32(7))  // PLATFORM_IOSSIMULATOR
            bytes = b
        default:
            log("note: proc_info PIDINFO flavor \(flavor) is not supported")
            throw Failure(errno: Errno.EINVAL)
        }
        try mem.write(va: buffer, bytes: bytes)
        return UInt64(bytes.count)
    }

    private func statusCode(_ p: DarwinProcess) -> UInt32 {
        switch p.state {
        case .running: 2
        case .stopped: 4
        case .zombie: 5
        }
    }

    /// `pbi_flags`: LP64 | has exec'd, plus session leader (`processes.md` §2.11).
    private func bsdFlags(_ p: DarwinProcess) -> UInt32 {
        var f: UInt32 = 0x10 | 0x4000
        if p.sid == p.pid { f |= 0x20 }
        if p.pid == DarwinSystem.initPID { f |= 0x1 }
        if p.exiting { f |= 0x4 }
        return f
    }

    /// `struct proc_bsdinfo` (136 bytes).
    private func bsdInfo(_ p: DarwinProcess) -> [UInt8] {
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
    private func uniqueIdentifierInfo(_ p: DarwinProcess) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 56)
        b.putLE(p.uniqueID, at: 16)
        b.putLE(p.parentUniqueID, at: 24)
        b.putLE(p.pidVersion, at: 32)
        b.putLE(p.originalParentPIDVersion, at: 36)
        return b
    }

    /// DIRTYCONTROL (`processes.md` §2.11): 1 TRACK, 2 SET, 3 GET, 4 CLEAR.
    private func dirtyControl(_ target: Int32, flavor: Int32, arg: UInt32, me: DarwinProcess) throws -> UInt64 {
        guard let p = system.processes[target], p.pid != DarwinSystem.initPID else { throw Failure(errno: Errno.ESRCH) }
        switch flavor {
        case 1:
            guard p.state != .zombie else { throw Failure(errno: Errno.ESRCH) }
            guard p.pid == pid || p.ppid == pid else { throw Failure(errno: Errno.EPERM) }
            var state = p.dirtyState & DirtyState.isDirty
            if arg & 0x1 != 0 { state |= DirtyState.tracked }
            if arg & 0x2 != 0 { state |= DirtyState.allowIdleExit }
            if arg & 0x8 != 0 { state |= DirtyState.launchInProgress }
            p.dirtyState = state
            return 0
        case 2:
            guard p.state != .zombie else { throw Failure(errno: Errno.ESRCH) }
            guard canSignal(p) else { throw Failure(errno: Errno.EPERM) }
            if arg != 0 { p.dirtyState |= DirtyState.isDirty } else { p.dirtyState &= ~DirtyState.isDirty }
            return 0
        case 3:
            return UInt64(p.dirtyState)
        case 4:
            guard p.state != .zombie else { throw Failure(errno: Errno.ESRCH) }
            guard canSignal(p) else { throw Failure(errno: Errno.EPERM) }
            if arg & 0x8 != 0 { p.dirtyState &= ~DirtyState.launchInProgress }
            return 0
        default:
            throw Failure(errno: Errno.EINVAL)
        }
    }
}
