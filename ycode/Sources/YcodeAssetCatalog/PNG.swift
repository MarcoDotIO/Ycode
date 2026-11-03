import Foundation

/// An 8-bit RGBA bitmap with straight (not premultiplied) alpha, rows top
/// to bottom.
public struct Bitmap: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "RGBA size")
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// A bitmap filled with one colour (components 0–1).
    public init(width: Int, height: Int, fill: (r: Double, g: Double, b: Double, a: Double)) {
        self.width = width
        self.height = height
        let px = [fill.r, fill.g, fill.b, fill.a].map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        var b = [UInt8]()
        b.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { b += px }
        rgba = b
    }

    public var isOpaque: Bool { stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 255 } }

    /// Pixel bytes as `Assets.car` stores them: B, G, R, A with
    /// premultiplied alpha (`assets-car.md` §7.3).
    public var premultipliedBGRA: [UInt8] {
        var out = [UInt8](repeating: 0, count: rgba.count)
        rgba.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                var i = 0
                while i < s.count {
                    let a = UInt32(s[i + 3])
                    if a == 255 {
                        o[i] = s[i + 2]; o[i + 1] = s[i + 1]; o[i + 2] = s[i]
                    } else {
                        o[i] = UInt8((UInt32(s[i + 2]) * a + 127) / 255)
                        o[i + 1] = UInt8((UInt32(s[i + 1]) * a + 127) / 255)
                        o[i + 2] = UInt8((UInt32(s[i]) * a + 127) / 255)
                    }
                    o[i + 3] = UInt8(a)
                    i += 4
                }
            }
        }
        return out
    }

    /// The inverse of `premultipliedBGRA`.
    public init(width: Int, height: Int, premultipliedBGRA b: [UInt8]) {
        var out = [UInt8](repeating: 0, count: b.count)
        var i = 0
        while i < b.count {
            let a = UInt32(b[i + 3])
            if a == 255 || a == 0 {
                out[i] = b[i + 2]; out[i + 1] = b[i + 1]; out[i + 2] = b[i]
            } else {
                out[i] = UInt8(min(255, (UInt32(b[i + 2]) * 255 + a / 2) / a))
                out[i + 1] = UInt8(min(255, (UInt32(b[i + 1]) * 255 + a / 2) / a))
                out[i + 2] = UInt8(min(255, (UInt32(b[i]) * 255 + a / 2) / a))
            }
            out[i + 3] = UInt8(a)
            i += 4
        }
        self.init(width: width, height: height, rgba: out)
    }

    /// Resampled to `w` × `h`: an area average when shrinking, bilinear when
    /// growing, in premultiplied space so transparent edges stay clean.
    public func resized(width w: Int, height h: Int) -> Bitmap {
        if w == width && h == height { return self }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let sx = Double(width) / Double(w), sy = Double(height) / Double(h)
        func px(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            let a = Double(rgba[i + 3]) / 255
            return (Double(rgba[i]) * a, Double(rgba[i + 1]) * a, Double(rgba[i + 2]) * a, a)
        }
        for y in 0..<h {
            for x in 0..<w {
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0
                if sx >= 1 && sy >= 1 {
                    let x0 = Int(Double(x) * sx), x1 = max(x0 + 1, Int(Double(x + 1) * sx))
                    let y0 = Int(Double(y) * sy), y1 = max(y0 + 1, Int(Double(y + 1) * sy))
                    for yy in y0..<min(y1, height) {
                        for xx in x0..<min(x1, width) {
                            let p = px(xx, yy)
                            r += p.0; g += p.1; b += p.2; a += p.3
                        }
                    }
                    let n = Double((min(x1, width) - x0) * (min(y1, height) - y0))
                    r /= n; g /= n; b /= n; a /= n
                } else {
                    let fx = (Double(x) + 0.5) * sx - 0.5, fy = (Double(y) + 0.5) * sy - 0.5
                    let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                    let tx = fx - Double(x0), ty = fy - Double(y0)
                    for (dx, dy, wgt) in [(0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)), (0, 1, (1 - tx) * ty), (1, 1, tx * ty)] {
                        let p = px(x0 + dx, y0 + dy)
                        r += p.0 * wgt; g += p.1 * wgt; b += p.2 * wgt; a += p.3 * wgt
                    }
                }
                let o = (y * w + x) * 4
                if a > 0 {
                    out[o] = UInt8(min(255, (r / a).rounded()))
                    out[o + 1] = UInt8(min(255, (g / a).rounded()))
                    out[o + 2] = UInt8(min(255, (b / a).rounded()))
                }
                out[o + 3] = UInt8(min(255, (a * 255).rounded()))
            }
        }
        return Bitmap(width: w, height: h, rgba: out)
    }

    /// The bitmap drawn over an opaque colour (the loose iOS PNGs and the
    /// flattened iOS icons are opaque, `icon-compile.md` §3, §5).
    public func flattened(onto bg: (r: Double, g: Double, b: Double)) -> Bitmap {
        var out = rgba
        let bgc = [bg.r, bg.g, bg.b].map { min(max($0, 0), 1) * 255 }
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = Double(out[i + 3]) / 255
            for c in 0..<3 { out[i + c] = UInt8((Double(out[i + c]) * a + bgc[c] * (1 - a)).rounded()) }
            out[i + 3] = 255
        }
        return Bitmap(width: width, height: height, rgba: out)
    }
}

/// PNG reading and writing (ISO/IEC 15948, the W3C PNG specification).
public enum PNG {
    public struct DecodeError: Error, CustomStringConvertible {
        public var message: String
        public var description: String { "PNG: \(message)" }
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func isPNG(_ data: Data) -> Bool { data.prefix(8).elementsEqual(signature) }

    /// Decodes every standard colour type and bit depth, palette
    /// transparency, and Adam7 interlacing. Apple's "CgBI" variant (BGR,
    /// premultiplied, raw DEFLATE) is decoded too.
    public static func decode(_ data: Data) throws -> Bitmap {
        let b = [UInt8](data)
        guard b.starts(with: signature) else { throw DecodeError(message: "not a PNG file") }
        var i = 8
        var width = 0, height = 0, depth = 0, colorType = 0, interlace = 0
        var palette: [UInt8] = [], trns: [UInt8] = []
        var idat: [UInt8] = []
        var cgbi = false
        while i + 12 <= b.count {
            let len = Int(b.u32be(at: i))
            let type = String(decoding: b[i + 4..<i + 8], as: UTF8.self)
            guard i + 12 + len <= b.count else { throw DecodeError(message: "chunk \(type) past the end") }
            let body = Array(b[i + 8..<i + 8 + len])
            switch type {
            case "CgBI": cgbi = true
            case "IHDR":
                guard len >= 13 else { throw DecodeError(message: "short IHDR") }
                width = Int(body.u32be(at: 0))
                height = Int(body.u32be(at: 4))
                depth = Int(body[8])
                colorType = Int(body[9])
                interlace = Int(body[12])
            case "PLTE": palette = body
            case "tRNS": trns = body
            case "IDAT": idat += body
            case "IEND": i = b.count
            default: break
            }
            i += 12 + len
        }
        guard width > 0, height > 0, width * height <= 1 << 28 else { throw DecodeError(message: "bad size \(width)x\(height)") }
        let channels: Int
        switch colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: throw DecodeError(message: "colour type \(colorType)")
        }
        guard [1, 2, 4, 8, 16].contains(depth) else { throw DecodeError(message: "bit depth \(depth)") }
        let raw: [UInt8]
        if cgbi { raw = try Inflate.inflate(idat, from: 0) } else { raw = try Zlib.decompress(idat) }
        let bpp = max(1, channels * depth / 8)   // bytes per complete pixel, for filtering
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var pos = 0

        func pass(_ x0: Int, _ y0: Int, _ dx: Int, _ dy: Int) throws {
            let pw = (width - x0 + dx - 1) / dx, ph = (height - y0 + dy - 1) / dy
            guard pw > 0, ph > 0 else { return }
            let rowBytes = (pw * channels * depth + 7) / 8
            var prev = [UInt8](repeating: 0, count: rowBytes)
            for row in 0..<ph {
                guard pos + 1 + rowBytes <= raw.count else { throw DecodeError(message: "image data too short") }
                let filter = raw[pos]
                var cur = Array(raw[pos + 1..<pos + 1 + rowBytes])
                pos += 1 + rowBytes
                for k in 0..<rowBytes {
                    let a = k >= bpp ? Int(cur[k - bpp]) : 0, up = Int(prev[k]), c = k >= bpp ? Int(prev[k - bpp]) : 0
                    let v: Int
                    switch filter {
                    case 0: v = 0
                    case 1: v = a
                    case 2: v = up
                    case 3: v = (a + up) / 2
                    case 4:
                        let p = a + up - c, pa = abs(p - a), pb = abs(p - up), pc = abs(p - c)
                        v = pa <= pb && pa <= pc ? a : pb <= pc ? up : c
                    default: throw DecodeError(message: "filter \(filter)")
                    }
                    cur[k] = UInt8((Int(cur[k]) + v) & 0xFF)
                }
                prev = cur
                let y = y0 + row * dy
                for col in 0..<pw {
                    let x = x0 + col * dx
                    func sample(_ ch: Int) -> Int {
                        if depth == 16 { return Int(cur[(col * channels + ch) * 2]) }
                        if depth == 8 { return Int(cur[col * channels + ch]) }
                        let bit = (col * channels + ch) * depth
                        let v = Int(cur[bit / 8]) >> (8 - depth - bit % 8) & ((1 << depth) - 1)
                        return colorType == 3 ? v : v * 255 / ((1 << depth) - 1)
                    }
                    func rawSample(_ ch: Int) -> Int {
                        if depth == 16 { return Int(cur[(col * channels + ch) * 2]) << 8 | Int(cur[(col * channels + ch) * 2 + 1]) }
                        let bit = (col * channels + ch) * depth
                        return depth == 8 ? Int(cur[col * channels + ch]) : Int(cur[bit / 8]) >> (8 - depth - bit % 8) & ((1 << depth) - 1)
                    }
                    var r = 0, g = 0, bl = 0, al = 255
                    switch colorType {
                    case 0:
                        r = sample(0); g = r; bl = r
                        if trns.count >= 2, rawSample(0) == Int(trns.u16be(at: 0)) { al = 0 }
                    case 2:
                        r = sample(0); g = sample(1); bl = sample(2)
                        if trns.count >= 6, rawSample(0) == Int(trns.u16be(at: 0)), rawSample(1) == Int(trns.u16be(at: 2)),
                           rawSample(2) == Int(trns.u16be(at: 4)) { al = 0 }
                    case 3:
                        let idx = sample(0)
                        guard idx * 3 + 2 < palette.count else { throw DecodeError(message: "palette index \(idx)") }
                        r = Int(palette[idx * 3]); g = Int(palette[idx * 3 + 1]); bl = Int(palette[idx * 3 + 2])
                        al = idx < trns.count ? Int(trns[idx]) : 255
                    case 4:
                        r = sample(0); g = r; bl = r; al = sample(1)
                    default:
                        r = sample(0); g = sample(1); bl = sample(2); al = sample(3)
                    }
                    let o = (y * width + x) * 4
                    out[o] = UInt8(r); out[o + 1] = UInt8(g); out[o + 2] = UInt8(bl); out[o + 3] = UInt8(al)
                }
            }
        }

        if interlace == 1 {
            for (x0, y0, dx, dy) in [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)] {
                try pass(x0, y0, dx, dy)
            }
        } else {
            try pass(0, 0, 1, 1)
        }
        if cgbi {
            // CgBI pixels are B, G, R, A, premultiplied.
            return Bitmap(width: width, height: height, premultipliedBGRA: out)
        }
        return Bitmap(width: width, height: height, rgba: out)
    }

    /// An ordinary PNG: RGBA (or RGB when opaque and `dropAlpha`), 8-bit,
    /// filter "up" on every row, with an sRGB chunk.
    public static func encode(_ bmp: Bitmap, dropAlpha: Bool = false) -> Data {
        let rgb = dropAlpha && bmp.isOpaque
        let ch = rgb ? 3 : 4
        let rowBytes = bmp.width * ch
        var raw = [UInt8]()
        raw.reserveCapacity((rowBytes + 1) * bmp.height)
        var prev = [UInt8](repeating: 0, count: rowBytes)
        for y in 0..<bmp.height {
            var row = [UInt8]()
            row.reserveCapacity(rowBytes)
            let base = y * bmp.width * 4
            for x in 0..<bmp.width {
                let o = base + x * 4
                row += rgb ? [bmp.rgba[o], bmp.rgba[o + 1], bmp.rgba[o + 2]] : Array(bmp.rgba[o..<o + 4])
            }
            raw.append(2)
            for k in 0..<rowBytes { raw.append(row[k] &- prev[k]) }
            prev = row
        }
        var w = ByteWriter()
        w.append(signature)
        func chunk(_ type: String, _ body: [UInt8]) {
            w.u32be(UInt32(body.count))
            let t = Array(type.utf8)
            w.append(t)
            w.append(body)
            w.u32be(CRC32.checksum(t + body))
        }
        var ihdr = ByteWriter()
        ihdr.u32be(UInt32(bmp.width))
        ihdr.u32be(UInt32(bmp.height))
        ihdr.append([8, rgb ? 2 : 6, 0, 0, 0])
        chunk("IHDR", ihdr.bytes)
        chunk("sRGB", [0])
        chunk("IDAT", Zlib.compress(raw))
        chunk("IEND", [])
        return Data(w.bytes)
    }
}
