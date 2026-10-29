// What the data volume's capability bits commit Ycode to
// (specs/simulator/file-system-features.md; service-fidelity.md §11):
// BSD file flags and document IDs (VOL_CAP_FMT_DOCUMENT_ID), write
// generation counts (VOL_CAP_FMT_WRITE_GENERATION_COUNT), clones
// (VOL_CAP_INT_CLONE), and the feed of file changes the host's file-event
// service reads (fsevents-host.md, "Ycode implementation"). Semantics from
// the public headers and open source (xnu `bsd/sys/attr.h`, `bsd/sys/stat.h`,
// `bsd/sys/clonefile.h`, `bsd/vfs/vfs_attrlist.c`, `bsd/vfs/vfs_syscalls.c`;
// the HFS sources' document-id and generation-count rules); level 1.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization

// MARK: - File flags and document IDs

/// Ycode's per-file metadata that a Linux host file cannot hold itself: the
/// BSD file flags (`st_flags`, chflags(2)) and the document ID. Kept as one
/// host extended attribute, `user.ycodevfs.meta` (8 bytes: u32 flags, u32
/// document ID, little-endian), so it moves with the file on renames, goes
/// with it when it is removed, and is copied with it by copies that keep
/// extended attributes. The guest never sees the attribute: guest
/// attributes live under `user.ycode.` (DarwinFileSystem's xattr calls).
public enum VolumeMetadata {
    /// The host extended attribute that holds a file's `Record`
    /// (`file-system-features.md` §3).
    public static let hostAttributeName = "user.ycodevfs.meta"
    /// The document-ID allocator's state: a host attribute of the directory
    /// `documentIDStateDirectory` (DEV/data in device mode), so the counter
    /// travels with the files whose IDs it issued.
    public static let allocatorAttributeName = "user.ycodevfs.next-document-id"

    // BSD file-flag bits for `st_flags` (xnu `bsd/sys/stat.h`); which ones a
    // guest may change is in `file-system-features.md` §3.
    public static let ufTracked: UInt32 = 0x40
    public static let ufDataVault: UInt32 = 0x80
    public static let ufCompressed: UInt32 = 0x20
    /// The owner-settable flags (the low 16 bits).
    public static let ufSettable: UInt32 = 0x0000_FFFF
    /// The superuser-settable flags; a guest that changes one gets EPERM.
    public static let sfSettable: UInt32 = 0x3FFF_0000

    /// One file's flags and document ID (0: none), as stored in the attribute.
    public struct Record: Equatable, Sendable {
        public var flags: UInt32
        public var documentID: UInt32
        public init(flags: UInt32 = 0, documentID: UInt32 = 0) {
            self.flags = flags
            self.documentID = documentID
        }
        var isEmpty: Bool { flags == 0 && documentID == 0 }
        var bytes: [UInt8] {
            var b: [UInt8] = []
            for v in [flags, documentID] { for i in 0..<4 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
            return b
        }
        init?(bytes: [UInt8]) {
            guard bytes.count >= 8 else { return nil }
            func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[o + $1]) << (8 * UInt32($1)) } }
            self.init(flags: u32(0), documentID: u32(4))
        }
    }

    /// The record of a host file (by path, not following a final link, or
    /// by descriptor); an empty record when it has none or the host cannot
    /// say.
    public static func read(hostPath: String? = nil, fd: Int32? = nil) -> Record {
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = buffer.withUnsafeMutableBytes { b -> Int in
            #if canImport(Darwin)
            if let fd { return fgetxattr(fd, hostAttributeName, b.baseAddress, 16, 0, 0) }
            return getxattr(hostPath!, hostAttributeName, b.baseAddress, 16, 0, XATTR_NOFOLLOW)
            #else
            if let fd { return LinuxXattr.fget(fd, hostAttributeName, b.baseAddress, 16) }
            return LinuxXattr.lget(hostPath!, hostAttributeName, b.baseAddress, 16)
            #endif
        }
        guard n >= 8 else { return Record() }
        return Record(bytes: Array(buffer.prefix(n))) ?? Record()
    }

    /// Stores (or, for an empty record, removes) the record. Throws the
    /// Darwin errno (ENOTSUP when the host file system keeps no attributes).
    public static func write(_ record: Record, hostPath: String? = nil, fd: Int32? = nil) throws {
        if record.isEmpty {
            #if canImport(Darwin)
            let r = fd.map { fremovexattr($0, hostAttributeName, 0) } ?? removexattr(hostPath!, hostAttributeName, XATTR_NOFOLLOW)
            #else
            let r = fd.map { LinuxXattr.fremove($0, hostAttributeName) } ?? LinuxXattr.lremove(hostPath!, hostAttributeName)
            #endif
            #if canImport(Darwin)
            let missing = errno == ENOATTR
            #else
            let missing = errno == ENODATA
            #endif
            guard r == 0 || missing else { throw DarwinErrnoError(xattrErrno()) }
            return
        }
        let bytes = record.bytes
        let r: Int32 = bytes.withUnsafeBytes { v in
            #if canImport(Darwin)
            if let fd { return fsetxattr(fd, hostAttributeName, v.baseAddress, v.count, 0, 0) }
            return setxattr(hostPath!, hostAttributeName, v.baseAddress, v.count, 0, XATTR_NOFOLLOW)
            #else
            if let fd { return LinuxXattr.fset(fd, hostAttributeName, v.baseAddress, v.count, 0) }
            return LinuxXattr.lset(hostPath!, hostAttributeName, v.baseAddress, v.count, 0)
            #endif
        }
        guard r == 0 else { throw DarwinErrnoError(xattrErrno()) }
    }

    static func xattrErrno() -> Int32 {
        #if canImport(Darwin)
        return DarwinErrnoCode.fromHost(errno)
        #else
        return errno == 95 ? DarwinErrnoCode.ENOTSUP : DarwinErrnoCode.fromHost(errno)
        #endif
    }

    // MARK: Document-ID allocation

    /// Set once before the guest runs (device mode: DEV/data). nil: an
    /// in-memory counter (tests, `--exec`).
    nonisolated(unsafe) public static var documentIDStateDirectory: String?
    /// The first document ID of a volume that has issued none.
    public static let firstDocumentID: UInt32 = 16
    private static let allocatorLock = NSLockLike(name: "document ids")
    nonisolated(unsafe) private static var memoryNext: UInt32 = firstDocumentID

    /// A new document ID: never 0, never issued before on this volume
    /// (the counter is stored before the ID is handed out).
    public static func allocateDocumentID() -> UInt32 {
        allocatorLock.withLock {
            guard let dir = documentIDStateDirectory else {
                defer { memoryNext = memoryNext == UInt32.max ? firstDocumentID : memoryNext + 1 }
                return memoryNext
            }
            var buffer = [UInt8](repeating: 0, count: 8)
            let n = buffer.withUnsafeMutableBytes { b -> Int in
                #if canImport(Darwin)
                return getxattr(dir, allocatorAttributeName, b.baseAddress, 8, 0, 0)
                #else
                return LinuxXattr.lget(dir, allocatorAttributeName, b.baseAddress, 8)
                #endif
            }
            var next = firstDocumentID
            if n >= 4 { next = max(firstDocumentID, (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[$1]) << (8 * UInt32($1)) }) }
            let id = next
            let after = next == UInt32.max ? firstDocumentID : next + 1
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: after >> (8 * UInt32($0))) }
            _ = bytes.withUnsafeBytes { v -> Int32 in
                #if canImport(Darwin)
                return setxattr(dir, allocatorAttributeName, v.baseAddress, 4, 0, 0)
                #else
                return LinuxXattr.lset(dir, allocatorAttributeName, v.baseAddress, 4, 0)
                #endif
            }
            return id
        }
    }

    /// Tests: forget the in-memory counter.
    public static func resetMemoryAllocator() { allocatorLock.withLock { memoryNext = firstDocumentID } }
}

// MARK: - Write generation counts

/// `ATTR_CMN_GEN_COUNT` (sys/attr.h; HFS keeps a per-file counter bumped by
/// every write). Ycode's value for a regular file or directory is an opaque
/// nonzero number that changes whenever the contents change and stays the
/// same otherwise, also across boots: a hash of the host modification time
/// and size, and of the number of writes made through Ycode since the last
/// time the value was read with that same modification time (the host
/// clock's granularity can leave two writes with one time stamp). Other
/// object types have none (0, as HFS answers).
public enum WriteGenerations {
    struct Key: Hashable { let dev: UInt32; let ino: UInt64 }
    struct Entry { var writes: UInt32 = 0; var seenMtime: DarwinTimespec?; var base: UInt32 = 0 }
    private static let lock = NSLockLike(name: "write generations")
    nonisolated(unsafe) private static var table: [Key: Entry] = [:]

    /// A write (or truncation) of the file `dev`/`ino` through Ycode.
    public static func noteWrite(dev: UInt32, ino: UInt64) {
        lock.withLock { table[Key(dev: dev, ino: ino), default: Entry()].writes &+= 1 }
    }

    /// The count `getattrlist` reports for an object with stat data `st`.
    public static func count(_ st: DarwinStat) -> UInt32 {
        guard st.isRegularFile || st.isDirectory else { return 0 }
        let delta: UInt32 = lock.withLock {
            let key = Key(dev: st.dev, ino: st.ino)
            guard var e = table[key] else { return 0 }
            if e.seenMtime != st.mtime {
                e.seenMtime = st.mtime
                e.base = e.writes
            }
            table[key] = e
            return e.writes &- e.base
        }
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for v in [UInt64(bitPattern: st.mtime.sec), UInt64(bitPattern: st.mtime.nsec), UInt64(bitPattern: st.size),
                  UInt64(delta), UInt64(st.ino)] {
            for i in 0..<8 { h = (h ^ ((v >> (8 * UInt64(i))) & 0xFF)) &* 0x0000_0100_0000_01B3 }
        }
        let value = UInt32(truncatingIfNeeded: h ^ (h >> 32))
        return value == 0 ? 1 : value
    }
}

// MARK: - File changes (the feed of the host's file-event service)

/// One change the guest made to its file system.
public struct FileChange: Equatable, Sendable {
    /// What changed (`file-system-features.md` §7).
    public enum Kind: UInt8, Sendable { case created, removed, renamed, modified, inodeMetadata, owner, extendedAttribute, cloned }
    /// The type of the object that changed.
    public enum Item: UInt8, Sendable { case file, directory, symbolicLink, other }
    public var kind: Kind
    public var item: Item
    /// The object's canonical guest path.
    public var path: String
    /// The guest process that made it (0: the host).
    public var pid: Int32
    public init(kind: Kind, item: Item, path: String, pid: Int32) {
        self.kind = kind
        self.item = item
        self.path = path
        self.pid = pid
    }

    /// The item type for a stat result; nil (the object is gone) counts as a file.
    public static func item(_ st: DarwinStat?) -> Item {
        guard let st else { return .file }
        if st.isDirectory { return .directory }
        if st.isSymbolicLink { return .symbolicLink }
        return st.isRegularFile ? .file : .other
    }
}

/// Where the VFS reports changes. One observer (the file-event service),
/// installed before the guest runs; `listening` is false while it has
/// nothing to watch, so the VFS's calls cost one atomic load.
public enum FileChangeFeed {
    nonisolated(unsafe) private static var observer: (@Sendable (FileChange) -> Void)?
    private static let listeningFlag = Atomic<Bool>(false)

    /// Sets the one observer (nil removes it and stops listening). Call
    /// before the guest runs; the observer is not guarded by a lock.
    public static func install(_ body: (@Sendable (FileChange) -> Void)?) {
        observer = body
        if body == nil { listeningFlag.store(false, ordering: .releasing) }
    }

    /// The observer has (true) or has no (false) interest in changes.
    public static func setListening(_ on: Bool) { listeningFlag.store(on && observer != nil, ordering: .releasing) }

    /// True when an observer is installed and wants changes; one atomic load.
    @inline(__always) public static var isListening: Bool { listeningFlag.load(ordering: .acquiring) }

    /// Reports one change to the observer when it is listening; a no-op
    /// otherwise. `pid` 0 means the host made the change.
    @inline(__always) public static func note(_ kind: FileChange.Kind, _ item: FileChange.Item, _ path: String, pid: Int32) {
        guard isListening, let o = observer else { return }
        o(FileChange(kind: kind, item: item, path: path, pid: pid))
    }
}

// MARK: - Host clones

/// Clones of host files: a copy-on-write clone where the host file system
/// has one (Linux FICLONE: btrfs, XFS; macOS clonefile), otherwise a copy
/// with the same observable result (contents, mode, times, guest extended
/// attributes, flags). ext4, the Thor's data drive, has no clones.
enum HostClone {
    #if os(Linux)
    typealias IoctlInt = @convention(c) (Int32, UInt, Int32) -> Int32
    typealias CopyRange = @convention(c) (Int32, UnsafeMutablePointer<Int64>?, Int32, UnsafeMutablePointer<Int64>?, Int, UInt32) -> Int
    static let ioctlInt: IoctlInt? = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "ioctl").map { unsafeBitCast($0, to: IoctlInt.self) }
    static let copyFileRange: CopyRange? = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "copy_file_range")
        .map { unsafeBitCast($0, to: CopyRange.self) }
    /// FICLONE = _IOW(0x94, 9, int).
    static let ficlone: UInt = 0x4004_9409
    #endif

    /// Copies the data of `from` into the empty file `to` (both open).
    static func copyData(from: Int32, to: Int32) throws {
        #if os(Linux)
        if let ioctlInt, ioctlInt(to, ficlone, from) == 0 { return }
        if let copyFileRange {
            while true {
                let n = copyFileRange(from, nil, to, nil, 1 << 30, 0)
                if n > 0 { continue }
                if n == 0 { return }
                if errno == EINTR { continue }
                if errno == EXDEV || errno == ENOSYS || errno == EINVAL || errno == EOPNOTSUPP { break }
                throw DarwinErrnoError(hostErrno())
            }
            // Start over with plain reads (nothing was copied, or the
            // offsets moved: rewind both).
            guard ftruncate(to, 0) == 0 else { throw DarwinErrnoError(hostErrno()) }
            _ = lseek(from, 0, SEEK_SET)
            _ = lseek(to, 0, SEEK_SET)
        }
        #endif
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset: off_t = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { pread(from, $0.baseAddress, $0.count, offset) }
            if n < 0 {
                if errno == EINTR { continue }
                throw DarwinErrnoError(hostErrno())
            }
            if n == 0 { return }
            var done = 0
            while done < n {
                let w = buffer.withUnsafeBytes { pwrite(to, $0.baseAddress! + done, n - done, offset + off_t(done)) }
                if w < 0 {
                    if errno == EINTR { continue }
                    throw DarwinErrnoError(hostErrno())
                }
                done += w
            }
            offset += off_t(n)
        }
    }

    /// The guest's extended attributes of `from` (host names `user.ycode.*`)
    /// copied to `to` (paths, links not followed).
    static func copyGuestAttributes(from: String, to: String) {
        func list(_ path: String) -> [String] {
            var buffer = [CChar](repeating: 0, count: 65536)
            #if canImport(Darwin)
            let n = listxattr(path, &buffer, buffer.count, XATTR_NOFOLLOW)
            #else
            let n = LinuxXattr.llist(path, &buffer, buffer.count)
            #endif
            guard n > 0 else { return [] }
            return buffer.prefix(n).map { UInt8(bitPattern: $0) }.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        }
        for name in list(from) where name.hasPrefix(DarwinFileSystem.xattrPrefix) {
            var value = [UInt8](repeating: 0, count: 65536)
            #if canImport(Darwin)
            let n = getxattr(from, name, &value, value.count, 0, XATTR_NOFOLLOW)
            #else
            let n = LinuxXattr.lget(from, name, &value, value.count)
            #endif
            guard n >= 0 else { continue }
            _ = value.withUnsafeBytes { v -> Int32 in
                #if canImport(Darwin)
                return setxattr(to, name, v.baseAddress, n, 0, XATTR_NOFOLLOW)
                #else
                return LinuxXattr.lset(to, name, v.baseAddress, n, 0)
                #endif
            }
        }
    }
}

// MARK: - The VFS side

extension GuestFile {
    /// A write or truncation through this open file.
    func noteWritten(pid: Int32) {
        WriteGenerations.noteWrite(dev: stat.dev, ino: stat.ino)
        FileChangeFeed.note(.modified, .file, guestPath, pid: pid)
    }
}

extension DarwinFileSystem {
    // MARK: File flags (chflags, fchflags, setattrlist ATTR_CMN_FLAGS)

    /// chflags(2): stores the owner-settable flags (`UF_SETTABLE`, except
    /// UF_COMPRESSED, which only a file system sets). Changing a
    /// superuser flag (`SF_SETTABLE`) or UF_DATAVAULT is EPERM: guest
    /// processes are never the superuser. Setting UF_TRACKED gives the
    /// object a document ID (a new one unless it has one); clearing it
    /// clears the ID (HFS `hfs_set_bsd_flags`). Read-only volumes: EROFS.
    /// The flags are kept and reported; Ycode does not enforce
    /// UF_IMMUTABLE or UF_APPEND.
    public func setFileFlags(_ target: XattrTarget, _ flags: UInt32) throws {
        let host = try xattrHost(target)
        guard host.path != nil || host.fd != nil else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        guard host.writable else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        var record = VolumeMetadata.read(hostPath: host.path, fd: host.fd)
        let old = record.flags
        if (flags ^ old) & (VolumeMetadata.sfSettable | VolumeMetadata.ufDataVault) != 0 {
            throw DarwinErrnoError(DarwinErrnoCode.EPERM)
        }
        let userBits = VolumeMetadata.ufSettable & ~VolumeMetadata.ufCompressed
        record.flags = (flags & userBits) | (old & ~userBits)
        let tracked = record.flags & VolumeMetadata.ufTracked != 0
        if tracked, record.documentID == 0 {
            record.documentID = VolumeMetadata.allocateDocumentID()
        } else if !tracked {
            record.documentID = 0
        }
        if record != VolumeMetadata.read(hostPath: host.path, fd: host.fd) {
            try VolumeMetadata.write(record, hostPath: host.path, fd: host.fd)
        }
        FileChangeFeed.note(.inodeMetadata, host.item, host.guestPath, pid: ownerPID)
        VnodeNotes.postAttrib(path: host.path, fd: host.fd)
    }

    /// The document ID of the object at a canonical guest path (its final
    /// component not followed), as `ATTR_CMN_DOCUMENT_ID` reports it: 0 for
    /// an untracked object; a tracked object without one gets a new one
    /// (HFS `hfs_vnop_getattr`; e.g. a clone of a tracked file).
    public func documentID(atCanonicalPath path: String) -> UInt32 {
        guard let r = try? resolve(path, followFinal: false), let st = r.stat, r.prefix.writable, !r.hostPath.isEmpty
        else { return 0 }
        var record = VolumeMetadata.read(hostPath: r.hostPath)
        if record.flags & VolumeMetadata.ufTracked != 0, record.documentID == 0,
           st.isRegularFile || st.isDirectory || st.isSymbolicLink {
            record.documentID = VolumeMetadata.allocateDocumentID()
            do { try VolumeMetadata.write(record, hostPath: r.hostPath) } catch { return 0 }
        }
        return record.documentID
    }

    /// For the file-event service: the inode number and document ID of the
    /// object at a canonical guest path (not followed), or nil if it is gone.
    public func identity(atCanonicalPath path: String) -> (inode: UInt64, documentID: UInt32)? {
        guard let r = try? resolve(path, followFinal: false), let st = r.stat else { return nil }
        let id = r.prefix.writable && !r.hostPath.isEmpty ? VolumeMetadata.read(hostPath: r.hostPath).documentID : 0
        return (st.ino, id)
    }

    // MARK: Document-ID tombstones (safe saves)

    private static func split(_ guestPath: String) -> (directory: String, name: String) {
        guard let slash = guestPath.lastIndex(of: "/") else { return ("", guestPath) }
        let dir = slash == guestPath.startIndex ? "/" : String(guestPath[..<slash])
        return (dir, String(guestPath[guestPath.index(after: slash)...]))
    }

    /// xnu `doc_tombstone_should_ignore_name`: names of temporary files.
    static func isTemporaryName(_ name: String) -> Bool {
        name.hasPrefix("atmp") || (name.utf8.count > 4 && (name.hasSuffix(".bak") || name.hasSuffix(".tmp")))
    }

    /// A tracked object left `guestPath` (removed, or renamed away to a
    /// free name): its document ID waits for the next object made there.
    func leaveTombstone(guestPath: String, _ record: VolumeMetadata.Record) {
        guard record.documentID != 0, record.flags & VolumeMetadata.ufTracked != 0 else { return }
        let (dir, name) = Self.split(guestPath)
        if tombstone != nil, Self.isTemporaryName(name) { return }
        tombstone = (dir, name, record.documentID)
    }

    /// A new object appeared at `guestPath` (created, or renamed there to a
    /// free name): it takes the tombstone's document ID when the tombstone
    /// names the same place, and keeps its own if it has one. Any other
    /// name, except a temporary one, clears the tombstone.
    func inheritTombstone(guestPath: String, hostFD: Int32? = nil, hostPath: String? = nil) {
        guard let t = tombstone else { return }
        let (dir, name) = Self.split(guestPath)
        guard t.directory == dir, t.name == name else {
            if !Self.isTemporaryName(name) { tombstone = nil }
            return
        }
        tombstone = nil
        var record = VolumeMetadata.read(hostPath: hostPath, fd: hostFD)
        guard record.documentID == 0 else { return }
        record.flags |= VolumeMetadata.ufTracked
        record.documentID = t.documentID
        try? VolumeMetadata.write(record, hostPath: hostPath, fd: hostFD)
    }

    // MARK: Clones (clonefileat, fclonefileat)

    /// `sys/clonefile.h`.
    public static let cloneNoFollow: UInt32 = 0x1, cloneNoOwnerCopy: UInt32 = 0x2, cloneACL: UInt32 = 0x4,
                      cloneNoFollowAny: UInt32 = 0x8, cloneResolveBeneath: UInt32 = 0x10

    /// clonefileat(2): a new object `to` (which must not exist) with the
    /// contents and attributes of `from`, a regular file, symbolic link or
    /// directory (recursively; not a volume's root). xnu
    /// `clonefile_internal`: unknown flags EINVAL; another type EINVAL; an
    /// existing target EEXIST; a read-only target volume EROFS; another
    /// volume EXDEV. The clone has the source's mode, times, extended
    /// attributes and flags (UF_DATAVAULT excepted), the caller as owner
    /// (guests are never the superuser), and no document ID of its own (a
    /// tracked clone gets a new one when it is read). CLONE_ACL is accepted
    /// (Ycode keeps no ACLs); CLONE_RESOLVE_BENEATH is not implemented
    /// (EINVAL), as for renameatx_np.
    public func clone(_ from: String, to: String, flags: UInt32) throws {
        try checkCloneFlags(flags)
        let a = try resolve(from, followFinal: flags & Self.cloneNoFollow == 0,
                            noFollowAny: flags & Self.cloneNoFollowAny != 0)
        guard let st = a.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        try cloneResolved(guestPath: a.guestPath, hostPath: a.hostPath, prefix: a.prefix, st: st, device: a.device != nil,
                          to: to, flags: flags)
    }

    /// fclonefileat(2): the source is an open descriptor (EBADF unless it
    /// was opened for reading).
    public func clone(fd: Int32, to: String, flags: UInt32) throws {
        try checkCloneFlags(flags)
        let d = try entry(fd)
        guard d.file.isReadable else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        guard case let .file(f) = d.file.node else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        guard let prefix = lookupPrefix(f.guestPath)?.prefix else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        var st = try hostFStat(f.hostFD)
        st.dev = f.stat.dev
        try cloneResolved(guestPath: f.guestPath, hostPath: f.hostPath, prefix: prefix, st: st, device: false,
                          to: to, flags: flags)
    }

    private func checkCloneFlags(_ flags: UInt32) throws {
        let known = Self.cloneNoFollow | Self.cloneNoOwnerCopy | Self.cloneACL | Self.cloneNoFollowAny
        guard flags & ~known == 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
    }

    private func cloneResolved(guestPath: String, hostPath: String, prefix: Prefix, st: DarwinStat, device: Bool,
                               to: String, flags: UInt32) throws {
        // The source: a file, link or directory with a host object behind
        // it; a directory that is a volume root or mount point is EINVAL.
        guard !device, !hostPath.isEmpty, st.isRegularFile || st.isSymbolicLink || st.isDirectory else {
            throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
        }
        if st.isDirectory, guestPath == prefix.volumeMountPoint || prefixes.contains(where: { $0.guestPath == guestPath }) {
            throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
        }
        let b = try resolve(to, followFinal: flags & Self.cloneNoFollow == 0, noFollowAny: flags & Self.cloneNoFollowAny != 0)
        if b.stat != nil || b.device != nil || b.guestLink != nil || sockets.nodes[b.guestPath] != nil {
            throw DarwinErrnoError(DarwinErrnoCode.EEXIST)
        }
        guard b.prefix.writable, !b.hostPath.isEmpty else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        let parent = Self.split(b.guestPath).directory
        let targetDevice = (try? stat(parent.isEmpty ? "/" : parent, followSymlinks: true))?.dev
        guard targetDevice == st.dev else { throw DarwinErrnoError(18) }  // EXDEV
        let watched = VnodeNotes.capture(b.hostPath)
        try HostClone.cloneTree(from: hostPath, to: b.hostPath, st: st)
        // xnu VNOP_CLONEFILE: the target's directory gets a new entry
        // (and a new link for a cloned directory, as mkdir).
        watched?.post(directory: VnodeNote.write | (st.isDirectory ? VnodeNote.link : 0))
        FileChangeFeed.note(.cloned, FileChange.item(st), guestPath, pid: ownerPID)
        FileChangeFeed.note(.cloned, FileChange.item(st), b.guestPath, pid: ownerPID)
        FileChangeFeed.note(.created, FileChange.item(st), b.guestPath, pid: ownerPID)
    }
}

// MARK: - Atomic host renames

/// RENAME_EXCL (`swap` false) or RENAME_SWAP done by the host in one step:
/// Linux renameat2 RENAME_NOREPLACE / RENAME_EXCHANGE (glibc 2.28), macOS
/// renamex_np. false: the host cannot (no such call, or the file system
/// refuses the flag); the caller falls back.
func hostRenameAtomically(_ from: String, _ to: String, swap: Bool) throws -> Bool {
    #if canImport(Darwin)
    if renamex_np(from, to, swap ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)) == 0 { return true }
    if errno == ENOTSUP || errno == EINVAL { return false }
    throw DarwinErrnoError(hostErrno())
    #else
    guard let renameat2 = LinuxRename.renameat2 else { return false }
    if renameat2(-100, from, -100, to, swap ? 2 : 1) == 0 { return true }
    if errno == EINVAL || errno == ENOSYS { return false }
    throw DarwinErrnoError(hostErrno())
    #endif
}

#if !canImport(Darwin)
enum LinuxRename {
    typealias Fn = @convention(c) (Int32, UnsafePointer<CChar>, Int32, UnsafePointer<CChar>, UInt32) -> Int32
    static let renameat2: Fn? = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "renameat2").map { unsafeBitCast($0, to: Fn.self) }
}
#endif

extension HostClone {
    /// Clones the host object `from` (stat data `st`, links not followed
    /// below it) to the new name `to`; on failure nothing is left at `to`.
    static func cloneTree(from: String, to: String, st: DarwinStat) throws {
        do {
            try cloneOne(from: from, to: to, st: st)
        } catch {
            removeTree(to)
            throw error
        }
    }

    private static func cloneOne(from: String, to: String, st: DarwinStat) throws {
        let mode = st.mode & 0o7777
        if st.isSymbolicLink {
            let target = try hostReadLink(from)
            guard symlink(target, to) == 0 else { throw DarwinErrnoError(hostErrno()) }
            return
        }
        if st.isDirectory {
            try hostMkdir(to, mode)
            guard let dir = opendir(from) else { throw DarwinErrnoError(hostErrno()) }
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                let child = from + "/" + name
                guard let cst = try? hostStatCall(child, follow: false) else { continue }
                // Only files, links and directories are cloned (a socket or
                // FIFO has no contents to share).
                guard cst.isRegularFile || cst.isSymbolicLink || cst.isDirectory else { continue }
                try cloneOne(from: child, to: to + "/" + name, st: cst)
            }
            copyAttributes(from: from, to: to, st: st, fd: nil)
            return
        }
        let source = try hostOpen(from, O_RDONLY | O_CLOEXEC | O_NOFOLLOW, 0)
        defer { hostClose(source) }
        let target = try hostOpen(to, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        defer { hostClose(target) }
        try copyData(from: source, to: target)
        _ = fchmod(target, mode_t(mode))
        copyAttributes(from: from, to: to, st: st, fd: target)
    }

    /// Times, guest extended attributes and flags (not UF_DATAVAULT, not the
    /// document ID) of `from` onto the new `to`.
    private static func copyAttributes(from: String, to: String, st: DarwinStat, fd: Int32?) {
        copyGuestAttributes(from: from, to: to)
        var record = VolumeMetadata.read(hostPath: from)
        record.flags &= ~VolumeMetadata.ufDataVault
        record.documentID = 0
        if !record.isEmpty {
            if let fd { try? VolumeMetadata.write(record, fd: fd) } else { try? VolumeMetadata.write(record, hostPath: to) }
        }
        _ = hostSetTimes(path: fd == nil ? to : nil, fd: fd, st.atime, st.mtime, follow: false)
    }

    /// Removes what a failed clone made (a file, a link, or a tree).
    static func removeTree(_ path: String) {
        guard let st = try? hostStatCall(path, follow: false) else { return }
        if st.isDirectory, let dir = opendir(path) {
            var names: [String] = []
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if name != "." && name != ".." { names.append(name) }
            }
            closedir(dir)
            for name in names { removeTree(path + "/" + name) }
            _ = rmdir(path)
        } else {
            _ = unlink(path)
        }
    }
}
