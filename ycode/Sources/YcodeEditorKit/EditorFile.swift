import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// How a file's bytes map to the editor's text, kept so a save writes back
/// what it read: the byte order mark and the line endings.
public struct EditorFileFormat: Equatable, Sendable {
    public enum Encoding: Equatable, Sendable {
        case utf8, utf8BOM, utf16LE, utf16BE
    }
    public var encoding: Encoding
    /// The file's lines all end in CRLF; the buffer holds LF.
    public var crlf: Bool
    public init(encoding: Encoding = .utf8, crlf: Bool = false) {
        self.encoding = encoding
        self.crlf = crlf
    }
}

/// What identifies a file's state on disk.
public struct EditorDiskStamp: Equatable, Sendable {
    public var size: Int64
    public var modified: Double
    public var inode: UInt64
    /// FNV-1a of the bytes.
    public var contentHash: UInt64
}

/// Why a save failed; the buffer keeps the text.
public enum EditorSaveError: Error, Equatable, CustomStringConvertible {
    case cannotWrite(path: String, reason: String)
    case verifyFailed(path: String)

    public var description: String {
        switch self {
        case .cannotWrite(let p, let r): "Could not write \((p as NSString).lastPathComponent): \(r)"
        case .verifyFailed(let p): "Could not write \((p as NSString).lastPathComponent): what was written does not read back the same."
        }
    }
}

public enum EditorFile {
    /// Files larger than this are not opened (as the read-only editor did).
    public static let sizeLimit = 16 << 20

    /// What opening a file gave.
    public enum Contents: Equatable, Sendable {
        case text(String, EditorFileFormat, EditorDiskStamp)
        /// Shown but not editable: saving would not give back its bytes.
        case readOnly(String, reason: String, EditorDiskStamp)
        case unavailable(String)
    }

    static let binaryExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "pdf", "zip", "gz", "a", "o", "dylib", "so", "icns", "ico", "tiff", "heic", "mov", "mp4", "mp3", "wav", "car", "nib", "ttf", "otf", "woff", "woff2"]

    public static func load(path: String) -> Contents {
        let name = (path as NSString).lastPathComponent
        guard let data = FileManager.default.contents(atPath: path) else { return .unavailable("Cannot read \(name)") }
        if data.count > sizeLimit { return .unavailable("File too large to show (\(data.count / 1024) KB)") }
        guard let decoded = decode(data) else {
            if data.prefix(8192).contains(0) || binaryExtensions.contains((path as NSString).pathExtension.lowercased()) {
                return .unavailable("Binary file")
            }
            // Not UTF-8: show it, but saving the replacement characters would destroy the bytes.
            return .readOnly(String(decoding: data, as: UTF8.self), reason: "\(name) is not valid UTF-8, so it is shown read-only.", stamp(path: path, data: data))
        }
        if binaryExtensions.contains((path as NSString).pathExtension.lowercased()) { return .unavailable("Binary file") }
        return .text(decoded.text, decoded.format, stamp(path: path, data: data))
    }

    /// The text and format of `data`; nil when it is binary or invalid UTF-8.
    public static func decode(_ data: Data) -> (text: String, format: EditorFileFormat)? {
        let bytes = [UInt8](data)
        var format = EditorFileFormat()
        var text: String
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let le = bytes[0] == 0xFF
            guard bytes.count % 2 == 0 else { return nil }
            format.encoding = le ? .utf16LE : .utf16BE
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            var i = 2
            while i + 1 < bytes.count {
                units.append(le ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                i += 2
            }
            guard let s = String(validating: units, as: UTF16.self) else { return nil }
            text = s
        } else {
            let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes[3...] : bytes[...]
            if body.count < bytes.count { format.encoding = .utf8BOM }
            if body.prefix(8192).contains(0) { return nil }
            guard let s = String(validating: body, as: UTF8.self) else { return nil }
            text = s
        }
        if text.utf8.contains(13) {
            // Only a file that is CRLF throughout is normalized: a mixed one
            // keeps its bytes (`\r` stays in the text, the line's end hides it).
            let u = Array(text.utf16)
            var crlf = 0, bareLF = 0, bareCR = 0
            for i in u.indices {
                if u[i] == 10 {
                    if i > 0, u[i - 1] == 13 { crlf += 1 } else { bareLF += 1 }
                } else if u[i] == 13, i + 1 >= u.count || u[i + 1] != 10 {
                    bareCR += 1
                }
            }
            if crlf > 0, bareLF == 0, bareCR == 0 {
                format.crlf = true
                text = text.replacingOccurrences(of: "\r\n", with: "\n")
            }
        }
        return (text, format)
    }

    /// The bytes for `text`, the inverse of `decode`.
    public static func encode(_ text: String, format: EditorFileFormat) -> Data {
        let t = format.crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        switch format.encoding {
        case .utf8: return Data(t.utf8)
        case .utf8BOM: return Data([0xEF, 0xBB, 0xBF] + Array(t.utf8))
        case .utf16LE, .utf16BE:
            let le = format.encoding == .utf16LE
            var out: [UInt8] = le ? [0xFF, 0xFE] : [0xFE, 0xFF]
            out.reserveCapacity(t.utf16.count * 2 + 2)
            for u in t.utf16 {
                if le {
                    out.append(UInt8(u & 0xFF))
                    out.append(UInt8(u >> 8))
                } else {
                    out.append(UInt8(u >> 8))
                    out.append(UInt8(u & 0xFF))
                }
            }
            return Data(out)
        }
    }

    public static func hash(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        data.withUnsafeBytes { p in
            for b in p { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        }
        return h
    }

    private static func statInfo(_ path: String) -> stat? {
        var st = stat()
        return stat(path, &st) == 0 ? st : nil
    }

    private static func modified(_ st: stat) -> Double {
        #if canImport(Darwin)
        Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        #else
        Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9
        #endif
    }

    /// The stamp of `path` whose bytes are `data`.
    public static func stamp(path: String, data: Data) -> EditorDiskStamp {
        let st = statInfo(path)
        return EditorDiskStamp(size: Int64(data.count), modified: st.map(modified) ?? 0, inode: UInt64(st?.st_ino ?? 0), contentHash: hash(data))
    }

    /// Whether `path` still looks as it did (size, time, inode), without
    /// reading it. A changed look may still be the same bytes.
    public static func looksUnchanged(path: String, stamp: EditorDiskStamp) -> Bool {
        guard let st = statInfo(path) else { return false }
        return Int64(st.st_size) == stamp.size && modified(st) == stamp.modified && UInt64(st.st_ino) == stamp.inode
    }

    /// Writes `data` so that `path` holds either its old bytes or all of the
    /// new ones, never a mix, also across a crash: a temporary file beside
    /// it, flushed and read back, renamed over it, then the directory flushed.
    /// A symbolic link stays a link (its target is what changes); the mode and,
    /// where allowed, the owner carry over. Where the directory takes no new
    /// file or the path can't be renamed over (a bind-mounted file), the file
    /// is written in place, after a copy of the old bytes beside the temporary
    /// directory's, which stays if that write fails.
    @discardableResult
    public static func writeAtomically(_ data: Data, to path: String) throws -> EditorDiskStamp {
        let target = resolvedPath(path)
        let old = statInfo(target)
        let dir = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        var template = Array(((dir.isEmpty ? "." : dir) + "/.\(name).ycode-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else {
            let e = errno
            if e == EACCES || e == EPERM, old != nil { return try writeInPlace(data, to: target) }
            throw EditorSaveError.cannotWrite(path: path, reason: String(cString: strerror(e)))
        }
        let temp = String(cString: template)
        var armed = true
        defer { if armed { unlink(temp) } }
        do {
            try writeAll(fd, data, path: path)
            if let old {
                _ = fchmod(fd, old.st_mode & 0o7777)
                _ = fchown(fd, old.st_uid, old.st_gid)
            } else {
                let mask = umask(0)
                umask(mask)
                _ = fchmod(fd, 0o666 & ~mask)
            }
            guard fsync(fd) == 0 else { throw EditorSaveError.cannotWrite(path: path, reason: String(cString: strerror(errno))) }
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        guard FileManager.default.contents(atPath: temp) == data else { throw EditorSaveError.verifyFailed(path: path) }
        guard rename(temp, target) == 0 else {
            let e = errno
            if e == EBUSY || e == EXDEV, old != nil { return try writeInPlace(data, to: target) }
            throw EditorSaveError.cannotWrite(path: path, reason: String(cString: strerror(e)))
        }
        armed = false
        let dfd = open(dir.isEmpty ? "." : dir, O_RDONLY)
        if dfd >= 0 {
            _ = fsync(dfd)
            close(dfd)
        }
        return stamp(path: target, data: data)
    }

    /// The real file behind `path` (symbolic links followed); `path` itself
    /// when it does not exist.
    static func resolvedPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else {
            // A dangling link: its target is the file to create.
            var buf = [CChar](repeating: 0, count: 4096)
            let n = readlink(path, &buf, buf.count - 1)
            guard n > 0 else { return path }
            let dest = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return dest.hasPrefix("/") ? dest : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
        }
        defer { free(r) }
        return String(cString: r)
    }

    private static func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { p in
            var done = 0
            while done < p.count {
                let n = write(fd, p.baseAddress! + done, p.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw EditorSaveError.cannotWrite(path: path, reason: String(cString: strerror(errno)))
                }
                done += n
            }
        }
    }

    private static func writeInPlace(_ data: Data, to target: String) throws -> EditorDiskStamp {
        let backup = NSTemporaryDirectory() + "/ycode-save-\(UInt64(getpid()))-\((target as NSString).lastPathComponent)"
        if let old = FileManager.default.contents(atPath: target) {
            guard FileManager.default.createFile(atPath: backup, contents: old) else {
                throw EditorSaveError.cannotWrite(path: target, reason: "no room for a backup copy")
            }
        }
        let fd = open(target, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { throw EditorSaveError.cannotWrite(path: target, reason: String(cString: strerror(errno))) }
        defer { close(fd) }
        try writeAll(fd, data, path: target)
        guard fsync(fd) == 0 else { throw EditorSaveError.cannotWrite(path: target, reason: String(cString: strerror(errno))) }
        guard FileManager.default.contents(atPath: target) == data else { throw EditorSaveError.verifyFailed(path: target) }
        try? FileManager.default.removeItem(atPath: backup)
        return stamp(path: target, data: data)
    }
}
