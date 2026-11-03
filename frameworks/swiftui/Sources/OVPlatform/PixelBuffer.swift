import Foundation

/// An 8-bit RGBA image (non-premultiplied, rows top to bottom): the frame a
/// software renderer hands to a window and what a readback returns.
public struct PixelBuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width × height × 4` bytes, R G B A.
    public var bytes: [UInt8]

    public init(width: Int, height: Int, fill: RGBA8 = RGBA8(r: 0, g: 0, b: 0, a: 255)) {
        self.width = max(0, width)
        self.height = max(0, height)
        bytes = [UInt8](repeating: 0, count: self.width * self.height * 4)
        if fill != RGBA8(r: 0, g: 0, b: 0, a: 0) { fillRect(x: 0, y: 0, width: self.width, height: self.height, fill) }
    }

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "pixel data size")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public subscript(x: Int, y: Int) -> RGBA8 {
        get {
            let i = (y * width + x) * 4
            return RGBA8(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            bytes[i] = newValue.r
            bytes[i + 1] = newValue.g
            bytes[i + 2] = newValue.b
            bytes[i + 3] = newValue.a
        }
    }

    /// Fills a pixel rectangle (clipped), blending with source-over when the
    /// colour is translucent.
    public mutating func fillRect(x: Int, y: Int, width w: Int, height h: Int, _ c: RGBA8) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        let a = Int(c.a)
        bytes.withUnsafeMutableBufferPointer { p in
            for yy in y0..<y1 {
                var i = (yy * width + x0) * 4
                for _ in x0..<x1 {
                    if a == 255 {
                        p[i] = c.r; p[i + 1] = c.g; p[i + 2] = c.b; p[i + 3] = 255
                    } else if a > 0 {
                        p[i] = UInt8((Int(c.r) * a + Int(p[i]) * (255 - a)) / 255)
                        p[i + 1] = UInt8((Int(c.g) * a + Int(p[i + 1]) * (255 - a)) / 255)
                        p[i + 2] = UInt8((Int(c.b) * a + Int(p[i + 2]) * (255 - a)) / 255)
                        p[i + 3] = UInt8(min(255, a + Int(p[i + 3]) * (255 - a) / 255))
                    }
                    i += 4
                }
            }
        }
    }

    /// Fills the pixels whose centres lie inside an ellipse inscribed in a
    /// pixel rectangle.
    public mutating func fillEllipse(x: Double, y: Double, width w: Double, height h: Double, _ c: RGBA8) {
        guard w > 0, h > 0 else { return }
        let cx = x + w / 2, cy = y + h / 2, rx = w / 2, ry = h / 2
        let y0 = max(0, Int(y.rounded(.down))), y1 = min(height, Int((y + h).rounded(.up)))
        for yy in y0..<y1 {
            let dy = (Double(yy) + 0.5 - cy) / ry
            let span = 1 - dy * dy
            guard span > 0 else { continue }
            let dx = span.squareRoot() * rx
            let xs = Int((cx - dx).rounded()), xe = Int((cx + dx).rounded())
            fillRect(x: xs, y: yy, width: xe - xs, height: 1, c)
        }
    }

    /// PNG encoding (8-bit RGBA, stored deflate blocks: no compression, but
    /// valid for every reader; written from the PNG and zlib specifications).
    public func pngData() -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity(height * (width * 4 + 1))
        for y in 0..<height {
            raw.append(0)
            raw.append(contentsOf: bytes[(y * width * 4)..<((y + 1) * width * 4)])
        }
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = [UInt8]()
        ihdr += PNG.be32(UInt32(width)) + PNG.be32(UInt32(height))
        ihdr += [8, 6, 0, 0, 0]
        PNG.chunk("IHDR", ihdr, into: &out)
        PNG.chunk("IDAT", PNG.zlibStored(raw), into: &out)
        PNG.chunk("IEND", [], into: &out)
        return out
    }

    public func writePNG(to url: URL) throws {
        try pngData().write(to: url)
    }
}

/// One 8-bit RGBA colour.
public struct RGBA8: Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// From components in 0…1 (sRGB).
    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: q(red), g: q(green), b: q(blue), a: q(opacity))
    }
}

private enum PNG {
    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func chunk(_ type: String, _ data: [UInt8], into out: inout Data) {
        let t = Array(type.utf8)
        out.append(contentsOf: be32(UInt32(data.count)))
        out.append(contentsOf: t)
        out.append(contentsOf: data)
        out.append(contentsOf: be32(crc32(t + data)))
    }

    /// A zlib stream of stored (uncompressed) deflate blocks.
    static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65_535, data.count - i)
            let final: UInt8 = i + n >= data.count ? 1 : 0
            out.append(final)
            out += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out.append(contentsOf: data[i..<(i + n)])
            i += n
        } while i < data.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        out += be32((b << 16) | a)
        return out
    }
}
