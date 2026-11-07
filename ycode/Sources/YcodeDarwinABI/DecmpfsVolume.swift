import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// decmpfs on Ycode's volume (`specs/simulator/lzbitmap.md` §4,
// `file-system-features.md` §3.1).
//
// A writer makes a compressed file with `fsetxattr("com.apple.ResourceFork",
// blocks, position)` (type 14), `fsetxattr("com.apple.decmpfs", header)`,
// `ftruncate(0)` and `fchflags(UF_COMPRESSED)` (§4.2). Ycode's host volume
// has no transparent compression, so the volume **decompresses the file when
// the flag is set**: the decoded bytes become the file's data, the two
// attributes go away, and the flag stays clear, as for a file a writer
// later opened and wrote (§4.2: such a file is decompressed first). Reads,
// `stat` and `mmap` then need nothing else. A file whose header is not a
// valid decmpfs header keeps the flag clear as on the reference.
//
// Resource forks are position-addressed (any position, any size; a write at
// position 0 does not truncate). The host's ext4 keeps attribute values of
// about 4 KB at most, so a fork is held by the volume, keyed by the host
// file's device and inode, until the file is decompressed or the attribute is
// removed. Forks are not kept across a restart of the simulator.

extension DarwinFileSystem {
    /// Host (device, inode) of a file.
    struct ForkKey: Hashable { let dev: UInt32, ino: UInt64 }

    /// The resource forks the volume holds (see the file comment).
    static let resourceForks = Mutex<[ForkKey: [UInt8]]>([:])

    /// Files decompressed when UF_COMPRESSED was set (statistics).
    public static let decompressedFiles = Atomic<Int>(0)

    func forkKey(_ host: (path: String?, fd: Int32?, writable: Bool, guestPath: String, item: FileChange.Item)) -> ForkKey? {
        let st: DarwinStat?
        if let fd = host.fd { st = try? hostFStat(fd) } else if let path = host.path { st = try? hostStatCall(path, follow: false) } else { st = nil }
        return st.map { ForkKey(dev: $0.dev, ino: $0.ino) }
    }

    /// The fork the volume holds for `t`, if any.
    func heldResourceFork(_ t: XattrTarget) -> [UInt8]? {
        guard let host = try? xattrHost(t), let key = forkKey(host) else { return nil }
        return Self.resourceForks.withLock { $0[key] }
    }

    /// `fsetxattr("com.apple.ResourceFork", value, position)`: writes at
    /// `position`, growing the fork (zero-filled gaps); never truncates.
    public func writeResourceFork(_ t: XattrTarget, value: [UInt8], position: Int, create: Bool, replace: Bool) throws {
        let host = try xattrHost(t)
        guard host.writable, host.path != nil || host.fd != nil else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        guard let key = forkKey(host) else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        let hostFork = try? getHostAttribute(host, name: Decmpfs.resourceForkName)
        try Self.resourceForks.withLock { forks in
            var fork = forks[key] ?? hostFork
            if create, fork != nil { throw DarwinErrnoError(DarwinErrnoCode.EEXIST) }
            if replace, fork == nil { throw DarwinErrnoError(Self.ENOATTR) }
            var bytes = fork ?? []
            let end = position + value.count
            if bytes.count < end { bytes += [UInt8](repeating: 0, count: end - bytes.count) }
            bytes.replaceSubrange(position..<end, with: value)
            fork = bytes
            forks[key] = fork
        }
        // A copy in the host attribute would now be stale.
        if hostFork != nil { try? removeHostAttribute(host, name: Decmpfs.resourceForkName) }
        FileChangeFeed.note(.extendedAttribute, host.item, host.guestPath, pid: ownerPID)
        VnodeNotes.postAttrib(path: host.path, fd: host.fd)
    }

    /// Removes the held fork of `t`; true when there was one.
    func removeHeldResourceFork(_ t: XattrTarget) -> Bool {
        guard let host = try? xattrHost(t), let key = forkKey(host) else { return false }
        return Self.resourceForks.withLock { $0.removeValue(forKey: key) != nil }
    }

    /// chflags with UF_COMPRESSED: decompresses the file into its data when
    /// its decmpfs attribute is valid (see the file comment). Returns true
    /// when it did.
    @discardableResult
    func decompressOnFlag(_ t: XattrTarget) throws -> Bool {
        let host = try xattrHost(t)
        guard host.writable, let attr = try? getHostAttribute(host, name: Decmpfs.attributeName),
              Decmpfs.header(attr) != nil else { return false }
        let key = forkKey(host)
        let fork = key.flatMap { k in Self.resourceForks.withLock { $0[k] } } ?? (try? getHostAttribute(host, name: Decmpfs.resourceForkName))
        let bytes: [UInt8]
        switch Decmpfs.decode(attribute: attr, fork: fork) {
        case let .success(b): bytes = b
        // The reference fails the open or the reads of such a file; Ycode
        // leaves it as it is (empty, the attributes kept, the flag clear).
        case .failure: return false
        }
        let fd: Int32
        var owned = false
        if let f = host.fd {
            fd = f
        } else if let path = host.path {
            fd = try hostOpen(path, O_WRONLY, 0)
            owned = true
        } else {
            return false
        }
        defer { if owned { hostClose(fd) } }
        guard ftruncate(fd, 0) == 0 else { throw DarwinErrnoError(hostErrno()) }
        if !bytes.isEmpty { _ = try hostPWrite(fd, bytes, offset: 0) }
        SharedFileViews.sizeMayHaveChanged(hostFD: fd)
        try? removeHostAttribute(host, name: Decmpfs.attributeName)
        try? removeHostAttribute(host, name: Decmpfs.resourceForkName)
        if let key { _ = Self.resourceForks.withLock { $0.removeValue(forKey: key) } }
        Self.decompressedFiles.wrappingAdd(1, ordering: .relaxed)
        FileChangeFeed.note(.modified, host.item, host.guestPath, pid: ownerPID)
        return true
    }

    // MARK: Host attributes (the guest's names, `user.ycode.<name>`)

    func getHostAttribute(_ host: (path: String?, fd: Int32?, writable: Bool, guestPath: String, item: FileChange.Item),
                          name: String) throws -> [UInt8] {
        let key = Self.xattrPrefix + name
        func call(_ buffer: UnsafeMutableRawPointer?, _ size: Int) -> Int {
            #if canImport(Darwin)
            if let fd = host.fd { return fgetxattr(fd, key, buffer, size, 0, 0) }
            return getxattr(host.path!, key, buffer, size, 0, XATTR_NOFOLLOW)
            #else
            if let fd = host.fd { return LinuxXattr.fget(fd, key, buffer, size) }
            return LinuxXattr.lget(host.path!, key, buffer, size)
            #endif
        }
        guard host.fd != nil || host.path != nil else { throw DarwinErrnoError(Self.ENOATTR) }
        let size = call(nil, 0)
        guard size >= 0 else { throw DarwinErrnoError(Self.ENOATTR) }
        var bytes = [UInt8](repeating: 0, count: size)
        let n = bytes.withUnsafeMutableBytes { call($0.baseAddress, size) }
        guard n >= 0 else { throw DarwinErrnoError(Self.ENOATTR) }
        return Array(bytes.prefix(n))
    }

    func removeHostAttribute(_ host: (path: String?, fd: Int32?, writable: Bool, guestPath: String, item: FileChange.Item),
                             name: String) throws {
        let key = Self.xattrPrefix + name
        #if canImport(Darwin)
        let r = host.fd.map { fremovexattr($0, key, 0) } ?? (host.path.map { removexattr($0, key, XATTR_NOFOLLOW) } ?? -1)
        #else
        let r = host.fd.map { LinuxXattr.fremove($0, key) } ?? (host.path.map { LinuxXattr.lremove($0, key) } ?? -1)
        #endif
        guard r == 0 else { throw DarwinErrnoError(Self.ENOATTR) }
    }
}
