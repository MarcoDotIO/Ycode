// A plain Apple Archive stream (what a decrypted asset `.aar` holds),
// extracted to a folder. Ycode's own reader of the public container format
// (the field layout libNeoAppleArchive, MIT, documents): each entry is a
// header — magic `AA01` or `YAA1`, a 16-bit little-endian header size, then
// fields of a three-letter key and a one-letter type — followed by the blobs
// its blob fields announce, in order. Types: `*` flag; `1 2 4 8` unsigned
// integers; `P` a string with a 16-bit length; `F G H I J` hashes of 4, 20,
// 32, 48, 64 bytes; `S T` times of 8 and 12 bytes; `A B C` blob sizes of 2,
// 4, 8 bytes. Entries Ycode writes: directories, regular files and symbolic
// links, with their modes and modification times. Nothing is written outside
// the destination: absolute paths, `..` and paths through a symbolic link
// are refused. Portable.
//
// An asset archive wraps its files in parts (seen in the decrypted asset,
// read as data): metadata entries (type `M`) whose `YOP` field says what the
// part is — `M` a manifest of the parts, `E` files to extract, `O` the files'
// owners, modes and SHA-256 (`SH2`) to apply and check afterwards — and whose
// `DAT` blob is a pbzx stream (stored or XZ chunks) holding a plain archive.

import Crypto
import Foundation
#if canImport(Glibc)
import Glibc
#endif

public final class AppleArchiveReader {
    public struct Entry: Equatable, Sendable {
        public var type: UInt8
        public var path: String
        public var link: String?
        public var mode: UInt32?
        public var mtime: Int64?
        public var dataSize: Int64?
        /// `YOP` of a metadata entry.
        public var operation: UInt8?
        /// `SH2`: the file's SHA-256.
        public var sha256: [UInt8]?
        /// Sizes of the blobs in header order (DAT, XAT, …), keyed by field.
        public var blobs: [(key: String, size: Int64)]

        public static func == (a: Entry, b: Entry) -> Bool {
            a.type == b.type && a.path == b.path && a.link == b.link && a.mode == b.mode && a.dataSize == b.dataSize
        }
    }

    public struct Stats: Sendable, Equatable {
        public var files = 0, directories = 0, links = 0
        public var bytes: Int64 = 0
        /// Files whose SHA-256 the archive named and that matched.
        public var verified = 0
        public var parts = 0
    }

    /// What the entries of this stream do.
    enum Role { case extract, attributes }
    var role = Role.extract
    /// The SHA-256 of each file written (path → digest), for the `O` part.
    var written: [String: [UInt8]] = [:]
    weak var parent: AppleArchiveReader?
    var root: AppleArchiveReader { parent?.root ?? self }

    let read: (Int) throws -> [UInt8]
    let destination: String
    public private(set) var stats = Stats()
    public var progress: ((Int64) -> Void)?
    public var cancel: RuntimeCancellation?
    var verifiedDirs: Set<String> = []

    /// `read(n)` returns up to `n` bytes, or none at the end.
    public init(destination: String, read: @escaping (Int) throws -> [UInt8]) {
        self.destination = destination.hasSuffix("/") ? String(destination.dropLast()) : destination
        self.read = read
    }

    func fail(_ m: String) -> RuntimeDownloadError { .expansion(m) }

    private var buffer: [UInt8] = []
    private var bufferStart = 0

    /// Exactly `n` bytes, or fewer at the very end (only before a header).
    func take(_ n: Int, allowShort: Bool = false) throws -> [UInt8] {
        while buffer.count - bufferStart < n {
            let more = try read(max(n - (buffer.count - bufferStart), 1 << 20))
            if more.isEmpty { break }
            if bufferStart > 0 {
                buffer.removeFirst(bufferStart)
                bufferStart = 0
            }
            buffer += more
        }
        let have = buffer.count - bufferStart
        if have < n && !allowShort { throw fail("the archive ends inside an entry") }
        let k = min(n, have)
        let out = Array(buffer[bufferStart..<bufferStart + k])
        bufferStart += k
        if bufferStart == buffer.count { buffer.removeAll(keepingCapacity: true); bufferStart = 0 }
        return out
    }

    /// Parses one header's fields.
    public static func parseHeader(_ h: [UInt8]) throws -> Entry {
        var e = Entry(type: 0, path: "", blobs: [])
        var i = 6
        func le(_ at: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<n { v |= UInt64(h[at + k]) << (8 * UInt64(k)) }
            return v
        }
        while i < h.count {
            guard i + 4 <= h.count else { throw RuntimeDownloadError.expansion("a field runs past its header") }
            let key = String(decoding: h[i..<i + 3], as: UTF8.self)
            let t = h[i + 3]
            i += 4
            let size: Int
            switch t {
            case UInt8(ascii: "*"): size = 0
            case UInt8(ascii: "1"): size = 1
            case UInt8(ascii: "2"): size = 2
            case UInt8(ascii: "4"): size = 4
            case UInt8(ascii: "8"): size = 8
            case UInt8(ascii: "A"): size = 2
            case UInt8(ascii: "B"): size = 4
            case UInt8(ascii: "C"): size = 8
            case UInt8(ascii: "F"): size = 4
            case UInt8(ascii: "G"): size = 20
            case UInt8(ascii: "H"): size = 32
            case UInt8(ascii: "I"): size = 48
            case UInt8(ascii: "J"): size = 64
            case UInt8(ascii: "S"): size = 8
            case UInt8(ascii: "T"): size = 12
            case UInt8(ascii: "P"):
                guard i + 2 <= h.count else { throw RuntimeDownloadError.expansion("a string runs past its header") }
                let n = Int(le(i, 2))
                guard i + 2 + n <= h.count else { throw RuntimeDownloadError.expansion("a string runs past its header") }
                var s = Array(h[i + 2..<i + 2 + n])
                while s.last == 0 { s.removeLast() }
                let text = String(decoding: s, as: UTF8.self)
                if key == "PAT" { e.path = text } else if key == "LNK" { e.link = text }
                i += 2 + n
                continue
            default:
                throw RuntimeDownloadError.expansion("unknown field type \(Character(UnicodeScalar(t))) in \(key)")
            }
            guard i + size <= h.count else { throw RuntimeDownloadError.expansion("field \(key) runs past its header") }
            switch t {
            case UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "4"), UInt8(ascii: "8"):
                let v = le(i, size)
                switch key {
                case "TYP": e.type = UInt8(truncatingIfNeeded: v)
                case "MOD": e.mode = UInt32(truncatingIfNeeded: v)
                case "YOP": e.operation = UInt8(truncatingIfNeeded: v)
                default: break
                }
            case UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "C"):
                let v = Int64(le(i, size))
                e.blobs.append((key, v))
                if key == "DAT" { e.dataSize = v }
            case UInt8(ascii: "S"), UInt8(ascii: "T"):
                if key == "MTM" { e.mtime = Int64(le(i, 8)) }
            case UInt8(ascii: "H"):
                if key == "SH2" { e.sha256 = Array(h[i..<i + 32]) }
            default: break
            }
            i += size
        }
        return e
    }

    /// Extracts every entry; returns the counts.
    @discardableResult
    public func extract() throws -> Stats {
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        verifiedDirs.insert(destination)
        while true {
            if let cancel, cancel.isCancelled { throw RuntimeDownloadError.cancelled }
            let head = try take(6, allowShort: true)
            if head.isEmpty { return stats }
            guard head.count == 6 else { throw fail("the archive ends inside a header") }
            let magic = String(decoding: head[0..<4], as: UTF8.self)
            guard magic == "AA01" || magic == "YAA1" else { throw fail("not an Apple Archive entry (\(magic.debugDescription))") }
            let size = Int(head[4]) | Int(head[5]) << 8
            guard size >= 6 else { throw fail("bad header size") }
            let entry = try Self.parseHeader(head + (try take(size - 6)))
            if entry.type == UInt8(ascii: "M") { try part(entry) } else if role == .attributes { try apply(entry) } else { try write(entry) }
        }
    }

    func target(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !parts.contains(where: { $0 == ".." }) else { throw fail("refused the path \(path.debugDescription)") }
        let clean = parts.filter { $0 != "." }.joined(separator: "/")
        return clean.isEmpty ? destination : destination + "/" + clean
    }

    /// Refuses a parent that is not a real directory inside the destination.
    func checkParent(of full: String) throws {
        let parent = (full as NSString).deletingLastPathComponent
        if verifiedDirs.contains(parent) { return }
        var st = stat()
        guard lstat(parent, &st) == 0 else {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try checkParent(of: parent)
            verifiedDirs.insert(parent)
            return
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw fail("refused to write through \(parent.debugDescription)") }
        if parent != destination { try checkParent(of: parent) }
        verifiedDirs.insert(parent)
    }

    func write(_ e: Entry) throws {
        let full = try target(e.path)
        let fm = FileManager.default
        switch e.type {
        case UInt8(ascii: "D"):
            if full != destination {
                try checkParent(of: full)
                var st = stat()
                if lstat(full, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR { try fm.removeItem(atPath: full) }
                if lstat(full, &st) != 0 { try fm.createDirectory(atPath: full, withIntermediateDirectories: false) }
                verifiedDirs.insert(full)
            }
            stats.directories += 1
            try skipBlobs(e)
            if let m = e.mode { chmod(full, mode_t(m & 0o7777) | 0o700) }
        case UInt8(ascii: "F"):
            try checkParent(of: full)
            try? fm.removeItem(atPath: full)
            guard let out = FileHandle(forWritingAtPath: full) ?? { fm.createFile(atPath: full, contents: nil) ? FileHandle(forWritingAtPath: full) : nil }() else {
                throw fail("cannot create \(e.path)")
            }
            defer { try? out.close() }
            var hasher = SHA256()
            for b in e.blobs {
                if b.key == "DAT" {
                    var left = b.size
                    while left > 0 {
                        if let cancel, cancel.isCancelled { throw RuntimeDownloadError.cancelled }
                        let piece = try take(Int(min(left, 4 << 20)))
                        try out.write(contentsOf: piece)
                        hasher.update(data: piece)
                        left -= Int64(piece.count)
                        stats.bytes += Int64(piece.count)
                        progress?(stats.bytes)
                    }
                } else {
                    try skip(b.size)
                }
            }
            if let m = e.mode { chmod(full, mode_t(m & 0o7777) | 0o600) }
            let digest = Array(hasher.finalize())
            if let want = e.sha256, want != digest { throw fail("\(e.path) does not match its SHA-256") }
            root.written[e.path] = digest
            stats.files += 1
        case UInt8(ascii: "L"):
            try checkParent(of: full)
            try? fm.removeItem(atPath: full)
            guard let link = e.link else { throw fail("link \(e.path) has no target") }
            try fm.createSymbolicLink(atPath: full, withDestinationPath: link)
            try skipBlobs(e)
            stats.links += 1
        default:
            // Other kinds (devices, fifos, sockets) have no place in an asset.
            try skipBlobs(e)
        }
        if let t = e.mtime, e.type != UInt8(ascii: "L") {
            var times = [timespec(tv_sec: Int(t), tv_nsec: 0), timespec(tv_sec: Int(t), tv_nsec: 0)]
            _ = utimensat(AT_FDCWD, full, &times, 0)
        }
    }

    /// A metadata entry: its DAT blob is a part to extract (E) or to apply (O).
    func part(_ e: Entry) throws {
        for b in e.blobs {
            let op = e.operation.map { Character(UnicodeScalar($0)) }
            guard b.key == "DAT", op == "E" || op == "O" else { try skip(b.size); continue }
            var left = b.size
            let blob: (Int) throws -> [UInt8] = { [unowned self] n in
                guard left > 0 else { return [] }
                let piece = try self.take(Int(min(Int64(n), left)))
                left -= Int64(piece.count)
                return piece
            }
            // A part is a pbzx stream, or a plain archive.
            let first = try take(4)
            var replay: [UInt8]? = first
            let source: (Int) throws -> [UInt8] = { n in
                if let r = replay { replay = nil; return r }
                return try blob(n)
            }
            left -= 4
            let inner: (Int) throws -> [UInt8]
            if first == Array("pbzx".utf8) {
                let p = PBZXSource(source)
                inner = { try p.read($0) }
            } else {
                inner = source
            }
            let sub = AppleArchiveReader(destination: destination, read: inner)
            sub.parent = self
            sub.role = op == "O" ? .attributes : .extract
            sub.cancel = cancel
            let base = root.stats.bytes
            sub.progress = { [weak self] n in self?.progress?(base + n) }
            sub.verifiedDirs = verifiedDirs
            try sub.extract()
            if left > 0 { try skip(left) }
            let r = root
            if r !== sub {
                r.stats.files += sub.stats.files
                r.stats.directories += sub.stats.directories
                r.stats.links += sub.stats.links
                r.stats.bytes += sub.stats.bytes
                r.stats.verified += sub.stats.verified
                r.stats.parts += 1
            }
        }
    }

    /// An entry of an `O` part: the mode, and the SHA-256 checked against what was written.
    func apply(_ e: Entry) throws {
        try skipBlobs(e)
        let full = try target(e.path)
        if let want = e.sha256, e.type == UInt8(ascii: "F") {
            guard let got = root.written[e.path] else { throw fail("\(e.path) is listed but was not in the archive") }
            guard got == want else { throw fail("\(e.path) does not match its SHA-256") }
            stats.verified += 1
        }
        var st = stat()
        if let m = e.mode, lstat(full, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK { chmod(full, mode_t(m & 0o7777) | 0o600) }
    }

    func skipBlobs(_ e: Entry) throws { for b in e.blobs { try skip(b.size) } }

    func skip(_ n: Int64) throws {
        var left = n
        while left > 0 {
            let piece = try take(Int(min(left, 4 << 20)))
            left -= Int64(piece.count)
        }
    }

    /// A reader over a file handle (a pipe from the decryptor, or a file).
    public static func reading(_ h: FileHandle, into destination: String) -> AppleArchiveReader {
        AppleArchiveReader(destination: destination) { n in Array(try h.read(upToCount: n) ?? Data()) }
    }
}
