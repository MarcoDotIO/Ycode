// The guest file system of the Ycode micro-VM: a path allowlist over host
// directories, a descriptor table, and the Darwin `struct stat` encoding.
// Contract: specs/simulator/stage3-contract.md §8 (VFS) and §8.1 (API);
// `struct stat` facts: specs/simulator/dyld-sim-handoff.md §7.4.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Errors

/// A BSD-style failure, carrying a **Darwin** errno value (not the host's).
public struct DarwinErrnoError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var errno: Int32

    public init(_ errno: Int32) { self.errno = errno }

    public var description: String { "Darwin errno \(errno)\(DarwinErrnoCode.name(errno).map { " (\($0))" } ?? "")" }
}

/// Darwin errno values (stage3-contract.md §8.1, plus a few the VFS reports).
public enum DarwinErrnoCode {
    public static let EPERM: Int32 = 1
    public static let ENOENT: Int32 = 2
    public static let EINTR: Int32 = 4
    public static let EIO: Int32 = 5
    public static let EBADF: Int32 = 9
    public static let EDEADLK: Int32 = 11
    public static let ENOMEM: Int32 = 12
    public static let EACCES: Int32 = 13
    public static let EFAULT: Int32 = 14
    public static let EEXIST: Int32 = 17
    public static let ENODEV: Int32 = 19
    public static let ENOTDIR: Int32 = 20
    public static let EISDIR: Int32 = 21
    public static let EINVAL: Int32 = 22
    public static let EMFILE: Int32 = 24
    public static let ENOTTY: Int32 = 25
    public static let EFBIG: Int32 = 27
    public static let ENOSPC: Int32 = 28
    public static let ESPIPE: Int32 = 29
    public static let EROFS: Int32 = 30
    public static let ERANGE: Int32 = 34
    public static let EAGAIN: Int32 = 35
    public static let ENOTSUP: Int32 = 45
    public static let ELOOP: Int32 = 62
    public static let ENAMETOOLONG: Int32 = 63
    public static let ENOTEMPTY: Int32 = 66
    public static let ENOSYS: Int32 = 78
    public static let EOVERFLOW: Int32 = 84
    // Stage 4b: pipes and sockets (`processes.md` conventions paragraph).
    public static let ESRCH: Int32 = 3
    public static let ENXIO: Int32 = 6
    public static let EDOM: Int32 = 33
    public static let EBUSY: Int32 = 16
    public static let EPIPE: Int32 = 32
    public static let ENOTSOCK: Int32 = 38
    public static let EDESTADDRREQ: Int32 = 39
    public static let EMSGSIZE: Int32 = 40
    public static let EPROTOTYPE: Int32 = 41
    public static let ENOPROTOOPT: Int32 = 42
    public static let EPROTONOSUPPORT: Int32 = 43
    public static let EAFNOSUPPORT: Int32 = 47
    public static let EADDRINUSE: Int32 = 48
    public static let ECONNABORTED: Int32 = 53
    public static let ECONNRESET: Int32 = 54
    public static let ENOBUFS: Int32 = 55
    public static let EISCONN: Int32 = 56
    public static let ENOTCONN: Int32 = 57
    public static let ETIMEDOUT: Int32 = 60
    public static let ECONNREFUSED: Int32 = 61
    public static let EOPNOTSUPP: Int32 = 102

    private static let names: [Int32: String] = [
        1: "EPERM", 2: "ENOENT", 3: "ESRCH", 4: "EINTR", 5: "EIO", 6: "ENXIO", 9: "EBADF", 16: "EBUSY", 11: "EDEADLK", 12: "ENOMEM",
        13: "EACCES", 14: "EFAULT", 17: "EEXIST", 19: "ENODEV", 20: "ENOTDIR", 21: "EISDIR", 22: "EINVAL",
        24: "EMFILE", 25: "ENOTTY", 27: "EFBIG", 28: "ENOSPC", 29: "ESPIPE", 30: "EROFS", 32: "EPIPE", 33: "EDOM",
        34: "ERANGE", 35: "EAGAIN", 38: "ENOTSOCK", 39: "EDESTADDRREQ", 40: "EMSGSIZE", 41: "EPROTOTYPE",
        42: "ENOPROTOOPT", 43: "EPROTONOSUPPORT", 45: "ENOTSUP", 47: "EAFNOSUPPORT", 48: "EADDRINUSE",
        53: "ECONNABORTED", 54: "ECONNRESET", 55: "ENOBUFS", 56: "EISCONN", 57: "ENOTCONN", 60: "ETIMEDOUT",
        61: "ECONNREFUSED", 62: "ELOOP", 63: "ENAMETOOLONG", 66: "ENOTEMPTY", 78: "ENOSYS", 84: "EOVERFLOW",
        102: "EOPNOTSUPP",
    ]

    /// The symbolic name of a Darwin errno value, if it is one listed here.
    public static func name(_ errno: Int32) -> String? { names[errno] }

    /// Converts a host errno value to the Darwin value. On a Darwin host this
    /// is the identity. On Linux, values 1–34 agree except 11 (Linux EAGAIN,
    /// Darwin EDEADLK); the higher values are translated by name, and an
    /// unknown value becomes EIO.
    public static func fromHost(_ e: Int32) -> Int32 {
        #if canImport(Darwin)
        return e
        #else
        switch e {
        case Glibc.EAGAIN: return EAGAIN
        case Glibc.EDEADLK: return EDEADLK
        case Glibc.ENAMETOOLONG: return ENAMETOOLONG
        case Glibc.ELOOP: return ELOOP
        case Glibc.ENOTEMPTY: return ENOTEMPTY
        case Glibc.ENOSYS: return ENOSYS
        case Glibc.EOPNOTSUPP: return ENOTSUP
        case Glibc.EOVERFLOW: return EOVERFLOW
        case Glibc.ENOTSOCK: return ENOTSOCK
        case Glibc.EADDRINUSE: return EADDRINUSE
        case Glibc.ECONNREFUSED: return ECONNREFUSED
        case 1...34: return e
        default: return EIO
        }
        #endif
    }
}

/// Darwin `open(2)` flag values (stage3-contract.md §8).
public enum DarwinOpen {
    public static let O_RDONLY: Int32 = 0x0000
    public static let O_WRONLY: Int32 = 0x0001
    public static let O_RDWR: Int32 = 0x0002
    public static let O_ACCMODE: Int32 = 0x0003
    public static let O_NONBLOCK: Int32 = 0x0004
    public static let O_APPEND: Int32 = 0x0008
    public static let O_ASYNC: Int32 = 0x0040
    public static let O_FSYNC: Int32 = 0x0080
    public static let O_NOFOLLOW: Int32 = 0x0100
    public static let O_CREAT: Int32 = 0x0200
    public static let O_TRUNC: Int32 = 0x0400
    public static let O_EXCL: Int32 = 0x0800
    public static let O_DIRECTORY: Int32 = 0x0010_0000
    public static let O_CLOEXEC: Int32 = 0x0100_0000
    public static let O_CLOFORK: Int32 = 0x0800_0000
}

// MARK: - struct stat

/// A Darwin `struct timespec` (two 64-bit words on arm64).
public struct DarwinTimespec: Equatable, Hashable, Sendable {
    public var sec: Int64
    public var nsec: Int64

    public init(sec: Int64 = 0, nsec: Int64 = 0) {
        self.sec = sec
        self.nsec = nsec
    }
}

/// The Darwin arm64 `struct stat` with 64-bit inodes (`stat64`), 144 bytes.
///
/// Byte offsets used by `encodedStat64()` (all little-endian; the first
/// five agree with dyld-sim-handoff.md §7.4, the rest follow from natural
/// alignment of the public struct's field order):
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 4 | `st_dev` (u32) |
/// | 4 | 2 | `st_mode` (u16) |
/// | 6 | 2 | `st_nlink` (u16) |
/// | 8 | 8 | `st_ino` (u64) |
/// | 16 | 4 | `st_uid` (u32) |
/// | 20 | 4 | `st_gid` (u32) |
/// | 24 | 4 | `st_rdev` (u32) |
/// | 28 | 4 | padding (timespecs are 8-aligned) |
/// | 32 | 16 | `st_atimespec` (sec i64, nsec i64) |
/// | 48 | 16 | `st_mtimespec` |
/// | 64 | 16 | `st_ctimespec` |
/// | 80 | 16 | `st_birthtimespec` |
/// | 96 | 8 | `st_size` (i64) |
/// | 104 | 8 | `st_blocks` (i64) |
/// | 112 | 4 | `st_blksize` (i32) |
/// | 116 | 4 | `st_flags` (u32) |
/// | 120 | 4 | `st_gen` (u32) |
/// | 124 | 4 | `st_lspare` (i32, 0) |
/// | 128 | 16 | `st_qspare` (2 × i64, 0) |
public struct DarwinStat: Equatable, Hashable, Sendable {
    public var dev: UInt32
    public var mode: UInt16
    public var nlink: UInt16
    public var ino: UInt64
    public var uid: UInt32
    public var gid: UInt32
    public var rdev: UInt32
    public var atime: DarwinTimespec
    public var mtime: DarwinTimespec
    public var ctime: DarwinTimespec
    public var birthtime: DarwinTimespec
    public var size: Int64
    public var blocks: Int64
    public var blksize: Int32
    public var flags: UInt32
    public var gen: UInt32

    public init(dev: UInt32 = 0, mode: UInt16 = 0, nlink: UInt16 = 1, ino: UInt64 = 0, uid: UInt32 = 0, gid: UInt32 = 0,
                rdev: UInt32 = 0, atime: DarwinTimespec = .init(), mtime: DarwinTimespec = .init(),
                ctime: DarwinTimespec = .init(), birthtime: DarwinTimespec = .init(), size: Int64 = 0,
                blocks: Int64 = 0, blksize: Int32 = 4096, flags: UInt32 = 0, gen: UInt32 = 0) {
        self.dev = dev
        self.mode = mode
        self.nlink = nlink
        self.ino = ino
        self.uid = uid
        self.gid = gid
        self.rdev = rdev
        self.atime = atime
        self.mtime = mtime
        self.ctime = ctime
        self.birthtime = birthtime
        self.size = size
        self.blocks = blocks
        self.blksize = blksize
        self.flags = flags
        self.gen = gen
    }

    /// The size of the encoded structure.
    public static let encodedSize = 144

    // File type bits of `st_mode` (identical on Darwin and Linux).
    public static let S_IFMT: UInt16 = 0o170000
    public static let S_IFIFO: UInt16 = 0o010000
    public static let S_IFCHR: UInt16 = 0o020000
    public static let S_IFDIR: UInt16 = 0o040000
    public static let S_IFBLK: UInt16 = 0o060000
    public static let S_IFREG: UInt16 = 0o100000
    public static let S_IFLNK: UInt16 = 0o120000
    public static let S_IFSOCK: UInt16 = 0o140000

    public var fileType: UInt16 { mode & Self.S_IFMT }
    public var isDirectory: Bool { fileType == Self.S_IFDIR }
    public var isRegularFile: Bool { fileType == Self.S_IFREG }
    public var isSymbolicLink: Bool { fileType == Self.S_IFLNK }

    /// Exactly 144 bytes in the layout of the table above.
    public func encodedStat64() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Self.encodedSize)
        func put<T: FixedWidthInteger>(_ v: T, at offset: Int) {
            for i in 0..<(T.bitWidth / 8) { b[offset + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
        }
        put(dev, at: 0)
        put(mode, at: 4)
        put(nlink, at: 6)
        put(ino, at: 8)
        put(uid, at: 16)
        put(gid, at: 20)
        put(rdev, at: 24)
        for (i, t) in [atime, mtime, ctime, birthtime].enumerated() {
            put(t.sec, at: 32 + 16 * i)
            put(t.nsec, at: 40 + 16 * i)
        }
        put(size, at: 96)
        put(blocks, at: 104)
        put(blksize, at: 112)
        put(flags, at: 116)
        put(gen, at: 120)
        return b
    }

    /// Decodes the 144-byte layout (the inverse of `encodedStat64()`).
    public init?(decodingStat64 b: [UInt8]) {
        guard b.count >= Self.encodedSize else { return nil }
        func get<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
            var v: T = 0
            for i in 0..<(T.bitWidth / 8) { v |= T(truncatingIfNeeded: b[offset + i]) << (8 * i) }
            return v
        }
        func ts(_ offset: Int) -> DarwinTimespec { .init(sec: get(Int64.self, at: offset), nsec: get(Int64.self, at: offset + 8)) }
        self.init(dev: get(UInt32.self, at: 0), mode: get(UInt16.self, at: 4), nlink: get(UInt16.self, at: 6),
                  ino: get(UInt64.self, at: 8), uid: get(UInt32.self, at: 16), gid: get(UInt32.self, at: 20),
                  rdev: get(UInt32.self, at: 24), atime: ts(32), mtime: ts(48), ctime: ts(64), birthtime: ts(80),
                  size: get(Int64.self, at: 96), blocks: get(Int64.self, at: 104), blksize: get(Int32.self, at: 112),
                  flags: get(UInt32.self, at: 116), gen: get(UInt32.self, at: 120))
    }
}

// MARK: - Host calls (kept outside the types whose members shadow the C names)

private func hostErrno() -> Int32 { DarwinErrnoCode.fromHost(errno) }

private func hostStatCall(_ path: String, follow: Bool) throws -> DarwinStat {
    #if canImport(Darwin)
    var st = Darwin.stat()
    #elseif canImport(Glibc)
    var st = Glibc.stat()
    #else
    var st = Musl.stat()
    #endif
    let r: Int32 = follow ? stat(path, &st) : lstat(path, &st)
    guard r == 0 else { throw DarwinErrnoError(hostErrno()) }
    return darwinStat(fromHost: st)
}

private func hostFStat(_ fd: Int32) throws -> DarwinStat {
    #if canImport(Darwin)
    var st = Darwin.stat()
    #elseif canImport(Glibc)
    var st = Glibc.stat()
    #else
    var st = Musl.stat()
    #endif
    guard fstat(fd, &st) == 0 else { throw DarwinErrnoError(hostErrno()) }
    return darwinStat(fromHost: st)
}

/// Converts a host `struct stat`. Files owned by the host user are reported
/// as owned by the guest user (uid 501, gid 20, as `getuid`/`getgid` return).
/// Linux has no birth time in `struct stat`; the earliest of the other three
/// times stands in. `st_flags` and `st_gen` are 0.
#if canImport(Darwin)
private func darwinStat(fromHost st: Darwin.stat) -> DarwinStat {
    func ts(_ t: timespec) -> DarwinTimespec { .init(sec: Int64(t.tv_sec), nsec: Int64(t.tv_nsec)) }
    return DarwinStat(
        dev: UInt32(truncatingIfNeeded: st.st_dev), mode: UInt16(truncatingIfNeeded: st.st_mode),
        nlink: UInt16(clamping: st.st_nlink), ino: UInt64(truncatingIfNeeded: st.st_ino),
        uid: guestUID(st.st_uid), gid: guestGID(st.st_gid), rdev: UInt32(truncatingIfNeeded: st.st_rdev),
        atime: ts(st.st_atimespec), mtime: ts(st.st_mtimespec), ctime: ts(st.st_ctimespec),
        birthtime: ts(st.st_birthtimespec), size: Int64(st.st_size), blocks: Int64(st.st_blocks),
        blksize: Int32(truncatingIfNeeded: st.st_blksize), flags: 0, gen: 0)
}
#else
private func darwinStat(fromHost st: stat) -> DarwinStat {
    func ts(_ t: timespec) -> DarwinTimespec { .init(sec: Int64(t.tv_sec), nsec: Int64(t.tv_nsec)) }
    let a = ts(st.st_atim), m = ts(st.st_mtim), c = ts(st.st_ctim)
    let birth = [a, m, c].min { ($0.sec, $0.nsec) < ($1.sec, $1.nsec) }!
    return DarwinStat(
        dev: UInt32(truncatingIfNeeded: st.st_dev), mode: UInt16(truncatingIfNeeded: st.st_mode),
        nlink: UInt16(clamping: st.st_nlink), ino: UInt64(truncatingIfNeeded: st.st_ino),
        uid: guestUID(st.st_uid), gid: guestGID(st.st_gid), rdev: UInt32(truncatingIfNeeded: st.st_rdev),
        atime: a, mtime: m, ctime: c, birthtime: birth, size: Int64(st.st_size), blocks: Int64(st.st_blocks),
        blksize: Int32(truncatingIfNeeded: st.st_blksize), flags: 0, gen: 0)
}
#endif

private func guestUID(_ uid: uid_t) -> UInt32 { uid == geteuid() ? DarwinFileSystem.guestUID : UInt32(uid) }
private func guestGID(_ gid: gid_t) -> UInt32 { gid == getegid() ? DarwinFileSystem.guestGID : UInt32(gid) }

private func hostOpen(_ path: String, _ flags: Int32, _ mode: UInt16) throws -> Int32 {
    let fd = open(path, flags, mode_t(mode))
    guard fd >= 0 else { throw DarwinErrnoError(hostErrno()) }
    return fd
}

private func hostClose(_ fd: Int32) { _ = close(fd) }

private func hostPRead(_ fd: Int32, count: Int, offset: UInt64) throws -> [UInt8] {
    guard offset <= UInt64(Int64.max) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
    guard count > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: count)
    var done = 0
    while done < count {
        let n = buffer.withUnsafeMutableBytes { raw in
            pread(fd, raw.baseAddress! + done, count - done, off_t(offset) + off_t(done))
        }
        if n < 0 {
            if errno == EINTR { continue }
            throw DarwinErrnoError(hostErrno())
        }
        if n == 0 { break }
        done += n
    }
    buffer.removeSubrange(done...)
    return buffer
}

private func hostPWrite(_ fd: Int32, _ bytes: [UInt8], offset: UInt64) throws -> Int {
    guard offset <= UInt64(Int64.max) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
    var done = 0
    while done < bytes.count {
        let n = bytes.withUnsafeBytes { raw in
            pwrite(fd, raw.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done))
        }
        if n < 0 {
            if errno == EINTR { continue }
            throw DarwinErrnoError(hostErrno())
        }
        done += n
    }
    return done
}

private func hostUnlink(_ path: String) throws {
    guard unlink(path) == 0 else { throw DarwinErrnoError(hostErrno()) }
}

private func hostMkdir(_ path: String, _ mode: UInt16) throws {
    guard mkdir(path, mode_t(mode)) == 0 else { throw DarwinErrnoError(hostErrno()) }
    // The host process's own umask must not change the guest's mode.
    _ = chmod(path, mode_t(mode))
}

private func hostRmdir(_ path: String) throws {
    guard rmdir(path) == 0 else { throw DarwinErrnoError(hostErrno()) }
}

private func hostReadLink(_ path: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: 4097)
    let n = readlink(path, &buffer, 4096)
    guard n >= 0 else { throw DarwinErrnoError(hostErrno()) }
    return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

// MARK: - GuestFile

/// An open host file (stage3-contract.md §4). It owns `hostFD` and closes it
/// when the last reference (a descriptor or a mapping) goes away.
public final class GuestFile {
    /// The guest path, with symbolic links resolved (what `F_GETPATH` returns).
    public let guestPath: String
    /// The host path the guest path maps to.
    public let hostPath: String
    public let hostFD: Int32
    /// The size when the file was opened.
    public let size: UInt64
    /// The stat data when the file was opened.
    public let stat: DarwinStat

    /// Takes ownership of `hostFD`.
    public init(guestPath: String, hostPath: String, hostFD: Int32, stat: DarwinStat) {
        self.guestPath = guestPath
        self.hostPath = hostPath
        self.hostFD = hostFD
        self.stat = stat
        self.size = UInt64(max(0, stat.size))
    }

    /// Opens a host file read-only, outside any allowlist (for the VMM's own
    /// use, e.g. loading images). `guestPath` defaults to `hostPath`.
    public static func openReadOnly(hostPath: String, guestPath: String? = nil) throws -> GuestFile {
        let fd = try hostOpen(hostPath, O_RDONLY | O_CLOEXEC, 0)
        do {
            return GuestFile(guestPath: guestPath ?? hostPath, hostPath: hostPath, hostFD: fd, stat: try hostFStat(fd))
        } catch {
            hostClose(fd)
            throw error
        }
    }

    public var isDirectory: Bool { stat.isDirectory }

    /// Reads up to `count` bytes at `offset` (short at end of file).
    public func read(count: Int, offset: UInt64) throws -> [UInt8] {
        guard count >= 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        return try hostPRead(hostFD, count: count, offset: offset)
    }

    deinit { hostClose(hostFD) }
}

// MARK: - Open file descriptions

/// An open file description (stage4b-contract.md §3.5): what the descriptors
/// made by `dup`, `dup2`, inheritance, SCM_RIGHTS, and fileports share — the
/// node, the file offset, and the status flags.
///
/// Reference counting is Swift's own: every holder (a descriptor-table
/// entry in any process, a queued SCM_RIGHTS message, a fileport) keeps a
/// strong reference, and when the last one lets go an object node gets
/// `lastReferenceClosed()` (`processes.md` §4.9, §5.5). A fileport or a
/// message therefore holds the description simply by keeping the
/// `DarwinOpenFile` it got from `openFile(for:)`.
public final class DarwinOpenFile {
    public enum Node {
        /// The console; `stream` (0, 1, 2) is what the console sink is told
        /// for writes, whatever descriptor number the write used.
        case console(stream: Int32)
        case file(GuestFile)
        case object(any DarwinDescriptorObject)
    }

    public let node: Node
    /// The file offset (host files).
    public var offset: UInt64 = 0
    /// Darwin open flags: the access mode, O_APPEND, O_NONBLOCK, O_ASYNC,
    /// O_FSYNC (`F_GETFL`/`F_SETFL`).
    public var statusFlags: Int32
    /// `F_SETNOSIGPIPE`: a write that fails with EPIPE raises no SIGPIPE.
    public var noSigPipe = false
    /// Run when the last reference goes (the kernel's OFD and flock locks
    /// are released there), keyed by who registered them.
    public var lastCloseHandlers: [String: () -> Void] = [:]
    /// `F_SETCONFINED`: the description may not leave its process (a
    /// spawned child does not inherit it; xnu FG_CONFINED). Never cleared.
    public var confinedToProcess = false

    public init(node: Node, statusFlags: Int32) {
        self.node = node
        self.statusFlags = statusFlags
    }

    /// The object of an object node.
    public var object: (any DarwinDescriptorObject)? {
        if case let .object(o) = node { return o }
        return nil
    }

    /// The host file of a file node.
    public var guestFile: GuestFile? {
        if case let .file(f) = node { return f }
        return nil
    }

    public var isReadable: Bool { statusFlags & DarwinOpen.O_ACCMODE != DarwinOpen.O_WRONLY }
    public var isWritable: Bool {
        let m = statusFlags & DarwinOpen.O_ACCMODE
        return m == DarwinOpen.O_WRONLY || m == DarwinOpen.O_RDWR
    }
    public var isNonBlocking: Bool { statusFlags & DarwinOpen.O_NONBLOCK != 0 }

    deinit {
        for handler in lastCloseHandlers.values { handler() }
        if case let .object(o) = node { o.lastReferenceClosed() }
    }
}

// MARK: - Socket files

/// The socket files `bind` creates (stage4b-contract.md §6 item 3). They are
/// virtual nodes of the guest namespace, not host files: `stat` reports
/// `S_IFSOCK`, `open` fails with EOPNOTSUPP, `unlink` removes the name, and
/// the name outlives the socket (a later `connect` gets ECONNREFUSED). A file
/// system and all of its child copies share one namespace, so every process
/// of a device sees the same names. Nothing is created on the host: a run of
/// the VMM starts with no socket files. Directory listings of the host do not
/// show them (`socketNames(inDirectory:)` lists them for a caller that wants
/// to merge them).
final class SocketNamespace {
    final class Node {
        weak var socket: (any DarwinDescriptorObject)?
        var stat: DarwinStat

        init(socket: any DarwinDescriptorObject, stat: DarwinStat) {
            self.socket = socket
            self.stat = stat
        }
    }

    /// The names. Writers hold the kernel lock; path resolution may read
    /// without it (stage 6: file-system I/O outside the global lock), so the
    /// table has its own leaf lock.
    var nodes: [String: Node] {
        get { nodesLock.withLock { storage } }
        set { nodesLock.withLock { storage = newValue } }
    }
    private var storage: [String: Node] = [:]
    private let nodesLock = NSLockLike()
    /// Inode numbers of socket files, in a range no host file system uses in practice.
    var nextInode: UInt64 = 0x7963_0000_0000_0001
}

// MARK: - DarwinFileSystem

/// The guest's view of files (stage3-contract.md §8). Guest paths equal host
/// paths under the allowed prefixes; everything else is ENOENT. Symbolic
/// links below a prefix are resolved here, in the guest namespace, so a link
/// can never lead outside the allowlist.
///
/// Stage 4b (stage4b-contract.md §3.5): the descriptor table maps numbers to
/// shared open file descriptions (`DarwinOpenFile`), so dup'd and inherited
/// descriptors share offset and flags; descriptors may hold kernel objects
/// (pipes, sockets, kqueues). Every call must be made with the kernel lock
/// held (the table is per process, but descriptions are shared).
public final class DarwinFileSystem {
    /// An allowed directory tree: `guestPath` (normalized, absolute) is served
    /// from `hostPath`. Writes are refused with EROFS unless `writable`.
    public struct Prefix: Equatable, Sendable {
        public var guestPath: String
        public var hostPath: String
        public var writable: Bool

        public init(guestPath: String, hostPath: String, writable: Bool) {
            self.guestPath = guestPath
            self.hostPath = hostPath
            self.writable = writable
        }
    }

    /// The uid and gid the guest runs as (`getuid` / `getgid`).
    public static let guestUID: UInt32 = 501
    public static let guestGID: UInt32 = 20
    /// Darwin `MAXPATHLEN` and `NAME_MAX`.
    public static let maxPathLength = 1024
    public static let maxNameLength = 255
    /// Symbolic links followed in one lookup before ELOOP (Darwin `MAXSYMLINKS`).
    public static let maxSymlinks = 32
    /// The largest single `read`/`pread` transfer; larger requests are short.
    public static let maxTransfer = 16 << 20
    /// The path `F_GETPATH` reports for the console descriptors.
    public static let consolePath = "/dev/console"
    /// Darwin `OPEN_MAX`: the largest table `setrlimit(RLIMIT_NOFILE)` may ask for.
    public static let openMax: Int32 = 10240

    private struct Descriptor {
        var file: DarwinOpenFile
        var closeOnExec: Bool
        /// FD_CLOFORK (O_CLOFORK, F_SETFD bit 2). Ycode has no fork; it only
        /// gates F_SETCONFINED (xnu kern_descrip.c).
        var closeOnFork = false
        /// A guarded descriptor (`guarded_open_np` & co., xnu `kern_guarded.c`).
        var guardState: DescriptorGuard? = nil
    }

    /// Told about every guard violation (the operation also fails with
    /// EPERM). The kernel logs it; see `checkGuard`.
    public var guardViolation: ((_ fd: Int32, _ flavor: UInt32, _ guard: UInt64) -> Void)?

    public let prefixes: [Prefix]
    private let console: (Int32, [UInt8]) -> Void
    private var descriptors: [Int32: Descriptor] = [:]
    private let sockets: SocketNamespace
    /// The highest descriptor number plus one (Darwin's default soft limit).
    public var maxDescriptors: Int32 = 256
    /// Serve the device nodes under `/dev` (stage4c-contract.md §4, agent F):
    /// `null`, `zero`, `random`, `urandom`, `console`, `tty`. `/dev` itself is
    /// a read-only directory listing them; it takes precedence over any
    /// prefix. Default: on.
    public var servesDevices = true
    /// Symbolic links of the guest namespace, by normalized absolute path →
    /// target (as `readlink` returns it; a relative target is relative to the
    /// link's directory). They take precedence over prefixes and are
    /// followed by every lookup. Default: none (`--exec` mode). Device mode
    /// sets `DarwinFileSystem.darwinRootSymlinks`.
    public var guestSymlinks: [String: String] = [:] {
        didSet {
            var normalized: [String: String] = [:]
            for (k, v) in guestSymlinks { normalized[Self.normalizeAbsolute(k)] = v }
            if normalized != guestSymlinks { guestSymlinks = normalized }
        }
    }
    /// The root links of a Darwin system: `/var`, `/tmp`, `/etc` → `private/…`.
    public static let darwinRootSymlinks = ["/var": "private/var", "/tmp": "private/tmp", "/etc": "private/etc"]

    /// A stable inode number for a guest symbolic link.
    fileprivate static func guestLinkInode(_ path: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return 0x7965_0000_0000_0000 | (h & 0xFFFF_FFFF)
    }
    /// Told the number of every descriptor this table closes (`close`, the
    /// target of `dup2`, exec, exit), after it is gone. The process layer can
    /// drop per-descriptor state there (kevent registrations, directory
    /// cursors, POSIX record locks); it gets the closed description too.
    public var descriptorClosed: ((Int32, DarwinOpenFile) -> Void)?

    /// Written under the kernel lock; read by path resolution, which may run
    /// without it (stage 6), hence the leaf lock.
    private var cwdStorage: String {
        get { cwdLock.withLock { cwdValue } }
        set { cwdLock.withLock { cwdValue = newValue } }
    }
    private var cwdValue = "/"
    private let cwdLock = NSLockLike()
    /// The current directory (a normalized guest path). Default "/". Setting
    /// it does not check the path; `chdir` does.
    public var cwd: String {
        get { cwdStorage }
        set { cwdStorage = normalize(newValue, cwd: cwdStorage) }
    }

    /// `prefixes` guest paths are normalized; fds 0, 1, and 2 are the
    /// console, and output written to them goes to `console(fd, bytes)`.
    public convenience init(prefixes: [Prefix], console: @escaping (Int32, [UInt8]) -> Void) {
        var normalized: [Prefix] = []
        for var p in prefixes {
            p.guestPath = Self.normalizeAbsolute(p.guestPath)
            while p.hostPath.count > 1 && p.hostPath.hasSuffix("/") { p.hostPath.removeLast() }
            normalized.append(p)
        }
        self.init(normalizedPrefixes: normalized, console: console, sockets: SocketNamespace())
        for fd: Int32 in 0...2 {
            let flags = fd == 0 ? DarwinOpen.O_RDONLY : DarwinOpen.O_WRONLY
            descriptors[fd] = Descriptor(file: DarwinOpenFile(node: .console(stream: fd), statusFlags: flags),
                                         closeOnExec: false)
        }
    }

    private init(normalizedPrefixes: [Prefix], console: @escaping (Int32, [UInt8]) -> Void, sockets: SocketNamespace) {
        self.prefixes = normalizedPrefixes
        self.console = console
        self.sockets = sockets
    }

    // MARK: Paths

    /// Makes `guestPath` absolute (relative to `cwd`) and removes `.`, `..`,
    /// and repeated or trailing `/`. `..` at the root stays at the root.
    public func normalize(_ guestPath: String, cwd: String) -> String {
        if guestPath.hasPrefix("/") { return Self.normalizeAbsolute(guestPath) }
        return Self.normalizeAbsolute(cwd + "/" + guestPath)
    }

    private static func normalizeAbsolute(_ path: String) -> String {
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The prefix that serves a normalized guest path (the longest match) and
    /// the host path for it.
    private func lookupPrefix(_ path: String) -> (prefix: Prefix, host: String)? {
        var best: (prefix: Prefix, host: String)?
        for p in prefixes {
            let rest: Substring
            if p.guestPath == "/" {
                rest = path.dropFirst()
            } else if path == p.guestPath {
                rest = ""
            } else if path.hasPrefix(p.guestPath + "/") {
                rest = path.dropFirst(p.guestPath.count + 1)
            } else {
                continue
            }
            if let b = best, b.prefix.guestPath.count >= p.guestPath.count { continue }
            let host = rest.isEmpty ? p.hostPath : (p.hostPath == "/" ? "/" : p.hostPath + "/") + rest
            best = (p, host)
        }
        return best
    }

    private struct Resolved {
        var guestPath: String
        var hostPath: String
        var prefix: Prefix
        /// The `lstat` of the final component, or nil if it does not exist.
        var stat: DarwinStat?
        /// The final component is a device node (`/dev/…`; `hostPath` is empty).
        var device: DarwinDevice.Kind? = nil
        /// The final component is a guest-namespace symbolic link with this
        /// target (not followed; `hostPath` is empty).
        var guestLink: String? = nil
    }

    /// The read-only pseudo prefix of `/dev` and of guest symbolic links.
    private static let devicePrefix = Prefix(guestPath: "/dev", hostPath: "/dev", writable: false)

    /// The first guest symbolic link on `path` (normalized): the link's
    /// path, its target, and the rest of `path` after it.
    private func firstGuestLink(in path: String) -> (link: String, target: String, rest: String)? {
        guard !guestSymlinks.isEmpty else { return nil }
        let parts = path.split(separator: "/")
        var current = ""
        for (i, part) in parts.enumerated() {
            current += "/" + part
            if let target = guestSymlinks[current] {
                return (current, target, parts[(i + 1)...].joined(separator: "/"))
            }
        }
        return nil
    }

    /// Resolves a normalized path at or below `/dev`.
    private func resolveDevice(_ path: String) throws -> Resolved {
        if path == "/dev" {
            var st = try hostStatCall("/dev", follow: true)
            st.mode = DarwinStat.S_IFDIR | 0o555
            st.uid = 0
            st.gid = 0
            return Resolved(guestPath: "/dev", hostPath: "/dev", prefix: Self.devicePrefix, stat: st)
        }
        let parts = path.dropFirst(5).split(separator: "/")
        let name = parts.first.map(String.init) ?? ""
        let kind = DarwinDevice.Kind(rawValue: name)
        if parts.count > 1 { throw DarwinErrnoError(kind == nil ? DarwinErrnoCode.ENOENT : DarwinErrnoCode.ENOTDIR) }
        guard name.utf8.count <= Self.maxNameLength else { throw DarwinErrnoError(DarwinErrnoCode.ENAMETOOLONG) }
        return Resolved(guestPath: "/dev/" + name, hostPath: "", prefix: Self.devicePrefix,
                        stat: kind.map { DarwinDevice.stat(of: $0) }, device: kind)
    }

    /// Resolves a guest path: normalizes it, checks the allowlist, and
    /// follows symbolic links below the prefix (the last one only when
    /// `followFinal`). A missing final component is not an error (`stat` is
    /// nil); a missing directory component is ENOENT.
    private func resolve(_ path: String, followFinal: Bool) throws -> Resolved {
        guard !path.isEmpty else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        guard path.utf8.count < Self.maxPathLength else { throw DarwinErrnoError(DarwinErrnoCode.ENAMETOOLONG) }
        var current = normalize(path, cwd: cwdStorage)
        var linksFollowed = 0

        restart: while true {
            // Guest-namespace symbolic links (`guestSymlinks`) come first.
            if let (link, target, rest) = firstGuestLink(in: current) {
                if rest.isEmpty && !followFinal {
                    let st = DarwinStat(mode: DarwinStat.S_IFLNK | 0o755, nlink: 1, ino: Self.guestLinkInode(link),
                                        uid: 0, gid: 0, size: Int64(target.utf8.count), blksize: 4096)
                    return Resolved(guestPath: link, hostPath: "", prefix: Self.devicePrefix, stat: st, guestLink: target)
                }
                linksFollowed += 1
                guard linksFollowed <= Self.maxSymlinks else { throw DarwinErrnoError(DarwinErrnoCode.ELOOP) }
                let parent = String(link[..<link.lastIndex(of: "/")!])
                var next = target.hasPrefix("/") ? target : (parent.isEmpty ? "/" : parent) + "/" + target
                if !rest.isEmpty { next += "/" + rest }
                current = Self.normalizeAbsolute(next)
                continue restart
            }
            // Device nodes.
            if servesDevices && (current == "/dev" || current.hasPrefix("/dev/")) {
                return try resolveDevice(current)
            }
            guard let (prefix, _) = lookupPrefix(current) else {
                // "/" and every directory above a served prefix exist as
                // read-only, empty directories of the guest namespace, so
                // lstat walks (realpath) work; nothing else there is reachable.
                if isSyntheticAncestor(current) {
                    let st = DarwinStat(mode: DarwinStat.S_IFDIR | 0o755, nlink: 2, ino: Self.guestLinkInode(current),
                                        uid: 0, gid: 0, size: 64, blksize: 4096)
                    return Resolved(guestPath: current, hostPath: "", prefix: Self.devicePrefix, stat: st)
                }
                throw DarwinErrnoError(DarwinErrnoCode.ENOENT)
            }
            let components = current == prefix.guestPath ? []
                : (prefix.guestPath == "/" ? current.dropFirst() : current.dropFirst(prefix.guestPath.count + 1))
                    .split(separator: "/").map(String.init)
            if components.contains(where: { $0.utf8.count > Self.maxNameLength }) {
                throw DarwinErrnoError(DarwinErrnoCode.ENAMETOOLONG)
            }
            // The prefix directory itself is trusted; walk what is below it.
            var guest = prefix.guestPath
            var host = prefix.hostPath
            var st: DarwinStat? = try hostStatCall(host, follow: true)
            for (i, name) in components.enumerated() {
                let isLast = i == components.count - 1
                guard let parent = st else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
                guard parent.isDirectory else { throw DarwinErrnoError(DarwinErrnoCode.ENOTDIR) }
                guest = guest == "/" ? "/" + name : guest + "/" + name
                host = host == "/" ? "/" + name : host + "/" + name
                do {
                    st = try hostStatCall(host, follow: false)
                } catch let e as DarwinErrnoError where e.errno == DarwinErrnoCode.ENOENT {
                    // A socket file is a node of the guest namespace only.
                    st = sockets.nodes[guest]?.stat
                    continue
                }
                if let s = st, s.isSymbolicLink, !isLast || followFinal {
                    linksFollowed += 1
                    guard linksFollowed <= Self.maxSymlinks else { throw DarwinErrnoError(DarwinErrnoCode.ELOOP) }
                    let target = try hostReadLink(host)
                    let parentGuest = String(guest[..<guest.lastIndex(of: "/")!])
                    let rest = components[(i + 1)...].joined(separator: "/")
                    var next = target.hasPrefix("/") ? target : (parentGuest.isEmpty ? "/" : parentGuest) + "/" + target
                    if !rest.isEmpty { next += "/" + rest }
                    current = Self.normalizeAbsolute(next)
                    continue restart
                }
            }
            return Resolved(guestPath: guest, hostPath: host, prefix: prefix, stat: st)
        }
    }

    /// True for "/" and for each directory strictly above a prefix or a
    /// guest symbolic link (both normalized).
    private func isSyntheticAncestor(_ path: String) -> Bool {
        if path == "/" { return true }
        let below = path + "/"
        if directoryPrefixPaths == nil {
            // Single-file prefixes (the host libraries) make no directories
            // (host-libraries.md §5: other /usr/lib/system paths stay ENOENT).
            directoryPrefixPaths = prefixes.filter { (try? hostStatCall($0.hostPath, follow: true))?.isDirectory ?? false }
                .map(\.guestPath)
        }
        return directoryPrefixPaths!.contains { $0.hasPrefix(below) } || guestSymlinks.keys.contains { $0.hasPrefix(below) }
    }
    private var directoryPrefixPaths: [String]?

    /// The canonical guest path: absolute, normalized, with every symbolic
    /// link resolved inside the allowlist. The path must exist.
    public func realpath(_ path: String) throws -> String {
        let r = try resolve(path, followFinal: true)
        guard r.stat != nil else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        return r.guestPath
    }

    // MARK: Descriptors

    private func entry(_ fd: Int32) throws -> Descriptor {
        guard let d = descriptors[fd] else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        return d
    }

    private func lowestFreeDescriptor(from minimum: Int32 = 0) throws -> Int32 {
        var fd = max(0, minimum)
        while descriptors[fd] != nil { fd += 1 }
        guard fd < maxDescriptors else { throw DarwinErrnoError(DarwinErrnoCode.EMFILE) }
        return fd
    }

    /// How many more descriptors the table can take now.
    public var freeDescriptorCount: Int {
        max(0, Int(maxDescriptors) - descriptors.keys.filter { $0 < maxDescriptors }.count)
    }

    /// Removes `fd` (if open) and tells `descriptorClosed`. The description
    /// is released after the table is consistent again.
    @discardableResult
    private func remove(_ fd: Int32) -> Descriptor? {
        guard let old = descriptors.removeValue(forKey: fd) else { return nil }
        descriptorClosed?(fd, old.file)
        return old
    }

    /// Opens a guest path with Darwin `flags` and returns the new descriptor
    /// (the lowest free number). Writing, creating, or truncating under a
    /// read-only prefix is EROFS; O_CREAT of an existing file there is fine.
    /// A socket file cannot be opened (EOPNOTSUPP). Device nodes open as
    /// devices (`/dev/tty`: ENXIO, no controlling terminal).
    public func open(_ path: String, flags: Int32, mode: UInt16) throws -> Int32 {
        let (file, closeOnExec) = try makeOpenFile(path, flags: flags, mode: mode)
        let fd = try lowestFreeDescriptor()
        descriptors[fd] = Descriptor(file: file, closeOnExec: closeOnExec,
                                     closeOnFork: flags & DarwinOpen.O_CLOFORK != 0)
        return fd
    }

    /// An opened file not yet in the table (`prepareOpen`, then `install`).
    public struct PreparedOpen {
        let file: DarwinOpenFile
        let closeOnExec: Bool
        let closeOnFork: Bool
    }

    /// `open` in two steps (stage 6, `stage6-contract.md` §5.1): the path
    /// resolution and host open touch no descriptor table, so the kernel may
    /// run this step without its lock, then `install` the result with it.
    public func prepareOpen(_ path: String, flags: Int32, mode: UInt16) throws -> PreparedOpen {
        let (file, closeOnExec) = try makeOpenFile(path, flags: flags, mode: mode)
        return PreparedOpen(file: file, closeOnExec: closeOnExec, closeOnFork: flags & DarwinOpen.O_CLOFORK != 0)
    }

    /// Puts a prepared open at the lowest free descriptor.
    public func install(_ prepared: PreparedOpen) throws -> Int32 {
        let fd = try lowestFreeDescriptor()
        descriptors[fd] = Descriptor(file: prepared.file, closeOnExec: prepared.closeOnExec,
                                     closeOnFork: prepared.closeOnFork)
        return fd
    }

    /// Opens a guest path as `open` does and places it at descriptor `fd`
    /// (a descriptor already open there is closed first, as `dup2`). For the
    /// VMM's process start: e.g. `open("/dev/null", flags: O_RDONLY, mode: 0, at: 0)`.
    /// `fd` outside the table is EBADF. Returns `fd`.
    @discardableResult
    public func open(_ path: String, flags: Int32, mode: UInt16, at fd: Int32) throws -> Int32 {
        guard fd >= 0, fd < maxDescriptors else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        let (file, closeOnExec) = try makeOpenFile(path, flags: flags, mode: mode)
        return try install(file, closeOnExec: closeOnExec, at: fd)
    }

    /// Device mode's standard descriptors (stage4c-contract.md §2): fd 0 =
    /// `/dev/null` read-only, fd 1 = `/dev/null` write-only, fd 2 left as it
    /// is (the console), fd 3 = `/dev/console` write-only. None is
    /// close-on-exec.
    public func installDeviceModeStandardDescriptors() throws {
        try open("/dev/null", flags: DarwinOpen.O_RDONLY, mode: 0, at: 0)
        try open("/dev/null", flags: DarwinOpen.O_WRONLY, mode: 0, at: 1)
        try open("/dev/console", flags: DarwinOpen.O_WRONLY, mode: 0, at: 3)
    }

    /// The description `open` makes, and its close-on-exec flag.
    private func makeOpenFile(_ path: String, flags: Int32, mode: UInt16) throws -> (DarwinOpenFile, Bool) {
        let accessMode = flags & DarwinOpen.O_ACCMODE
        guard accessMode != DarwinOpen.O_ACCMODE else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        let wantsWrite = accessMode != DarwinOpen.O_RDONLY
        let create = flags & DarwinOpen.O_CREAT != 0
        let exclusive = create && flags & DarwinOpen.O_EXCL != 0
        let truncate = flags & DarwinOpen.O_TRUNC != 0
        let directory = flags & DarwinOpen.O_DIRECTORY != 0
        let follow = flags & DarwinOpen.O_NOFOLLOW == 0 && !exclusive

        let r = try resolve(path, followFinal: follow)
        let status = flags & (DarwinOpen.O_ACCMODE | DarwinOpen.O_APPEND | DarwinOpen.O_NONBLOCK)
        let closeOnExec = flags & DarwinOpen.O_CLOEXEC != 0
        if let kind = r.device {
            if exclusive { throw DarwinErrnoError(DarwinErrnoCode.EEXIST) }
            if directory { throw DarwinErrnoError(DarwinErrnoCode.ENOTDIR) }
            switch kind {
            case .tty: throw DarwinErrnoError(DarwinErrnoCode.ENXIO)
            case .console: return (DarwinOpenFile(node: .console(stream: 1), statusFlags: status), closeOnExec)
            default: return (DarwinOpenFile(node: .object(DarwinDevice(kind)), statusFlags: status), closeOnExec)
            }
        }
        if let st = r.stat {
            if exclusive { throw DarwinErrnoError(DarwinErrnoCode.EEXIST) }
            if st.isSymbolicLink { throw DarwinErrnoError(DarwinErrnoCode.ELOOP) }
            if directory && !st.isDirectory { throw DarwinErrnoError(DarwinErrnoCode.ENOTDIR) }
            if st.fileType == DarwinStat.S_IFSOCK { throw DarwinErrnoError(DarwinErrnoCode.EOPNOTSUPP) }
            if st.isDirectory && (wantsWrite || truncate) { throw DarwinErrnoError(DarwinErrnoCode.EISDIR) }
            if !r.prefix.writable && (wantsWrite || truncate) { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        } else {
            guard create else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
            guard r.prefix.writable else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
            guard !directory else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        }
        var hostFlags: Int32 = O_CLOEXEC
        switch accessMode {
        case DarwinOpen.O_WRONLY: hostFlags |= O_WRONLY
        case DarwinOpen.O_RDWR: hostFlags |= O_RDWR
        default: hostFlags |= O_RDONLY
        }
        if r.stat == nil { hostFlags |= O_CREAT | O_EXCL }
        if truncate { hostFlags |= O_TRUNC }
        if directory { hostFlags |= O_DIRECTORY }
        // The final component was resolved above; never follow a link the
        // host might find there now.
        hostFlags |= O_NOFOLLOW
        // A synthetic ancestor directory has no host file behind it.
        if r.hostPath.isEmpty { throw DarwinErrnoError(DarwinErrnoCode.EACCES) }
        let hostFD = try hostOpen(r.hostPath, hostFlags, mode & 0o7777)
        let file: GuestFile
        do {
            file = GuestFile(guestPath: r.guestPath, hostPath: r.hostPath, hostFD: hostFD, stat: try hostFStat(hostFD))
        } catch {
            hostClose(hostFD)
            throw error
        }
        return (DarwinOpenFile(node: .file(file), statusFlags: status), closeOnExec)
    }

    /// Closes a descriptor. The description (and a host file, which a mapping
    /// may also hold) lives on while anything else refers to it.
    public func close(_ fd: Int32) throws {
        try checkGuard(fd, DarwinGuard.close, flavor: DarwinGuard.exceptionClose)
        guard remove(fd) != nil else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
    }

    /// Reads at the description's offset and advances it. The console reads
    /// as end of file. Requests above `maxTransfer` bytes are short. Object
    /// descriptors are served by the kernel (EOPNOTSUPP here).
    public func read(_ fd: Int32, count: Int) throws -> [UInt8] {
        let d = try entry(fd)
        guard d.file.isReadable else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        guard count >= 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        switch d.file.node {
        case .console:
            return []
        case let .file(f):
            if f.isDirectory { throw DarwinErrnoError(DarwinErrnoCode.EISDIR) }
            let bytes = try hostPRead(f.hostFD, count: min(count, Self.maxTransfer), offset: d.file.offset)
            d.file.offset += UInt64(bytes.count)
            return bytes
        case let .object(o):
            guard let device = o as? DarwinDevice else { throw DarwinErrnoError(DarwinErrnoCode.EOPNOTSUPP) }
            return device.read(count: min(count, Self.maxTransfer))
        }
    }

    /// Reads at `offset` without moving the description's offset.
    public func pread(_ fd: Int32, count: Int, offset: UInt64) throws -> [UInt8] {
        let d = try entry(fd)
        guard d.file.isReadable else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        guard count >= 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        switch d.file.node {
        case let .object(o as DarwinDevice):
            return o.read(count: min(count, Self.maxTransfer))
        case .console, .object:
            throw DarwinErrnoError(DarwinErrnoCode.ESPIPE)
        case let .file(f):
            if f.isDirectory { throw DarwinErrnoError(DarwinErrnoCode.EISDIR) }
            return try hostPRead(f.hostFD, count: min(count, Self.maxTransfer), offset: offset)
        }
    }

    /// Writes at the description's offset (at the end with O_APPEND) and
    /// advances it. Console output goes to the console sink.
    public func write(_ fd: Int32, _ bytes: [UInt8]) throws -> Int {
        try write(fd, bytes, guardChecked: false)
    }

    /// `write`; with `guardChecked` (guarded_write_np matched the guard)
    /// a GUARD_WRITE descriptor may be written.
    public func write(_ fd: Int32, _ bytes: [UInt8], guardChecked: Bool) throws -> Int {
        if !guardChecked { try checkGuard(fd, DarwinGuard.write, flavor: DarwinGuard.exceptionWrite) }
        let d = try entry(fd)
        switch d.file.node {
        case let .console(stream):
            console(stream, bytes)
            return bytes.count
        case let .file(f):
            guard d.file.isWritable else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
            if d.file.statusFlags & DarwinOpen.O_APPEND != 0 {
                d.file.offset = UInt64(max(0, try hostFStat(f.hostFD).size))
            }
            let n = try hostPWrite(f.hostFD, bytes, offset: d.file.offset)
            d.file.offset += UInt64(n)
            return n
        case let .object(o):
            guard let device = o as? DarwinDevice else { throw DarwinErrnoError(DarwinErrnoCode.EOPNOTSUPP) }
            guard d.file.isWritable else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
            return device.write(bytes)
        }
    }

    /// Writes at `offset` without moving the description's offset (`pwrite`).
    public func pwrite(_ fd: Int32, _ bytes: [UInt8], offset: UInt64) throws -> Int {
        try pwrite(fd, bytes, offset: offset, guardChecked: false)
    }

    /// `pwrite`; `guardChecked` as for `write`.
    public func pwrite(_ fd: Int32, _ bytes: [UInt8], offset: UInt64, guardChecked: Bool) throws -> Int {
        if !guardChecked { try checkGuard(fd, DarwinGuard.write, flavor: DarwinGuard.exceptionWrite) }
        let d = try entry(fd)
        guard d.file.isWritable else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        switch d.file.node {
        case let .object(o as DarwinDevice):
            return o.write(bytes)
        case .console, .object:
            throw DarwinErrnoError(DarwinErrnoCode.ESPIPE)
        case let .file(f):
            return try hostPWrite(f.hostFD, bytes, offset: offset)
        }
    }

    /// `lseek`: `whence` 0 (SET), 1 (CUR), 2 (END). The console, pipes, and
    /// sockets are ESPIPE; a negative result is EINVAL.
    public func lseek(_ fd: Int32, offset: Int64, whence: Int32) throws -> UInt64 {
        let d = try entry(fd)
        let f: GuestFile?
        switch d.file.node {
        case let .file(file): f = file
        case .object(is DarwinDevice): f = nil  // character devices seek freely (size 0)
        default: throw DarwinErrnoError(DarwinErrnoCode.ESPIPE)
        }
        let base: Int64
        switch whence {
        case 0: base = 0
        case 1: base = Int64(clamping: d.file.offset)
        case 2: base = try f.map { try hostFStat($0.hostFD).size } ?? 0
        default: throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow else { throw DarwinErrnoError(DarwinErrnoCode.EOVERFLOW) }
        guard target >= 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        d.file.offset = UInt64(target)
        return UInt64(target)
    }

    /// `stat` (following a final symbolic link) or `lstat`. Socket files
    /// report `S_IFSOCK`.
    public func stat(_ path: String, followSymlinks: Bool) throws -> DarwinStat {
        let r = try resolve(path, followFinal: followSymlinks)
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        return st
    }

    /// Current stat data of an open descriptor.
    public func fstat(_ fd: Int32) throws -> DarwinStat {
        switch try entry(fd).file.node {
        case .console:
            return DarwinStat(mode: DarwinStat.S_IFCHR | 0o620, nlink: 1, uid: Self.guestUID, gid: 4,
                              blksize: 131_072)
        case let .file(f):
            return try hostFStat(f.hostFD)
        case let .object(o):
            return o.descriptorStat()
        }
    }

    /// The open file behind a descriptor (for `mmap`). The console and
    /// objects are ENODEV.
    public func file(for fd: Int32) throws -> GuestFile {
        switch try entry(fd).file.node {
        case .console, .object: throw DarwinErrnoError(DarwinErrnoCode.ENODEV)
        case let .file(f): return f
        }
    }

    /// The descriptor's resolved guest path (`F_GETPATH`). Objects have no
    /// path (EBADF, as xnu answers F_GETPATH for a non-vnode).
    public func path(for fd: Int32) throws -> String {
        switch try entry(fd).file.node {
        case .console: return Self.consolePath
        case let .file(f): return f.guestPath
        case let .object(o as DarwinDevice): return o.path
        case .object: throw DarwinErrnoError(DarwinErrnoCode.EBADF)
        }
    }

    /// Sets or clears FD_CLOEXEC (`F_SETFD`).
    public func setCloseOnExec(_ fd: Int32, _ on: Bool) throws {
        var d = try entry(fd)
        // A guarded descriptor stays close-on-exec (kGUARD_EXC_NOCLOEXEC).
        if let g = d.guardState, !on {
            guardViolation?(fd, DarwinGuard.exceptionNoCloexec, g.value)
            throw DarwinErrnoError(DarwinErrnoCode.EPERM)
        }
        d.closeOnExec = on
        descriptors[fd] = d
    }

    /// FD_CLOEXEC (`F_GETFD`).
    public func closeOnExec(_ fd: Int32) throws -> Bool { try entry(fd).closeOnExec }

    /// FD_CLOFORK (`F_GETFD` bit 2).
    public func closeOnFork(_ fd: Int32) throws -> Bool { try entry(fd).closeOnFork }

    /// Sets or clears FD_CLOFORK (`F_SETFD` bit 2).
    public func setCloseOnFork(_ fd: Int32, _ on: Bool) throws {
        _ = try entry(fd)
        descriptors[fd]?.closeOnFork = on
    }

    /// `F_SETCONFINED` (xnu kern_descrip.c, level 1): `on == false` is EPERM
    /// (confinement is permanent); an already confined description succeeds;
    /// a description another descriptor shares is EAGAIN (Ycode sees only
    /// this table's references); a descriptor without FD_CLOFORK is EBADF.
    public func setConfined(_ fd: Int32, _ on: Bool) throws {
        let d = try entry(fd)
        guard on else { throw DarwinErrnoError(DarwinErrnoCode.EPERM) }
        if d.file.confinedToProcess { return }
        guard descriptors.values.filter({ $0.file === d.file }).count == 1 else {
            throw DarwinErrnoError(DarwinErrnoCode.EAGAIN)
        }
        guard d.closeOnFork else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        d.file.confinedToProcess = true
    }

    /// The Darwin status flags (`F_GETFL`): access mode, O_APPEND, O_NONBLOCK.
    public func statusFlags(_ fd: Int32) throws -> Int32 { try entry(fd).file.statusFlags }

    /// The flags `F_SETFL` may change (Darwin `FCNTLFLAGS` minus the
    /// synchronous-I/O bits Ycode ignores): O_APPEND, O_NONBLOCK, O_ASYNC, O_FSYNC.
    public static let settableStatusFlags = DarwinOpen.O_APPEND | DarwinOpen.O_NONBLOCK | DarwinOpen.O_ASYNC
        | DarwinOpen.O_FSYNC

    /// `F_SETFL`: replaces the settable flags of the description (shared by
    /// every dup of it); the access mode is kept.
    public func setStatusFlags(_ fd: Int32, _ flags: Int32) throws {
        let file = try entry(fd).file
        file.statusFlags = (file.statusFlags & ~Self.settableStatusFlags) | (flags & Self.settableStatusFlags)
    }

    /// The open descriptor numbers, ascending.
    public var openDescriptors: [Int32] { descriptors.keys.sorted() }
}

// MARK: - Stage 4b API (stage4b-contract.md §3.5)

extension DarwinFileSystem {
    /// Installs a new description holding `object` at the lowest free number.
    public func installObject(_ object: DarwinDescriptorObject, statusFlags: Int32, closeOnExec: Bool) throws -> Int32 {
        try install(DarwinOpenFile(node: .object(object), statusFlags: statusFlags), closeOnExec: closeOnExec)
    }

    /// The object behind `fd`; nil for host files and the console. EBADF if
    /// `fd` is not open.
    public func object(for fd: Int32) throws -> DarwinDescriptorObject? {
        try entry(fd).file.object
    }

    /// The open file description behind `fd` (fileports, SCM_RIGHTS). The
    /// caller keeps it alive simply by holding it.
    public func openFile(for fd: Int32) throws -> DarwinOpenFile {
        try entry(fd).file
    }

    /// Adds a descriptor for `file`: at the lowest free number, or at `fd`
    /// (dup2-style: a descriptor already open there is closed first; `fd`
    /// outside the table is EBADF). Returns the number.
    @discardableResult
    public func install(_ file: DarwinOpenFile, closeOnExec: Bool, at fd: Int32? = nil) throws -> Int32 {
        if let fd {
            guard fd >= 0, fd < maxDescriptors else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
            if descriptors[fd] != nil { try checkGuard(fd, DarwinGuard.close, flavor: DarwinGuard.exceptionClose) }
            let old = descriptors[fd]
            descriptors[fd] = Descriptor(file: file, closeOnExec: closeOnExec)
            if let old { descriptorClosed?(fd, old.file) }
            return fd
        }
        let n = try lowestFreeDescriptor()
        descriptors[n] = Descriptor(file: file, closeOnExec: closeOnExec)
        return n
    }

    /// `dup` / `F_DUPFD`: a new descriptor (the lowest free number ≥
    /// `minimum`) sharing `fd`'s description, close-on-exec clear. EBADF if
    /// `fd` is not open, EINVAL if `minimum` is outside the table, EMFILE if
    /// the table is full.
    public func dup(_ fd: Int32, minimum: Int32 = 0) throws -> Int32 {
        try dup(fd, minimum: minimum, closeOnExec: false)
    }

    /// `F_DUPFD_CLOEXEC` when `closeOnExec`.
    public func dup(_ fd: Int32, minimum: Int32, closeOnExec: Bool) throws -> Int32 {
        let d = try entry(fd)
        try checkGuard(fd, DarwinGuard.dup, flavor: DarwinGuard.exceptionDup)
        guard minimum >= 0, minimum < maxDescriptors else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        let n = try lowestFreeDescriptor(from: minimum)
        descriptors[n] = Descriptor(file: d.file, closeOnExec: closeOnExec)
        return n
    }

    /// `dup2`: `to` shares `from`'s description, close-on-exec clear; a
    /// descriptor open at `to` is closed first. `from == to` only checks that
    /// it is open. EBADF for a closed `from` or a `to` outside the table.
    public func dup2(_ from: Int32, _ to: Int32) throws {
        let d = try entry(from)
        try checkGuard(from, DarwinGuard.dup, flavor: DarwinGuard.exceptionDup)
        guard to >= 0, to < maxDescriptors else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        if from == to { return }
        try install(d.file, closeOnExec: false, at: to)
    }

    /// A spawned child's file system (`processes.md` §1.11): the same
    /// prefixes, console sink, cwd, socket files, and limit; every descriptor
    /// shares its description and keeps its close-on-exec flag, except
    /// confined objects (kqueues), which are not inherited.
    /// `newProcess` (posix_spawn, not an exec in place): confined
    /// descriptions (`F_SETCONFINED`) stay behind (xnu fdt_fork).
    public func makeChildCopy(newProcess: Bool = true) -> DarwinFileSystem {
        let child = DarwinFileSystem(normalizedPrefixes: prefixes, console: console, sockets: sockets)
        child.cwdStorage = cwdStorage
        child.maxDescriptors = maxDescriptors
        child.servesDevices = servesDevices
        child.guestSymlinks = guestSymlinks
        for (fd, d) in descriptors where !(d.file.object?.isConfined ?? false)
            && !(newProcess && d.file.confinedToProcess) {
            child.descriptors[fd] = d
        }
        return child
    }

    /// Exec (`processes.md` §1.7 rule 3, §1.11): closes every close-on-exec
    /// descriptor; with `keepOnly` (POSIX_SPAWN_CLOEXEC_DEFAULT) also every
    /// descriptor not in the set.
    public func closeOnExecDescriptors(keepOnly: Set<Int32>? = nil) {
        let doomed = descriptors.filter { fd, d in d.closeOnExec || !(keepOnly?.contains(fd) ?? true) }.keys.sorted()
        var released: [Descriptor] = []
        for fd in doomed { if let d = remove(fd) { released.append(d) } }
        released.removeAll()
    }

    /// Process exit: closes every descriptor.
    public func closeAll() {
        var released: [Descriptor] = []
        for fd in descriptors.keys.sorted() { if let d = remove(fd) { released.append(d) } }
        released.removeAll()
    }

    /// `chdir`: the path must name a directory (ENOENT, ENOTDIR); symbolic
    /// links are resolved, so the new cwd is canonical.
    public func chdir(_ path: String) throws {
        let r = try resolve(path, followFinal: true)
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        guard st.isDirectory else { throw DarwinErrnoError(DarwinErrnoCode.ENOTDIR) }
        cwdStorage = r.guestPath
    }

    /// `fchdir`: the descriptor must be an open directory (EBADF, ENOTDIR).
    public func fchdir(_ fd: Int32) throws {
        guard case let .file(f) = try entry(fd).file.node, f.isDirectory else {
            throw DarwinErrnoError(DarwinErrnoCode.ENOTDIR)
        }
        cwdStorage = f.guestPath
    }

    /// Resolves an executable for spawn/exec: cwd-relative, every symbolic
    /// link followed. ENOENT if missing, EACCES if it is not a regular file
    /// (a directory, a socket file).
    public func hostPathForExec(_ path: String) throws -> (guestPath: String, hostPath: String) {
        let r = try resolve(path, followFinal: true)
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        guard st.isRegularFile, sockets.nodes[r.guestPath] == nil else {
            throw DarwinErrnoError(DarwinErrnoCode.EACCES)
        }
        return (r.guestPath, r.hostPath)
    }

    /// `unlink`: removes a socket file's name, or a host file under a
    /// writable prefix (EROFS otherwise). A directory is EPERM; a missing
    /// path ENOENT. A final symbolic link is removed, not followed.
    public func unlink(_ path: String) throws {
        let r = try resolve(path, followFinal: false)
        if sockets.nodes.removeValue(forKey: r.guestPath) != nil { return }
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        if st.isDirectory { throw DarwinErrnoError(DarwinErrnoCode.EPERM) }
        guard r.prefix.writable else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        try hostUnlink(r.hostPath)
    }

    /// `mkdir`: creates a directory with `mode & ~umask & 0o7777`. Any
    /// existing name (file, directory, symbolic link, device, socket file)
    /// is EEXIST; a missing parent ENOENT; a read-only prefix (and `/dev`)
    /// EROFS. A final symbolic link is not followed.
    public func mkdir(_ path: String, mode: UInt16, umask: UInt16) throws {
        let r = try resolve(path, followFinal: false)
        guard r.stat == nil else { throw DarwinErrnoError(DarwinErrnoCode.EEXIST) }
        guard r.prefix.writable, !r.hostPath.isEmpty else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        try hostMkdir(r.hostPath, mode & ~umask & 0o7777)
    }

    /// `rmdir`: removes an empty directory. Missing: ENOENT; not a directory
    /// (a symbolic link included): ENOTDIR; the root of a prefix or `/dev`:
    /// EBUSY; a read-only prefix: EROFS; not empty (socket files count):
    /// ENOTEMPTY.
    public func rmdir(_ path: String) throws {
        let r = try resolve(path, followFinal: false)
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        guard st.isDirectory else { throw DarwinErrnoError(DarwinErrnoCode.ENOTDIR) }
        if r.guestPath == r.prefix.guestPath || prefixes.contains(where: { $0.guestPath == r.guestPath }) {
            throw DarwinErrnoError(DarwinErrnoCode.EBUSY)
        }
        guard r.prefix.writable else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        if !socketNames(inDirectory: r.guestPath).isEmpty { throw DarwinErrnoError(DarwinErrnoCode.ENOTEMPTY) }
        try hostRmdir(r.hostPath)
    }

    /// `readlink`: the target of a symbolic link (a guest-namespace link or
    /// a host link below a prefix), as stored. Not a link: EINVAL.
    public func readlink(_ path: String) throws -> String {
        let r = try resolve(path, followFinal: false)
        if let target = r.guestLink { return target }
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        guard st.isSymbolicLink else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        return try hostReadLink(r.hostPath)
    }

    // MARK: Socket files

    /// `bind` of an AF_UNIX socket (`processes.md` §5.3): creates the socket
    /// file at `path` (final symbolic links are not followed) with
    /// `0777 & ~umask` and returns its canonical guest path. An existing name
    /// is EADDRINUSE; a missing directory ENOENT; a read-only prefix EROFS.
    public func bindSocket(_ socket: DarwinDescriptorObject, path: String, umask: UInt16) throws -> String {
        let r = try resolve(path, followFinal: false)
        guard r.stat == nil else { throw DarwinErrnoError(DarwinErrnoCode.EADDRINUSE) }
        guard r.prefix.writable else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        let parentHost = r.hostPath.lastIndex(of: "/").map { String(r.hostPath[..<$0]) } ?? "/"
        let parent = try? hostStatCall(parentHost.isEmpty ? "/" : parentHost, follow: true)
        let now = Self.now()
        let st = DarwinStat(dev: parent?.dev ?? 0, mode: DarwinStat.S_IFSOCK | (0o777 & ~umask), nlink: 1,
                            ino: sockets.nextInode, uid: Self.guestUID, gid: Self.guestGID, atime: now, mtime: now,
                            ctime: now, birthtime: now, size: 0, blocks: 0, blksize: 4096)
        sockets.nextInode += 1
        sockets.nodes[r.guestPath] = SocketNamespace.Node(socket: socket, stat: st)
        return r.guestPath
    }

    /// What a `connect` (or a datagram `sendto`) to `path` reaches.
    public enum SocketPathTarget {
        /// A socket file whose socket is still open.
        case socket(DarwinDescriptorObject)
        /// A socket file whose socket was closed (ECONNREFUSED), or a socket
        /// node of the host.
        case noSocket
    }

    /// Looks `path` up for `connect` (symbolic links followed). A missing
    /// path is ENOENT (or the lookup error); a file that is not a socket is
    /// ENOTSOCK (xnu `unp_connect`).
    public func socketTarget(_ path: String) throws -> SocketPathTarget {
        let r = try resolve(path, followFinal: true)
        if let node = sockets.nodes[r.guestPath] {
            if let s = node.socket { return .socket(s) }
            return .noSocket
        }
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        guard st.fileType == DarwinStat.S_IFSOCK else { throw DarwinErrnoError(DarwinErrnoCode.ENOTSOCK) }
        return .noSocket
    }

    /// The socket files directly inside the directory `guestPath`
    /// (normalized), with their stat data, by name.
    public func socketNames(inDirectory guestPath: String) -> [(name: String, stat: DarwinStat)] {
        let dir = normalize(guestPath, cwd: cwdStorage)
        let start = dir == "/" ? "/" : dir + "/"
        return sockets.nodes.compactMap { path, node in
            guard path.hasPrefix(start) else { return nil }
            let name = String(path.dropFirst(start.count))
            return name.contains("/") ? nil : (name, node.stat)
        }.sorted { $0.name < $1.name }
    }

    private static func now() -> DarwinTimespec {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return DarwinTimespec(sec: Int64(ts.tv_sec), nsec: Int64(ts.tv_nsec))
    }
}

// MARK: - Device nodes

/// A character device under `/dev` (stage4c-contract.md §4, agent F): the
/// descriptor object behind an open `/dev/null`, `/dev/zero`,
/// `/dev/random`, or `/dev/urandom`. (`/dev/console` opens as the console
/// node; `/dev/tty` cannot be opened: ENXIO, no controlling terminal.)
/// Reads and writes never block.
public final class DarwinDevice: DarwinDescriptorObject {
    public enum Kind: String, CaseIterable, Sendable {
        case null, zero, random, urandom, console, tty
    }

    public let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    /// The guest path (`F_GETPATH`).
    public var path: String { "/dev/" + kind.rawValue }

    public var fileType: UInt16 { DarwinStat.S_IFCHR }

    public func lastReferenceClosed() {}

    public func descriptorStat() -> DarwinStat { Self.stat(of: kind) }

    /// Random bytes for `/dev/random` and `/dev/urandom` (default: the
    /// host's generator, `SystemRandomNumberGenerator`).
    nonisolated(unsafe) public static var entropy: (Int) -> [UInt8] = { count in
        var rng = SystemRandomNumberGenerator()
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            var v = rng.next()
            for _ in 0..<8 where out.count < count {
                out.append(UInt8(truncatingIfNeeded: v))
                v >>= 8
            }
        }
        return out
    }

    /// `null`: end of file; `zero`: zeros; `random`/`urandom`: entropy.
    public func read(count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        switch kind {
        case .zero: return [UInt8](repeating: 0, count: count)
        case .random, .urandom: return Self.entropy(count)
        default: return []
        }
    }

    /// Every device takes all bytes and discards them.
    public func write(_ bytes: [UInt8]) -> Int { bytes.count }

    /// The device file system's `st_dev`.
    public static let deviceFileSystemID: UInt32 = 0x0300_0000 | 0x7963
    /// When the nodes appear to have been made.
    private static let created: DarwinTimespec = {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return DarwinTimespec(sec: Int64(ts.tv_sec), nsec: 0)
    }()

    /// `stat` of a device node: `S_IFCHR`, Darwin's device numbers
    /// (`makedev(major, minor)` = major << 24 | minor): null 3/2, zero 3/3,
    /// random 14/0, urandom 14/1, console 0/0, tty 2/0; mode 0666 owned by
    /// root, except the console (0600, the guest user).
    public static func stat(of kind: Kind) -> DarwinStat {
        let index = UInt64(Kind.allCases.firstIndex(of: kind)!)
        let rdev: UInt32
        switch kind {
        case .null: rdev = 0x0300_0002
        case .zero: rdev = 0x0300_0003
        case .random: rdev = 0x0E00_0000
        case .urandom: rdev = 0x0E00_0001
        case .console: rdev = 0
        case .tty: rdev = 0x0200_0000
        }
        let console = kind == .console
        return DarwinStat(dev: deviceFileSystemID, mode: DarwinStat.S_IFCHR | (console ? 0o600 : 0o666), nlink: 1,
                          ino: 300 + index, uid: console ? DarwinFileSystem.guestUID : 0, gid: 0, rdev: rdev,
                          atime: created, mtime: created, ctime: created, birthtime: created, size: 0, blocks: 0,
                          blksize: 131_072)
    }
}

// MARK: - Guarded descriptors

/// A descriptor's guard: a nonzero 64-bit value and the GUARD_* flags.
public struct DescriptorGuard: Equatable, Sendable {
    public var value: UInt64
    public var flags: UInt32

    public init(value: UInt64, flags: UInt32) {
        self.value = value
        self.flags = flags
    }
}

/// Guarded-descriptor values (xnu `sys/guarded.h`, `kern_guarded.c`).
public enum DarwinGuard {
    public static let close: UInt32 = 1 << 0
    public static let dup: UInt32 = 1 << 1
    public static let socketIPC: UInt32 = 1 << 2
    public static let fileport: UInt32 = 1 << 3
    public static let write: UInt32 = 1 << 4
    /// Every guard must include GUARD_DUP; no other bits are allowed.
    public static let required: UInt32 = dup
    public static let all: UInt32 = close | dup | socketIPC | fileport | write
    // EXC_GUARD flavors for file descriptors (kGUARD_EXC_*).
    public static let exceptionClose: UInt32 = 1, exceptionDup: UInt32 = 2, exceptionNoCloexec: UInt32 = 4,
                      exceptionSocketIPC: UInt32 = 8, exceptionFileport: UInt32 = 16, exceptionMismatch: UInt32 = 32,
                      exceptionWrite: UInt32 = 64

    /// Guard flags a new guard may have: GUARD_DUP plus any of the others.
    public static func isValid(_ flags: UInt32) -> Bool { flags & required == required && flags & ~all == 0 }
}

extension DarwinFileSystem {
    /// The guard of `fd` (nil when unguarded). EBADF if not open.
    public func guardState(of fd: Int32) throws -> DescriptorGuard? { try entry(fd).guardState }

    /// Fails with EPERM when `fd` is guarded with all of `flags` (an
    /// operation the guard forbids). On Darwin this also raises a fatal
    /// EXC_GUARD exception that ends the process; Ycode only reports it to
    /// `guardViolation` (the kernel logs it) and returns EPERM, so a guest
    /// that trips a guard keeps running. A closed `fd` passes (the caller
    /// reports EBADF).
    public func checkGuard(_ fd: Int32, _ flags: UInt32, flavor: UInt32) throws {
        guard let g = descriptors[fd]?.guardState, g.flags & flags == flags else { return }
        guardViolation?(fd, flavor, g.value)
        throw DarwinErrnoError(DarwinErrnoCode.EPERM)
    }

    /// `guarded_open_np`: `open` with a guard. `flags` must include
    /// O_CLOEXEC, `guardFlags` must be valid and `guard` nonzero (EINVAL).
    /// The descriptor is close-on-exec. `mode` is used as given (the
    /// caller applies the umask).
    public func openGuarded(_ path: String, flags: Int32, mode: UInt16, guard value: UInt64,
                            guardFlags: UInt32) throws -> Int32 {
        guard flags & DarwinOpen.O_CLOEXEC != 0, DarwinGuard.isValid(guardFlags), value != 0 else {
            throw DarwinErrnoError(DarwinErrnoCode.EINVAL)
        }
        let fd = try open(path, flags: flags, mode: mode)
        descriptors[fd]?.guardState = DescriptorGuard(value: value, flags: guardFlags)
        descriptors[fd]?.closeOnExec = true
        return fd
    }

    /// Puts a guard on a new descriptor (`guarded_kqueue_np`): close-on-exec.
    public func setGuard(_ fd: Int32, _ g: DescriptorGuard) throws {
        guard DarwinGuard.isValid(g.flags), g.value != 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        _ = try entry(fd)
        descriptors[fd]?.guardState = g
        descriptors[fd]?.closeOnExec = true
    }

    /// `guarded_close_np`: closes a guarded descriptor whose guard value is
    /// `value`. Unguarded: EINVAL; another value: EPERM (no exception).
    public func guardedClose(_ fd: Int32, guard value: UInt64) throws {
        guard let g = try entry(fd).guardState else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        guard g.value == value else { throw DarwinErrnoError(DarwinErrnoCode.EPERM) }
        remove(fd)
    }

    /// Checks `guard value` for a guarded write (`guarded_write_np` & co.).
    /// Unguarded: EINVAL; another value: EPERM.
    public func checkGuardValue(_ fd: Int32, _ value: UInt64) throws {
        guard let g = try entry(fd).guardState else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        guard g.value == value else { throw DarwinErrnoError(DarwinErrnoCode.EPERM) }
    }

    /// `change_fdguard_np` (xnu semantics). `old`/`new` are nil when the
    /// guest passed NULL for that guard pointer (`oldFlags`/`newFlags` are
    /// the flag arguments as given). `fdFlags` is the value at `fdflagsp`
    /// (0 if NULL): FD_CLOEXEC (1) restores close-on-exec when a guard is
    /// removed. Adding a guard makes the descriptor close-on-exec.
    public func changeGuard(_ fd: Int32, old: UInt64?, oldFlags: UInt32, new: UInt64?, newFlags: UInt32,
                            fdFlags: Int32) throws {
        let d = try entry(fd)
        if let g = d.guardState {
            guard old != nil, oldFlags != 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
            guard old != 0 else { throw DarwinErrnoError(DarwinErrnoCode.EPERM) }
            if let new {
                guard new != 0, DarwinGuard.isValid(newFlags) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
                guard old == g.value, oldFlags == g.flags else { throw DarwinErrnoError(DarwinErrnoCode.EPERM) }
                descriptors[fd]?.guardState = DescriptorGuard(value: new, flags: newFlags)
            } else {
                guard newFlags == 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
                guard old == g.value, oldFlags == g.flags else { throw DarwinErrnoError(DarwinErrnoCode.EPERM) }
                descriptors[fd]?.guardState = nil
                descriptors[fd]?.closeOnExec = fdFlags & 1 != 0
            }
        } else {
            guard old == nil, oldFlags == 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
            guard let new else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
            guard new != 0, DarwinGuard.isValid(newFlags) else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
            descriptors[fd]?.guardState = DescriptorGuard(value: new, flags: newFlags)
            descriptors[fd]?.closeOnExec = true
        }
    }
}

// MARK: - Renames, modes, owners, times (stage 6)

extension DarwinFileSystem {
    /// `renameatx_np` flags (sys/stdio.h).
    public static let renameSwap: UInt32 = 0x2, renameExclusive: UInt32 = 0x4

    /// rename / renameat / renameatx_np: both names on writable prefixes
    /// (EROFS), the source must exist (ENOENT), RENAME_EXCL refuses an
    /// existing target (EEXIST), RENAME_SWAP exchanges two existing names.
    /// Other rules (a directory over a file, a non-empty target directory,
    /// across file systems → EXDEV) are the host's, which match POSIX.
    /// Socket files move with their name.
    public func rename(_ from: String, to: String, flags: UInt32 = 0) throws {
        guard flags & ~(Self.renameSwap | Self.renameExclusive) == 0,
              flags != Self.renameSwap | Self.renameExclusive else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        let a = try resolve(from, followFinal: false), b = try resolve(to, followFinal: false)
        if a.device != nil || b.device != nil { throw DarwinErrnoError(18) }  // EXDEV
        if let node = sockets.nodes[a.guestPath] {
            if flags & Self.renameExclusive != 0, b.stat != nil || sockets.nodes[b.guestPath] != nil {
                throw DarwinErrnoError(DarwinErrnoCode.EEXIST)
            }
            sockets.nodes[a.guestPath] = nil
            sockets.nodes[b.guestPath] = node
            return
        }
        guard a.stat != nil else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        guard a.prefix.writable, b.prefix.writable, !a.hostPath.isEmpty, !b.hostPath.isEmpty else {
            throw DarwinErrnoError(DarwinErrnoCode.EROFS)
        }
        if flags & Self.renameExclusive != 0, b.stat != nil { throw DarwinErrnoError(DarwinErrnoCode.EEXIST) }
        if flags & Self.renameSwap != 0 {
            guard b.stat != nil else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
            let temporary = a.hostPath + ".ycode-swap-\(UInt32.random(in: 0...UInt32.max))"
            try hostRename(a.hostPath, temporary)
            do { try hostRename(b.hostPath, a.hostPath) } catch { try? hostRename(temporary, a.hostPath); throw error }
            try hostRename(temporary, b.hostPath)
            return
        }
        try hostRename(a.hostPath, b.hostPath)
    }

    /// chmod / lchmod / fchmodat: the permission bits of a host file.
    public func chmod(_ path: String, mode: UInt16, followSymlinks: Bool) throws {
        let r = try resolve(path, followFinal: followSymlinks)
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        guard r.prefix.writable, !r.hostPath.isEmpty else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        if st.isSymbolicLink { return }  // the host keeps link modes fixed; Darwin's lchmod is accepted
        guard hostChmod(r.hostPath, mode & 0o7777) == 0 else { throw DarwinErrnoError(hostErrno()) }
    }

    /// fchmod.
    public func fchmod(_ fd: Int32, mode: UInt16) throws {
        guard case let .file(f) = try entry(fd).file.node else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        guard writable(guestPath: f.guestPath) else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        guard hostFchmod(f.hostFD, mode & 0o7777) == 0 else { throw DarwinErrnoError(hostErrno()) }
    }

    /// chown / lchown / fchownat / fchown. Every guest file belongs to the
    /// guest user, which may not give it away: the owner stays (uid −1 or
    /// the current owner) and the group may become −1, the current group,
    /// or the guest's group; anything else is EPERM. Nothing changes on the
    /// host.
    public func chown(_ path: String, uid: UInt32, gid: UInt32, followSymlinks: Bool) throws {
        let r = try resolve(path, followFinal: followSymlinks)
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        try checkOwnerChange(st, uid: uid, gid: gid)
        guard r.prefix.writable else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
    }

    public func fchown(_ fd: Int32, uid: UInt32, gid: UInt32) throws {
        let st = try fstat(fd)
        try checkOwnerChange(st, uid: uid, gid: gid)
    }

    private func checkOwnerChange(_ st: DarwinStat, uid: UInt32, gid: UInt32) throws {
        let keep = UInt32.max
        guard uid == keep || uid == st.uid else { throw DarwinErrnoError(DarwinErrnoCode.EPERM) }
        guard gid == keep || gid == st.gid || gid == Self.guestGID else { throw DarwinErrnoError(DarwinErrnoCode.EPERM) }
    }

    /// utimes / lutimes / futimes / setattrlist times: access and
    /// modification times (nil = now).
    public func setTimes(_ path: String, access: DarwinTimespec?, modification: DarwinTimespec?, followSymlinks: Bool) throws {
        let r = try resolve(path, followFinal: followSymlinks)
        guard r.stat != nil else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        guard r.prefix.writable, !r.hostPath.isEmpty else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        guard hostSetTimes(path: r.hostPath, fd: nil, access, modification, follow: followSymlinks) == 0 else {
            throw DarwinErrnoError(hostErrno())
        }
    }

    public func setTimes(_ fd: Int32, access: DarwinTimespec?, modification: DarwinTimespec?) throws {
        guard case let .file(f) = try entry(fd).file.node else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        guard writable(guestPath: f.guestPath) else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        guard hostSetTimes(path: nil, fd: f.hostFD, access, modification, follow: true) == 0 else {
            throw DarwinErrnoError(hostErrno())
        }
    }

    /// truncate(2) by path.
    public func truncate(_ path: String, length: Int64) throws {
        guard length >= 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        let r = try resolve(path, followFinal: true)
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        if st.isDirectory { throw DarwinErrnoError(DarwinErrnoCode.EISDIR) }
        guard r.prefix.writable, !r.hostPath.isEmpty else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        guard hostTruncate(r.hostPath, length) == 0 else { throw DarwinErrnoError(hostErrno()) }
    }

    /// True when `guestPath` lies under a writable prefix.
    func writable(guestPath: String) -> Bool { lookupPrefix(guestPath)?.prefix.writable ?? false }
}

private func hostRename(_ from: String, _ to: String) throws {
    guard rename(from, to) == 0 else { throw DarwinErrnoError(hostErrno()) }
}

private func hostChmod(_ path: String, _ mode: UInt16) -> Int32 { chmod(path, mode_t(mode)) }
private func hostFchmod(_ fd: Int32, _ mode: UInt16) -> Int32 { fchmod(fd, mode_t(mode)) }
private func hostTruncate(_ path: String, _ length: Int64) -> Int32 { truncate(path, off_t(length)) }

private func hostSetTimes(path: String?, fd: Int32?, _ access: DarwinTimespec?, _ modification: DarwinTimespec?,
                          follow: Bool) -> Int32 {
    func spec(_ t: DarwinTimespec?) -> timespec {
        #if canImport(Darwin)
        let now = -1  // UTIME_NOW
        #else
        let now = (1 << 30) - 1  // UTIME_NOW (Linux)
        #endif
        guard let t else { return timespec(tv_sec: 0, tv_nsec: now) }
        return timespec(tv_sec: Int(t.sec), tv_nsec: Int(t.nsec))
    }
    var times = [spec(access), spec(modification)]
    if let fd { return futimens(fd, &times) }
    #if canImport(Darwin)
    let cwd: Int32 = -2, noFollow: Int32 = 0x20
    #else
    let cwd: Int32 = -100, noFollow: Int32 = 0x100
    #endif
    return utimensat(cwd, path!, &times, follow ? 0 : noFollow)
}


// MARK: - Extended attributes (stage 6)

#if !canImport(Darwin)
/// glibc's xattr functions (sys/xattr.h is not part of Swift's Glibc
/// module): looked up once with dlsym.
private enum LinuxXattr {
    typealias Get = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutableRawPointer?, Int) -> Int
    typealias FGet = @convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutableRawPointer?, Int) -> Int
    typealias Set = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeRawPointer?, Int, Int32) -> Int32
    typealias FSet = @convention(c) (Int32, UnsafePointer<CChar>, UnsafeRawPointer?, Int, Int32) -> Int32
    typealias Remove = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    typealias FRemove = @convention(c) (Int32, UnsafePointer<CChar>) -> Int32
    typealias List = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>?, Int) -> Int
    typealias FList = @convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int

    static func symbol<T>(_ name: String, _: T.Type) -> T {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: 0), name) else { fatalError("libc lacks \(name)") }
        return unsafeBitCast(p, to: T.self)
    }
    static let lget = symbol("lgetxattr", Get.self), fget = symbol("fgetxattr", FGet.self)
    static let lset = symbol("lsetxattr", Set.self), fset = symbol("fsetxattr", FSet.self)
    static let lremove = symbol("lremovexattr", Remove.self), fremove = symbol("fremovexattr", FRemove.self)
    static let llist = symbol("llistxattr", List.self), flist = symbol("flistxattr", FList.self)
}
#endif

/// Extended attributes, kept as host extended attributes named
/// `user.ycode.<name>` (Linux `user` namespace; on a macOS host the same
/// name), so they persist with the device's files. Darwin semantics
/// (sys/xattr.h, getxattr(2)/setxattr(2)): a missing attribute is ENOATTR
/// (93), XATTR_CREATE on an existing one EEXIST, XATTR_REPLACE on a missing
/// one ENOATTR, names of 1…127 bytes, read-only prefixes EROFS.
extension DarwinFileSystem {
    public enum XattrTarget {
        case path(String, followSymlinks: Bool)
        case descriptor(Int32)
    }

    static let xattrPrefix = "user.ycode."
    static let ENOATTR: Int32 = 93

    /// The host file behind a target: its path or descriptor, and whether it may be written.
    private func xattrHost(_ t: XattrTarget) throws -> (path: String?, fd: Int32?, writable: Bool) {
        switch t {
        case let .path(path, follow):
            let r = try resolve(path, followFinal: follow)
            guard r.stat != nil else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
            return (r.hostPath.isEmpty ? nil : r.hostPath, nil, r.prefix.writable && !r.hostPath.isEmpty)
        case let .descriptor(fd):
            let d = try entry(fd)
            guard case let .file(f) = d.file.node else { return (nil, nil, false) }
            return (nil, f.hostFD, writable(guestPath: f.guestPath))
        }
    }

    private static func checkName(_ name: String) throws {
        guard !name.isEmpty else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        guard name.utf8.count <= 127 else { throw DarwinErrnoError(DarwinErrnoCode.ENAMETOOLONG) }
    }

    private static func xattrErrno() -> Int32 {
        #if canImport(Darwin)
        return errno == 93 ? ENOATTR : DarwinErrnoCode.fromHost(errno)
        #else
        return errno == 61 ? ENOATTR : (errno == 95 ? DarwinErrnoCode.ENOTSUP : DarwinErrnoCode.fromHost(errno))
        #endif
    }

    public func getExtendedAttribute(_ t: XattrTarget, name: String) throws -> [UInt8] {
        try Self.checkName(name)
        let host = try xattrHost(t)
        guard host.path != nil || host.fd != nil else { throw DarwinErrnoError(Self.ENOATTR) }
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
        for _ in 0..<4 {
            let size = call(nil, 0)
            guard size >= 0 else { throw DarwinErrnoError(Self.xattrErrno()) }
            var bytes = [UInt8](repeating: 0, count: size)
            let n = bytes.withUnsafeMutableBytes { call($0.baseAddress, size) }
            if n >= 0 { return Array(bytes.prefix(n)) }
            guard errno == ERANGE else { throw DarwinErrnoError(Self.xattrErrno()) }
        }
        throw DarwinErrnoError(DarwinErrnoCode.EIO)
    }

    /// `create`: XATTR_CREATE; `replace`: XATTR_REPLACE.
    public func setExtendedAttribute(_ t: XattrTarget, name: String, value: [UInt8], create: Bool, replace: Bool) throws {
        try Self.checkName(name)
        let host = try xattrHost(t)
        guard host.writable, host.path != nil || host.fd != nil else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        let key = Self.xattrPrefix + name
        let r: Int32 = value.withUnsafeBytes { v in
            #if canImport(Darwin)
            let flags: Int32 = (create ? XATTR_CREATE : 0) | (replace ? XATTR_REPLACE : 0)
            if let fd = host.fd { return fsetxattr(fd, key, v.baseAddress, v.count, 0, flags) }
            return setxattr(host.path!, key, v.baseAddress, v.count, 0, flags | XATTR_NOFOLLOW)
            #else
            let flags: Int32 = (create ? 1 : 0) | (replace ? 2 : 0)  // XATTR_CREATE, XATTR_REPLACE (Linux)
            if let fd = host.fd { return LinuxXattr.fset(fd, key, v.baseAddress, v.count, flags) }
            return LinuxXattr.lset(host.path!, key, v.baseAddress, v.count, flags)
            #endif
        }
        guard r == 0 else { throw DarwinErrnoError(Self.xattrErrno()) }
    }

    public func removeExtendedAttribute(_ t: XattrTarget, name: String) throws {
        try Self.checkName(name)
        let host = try xattrHost(t)
        guard host.path != nil || host.fd != nil else { throw DarwinErrnoError(Self.ENOATTR) }
        guard host.writable else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        let key = Self.xattrPrefix + name
        #if canImport(Darwin)
        let r = host.fd.map { fremovexattr($0, key, 0) } ?? removexattr(host.path!, key, XATTR_NOFOLLOW)
        #else
        let r = host.fd.map { LinuxXattr.fremove($0, key) } ?? LinuxXattr.lremove(host.path!, key)
        #endif
        guard r == 0 else { throw DarwinErrnoError(Self.xattrErrno()) }
    }

    /// The guest's attribute names, in host order.
    public func listExtendedAttributes(_ t: XattrTarget) throws -> [String] {
        let host = try xattrHost(t)
        guard host.path != nil || host.fd != nil else { return [] }
        func call(_ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int {
            #if canImport(Darwin)
            if let fd = host.fd { return flistxattr(fd, buffer, size, 0) }
            return listxattr(host.path!, buffer, size, XATTR_NOFOLLOW)
            #else
            if let fd = host.fd { return LinuxXattr.flist(fd, buffer, size) }
            return LinuxXattr.llist(host.path!, buffer, size)
            #endif
        }
        for _ in 0..<4 {
            let size = call(nil, 0)
            guard size >= 0 else {
                if errno == ENOTSUP || errno == EPERM { return [] }
                throw DarwinErrnoError(Self.xattrErrno())
            }
            if size == 0 { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            let n = buffer.withUnsafeMutableBufferPointer { call($0.baseAddress, size) }
            if n < 0 {
                guard errno == ERANGE else { throw DarwinErrnoError(Self.xattrErrno()) }
                continue
            }
            let bytes = buffer.prefix(n).map { UInt8(bitPattern: $0) }
            return bytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                .filter { $0.hasPrefix(Self.xattrPrefix) }.map { String($0.dropFirst(Self.xattrPrefix.count)) }
        }
        throw DarwinErrnoError(DarwinErrnoCode.EIO)
    }
}
