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

    private static let names: [Int32: String] = [
        1: "EPERM", 2: "ENOENT", 4: "EINTR", 5: "EIO", 9: "EBADF", 11: "EDEADLK", 12: "ENOMEM", 13: "EACCES",
        14: "EFAULT", 17: "EEXIST", 19: "ENODEV", 20: "ENOTDIR", 21: "EISDIR", 22: "EINVAL", 24: "EMFILE",
        25: "ENOTTY", 27: "EFBIG", 28: "ENOSPC", 29: "ESPIPE", 30: "EROFS", 34: "ERANGE", 35: "EAGAIN",
        45: "ENOTSUP", 62: "ELOOP", 63: "ENAMETOOLONG", 66: "ENOTEMPTY", 78: "ENOSYS", 84: "EOVERFLOW",
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
    public static let O_NOFOLLOW: Int32 = 0x0100
    public static let O_CREAT: Int32 = 0x0200
    public static let O_TRUNC: Int32 = 0x0400
    public static let O_EXCL: Int32 = 0x0800
    public static let O_DIRECTORY: Int32 = 0x0010_0000
    public static let O_CLOEXEC: Int32 = 0x0100_0000
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

// MARK: - DarwinFileSystem

/// The guest's view of files (stage3-contract.md §8). Guest paths equal host
/// paths under the allowed prefixes; everything else is ENOENT. Symbolic
/// links below a prefix are resolved here, in the guest namespace, so a link
/// can never lead outside the allowlist.
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

    private enum Node {
        case console
        case file(GuestFile)
    }

    private struct Descriptor {
        var node: Node
        var offset: UInt64 = 0
        /// Darwin open flags as given (access mode, O_APPEND, O_NONBLOCK).
        var statusFlags: Int32
        var closeOnExec: Bool
        var readable: Bool { statusFlags & DarwinOpen.O_ACCMODE != DarwinOpen.O_WRONLY }
        var writable: Bool {
            let m = statusFlags & DarwinOpen.O_ACCMODE
            return m == DarwinOpen.O_WRONLY || m == DarwinOpen.O_RDWR
        }
    }

    public let prefixes: [Prefix]
    private let console: (Int32, [UInt8]) -> Void
    private var descriptors: [Int32: Descriptor] = [:]
    /// The highest descriptor number plus one (Darwin's default soft limit).
    public var maxDescriptors: Int32 = 256

    private var cwdStorage = "/"
    /// The current directory (a normalized guest path). Default "/".
    public var cwd: String {
        get { cwdStorage }
        set { cwdStorage = normalize(newValue, cwd: cwdStorage) }
    }

    /// `prefixes` guest paths are normalized; fds 0, 1, and 2 are the
    /// console, and output written to them goes to `console(fd, bytes)`.
    public init(prefixes: [Prefix], console: @escaping (Int32, [UInt8]) -> Void) {
        self.console = console
        var normalized: [Prefix] = []
        for var p in prefixes {
            p.guestPath = Self.normalizeAbsolute(p.guestPath)
            while p.hostPath.count > 1 && p.hostPath.hasSuffix("/") { p.hostPath.removeLast() }
            normalized.append(p)
        }
        self.prefixes = normalized
        for fd: Int32 in 0...2 {
            descriptors[fd] = Descriptor(node: .console, statusFlags: fd == 0 ? DarwinOpen.O_RDONLY : DarwinOpen.O_WRONLY,
                                         closeOnExec: false)
        }
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
            guard let (prefix, _) = lookupPrefix(current) else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
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
                    st = nil
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

    /// The canonical guest path: absolute, normalized, with every symbolic
    /// link resolved inside the allowlist. The path must exist.
    public func realpath(_ path: String) throws -> String {
        let r = try resolve(path, followFinal: true)
        guard r.stat != nil else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        return r.guestPath
    }

    // MARK: Descriptors

    private func descriptor(_ fd: Int32) throws -> Descriptor {
        guard let d = descriptors[fd] else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        return d
    }

    private func lowestFreeDescriptor() throws -> Int32 {
        var fd: Int32 = 0
        while descriptors[fd] != nil { fd += 1 }
        guard fd < maxDescriptors else { throw DarwinErrnoError(DarwinErrnoCode.EMFILE) }
        return fd
    }

    /// Opens a guest path with Darwin `flags` and returns the new descriptor
    /// (the lowest free number). Writing, creating, or truncating under a
    /// read-only prefix is EROFS; O_CREAT of an existing file there is fine.
    public func open(_ path: String, flags: Int32, mode: UInt16) throws -> Int32 {
        let accessMode = flags & DarwinOpen.O_ACCMODE
        guard accessMode != DarwinOpen.O_ACCMODE else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        let wantsWrite = accessMode != DarwinOpen.O_RDONLY
        let create = flags & DarwinOpen.O_CREAT != 0
        let exclusive = create && flags & DarwinOpen.O_EXCL != 0
        let truncate = flags & DarwinOpen.O_TRUNC != 0
        let directory = flags & DarwinOpen.O_DIRECTORY != 0
        let follow = flags & DarwinOpen.O_NOFOLLOW == 0 && !exclusive

        let r = try resolve(path, followFinal: follow)
        if let st = r.stat {
            if exclusive { throw DarwinErrnoError(DarwinErrnoCode.EEXIST) }
            if st.isSymbolicLink { throw DarwinErrnoError(DarwinErrnoCode.ELOOP) }
            if directory && !st.isDirectory { throw DarwinErrnoError(DarwinErrnoCode.ENOTDIR) }
            if st.isDirectory && (wantsWrite || truncate) { throw DarwinErrnoError(DarwinErrnoCode.EISDIR) }
            if !r.prefix.writable && (wantsWrite || truncate) { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
        } else {
            guard create else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
            guard r.prefix.writable else { throw DarwinErrnoError(DarwinErrnoCode.EROFS) }
            guard !directory else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        }
        let fd = try lowestFreeDescriptor()

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
        let hostFD = try hostOpen(r.hostPath, hostFlags, mode & 0o7777)
        let file: GuestFile
        do {
            file = GuestFile(guestPath: r.guestPath, hostPath: r.hostPath, hostFD: hostFD, stat: try hostFStat(hostFD))
        } catch {
            hostClose(hostFD)
            throw error
        }
        let status = flags & (DarwinOpen.O_ACCMODE | DarwinOpen.O_APPEND | DarwinOpen.O_NONBLOCK)
        descriptors[fd] = Descriptor(node: .file(file), statusFlags: status,
                                     closeOnExec: flags & DarwinOpen.O_CLOEXEC != 0)
        return fd
    }

    /// Closes a descriptor. The host file stays open while a mapping holds it.
    public func close(_ fd: Int32) throws {
        guard descriptors.removeValue(forKey: fd) != nil else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
    }

    /// Reads at the descriptor's offset and advances it. The console reads
    /// as end of file. Requests above `maxTransfer` bytes are short.
    public func read(_ fd: Int32, count: Int) throws -> [UInt8] {
        var d = try descriptor(fd)
        guard d.readable else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        guard count >= 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        switch d.node {
        case .console:
            return []
        case let .file(f):
            if f.isDirectory { throw DarwinErrnoError(DarwinErrnoCode.EISDIR) }
            let bytes = try hostPRead(f.hostFD, count: min(count, Self.maxTransfer), offset: d.offset)
            d.offset += UInt64(bytes.count)
            descriptors[fd] = d
            return bytes
        }
    }

    /// Reads at `offset` without moving the descriptor's offset.
    public func pread(_ fd: Int32, count: Int, offset: UInt64) throws -> [UInt8] {
        let d = try descriptor(fd)
        guard d.readable else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
        guard count >= 0 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
        switch d.node {
        case .console:
            throw DarwinErrnoError(DarwinErrnoCode.ESPIPE)
        case let .file(f):
            if f.isDirectory { throw DarwinErrnoError(DarwinErrnoCode.EISDIR) }
            return try hostPRead(f.hostFD, count: min(count, Self.maxTransfer), offset: offset)
        }
    }

    /// Writes at the descriptor's offset (at the end with O_APPEND) and
    /// advances it. Console output goes to the console sink.
    public func write(_ fd: Int32, _ bytes: [UInt8]) throws -> Int {
        var d = try descriptor(fd)
        switch d.node {
        case .console:
            console(fd, bytes)
            return bytes.count
        case let .file(f):
            guard d.writable else { throw DarwinErrnoError(DarwinErrnoCode.EBADF) }
            if d.statusFlags & DarwinOpen.O_APPEND != 0 {
                d.offset = UInt64(max(0, try hostFStat(f.hostFD).size))
            }
            let n = try hostPWrite(f.hostFD, bytes, offset: d.offset)
            d.offset += UInt64(n)
            descriptors[fd] = d
            return n
        }
    }

    /// `stat` (following a final symbolic link) or `lstat`.
    public func stat(_ path: String, followSymlinks: Bool) throws -> DarwinStat {
        let r = try resolve(path, followFinal: followSymlinks)
        guard let st = r.stat else { throw DarwinErrnoError(DarwinErrnoCode.ENOENT) }
        return st
    }

    /// Current stat data of an open descriptor.
    public func fstat(_ fd: Int32) throws -> DarwinStat {
        switch try descriptor(fd).node {
        case .console:
            return DarwinStat(mode: DarwinStat.S_IFCHR | 0o620, nlink: 1, uid: Self.guestUID, gid: 4,
                              blksize: 131_072)
        case let .file(f):
            return try hostFStat(f.hostFD)
        }
    }

    /// The open file behind a descriptor (for `mmap`). The console is ENODEV.
    public func file(for fd: Int32) throws -> GuestFile {
        switch try descriptor(fd).node {
        case .console: throw DarwinErrnoError(DarwinErrnoCode.ENODEV)
        case let .file(f): return f
        }
    }

    /// The descriptor's resolved guest path (`F_GETPATH`).
    public func path(for fd: Int32) throws -> String {
        switch try descriptor(fd).node {
        case .console: return Self.consolePath
        case let .file(f): return f.guestPath
        }
    }

    /// Sets or clears FD_CLOEXEC (`F_SETFD`).
    public func setCloseOnExec(_ fd: Int32, _ on: Bool) throws {
        var d = try descriptor(fd)
        d.closeOnExec = on
        descriptors[fd] = d
    }

    /// FD_CLOEXEC (`F_GETFD`).
    public func closeOnExec(_ fd: Int32) throws -> Bool { try descriptor(fd).closeOnExec }

    /// The Darwin status flags (`F_GETFL`): access mode, O_APPEND, O_NONBLOCK.
    public func statusFlags(_ fd: Int32) throws -> Int32 { try descriptor(fd).statusFlags }

    /// The open descriptor numbers, ascending.
    public var openDescriptors: [Int32] { descriptors.keys.sorted() }
}

// MARK: - Stage 4b API (stage4b-contract.md §3.5; stubs, agent F implements)

/// An open file description: what dup'd and inherited descriptors share
/// (offset, status flags, the node). Contract-pinned name.
public final class DarwinOpenFile {
    public init() {}
}

extension DarwinFileSystem {
    public func installObject(_ object: DarwinDescriptorObject, statusFlags: Int32, closeOnExec: Bool) throws -> Int32 {
        throw DarwinErrnoError(DarwinErrnoCode.ENOSYS)
    }

    public func object(for fd: Int32) throws -> DarwinDescriptorObject? { nil }

    public func openFile(for fd: Int32) throws -> DarwinOpenFile {
        throw DarwinErrnoError(DarwinErrnoCode.ENOSYS)
    }

    public func install(_ file: DarwinOpenFile, closeOnExec: Bool, at fd: Int32? = nil) throws -> Int32 {
        throw DarwinErrnoError(DarwinErrnoCode.ENOSYS)
    }

    public func dup(_ fd: Int32, minimum: Int32 = 0) throws -> Int32 {
        throw DarwinErrnoError(DarwinErrnoCode.ENOSYS)
    }

    public func dup2(_ from: Int32, _ to: Int32) throws {
        throw DarwinErrnoError(DarwinErrnoCode.ENOSYS)
    }

    public func makeChildCopy() -> DarwinFileSystem {
        DarwinFileSystem(prefixes: prefixes, console: { _, _ in })
    }

    public func closeOnExecDescriptors(keepOnly: Set<Int32>? = nil) {}

    public func closeAll() {}

    public func chdir(_ path: String) throws {
        throw DarwinErrnoError(DarwinErrnoCode.ENOSYS)
    }

    public func fchdir(_ fd: Int32) throws {
        throw DarwinErrnoError(DarwinErrnoCode.ENOSYS)
    }

    public func hostPathForExec(_ path: String) throws -> (guestPath: String, hostPath: String) {
        throw DarwinErrnoError(DarwinErrnoCode.ENOSYS)
    }
}
