// A minimal PNG writer (PNG specification, RFC 2083: signature, IHDR,
// one IDAT of zlib-compressed filter-0 rows, IEND) for the viewer's
// screenshots of what it shows; zlib comes from CYcodeCodec.

import CYcodeCodec
import Foundation

public enum PNGWriter {
    /// RGBA rows (8 bits per channel, no padding) → PNG bytes; nil without zlib.
    public static func encode(rgba: [UInt8], width: Int, height: Int, level: Int32 = 6) -> [UInt8]? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        var raw = [UInt8]()
        raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height {
            raw.append(0)
            raw += rgba[(y * width * 4)..<((y + 1) * width * 4)]
        }
        var capacity = ycodec_zlib_bound(raw.count)
        guard capacity > 0 else { return nil }
        var compressed = [UInt8](repeating: 0, count: capacity)
        let ok = raw.withUnsafeBufferPointer { src in
            compressed.withUnsafeMutableBufferPointer { dst in
                ycodec_zlib_compress(src.baseAddress!, src.count, level, dst.baseAddress!, &capacity)
            }
        }
        guard ok == 0 else { return nil }
        compressed.removeLast(compressed.count - capacity)
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdr = [UInt8]()
        ihdr += be32(UInt32(width)) + be32(UInt32(height))
        ihdr += [8, 6, 0, 0, 0]  // 8-bit, RGBA, deflate, filter 0, no interlace
        chunk("IHDR", ihdr, into: &out)
        chunk("IDAT", compressed, into: &out)
        chunk("IEND", [], into: &out)
        return out
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    static func chunk(_ type: String, _ data: [UInt8], into out: inout [UInt8]) {
        out += be32(UInt32(data.count))
        let typed = Array(type.utf8) + data
        out += typed
        let crc = typed.withUnsafeBufferPointer { ycodec_crc32(0, $0.baseAddress!, $0.count) }
        out += be32(crc)
    }

    /// BGRX rows (any row stride) → RGBA rows.
    public static func rgba(fromBGRX p: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0xFF, count: width * height * 4)
        let s = p.assumingMemoryBound(to: UInt8.self)
        out.withUnsafeMutableBufferPointer { d in
            for y in 0..<height {
                let row = s + y * bytesPerRow
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    d[o] = row[x * 4 + 2]
                    d[o + 1] = row[x * 4 + 1]
                    d[o + 2] = row[x * 4]
                }
            }
        }
        return out
    }
}
