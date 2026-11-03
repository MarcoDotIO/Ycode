import Foundation
#if canImport(Compression)
import Compression
#endif

/// LZFSE streams as `Assets.car` uses them (`specs/formats/assets-car.md`
/// §7.3, §7.4). The format is public: Apple's open-source reference
/// implementation (github.com/lzfse/lzfse, BSD-3-Clause) defines it, and
/// this file follows the block layout and opcode table that reference
/// documents. No code is taken from it.
///
/// A stream is a list of blocks, each starting with a four-byte magic:
/// `bvx$` ends the stream, `bvx-` holds raw bytes (`u32 size`, bytes),
/// `bvxn` holds LZVN-coded bytes (`u32 decoded size`, `u32 payload size`,
/// payload). `bvx1`/`bvx2` (the FSE-coded blocks) are not written; they are
/// read only through the system library on macOS.
///
/// Ycode writes LZVN blocks (or a raw block when that is smaller) with its
/// own encoder, so the same input gives the same bytes on every platform.
public enum LZFSE {
    static let endMagic: [UInt8] = Array("bvx$".utf8)
    static let rawMagic: [UInt8] = Array("bvx-".utf8)
    static let lzvnMagic: [UInt8] = Array("bvxn".utf8)

    public struct DecodeError: Error, CustomStringConvertible {
        public var message: String
        public var description: String { "LZFSE: \(message)" }
    }

    /// The largest block Ycode writes, in decoded bytes. CoreUI decoded
    /// only the first 782,336 bytes of a single 1.4 MB LZVN block (the rest
    /// of the image stayed black, on macOS and on iOS), so long inputs are
    /// cut into independent blocks.
    public static let blockSize = 64 * 1024

    /// The input in independent blocks of at most `blockSize` bytes, each an
    /// LZVN block (or a raw block when that is smaller), then the end marker.
    public static func encode(_ input: [UInt8], blockSize: Int = LZFSE.blockSize) -> [UInt8] {
        var w = ByteWriter(capacity: input.count / 8 + 64)
        var p = 0
        repeat {
            let piece = Array(input[p..<min(p + blockSize, input.count)])
            let payload = LZVN.encode(piece)
            if payload.count + 12 < piece.count + 8 {
                w.append(lzvnMagic)
                w.u32le(UInt32(piece.count))
                w.u32le(UInt32(payload.count))
                w.append(payload)
            } else {
                w.append(rawMagic)
                w.u32le(UInt32(piece.count))
                w.append(piece)
            }
            p += piece.count
        } while p < input.count
        w.append(endMagic)
        return w.bytes
    }

    /// Decodes a stream. `expectedSize`, when known, lets the system library
    /// decode FSE blocks on macOS.
    public static func decode(_ input: ArraySlice<UInt8>, expectedSize: Int? = nil) throws -> [UInt8] {
        var out: [UInt8] = []
        if let expectedSize { out.reserveCapacity(expectedSize) }
        let b = Array(input)
        var i = 0
        while true {
            guard i + 4 <= b.count else { throw DecodeError(message: "stream without an end marker") }
            let magic = Array(b[i..<i + 4])
            switch magic {
            case endMagic:
                return out
            case rawMagic:
                let n = Int(b.u32le(at: i + 4))
                guard i + 8 + n <= b.count else { throw DecodeError(message: "raw block past the end") }
                out += b[i + 8..<i + 8 + n]
                i += 8 + n
            case lzvnMagic:
                let n = Int(b.u32le(at: i + 4)), p = Int(b.u32le(at: i + 8))
                guard i + 12 + p <= b.count else { throw DecodeError(message: "LZVN block past the end") }
                try LZVN.decode(b[i + 12..<i + 12 + p], into: &out, expected: n)
                i += 12 + p
            default:
                #if canImport(Compression)
                return try systemDecode(b, expectedSize: expectedSize)
                #else
                throw DecodeError(message: "block \(String(decoding: magic, as: UTF8.self)) needs the FSE decoder (macOS only)")
                #endif
            }
        }
    }

    #if canImport(Compression)
    /// The system's decoder, for FSE blocks written by other tools.
    static func systemDecode(_ b: [UInt8], expectedSize: Int?) throws -> [UInt8] {
        var capacity = max(expectedSize ?? 0, b.count * 8, 1 << 16)
        while capacity <= 1 << 30 {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = out.withUnsafeMutableBufferPointer { o in
                b.withUnsafeBufferPointer { s in
                    compression_decode_buffer(o.baseAddress!, capacity, s.baseAddress!, b.count, nil, COMPRESSION_LZFSE)
                }
            }
            if n == 0 { throw DecodeError(message: "the system decoder rejected the stream") }
            if n < capacity || expectedSize == n {
                out.removeLast(capacity - n)
                return out
            }
            capacity *= 4
        }
        throw DecodeError(message: "stream too large")
    }
    #endif
}

/// The LZVN block coding (opcode table of the LZFSE reference decoder).
///
///     sml_d  LLMMMDDD DDDDDDDD          L literals, M+3 match, 11-bit distance (DDD < 6)
///     med_d  101LLMMM DDDDDDMM DDDDDDDD  L literals, 5-bit M+3 match, 14-bit distance
///     lrg_d  LLMMM111 DDDDDDDD DDDDDDDD  L literals, M+3 match, 16-bit distance
///     pre_d  LLMMM110                   L ≥ 1 literals, M+3 match, previous distance
///     sml_l  1110LLLL, lrg_l 11100000 L  literals 1–15, 16–271
///     sml_m  1111MMMM, lrg_m 11110000 M  match 1–15, 16–271 at the previous distance
///     eos    00000110 (then 7 zero bytes), nop 0x0E 0x16
///
/// L is two bits (0–3) in the distance opcodes, but the longest match each
/// L allows is 10, 8, 6 and 4: with L = 1 the patterns 0x70–0x7F are not
/// distance opcodes (the system decoder on macOS rejects them; found by
/// probing it with our own streams), with L = 2 the patterns 0xA0–0xBF are
/// med_d, with L = 3 the patterns 0xD0–0xFF are undefined or literal and
/// match opcodes.
enum LZVN {
    static func maxShortMatch(literals l: Int) -> Int { [10, 8, 6, 4][l] }

    static func encode(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count / 16 + 32)
        let n = input.count
        input.withUnsafeBufferPointer { src in
            var table = [Int32](repeating: -1, count: 1 << 14)
            var anchor = 0          // first byte not yet emitted
            var i = 0
            var prevD = 0
            @inline(__always) func hash(_ p: Int) -> Int {
                let v = UInt32(src[p]) | UInt32(src[p + 1]) << 8 | UInt32(src[p + 2]) << 16 | UInt32(src[p + 3]) << 24
                return Int((v &* 2_654_435_761) >> 18)
            }
            while i + 4 <= n {
                let h = hash(i)
                let cand = Int(table[h])
                table[h] = Int32(i)
                var d = 0, m = 0
                // Prefer the previous distance (cheap opcodes), then the hash candidate.
                if prevD > 0, i - prevD >= 0, src[i] == src[i - prevD], src[i + 1] == src[i + 1 - prevD], src[i + 2] == src[i + 2 - prevD] {
                    d = prevD
                } else if cand >= 0, i - cand <= 0xFFFF, i - cand > 0,
                          src[cand] == src[i], src[cand + 1] == src[i + 1], src[cand + 2] == src[i + 2] {
                    d = i - cand
                }
                if d > 0 {
                    m = 3
                    while i + m < n, src[i + m] == src[i + m - d] { m += 1 }
                }
                guard m >= 3 else { i += 1; continue }
                emit(literals: anchor, i, match: m, distance: d, prevD: &prevD, src: src, out: &out)
                let end = i + m
                // Index a few positions inside the match.
                var k = i + 1
                while k < end, k + 4 <= n, k < i + 8 {
                    table[hash(k)] = Int32(k)
                    k += 1
                }
                i = end
                anchor = end
            }
            emitLiterals(anchor, n, src: src, out: &out)
        }
        out += [0x06, 0, 0, 0, 0, 0, 0, 0]
        return out
    }

    static func emitLiterals(_ from: Int, _ to: Int, src: UnsafeBufferPointer<UInt8>, out: inout [UInt8]) {
        var p = from
        while p < to {
            let l = min(to - p, 271)
            if l >= 16 { out += [0xE0, UInt8(l - 16)] } else { out.append(0xE0 | UInt8(l)) }
            out += src[p..<p + l]
            p += l
        }
    }

    static func emitMatchTail(_ m: Int, out: inout [UInt8]) {
        var r = m
        while r > 0 {
            let k = min(r, 271)
            if k >= 16 { out += [0xF0, UInt8(k - 16)] } else { out.append(0xF0 | UInt8(k)) }
            r -= k
        }
    }

    /// The literals `[from, to)` and a match of `m` bytes at distance `d`.
    static func emit(literals from: Int, _ to: Int, match m: Int, distance d: Int, prevD: inout Int,
                     src: UnsafeBufferPointer<UInt8>, out: inout [UInt8]) {
        var litStart = from
        var l = to - from
        if l > 3 {
            emitLiterals(from, to, src: src, out: &out)
            litStart = to
            l = 0
        }
        let lits = src[litStart..<to]
        if d == prevD, l == 0 {
            emitMatchTail(m, out: &out)
            return
        }
        let first: Int
        let L = UInt8(l)
        if d == prevD {
            // pre_d (L ≥ 1 here)
            first = min(m, maxShortMatch(literals: l))
            out.append(L << 6 | UInt8(first - 3) << 3 | 6)
            out += lits
        } else if d < 0x600, m <= maxShortMatch(literals: l) {
            first = m
            out += [L << 6 | UInt8(first - 3) << 3 | UInt8(d >> 8), UInt8(d & 0xFF)]
            out += lits
        } else if d < 0x4000 {
            // med_d: 101LLMMM, then u16 (D << 2 | M low bits)
            first = min(m, 34)
            let mm = first - 3
            let w = UInt16(d) << 2 | UInt16(mm & 3)
            out += [0xA0 | L << 3 | UInt8(mm >> 2), UInt8(w & 0xFF), UInt8(w >> 8)]
            out += lits
        } else {
            first = min(m, maxShortMatch(literals: l))
            out += [L << 6 | UInt8(first - 3) << 3 | 7, UInt8(d & 0xFF), UInt8(d >> 8)]
            out += lits
        }
        prevD = d
        if m > first { emitMatchTail(m - first, out: &out) }
    }

    static func decode(_ payload: ArraySlice<UInt8>, into out: inout [UInt8], expected: Int) throws {
        let s = Array(payload)
        let base = out.count
        var i = 0
        var d = 0
        func fail(_ m: String) -> LZFSE.DecodeError { LZFSE.DecodeError(message: "LZVN: \(m) at \(i)") }
        func copy(literals l: Int, match m: Int, at opLen: Int) throws {
            guard i + opLen + l <= s.count else { throw fail("literal past the end") }
            out += s[i + opLen..<i + opLen + l]
            i += opLen + l
            guard d > 0, d <= out.count - base else { throw fail("bad distance \(d)") }
            for _ in 0..<m { out.append(out[out.count - d]) }
        }
        while i < s.count {
            let op = s[i]
            func byte(_ k: Int) throws -> Int {
                guard i + k < s.count else { throw fail("opcode past the end") }
                return Int(s[i + k])
            }
            switch op {
            case 0x06:
                guard out.count - base == expected else { throw fail("decoded \(out.count - base) bytes, expected \(expected)") }
                return
            case 0x0E, 0x16: i += 1
            case 0xD0...0xDF, 0x70...0x7F: throw fail("undefined opcode")
            case 0xE0:
                let l = try byte(1) + 16
                guard i + 2 + l <= s.count else { throw fail("literal past the end") }
                out += s[i + 2..<i + 2 + l]
                i += 2 + l
            case 0xE1...0xEF:
                let l = Int(op & 0xF)
                guard i + 1 + l <= s.count else { throw fail("literal past the end") }
                out += s[i + 1..<i + 1 + l]
                i += 1 + l
            case 0xF0:
                let m = try byte(1) + 16
                guard d > 0 else { throw fail("match before any distance") }
                for _ in 0..<m { out.append(out[out.count - d]) }
                i += 2
            case 0xF1...0xFF:
                guard d > 0 else { throw fail("match before any distance") }
                for _ in 0..<Int(op & 0xF) { out.append(out[out.count - d]) }
                i += 1
            case 0xA0...0xBF:
                let w = try byte(1) | byte(2) << 8
                let l = Int(op >> 3) & 3, m = ((Int(op) & 7) << 2 | w & 3) + 3
                d = w >> 2
                try copy(literals: l, match: m, at: 3)
            default:
                let l = Int(op >> 6), m = (Int(op) >> 3 & 7) + 3
                switch op & 7 {
                case 6:
                    guard l > 0 else { throw fail("undefined opcode") }
                    try copy(literals: l, match: m, at: 1)
                case 7:
                    d = try byte(1) | byte(2) << 8
                    try copy(literals: l, match: m, at: 3)
                default:
                    d = Int(op & 7) << 8 | (try byte(1))
                    try copy(literals: l, match: m, at: 2)
                }
            }
        }
        throw fail("no end-of-stream opcode")
    }
}
