// PNG output and image headers. Written from the PNG specification (W3C,
// third edition), RFC 1950 (zlib) and RFC 1951 (DEFLATE); JPEG frame
// headers from ITU-T T.81 (B.2.2). Decoding of PNG and JPEG pixels is done
// by ThorVG's loaders (Rasterizer.swift).

import Foundation

public enum PNGCodec {
    /// Encodes premultiplied RGBA8 pixels as an 8-bit RGBA PNG (straight
    /// alpha, as PNG stores it).
    public static func encode(_ image: PixelImage) -> Data {
        let w = image.size.width, h = image.size.height
        let stride = w * 4
        // Un-premultiply, then filter each row (the filter with the smallest
        // sum of absolute values, the usual heuristic).
        var straight = image.rgba
        var i = 0
        while i < straight.count {
            let a = Int(straight[i + 3])
            if a != 0 && a != 255 {
                for k in 0..<3 { straight[i + k] = UInt8(min(255, (Int(straight[i + k]) * 255 + a / 2) / a)) }
            } else if a == 0 {
                straight[i] = 0
                straight[i + 1] = 0
                straight[i + 2] = 0
            }
            i += 4
        }
        var raw = [UInt8]()
        raw.reserveCapacity((stride + 1) * h)
        var row = [UInt8](repeating: 0, count: stride)
        var best = [UInt8](repeating: 0, count: stride)
        for y in 0..<h {
            let cur = y * stride, prev = (y - 1) * stride
            var bestType: UInt8 = 0, bestSum = Int.max
            for t: UInt8 in 0...4 {
                var sum = 0
                for x in 0..<stride {
                    let v = Int(straight[cur + x])
                    let left = x >= 4 ? Int(straight[cur + x - 4]) : 0
                    let up = y > 0 ? Int(straight[prev + x]) : 0
                    let ul = (y > 0 && x >= 4) ? Int(straight[prev + x - 4]) : 0
                    let pred: Int
                    switch t {
                    case 0: pred = 0
                    case 1: pred = left
                    case 2: pred = up
                    case 3: pred = (left + up) / 2
                    default: pred = paeth(left, up, ul)
                    }
                    let f = UInt8(truncatingIfNeeded: v - pred)
                    row[x] = f
                    sum += f < 128 ? Int(f) : 256 - Int(f)
                }
                if sum < bestSum {
                    bestSum = sum
                    bestType = t
                    swap(&row, &best)
                }
            }
            raw.append(bestType)
            raw.append(contentsOf: best)
        }
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = [UInt8]()
        ihdr += be32(UInt32(w))
        ihdr += be32(UInt32(h))
        ihdr += [8, 6, 0, 0, 0]
        chunk(&out, "IHDR", ihdr)
        chunk(&out, "IDAT", zlib(raw))
        chunk(&out, "IEND", [])
        return out
    }

    /// Decodes PNG bytes to premultiplied RGBA8.
    public static func decode(_ data: Data) -> PixelImage? { SoftwareRasterizer.decode(data, mime: "png") }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    private static func chunk(_ out: inout Data, _ type: String, _ body: [UInt8]) {
        out.append(contentsOf: be32(UInt32(body.count)))
        let t = Array(type.utf8)
        out.append(contentsOf: t)
        out.append(contentsOf: body)
        out.append(contentsOf: be32(crc32(t + body)))
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }

    // MARK: - zlib / DEFLATE (fixed Huffman codes, greedy LZ77 with hash chains)

    static func zlib(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var bits = BitWriter()
        bits.write(1, count: 1)        // BFINAL
        bits.write(1, count: 2)        // BTYPE = 01, fixed codes
        let n = data.count
        var head = [Int](repeating: -1, count: 1 << 15)
        var prevLink = [Int](repeating: -1, count: n)
        func hash(_ i: Int) -> Int {
            (Int(data[i]) << 10 ^ Int(data[i + 1]) << 5 ^ Int(data[i + 2])) & 0x7fff
        }
        func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            prevLink[i] = head[h]
            head[h] = i
        }
        var i = 0
        while i < n {
            var bestLen = 0, bestDist = 0
            if i + 2 < n {
                var cand = head[hash(i)]
                var tries = 64
                while cand >= 0, i - cand <= 32_768, tries > 0 {
                    var l = 0
                    let maxL = min(258, n - i)
                    while l < maxL && data[cand + l] == data[i + l] { l += 1 }
                    if l > bestLen {
                        bestLen = l
                        bestDist = i - cand
                        if l == maxL { break }
                    }
                    cand = prevLink[cand]
                    tries -= 1
                }
            }
            if bestLen >= 3 {
                writeLength(&bits, bestLen)
                writeDistance(&bits, bestDist)
                for k in 0..<bestLen { insert(i + k) }
                i += bestLen
            } else {
                writeLiteral(&bits, Int(data[i]))
                insert(i)
                i += 1
            }
        }
        writeLiteral(&bits, 256)
        out.append(contentsOf: bits.finish())
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        out.append(contentsOf: be32(b << 16 | a))
        return out
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var acc: UInt32 = 0
        var n: UInt32 = 0
        mutating func write(_ v: Int, count: Int) {
            acc |= UInt32(v) << n
            n += UInt32(count)
            while n >= 8 {
                bytes.append(UInt8(acc & 0xff))
                acc >>= 8
                n -= 8
            }
        }
        /// Huffman codes are written most significant bit first.
        mutating func writeCode(_ code: Int, length: Int) {
            var rev = 0
            for k in 0..<length { rev |= ((code >> k) & 1) << (length - 1 - k) }
            write(rev, count: length)
        }
        mutating func finish() -> [UInt8] {
            if n > 0 { bytes.append(UInt8(acc & 0xff)) }
            return bytes
        }
    }

    private static func writeLiteral(_ bits: inout BitWriter, _ v: Int) {
        switch v {
        case 0...143: bits.writeCode(0x30 + v, length: 8)
        case 144...255: bits.writeCode(0x190 + v - 144, length: 9)
        case 256...279: bits.writeCode(v - 256, length: 7)
        default: bits.writeCode(0xC0 + v - 280, length: 8)
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                   4097, 6145, 8193, 12_289, 16_385, 24_577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static func writeLength(_ bits: inout BitWriter, _ len: Int) {
        var k = lengthBase.count - 1
        while lengthBase[k] > len { k -= 1 }
        writeLiteral(&bits, 257 + k)
        if lengthExtra[k] > 0 { bits.write(len - lengthBase[k], count: lengthExtra[k]) }
    }

    private static func writeDistance(_ bits: inout BitWriter, _ dist: Int) {
        var k = distBase.count - 1
        while distBase[k] > dist { k -= 1 }
        bits.writeCode(k, length: 5)
        if distExtra[k] > 0 { bits.write(dist - distBase[k], count: distExtra[k]) }
    }
}

/// Image sizes read from file headers, without decoding.
public enum ImageHeader {
    public enum Format: Sendable { case png, jpeg }

    /// Format and pixel size of PNG or JPEG bytes.
    public static func inspect(_ data: Data) -> (Format, PixelSize)? {
        let b = [UInt8](data.prefix(64 * 1024))
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            let w = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
            let h = Int(b[20]) << 24 | Int(b[21]) << 16 | Int(b[22]) << 8 | Int(b[23])
            return (.png, PixelSize(width: w, height: h))
        }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 {
            var i = 2
            while i + 9 < b.count {
                guard b[i] == 0xFF else { i += 1; continue }
                let marker = b[i + 1]
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) || marker == 0xFF { i += marker == 0xFF ? 1 : 2; continue }
                let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
                // SOF0…SOF15 except DHT (C4), JPG (C8) and DAC (CC).
                if (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                    let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                    let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                    return (.jpeg, PixelSize(width: w, height: h))
                }
                i += 2 + len
            }
        }
        return nil
    }
}
