// XZ streams (the compressed chunks of a pbzx stream), decoded with the
// system's liblzma (public domain / 0BSD), loaded at run time: every Mac has
// it in /usr/lib and Linux distributions ship liblzma.so.5. Only its one-call
// buffer decoder is used, whose arguments are plain C types.

import Foundation
#if canImport(Glibc)
import Glibc
#endif

public enum XZ {
    typealias BufferDecode = @convention(c) (UnsafeMutablePointer<UInt64>, UInt32, UnsafeRawPointer?, UnsafePointer<UInt8>, UnsafeMutablePointer<Int>,
                                             Int, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<Int>, Int) -> Int32

    nonisolated(unsafe) static let decodeFunction: BufferDecode? = {
        #if os(macOS)
        let names = ["liblzma.5.dylib", "/usr/lib/liblzma.5.dylib"]
        #else
        let names = ["liblzma.so.5", "liblzma.so"]
        #endif
        for n in names {
            if let h = dlopen(n, RTLD_NOW | RTLD_LOCAL), let f = dlsym(h, "lzma_stream_buffer_decode") {
                return unsafeBitCast(f, to: BufferDecode.self)
            }
        }
        return nil
    }()

    public static var isAvailable: Bool { decodeFunction != nil }

    /// Decodes one complete .xz stream whose decoded size is known.
    public static func decode(_ input: [UInt8], size: Int) throws -> [UInt8] {
        guard let f = decodeFunction else { throw RuntimeDownloadError.expansion("liblzma (XZ) was not found on this computer") }
        var out = [UInt8](repeating: 0, count: max(size, 1))
        var memlimit = UInt64.max
        var inPos = 0, outPos = 0
        let r = input.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                f(&memlimit, 0, nil, i.baseAddress!, &inPos, input.count, o.baseAddress!, &outPos, size)
            }
        }
        guard r == 0, outPos == size else { throw RuntimeDownloadError.expansion("an XZ chunk did not decode (liblzma \(r), \(outPos) of \(size) bytes)") }
        if out.count != size { out.removeLast(out.count - size) }
        return out
    }
}

/// A pbzx stream: "pbzx", a big-endian 64-bit chunk size, then chunks of
/// (decoded size, stored size, bytes), each stored as is when the sizes are
/// equal, else as one XZ stream. Read as a byte source.
final class PBZXSource {
    let next: (Int) throws -> [UInt8]
    var pending: [UInt8] = []
    var offset = 0
    var started = false
    var done = false

    /// `read(n)` reads the pbzx bytes (an exact count, or fewer at the end).
    init(_ read: @escaping (Int) throws -> [UInt8]) { next = read }

    func exactly(_ n: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        while out.count < n {
            let more = try next(n - out.count)
            if more.isEmpty { break }
            out += more
        }
        return out
    }

    static func u64be(_ b: [UInt8], _ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 << 8 | UInt64(b[at + $1]) } }

    func read(_ n: Int) throws -> [UInt8] {
        if !started {
            started = true
            let head = try exactly(12)
            guard head.count == 12, Array(head[0..<4]) == Array("pbzx".utf8) else { throw RuntimeDownloadError.expansion("not a pbzx stream") }
        }
        while offset >= pending.count {
            if done { return [] }
            let h = try exactly(16)
            if h.isEmpty { done = true; return [] }
            guard h.count == 16 else { throw RuntimeDownloadError.expansion("a pbzx chunk header is cut short") }
            let size = Int(Self.u64be(h, 0)), stored = Int(Self.u64be(h, 8))
            guard size >= 0, stored >= 0, size <= 1 << 30, stored <= 1 << 30 else { throw RuntimeDownloadError.expansion("a pbzx chunk is too large") }
            let body = try exactly(stored)
            guard body.count == stored else { throw RuntimeDownloadError.expansion("a pbzx chunk is cut short") }
            pending = stored == size ? body : try XZ.decode(body, size: size)
            offset = 0
        }
        let k = min(n, pending.count - offset)
        let out = Array(pending[offset..<offset + k])
        offset += k
        return out
    }
}
