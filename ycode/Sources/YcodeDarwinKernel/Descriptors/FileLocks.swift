import Foundation
import YcodeDarwinABI

// Advisory file locks and data-protection classes (stage 6).
//
// Locks follow xnu `bsd/kern/kern_lockf.c` and `kern_descrip.c` (level 1):
// one lock list per file, shared by every process of the device. Three
// kinds of owner share that list and conflict with each other:
// - POSIX record locks (`F_GETLK`/`F_SETLK`/`F_SETLKW`/`F_SETLKWTIMEOUT`):
//   owned by the process; any close of any descriptor of the file by that
//   process releases all of them, as does exit;
// - OFD locks (`F_OFD_GETLK`/`F_OFD_SETLK`/`F_OFD_SETLKW`/
//   `F_OFD_SETLKWTIMEOUT`) and `flock(2)`: owned by the open file
//   description, released when its last reference closes.
// Two locks conflict when their owners differ, their byte ranges overlap,
// and at least one is a write (exclusive) lock. A process's own locks are
// replaced, split, or merged by a new request over their range.
//
// Data-protection classes (`F_GETPROTECTIONCLASS`, `F_SETPROTECTIONCLASS`,
// `open_dprotected_np`): Ycode keeps them per file in memory, with the
// behavior observed on the simulator's host volume (level 3, our own probe
// on this Mac's iOS simulator; see FileLockTable.setClass).

/// A file, as the lock table and the class table name it: the host device
/// and inode of an open host file.
struct FileIdentity: Hashable {
    let dev: UInt32
    let ino: UInt64
    init(_ stat: DarwinStat) {
        dev = stat.dev
        ino = stat.ino
    }
}

/// The device's advisory locks (one per `DarwinSystem`). Lock held for
/// every call.
final class FileLockTable {
    enum Owner: Hashable {
        case process(Int32)
        case description(ObjectIdentifier)
    }

    enum Kind { case posix, ofd, flock }

    struct Lock: Equatable {
        var owner: Owner
        var kind: Kind
        var exclusive: Bool
        /// Inclusive byte range; `end == Int64.max` means "to end of file
        /// and beyond" (l_len 0).
        var start: Int64
        var end: Int64

        func overlaps(_ s: Int64, _ e: Int64) -> Bool { start <= e && s <= end }
    }

    final class FileState {
        var locks: [Lock] = []
        let waiters = WaitQueue()
    }

    private(set) var files: [FileIdentity: FileState] = [:]
    /// POSIX owners blocked in F_SETLKW: pid → the owner they wait for
    /// (xnu's deadlock detection follows this chain).
    var blockedOn: [Int32: Owner] = [:]
    /// Data-protection classes set on files and directories.
    var protectionClasses: [FileIdentity: Int32] = [:]

    func state(_ id: FileIdentity) -> FileState {
        if let s = files[id] { return s }
        let s = FileState()
        files[id] = s
        return s
    }

    /// The first lock of another owner that blocks the request.
    func blocker(_ id: FileIdentity, owner: Owner, exclusive: Bool, start: Int64, end: Int64) -> Lock? {
        files[id]?.locks.first { $0.owner != owner && $0.overlaps(start, end) && (exclusive || $0.exclusive) }
    }

    /// Sets (exclusive true/false) or clears (`exclusive == nil`) the
    /// owner's lock over [start, end]: the owner's overlapping locks are
    /// trimmed or split, the new lock added, and adjacent locks of the same
    /// type merged. Wakes every waiter of the file.
    func apply(_ id: FileIdentity, owner: Owner, kind: Kind, exclusive: Bool?, start: Int64, end: Int64) {
        let s = state(id)
        var kept: [Lock] = []
        var mine: [Lock] = []
        for l in s.locks {
            guard l.owner == owner else { kept.append(l); continue }
            guard l.overlaps(start, end) else { mine.append(l); continue }
            if l.start < start { var left = l; left.end = start - 1; mine.append(left) }
            if l.end > end { var right = l; right.start = end + 1; mine.append(right) }
        }
        if let exclusive { mine.append(Lock(owner: owner, kind: kind, exclusive: exclusive, start: start, end: end)) }
        mine.sort { $0.start < $1.start }
        var merged: [Lock] = []
        for l in mine {
            if var last = merged.last, last.exclusive == l.exclusive, last.kind == l.kind,
               last.end == Int64.max || last.end + 1 >= l.start {
                last.end = max(last.end, l.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(l)
            }
        }
        s.locks = kept + merged
        changed(id)
    }

    /// Removes every lock of `owner` (on one file, or on all). Wakes waiters.
    func release(owner: Owner, on id: FileIdentity? = nil) {
        for (key, s) in files where id == nil || key == id {
            let before = s.locks.count
            s.locks.removeAll { $0.owner == owner }
            if s.locks.count != before { changed(key) }
        }
    }

    private func changed(_ id: FileIdentity) {
        guard let s = files[id] else { return }
        _ = s.waiters.wakeAll()
        if s.locks.isEmpty && s.waiters.isEmpty { files[id] = nil }
    }

    func hasLocks(of owner: Owner, on id: FileIdentity) -> Bool {
        files[id]?.locks.contains { $0.owner == owner } ?? false
    }

    /// True when `pid` waiting for `owner` would close a cycle back to `pid`.
    func wouldDeadlock(_ pid: Int32, waitingFor owner: Owner) -> Bool {
        var current = owner
        for _ in 0..<64 {
            guard case let .process(p) = current else { return false }
            if p == pid { return true }
            guard let next = blockedOn[p] else { return false }
            current = next
        }
        return false
    }
}

extension DarwinSystem {
    /// The device-wide lock and protection-class table (made on first use).
    var fileLocks: FileLockTable {
        if let t = fileLockStorage { return t }
        let t = FileLockTable()
        fileLockStorage = t
        return t
    }
}

/// `sys/fcntl.h` values for locks and data protection.
enum FileLockControl {
    static let getlk: Int32 = 7, setlk: Int32 = 8, setlkw: Int32 = 9, setlkwTimeout: Int32 = 10
    static let ofdSetlk: Int32 = 90, ofdSetlkw: Int32 = 91, ofdGetlk: Int32 = 92, ofdSetlkwTimeout: Int32 = 93
    static let rdlck: Int16 = 1, unlck: Int16 = 2, wrlck: Int16 = 3
    static let lockSH: Int32 = 1, lockEX: Int32 = 2, lockNB: Int32 = 4, lockUN: Int32 = 8
    static let commands: Set<Int32> = [getlk, setlk, setlkw, setlkwTimeout, ofdSetlk, ofdSetlkw, ofdGetlk, ofdSetlkwTimeout]
    static let names: [Int32: String] = [7: "F_GETLK", 8: "F_SETLK", 9: "F_SETLKW", 10: "F_SETLKWTIMEOUT",
                                         90: "F_OFD_SETLK", 91: "F_OFD_SETLKW", 92: "F_OFD_GETLK",
                                         93: "F_OFD_SETLKWTIMEOUT"]
    /// F_GETPROTECTIONLEVEL's answer on the simulator's host volume (level 3).
    static let protectionLevel: UInt64 = 5
    static let defaultFileClass: Int32 = 3
}

extension DarwinKernel {
    /// The open description and host file of a lockable descriptor
    /// (a vnode; anything else is EBADF, as xnu's fcntl).
    func lockableFile(_ fd: Int32, notFile: Int32 = DarwinErrnoCode.EBADF) throws -> (DarwinOpenFile, GuestFile) {
        let open = try fileSystem.openFile(for: fd)
        guard let f = open.guestFile else { throw fail(notFile) }
        return (open, f)
    }

    /// Registers the description's lock release for when its last
    /// reference goes (OFD and flock locks).
    private func watchDescription(_ open: DarwinOpenFile) {
        let key = ObjectIdentifier(open)
        guard !open.lastCloseHandlers.keys.contains("locks") else { return }
        let system = self.system
        open.lastCloseHandlers["locks"] = { [weak system] in
            guard let system else { return }
            system.lock.withLock { system.fileLocks.release(owner: .description(key)) }
        }
    }

    /// fcntl F_GETLK / F_SETLK / F_SETLKW / F_SETLKWTIMEOUT and the F_OFD_*
    /// forms. `arg` points at a `struct flock` (l_start @0, l_len @8,
    /// l_pid @16, l_type @20 (short), l_whence @22 (short); 24 bytes), or a
    /// `struct flocktimeout` (the flock, then a timespec @24).
    func fileLockFcntl(_ fd: Int32, _ cmd: Int32, _ arg: UInt64, _ call: inout String,
                       _ mem: any KernelGuestMemory) throws -> UInt64 {
        call = "fcntl(fd=\(fd), \(FileLockControl.names[cmd] ?? "cmd \(cmd)"), arg=\(hx(arg)))"
        let (open, file) = try lockableFile(fd)
        let raw = try mem.read(va: arg, count: 24)
        let lStart = raw.readLE(Int64.self, at: 0), lLen = raw.readLE(Int64.self, at: 8)
        let lType = raw.readLE(Int16.self, at: 20), lWhence = raw.readLE(Int16.self, at: 22)
        // The range (xnu lf_advlock).
        var start: Int64
        switch lWhence {
        case 0: start = lStart
        case 1: start = Int64(clamping: open.offset).addingReportingOverflow(lStart).partialValue
        case 2: start = (try fileSystem.fstat(fd).size).addingReportingOverflow(lStart).partialValue
        default: throw fail(Code.EINVAL)
        }
        guard start >= 0 else { throw fail(Code.EINVAL) }
        let end: Int64
        if lLen < 0 {
            guard start != 0 else { throw fail(Code.EINVAL) }
            end = start - 1
            start += lLen
            guard start >= 0 else { throw fail(Code.EINVAL) }
        } else if lLen == 0 {
            end = Int64.max
        } else {
            guard lLen - 1 <= Int64.max - start else { throw fail(Code.EOVERFLOW) }
            end = start + (lLen - 1)
        }
        let ofd = cmd >= FileLockControl.ofdSetlk
        let owner: FileLockTable.Owner = ofd ? .description(ObjectIdentifier(open)) : .process(pid)
        let table = system.fileLocks
        let id = FileIdentity(file.stat)
        call += " [\(lType == FileLockControl.rdlck ? "rd" : lType == FileLockControl.wrlck ? "wr" : lType == FileLockControl.unlck ? "un" : "type \(lType)") "
            + "\(start)…\(end == Int64.max ? "eof" : String(end))]"

        if cmd == FileLockControl.getlk || cmd == FileLockControl.ofdGetlk {
            guard [FileLockControl.rdlck, FileLockControl.wrlck, FileLockControl.unlck].contains(lType) else {
                throw fail(Code.EINVAL)
            }
            var out = raw
            if let b = table.blocker(id, owner: owner, exclusive: lType == FileLockControl.wrlck, start: start, end: end) {
                out.putLE(b.start, at: 0)
                out.putLE(b.end == Int64.max ? Int64(0) : b.end - b.start + 1, at: 8)
                if case let .process(p) = b.owner { out.putLE(p, at: 16) } else { out.putLE(Int32(-1), at: 16) }
                out.putLE(b.exclusive ? FileLockControl.wrlck : FileLockControl.rdlck, at: 20)
                out.putLE(Int16(0), at: 22)
                call += " [held by \(b.owner)]"
            } else {
                out.putLE(FileLockControl.unlck, at: 20)
            }
            try mem.write(va: arg, bytes: out)
            return 0
        }

        let exclusive: Bool?
        switch lType {
        case FileLockControl.rdlck:
            guard open.isReadable else { throw fail(Code.EBADF) }
            exclusive = false
        case FileLockControl.wrlck:
            guard open.isWritable else { throw fail(Code.EBADF) }
            exclusive = true
        case FileLockControl.unlck:
            exclusive = nil
        default:
            throw fail(Code.EINVAL)
        }
        if ofd { watchDescription(open) }
        let wait = cmd == FileLockControl.setlkw || cmd == FileLockControl.ofdSetlkw
            || cmd == FileLockControl.setlkwTimeout || cmd == FileLockControl.ofdSetlkwTimeout
        var deadline: UInt64?
        if cmd == FileLockControl.setlkwTimeout || cmd == FileLockControl.ofdSetlkwTimeout {
            let ts = try mem.read(va: arg + 24, count: 16)
            let sec = ts.readLE(Int64.self, at: 0), nsec = ts.readLE(Int64.self, at: 8)
            guard sec >= 0, nsec >= 0, nsec < 1_000_000_000 else { throw fail(Code.EINVAL) }
            let ns = UInt64(sec).multipliedReportingOverflow(by: 1_000_000_000)
            deadline = ns.overflow ? UInt64.max : KernelClock.deadline(afterNanoseconds: ns.partialValue &+ UInt64(nsec))
        }
        try acquire(table, id, owner: owner, kind: ofd ? .ofd : .posix, exclusive: exclusive, start: start, end: end,
                    wait: wait, deadline: deadline, call: &call)
        return 0
    }

    /// Takes (or clears) a lock, waiting while another owner blocks it when
    /// `wait`. EAGAIN when it may not wait, EDEADLK for a POSIX cycle,
    /// ETIMEDOUT at `deadline`, EINTR when interrupted.
    private func acquire(_ table: FileLockTable, _ id: FileIdentity, owner: FileLockTable.Owner, kind: FileLockTable.Kind,
                         exclusive: Bool?, start: Int64, end: Int64, wait: Bool, deadline: UInt64?,
                         call: inout String) throws {
        if let exclusive {
            while let b = table.blocker(id, owner: owner, exclusive: exclusive, start: start, end: end) {
                guard wait else { throw fail(Code.EAGAIN) }
                if case let .process(me) = owner, kind == .posix, table.wouldDeadlock(me, waitingFor: b.owner) {
                    throw fail(Code.EDEADLK)
                }
                call += " [waits for \(b.owner)]"
                let state = table.state(id)
                if case let .process(me) = owner { table.blockedOn[me] = b.owner }
                let result = state.waiters.wait(on: lock, deadline: deadline)
                if case let .process(me) = owner { table.blockedOn[me] = nil }
                switch result {
                case .woken: continue
                case .timedOut: throw fail(Code.ETIMEDOUT)
                case .interrupted: throw fail(Code.EINTR)
                }
            }
        }
        table.apply(id, owner: owner, kind: kind, exclusive: exclusive, start: start, end: end)
    }

    /// flock(2) (BSD 131): a whole-file lock owned by the open description.
    func flockCall(_ fd: Int32, _ operation: Int32, _ call: inout String) throws -> UInt64 {
        call = "flock(\(fd), \(hx(UInt32(bitPattern: operation))))"
        // xnu fp_getfvp: not a vnode → ENOTSUP.
        let (open, file) = try lockableFile(fd, notFile: Code.ENOTSUP)
        let owner = FileLockTable.Owner.description(ObjectIdentifier(open))
        let table = system.fileLocks
        let id = FileIdentity(file.stat)
        let op = operation & ~FileLockControl.lockNB
        if op & FileLockControl.lockUN != 0 {
            table.apply(id, owner: owner, kind: .flock, exclusive: nil, start: 0, end: Int64.max)
            return 0
        }
        let exclusive: Bool
        if op & FileLockControl.lockEX != 0 {
            exclusive = true
        } else if op & FileLockControl.lockSH != 0 {
            exclusive = false
        } else {
            throw fail(Code.EBADF)  // xnu sys_flock: no operation → EBADF
        }
        watchDescription(open)
        try acquire(table, id, owner: owner, kind: .flock, exclusive: exclusive, start: 0, end: Int64.max,
                    wait: operation & FileLockControl.lockNB == 0, deadline: nil, call: &call)
        return 0
    }

    /// A descriptor of this process was closed: xnu releases every POSIX
    /// lock the process holds on that file (closef → VOP_ADVLOCK F_UNLCK).
    /// The old image's table at exec is not a close (the new image keeps
    /// the descriptors).
    func releasePOSIXLocksOnClose(_ file: DarwinOpenFile) {
        guard termination != .imageReplaced, let f = file.guestFile else { return }
        let table = system.fileLocks
        let id = FileIdentity(f.stat)
        guard table.hasLocks(of: .process(pid), on: id) else { return }
        table.release(owner: .process(pid), on: id)
    }

    // MARK: Data-protection classes

    /// The class of an open file or directory: the one set on it, else the
    /// nearest ancestor directory's (a new file of a class-0 directory gets
    /// class C, 3), as on the simulator's host volume (level 3).
    func protectionClass(of file: GuestFile) -> Int32 {
        let table = system.fileLocks
        if let c = table.protectionClasses[FileIdentity(file.stat)] { return c }
        var path = (file.guestPath as NSString).deletingLastPathComponent
        while !path.isEmpty {
            if let st = try? fileSystem.stat(path, followSymlinks: true),
               let c = table.protectionClasses[FileIdentity(st)] {
                return file.isDirectory || c != 0 ? c : FileLockControl.defaultFileClass
            }
            if path == "/" { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return file.isDirectory ? 0 : FileLockControl.defaultFileClass
    }

    /// F_SETPROTECTIONCLASS as observed on the simulator's host volume
    /// (level 3): files take classes 1–4 (4, class D, is stored as 3) and
    /// refuse 6 and 7 with EPERM; directories also take 0 and 7 (7 leaves
    /// the class as it is); anything else is EINVAL.
    func setProtectionClass(_ file: GuestFile, _ requested: Int32) throws {
        let table = system.fileLocks
        let id = FileIdentity(file.stat)
        switch requested {
        case 1, 2, 3: table.protectionClasses[id] = requested
        case 4: table.protectionClasses[id] = 3
        case 0 where file.isDirectory: table.protectionClasses[id] = 0
        case 7 where file.isDirectory: break
        case 6, 7: throw fail(Code.EPERM)
        default: throw fail(Code.EINVAL)
        }
    }

    /// fcntl F_GETPROTECTIONCLASS (63), F_SETPROTECTIONCLASS (64),
    /// F_GETPROTECTIONLEVEL (77). Not a file → EBADF.
    func protectionFcntl(_ fd: Int32, _ cmd: Int32, _ arg: UInt64, _ call: inout String) throws -> UInt64 {
        let (_, file) = try lockableFile(fd)
        switch cmd {
        case 63:
            let c = protectionClass(of: file)
            call += " [class \(c)]"
            return UInt64(UInt32(bitPattern: c))
        case 64:
            try setProtectionClass(file, Int32(truncatingIfNeeded: arg))
            return 0
        default:
            return FileLockControl.protectionLevel
        }
    }

    /// `open_dprotected_np` created `fd`: record the requested class (as the
    /// host volume does: 4 is stored as 3; -1, the default, and invalid
    /// classes leave the inherited one).
    func noteCreatedWithClass(_ fd: Int32, _ requested: Int32) {
        guard let (_, file) = try? lockableFile(fd), (1...4).contains(requested) else { return }
        try? setProtectionClass(file, requested)
    }
}

extension DarwinKernel {
    /// The `dpflags` of `open_dprotected_np` and `guarded_open_dprotected_np`
    /// (sys/fcntl.h), as on the simulator's host volume (level 3):
    /// O_DP_GETRAWENCRYPTED (1) opens for reading only (EINVAL with write
    /// access), O_DP_GETRAWUNENCRYPTED (2) is EPERM, O_DP_AUTHENTICATE (4)
    /// is EINVAL; other bits are ignored.
    func checkDataProtectionOpen(flags: Int32, dpflags: Int32) throws {
        if dpflags & 0x2 != 0 { throw fail(Code.EPERM) }
        if dpflags & 0x4 != 0 { throw fail(Code.EINVAL) }
        if dpflags & 0x1 != 0 && flags & DarwinOpen.O_ACCMODE != DarwinOpen.O_RDONLY { throw fail(Code.EINVAL) }
    }
}

extension DarwinKernel {
    /// fsync (95) / fdatasync (187): a vnode descriptor succeeds (Ycode's
    /// writes reach the host file before the call returns; durability
    /// against a host crash is not promised); another descriptor is ENOTSUP
    /// (xnu fp_getfvp), a closed one EBADF.
    func syncCall(_ n: Int, _ fd: Int32, _ call: inout String) throws -> UInt64 {
        call = "\(n == 95 ? "fsync" : "fdatasync")(\(fd))"
        _ = try lockableFile(fd, notFile: Code.ENOTSUP)
        return 0
    }
}
