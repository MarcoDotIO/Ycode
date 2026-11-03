import Foundation

/// The `.icns` container (publicly documented; `icon-compile.md` §3): the
/// magic `icns` and a big-endian total length, then entries of a four-byte
/// type, a big-endian length (header included) and the data.
public enum ICNS {
    /// The entry types by pixel size: PNG entries, except `ic04` (16 × 16)
    /// which holds ARGB.
    public static let types: [(type: String, pixels: Int)] = [
        ("ic04", 16), ("ic05", 32), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
        ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512),
    ]

    /// The default set `actool` writes: `ic13`, `ic11`, `ic04`, `ic07`.
    public static let defaultSet = ["ic13", "ic11", "ic04", "ic07"]
    /// `--standalone-icon-behavior all`: every size 16–1024.
    public static let fullSet = ["ic04", "ic05", "ic07", "ic08", "ic09", "ic10", "ic11", "ic12", "ic13", "ic14"]

    public static func pixels(for type: String) -> Int? { types.first { $0.type == type }?.pixels }

    /// Writes the entries `set`, each rendered from `image(pixels)`.
    public static func write(_ set: [String], image: (Int) -> Bitmap) -> Data {
        var w = ByteWriter()
        w.tag("icns")
        w.u32be(0)
        for t in set {
            guard let px = pixels(for: t) else { continue }
            let bmp = image(px).resized(width: px, height: px)
            let body = t == "ic04" ? argb(bmp) : [UInt8](PNG.encode(bmp))
            w.tag(t)
            w.u32be(UInt32(body.count + 8))
            w.append(body)
        }
        w.patchU32be(UInt32(w.count), at: 4)
        return Data(w.bytes)
    }

    /// `ARGB` then the A, R, G and B planes, each run-length coded (a byte
    /// below 0x80 copies that many plus one bytes; a byte from 0x80 repeats
    /// the next byte `n − 125` times).
    static func argb(_ bmp: Bitmap) -> [UInt8] {
        var out = Array("ARGB".utf8)
        for plane in [3, 0, 1, 2] {
            let values = stride(from: plane, to: bmp.rgba.count, by: 4).map { bmp.rgba[$0] }
            out += packBits(values)
        }
        return out
    }

    static func packBits(_ v: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        var literal: [UInt8] = []
        func flush() {
            var p = 0
            while p < literal.count {
                let n = min(128, literal.count - p)
                out.append(UInt8(n - 1))
                out += literal[p..<p + n]
                p += n
            }
            literal = []
        }
        while i < v.count {
            var run = 1
            while i + run < v.count, v[i + run] == v[i], run < 130 { run += 1 }
            if run >= 3 {
                flush()
                out += [UInt8(run + 125), v[i]]
                i += run
            } else {
                literal.append(v[i])
                i += 1
            }
        }
        flush()
        return out
    }

    /// The entries of an icns file (type and data), for tests and `info`.
    public static func entries(_ d: Data) -> [(type: String, data: [UInt8])] {
        let b = [UInt8](d)
        guard b.count >= 8, b.starts(with: Array("icns".utf8)) else { return [] }
        var out: [(String, [UInt8])] = []
        var i = 8
        while i + 8 <= b.count {
            let len = Int(b.u32be(at: i + 4))
            guard len >= 8, i + len <= b.count else { break }
            out.append((String(decoding: b[i..<i + 4], as: UTF8.self), Array(b[i + 8..<i + len])))
            i += len
        }
        return out
    }
}
