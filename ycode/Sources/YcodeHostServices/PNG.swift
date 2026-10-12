// A minimal PNG writer (public PNG specification, RFC 2083; zlib RFC 1950
// and deflate RFC 1951 "stored" blocks): 8-bit RGBA, filter 0, no
// compression. No external libraries, so it runs wherever ycode-simd does.

public enum PNG {
    /// An RGBA image (`rgba.count == width * height * 4`) as PNG bytes.
    public static func encode(width: Int, height: Int, rgba: [UInt8]) -> [UInt8] {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4)
        // Raw scanlines: filter byte 0, then the row.
        var raw: [UInt8] = []
        raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height {
            raw.append(0)
            raw += rgba[(y * width * 4)..<((y + 1) * width * 4)]
        }
        // zlib: header 0x78 0x01, stored blocks of at most 65 535 bytes, Adler-32.
        var z: [UInt8] = [0x78, 0x01]
        var at = 0
        repeat {
            let n = min(65535, raw.count - at)
            let last: UInt8 = at + n == raw.count ? 1 : 0
            z += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            z += raw[at..<(at + n)]
            at += n
        } while at < raw.count
        z += be32(adler32(raw))
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [8, 6, 0, 0, 0])
        out += chunk("IDAT", z)
        out += chunk("IEND", [])
        return out
    }

    /// Converts BGRA rows (`bytesPerRow` apart) to packed RGBA.
    public static func rgba(fromBGRA bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = y * bytesPerRow
            guard row + width * 4 <= bytes.count else { break }
            for x in 0..<width {
                let s = row + x * 4, d = (y * width + x) * 4
                out[d] = bytes[s + 2]
                out[d + 1] = bytes[s + 1]
                out[d + 2] = bytes[s]
                out[d + 3] = bytes[s + 3]
            }
        }
        return out
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let t = Array(type.utf8)
        return be32(UInt32(data.count)) + t + data + be32(crc32(t + data))
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let end = min(i + 5552, bytes.count)
            while i < end {
                a += UInt32(bytes[i])
                b += a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }
}
