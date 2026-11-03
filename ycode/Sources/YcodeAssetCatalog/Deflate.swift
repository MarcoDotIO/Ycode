import Foundation

/// zlib streams (RFC 1950) with DEFLATE data (RFC 1951), for PNG. Portable
/// Swift, so PNG reading and writing work the same on Linux and macOS.
enum Zlib {
    struct DecodeError: Error, CustomStringConvertible {
        var message: String
        var description: String { "zlib: \(message)" }
    }

    static func adler32(_ b: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, s: UInt32 = 0
        var i = 0
        while i < b.count {
            let end = min(i + 5552, b.count)
            while i < end {
                a &+= UInt32(b[i])
                s &+= a
                i += 1
            }
            a %= 65521
            s %= 65521
        }
        return s << 16 | a
    }

    static func decompress(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count >= 2, (UInt16(b[0]) << 8 | UInt16(b[1])) % 31 == 0, b[0] & 0x0F == 8 else { throw DecodeError(message: "bad header") }
        guard b[1] & 0x20 == 0 else { throw DecodeError(message: "preset dictionary") }
        return try Inflate.inflate(b, from: 2)
    }

    /// Fixed-Huffman DEFLATE with a greedy LZ77 matcher (level "fast"), or
    /// stored blocks when that is smaller.
    static func compress(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x5E]
        let fixed = Deflate.fixedHuffman(input)
        if fixed.count < input.count + input.count / 65535 * 5 + 5 {
            out += fixed
        } else {
            out += Deflate.stored(input)
        }
        let a = adler32(input)
        out += [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)]
        return out
    }
}

enum Inflate {
    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []
        init(lengths: [Int]) throws {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offs = [Int](repeating: 0, count: 16)
            for k in 1..<16 { offs[k] = offs[k - 1] + counts[k - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (s, l) in lengths.enumerated() where l != 0 {
                symbols[offs[l]] = s
                offs[l] += 1
            }
        }
    }

    struct Bits {
        let b: [UInt8]
        var pos: Int
        var bitBuf: UInt32 = 0
        var bitCnt = 0
        mutating func need(_ n: Int) throws -> UInt32 {
            while bitCnt < n {
                guard pos < b.count else { throw Zlib.DecodeError(message: "unexpected end of data") }
                bitBuf |= UInt32(b[pos]) << UInt32(bitCnt)
                pos += 1
                bitCnt += 8
            }
            let v = bitBuf & ((1 << UInt32(n)) - 1)
            bitBuf >>= UInt32(n)
            bitCnt -= n
            return v
        }
        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= Int(try need(1))
                let count = h.counts[len]
                if code - count < first { return h.symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Zlib.DecodeError(message: "bad Huffman code")
        }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                           4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static func inflate(_ b: [UInt8], from start: Int) throws -> [UInt8] {
        var s = Bits(b: b, pos: start)
        var out: [UInt8] = []
        out.reserveCapacity(b.count * 4)
        let fixedLit = try Huffman(lengths: (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })
        let fixedDist = try Huffman(lengths: [Int](repeating: 5, count: 30))
        var last = false
        while !last {
            last = try s.need(1) == 1
            switch try s.need(2) {
            case 0:
                s.bitBuf = 0
                s.bitCnt = 0
                guard s.pos + 4 <= b.count else { throw Zlib.DecodeError(message: "stored block past the end") }
                let len = Int(b[s.pos]) | Int(b[s.pos + 1]) << 8
                s.pos += 4
                guard s.pos + len <= b.count else { throw Zlib.DecodeError(message: "stored block past the end") }
                out += b[s.pos..<s.pos + len]
                s.pos += len
            case 1:
                try codes(&s, &out, fixedLit, fixedDist)
            case 2:
                let nlen = Int(try s.need(5)) + 257, ndist = Int(try s.need(5)) + 1, ncode = Int(try s.need(4)) + 4
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var cl = [Int](repeating: 0, count: 19)
                for k in 0..<ncode { cl[order[k]] = Int(try s.need(3)) }
                let clh = try Huffman(lengths: cl)
                var lengths: [Int] = []
                while lengths.count < nlen + ndist {
                    let sym = try s.decode(clh)
                    switch sym {
                    case 0..<16: lengths.append(sym)
                    case 16:
                        guard let p = lengths.last else { throw Zlib.DecodeError(message: "repeat without a length") }
                        lengths += [Int](repeating: p, count: 3 + Int(try s.need(2)))
                    case 17: lengths += [Int](repeating: 0, count: 3 + Int(try s.need(3)))
                    default: lengths += [Int](repeating: 0, count: 11 + Int(try s.need(7)))
                    }
                }
                guard lengths.count == nlen + ndist else { throw Zlib.DecodeError(message: "bad code lengths") }
                try codes(&s, &out, try Huffman(lengths: Array(lengths[0..<nlen])), try Huffman(lengths: Array(lengths[nlen...])))
            default:
                throw Zlib.DecodeError(message: "bad block type")
            }
        }
        return out
    }

    static func codes(_ s: inout Bits, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try s.decode(lit)
            if sym < 256 { out.append(UInt8(sym)); continue }
            if sym == 256 { return }
            let li = sym - 257
            guard li < 29 else { throw Zlib.DecodeError(message: "bad length symbol") }
            let len = lengthBase[li] + Int(try s.need(lengthExtra[li]))
            let di = try s.decode(dist)
            guard di < 30 else { throw Zlib.DecodeError(message: "bad distance symbol") }
            let d = distBase[di] + Int(try s.need(distExtra[di]))
            guard d <= out.count else { throw Zlib.DecodeError(message: "distance too far back") }
            for _ in 0..<len { out.append(out[out.count - d]) }
        }
    }
}

enum Deflate {
    static func stored(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var p = 0
        repeat {
            let n = min(65535, input.count - p)
            let last: UInt8 = p + n == input.count ? 1 : 0
            out += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += input[p..<p + n]
            p += n
        } while p < input.count
        return out
    }

    struct BitWriter {
        var out: [UInt8] = []
        var buf: UInt32 = 0
        var cnt = 0
        mutating func put(_ v: UInt32, _ n: Int) {
            buf |= v << UInt32(cnt)
            cnt += n
            while cnt >= 8 {
                out.append(UInt8(buf & 0xFF))
                buf >>= 8
                cnt -= 8
            }
        }
        /// Huffman codes go most-significant bit first.
        mutating func code(_ c: UInt32, _ n: Int) {
            var r: UInt32 = 0
            for k in 0..<n { r |= ((c >> UInt32(k)) & 1) << UInt32(n - 1 - k) }
            put(r, n)
        }
        mutating func flush() {
            if cnt > 0 { out.append(UInt8(buf & 0xFF)) }
            buf = 0
            cnt = 0
        }
    }

    static func literal(_ w: inout BitWriter, _ sym: Int) {
        switch sym {
        case 0..<144: w.code(UInt32(0x30 + sym), 8)
        case 144..<256: w.code(UInt32(0x190 + sym - 144), 9)
        case 256..<280: w.code(UInt32(sym - 256), 7)
        default: w.code(UInt32(0xC0 + sym - 280), 8)
        }
    }

    static func fixedHuffman(_ input: [UInt8]) -> [UInt8] {
        var w = BitWriter()
        w.out.reserveCapacity(input.count / 2 + 16)
        w.put(1, 1)   // last block
        w.put(1, 2)   // fixed Huffman
        let n = input.count
        var table = [Int32](repeating: -1, count: 1 << 15)
        var i = 0
        input.withUnsafeBufferPointer { src in
            while i < n {
                var len = 0, dist = 0
                if i + 3 <= n {
                    let h = Int(((UInt32(src[i]) << 16 | UInt32(src[i + 1]) << 8 | UInt32(src[i + 2])) &* 2_654_435_761) >> 17)
                    let c = Int(table[h])
                    table[h] = Int32(i)
                    if c >= 0, i - c <= 32768, src[c] == src[i], src[c + 1] == src[i + 1], src[c + 2] == src[i + 2] {
                        len = 3
                        while len < 258, i + len < n, src[c + len] == src[i + len] { len += 1 }
                        dist = i - c
                    }
                }
                if len >= 3 {
                    var li = 0
                    while li < 28, Inflate.lengthBase[li + 1] <= len { li += 1 }
                    literal(&w, 257 + li)
                    w.put(UInt32(len - Inflate.lengthBase[li]), Inflate.lengthExtra[li])
                    var di = 0
                    while di < 29, Inflate.distBase[di + 1] <= dist { di += 1 }
                    w.code(UInt32(di), 5)
                    w.put(UInt32(dist - Inflate.distBase[di]), Inflate.distExtra[di])
                    i += len
                } else {
                    literal(&w, Int(src[i]))
                    i += 1
                }
            }
        }
        literal(&w, 256)
        w.flush()
        return w.out
    }
}

/// CRC-32 (ISO-HDLC), for PNG chunks.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func checksum<S: Sequence>(_ b: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in b { c = table[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
