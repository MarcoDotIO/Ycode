// A directory as a byte stream (sim-link.md §6.2): how an app bundle built
// on the client reaches the host. Entries, depth first:
//
//   u8 kind (1 directory, 2 file, 3 symbolic link, 0 end), u16 path length,
//   path (UTF-8, relative, "/"-separated), u32 mode, u64 size, size bytes
//   (a file's contents, a link's target)
//
// little-endian. The reader refuses absolute paths, "..", empty components
// and link targets that leave the tree, so an archive cannot write outside
// its destination.

import Foundation

public enum DirectoryArchive {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

    /// Writes `root`'s tree through `emit` (chunks of at most 1 MiB).
    public static func write(_ root: URL, emit: ([UInt8]) throws -> Void) throws {
        let fm = FileManager.default
        func entry(_ kind: UInt8, _ path: String, _ mode: Int, _ body: [UInt8]) throws {
            let p = Array(path.utf8)
            guard p.count < 65536 else { throw Failure(description: "path too long: \(path)") }
            try emit([kind] + le(UInt64(p.count), 2) + p + le(UInt64(mode), 4) + le(UInt64(body.count), 8))
            var at = 0
            while at < body.count {
                let n = min(1 << 20, body.count - at)
                try emit(Array(body[at..<(at + n)]))
                at += n
            }
        }
        func walk(_ dir: URL, _ rel: String) throws {
            let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
            for name in names {
                let url = dir.appendingPathComponent(name)
                let path = rel.isEmpty ? name : rel + "/" + name
                let attrs = try fm.attributesOfItem(atPath: url.path)
                let mode = (attrs[.posixPermissions] as? Int) ?? 0o644
                switch attrs[.type] as? FileAttributeType {
                case .typeSymbolicLink?:
                    try entry(3, path, mode, Array(try fm.destinationOfSymbolicLink(atPath: url.path).utf8))
                case .typeDirectory?:
                    try entry(1, path, mode, [])
                    try walk(url, path)
                default:
                    guard let d = fm.contents(atPath: url.path) else { throw Failure(description: "cannot read \(url.path)") }
                    try entry(2, path, mode, Array(d))
                }
            }
        }
        try walk(root, "")
        try emit([0])
    }

    /// The archive of a directory as one array (tests, small trees).
    public static func bytes(of root: URL) throws -> [UInt8] {
        var out: [UInt8] = []
        try write(root) { out += $0 }
        return out
    }

    static func safe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == ".." || $0 == "." }
    }

    /// Reads an archive into `destination` (created; must not exist).
    /// `read(n)` returns exactly n bytes or nil. Returns the bytes read.
    @discardableResult
    public static func extract(into destination: URL, limit: Int = 4 << 30, read: (Int) -> [UInt8]?) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        var total = 0
        func take(_ n: Int) throws -> [UInt8] {
            guard let b = read(n), b.count == n else { throw Failure(description: "the archive ended early") }
            total += n
            guard total <= limit else { throw Failure(description: "the archive is larger than \(limit) bytes") }
            return b
        }
        func num(_ b: [UInt8]) -> UInt64 { b.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }
        while true {
            let kind = try take(1)[0]
            if kind == 0 { return total }
            let plen = Int(num(try take(2)))
            guard let path = String(bytes: try take(plen), encoding: .utf8), safe(path) else { throw Failure(description: "unsafe path in the archive") }
            let mode = Int(num(try take(4))) & 0o7777
            let size = Int(num(try take(8)))
            let url = destination.appendingPathComponent(path)
            switch kind {
            case 1:
                guard size == 0 else { throw Failure(description: "directory with contents") }
                try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: mode | 0o700])
            case 2:
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: mode & 0o777]) else {
                    throw Failure(description: "cannot create \(path)")
                }
                let h = try FileHandle(forWritingTo: url)
                var left = size
                while left > 0 {
                    let n = min(left, 1 << 20)
                    h.write(Data(try take(n)))
                    left -= n
                }
                try h.close()
            case 3:
                guard let target = String(bytes: try take(size), encoding: .utf8) else { throw Failure(description: "bad link") }
                // The target, resolved from the link's directory, must stay inside the tree.
                let base = path.split(separator: "/").dropLast().map(String.init)
                var parts = target.hasPrefix("/") ? ["/"] : base
                for c in target.split(separator: "/") {
                    if c == ".." { guard !parts.isEmpty, parts != ["/"] else { throw Failure(description: "link leaves the tree") }; parts.removeLast() }
                    else if c != "." { parts.append(String(c)) }
                }
                guard !target.hasPrefix("/") else { throw Failure(description: "absolute link in the archive") }
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            default:
                throw Failure(description: "unknown entry kind \(kind)")
            }
        }
    }
}
