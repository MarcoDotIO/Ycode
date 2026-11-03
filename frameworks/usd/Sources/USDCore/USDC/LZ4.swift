/// LZ4 block compression (the public LZ4 block format), and the chunked
/// wrapper the crate format uses around it: one leading byte with the chunk
/// count (0 = a single block follows), then for several chunks a 32-bit
/// compressed size before each block.
public enum LZ4 {
    /// Largest input of one LZ4 block (LZ4_MAX_INPUT_SIZE).
    static let maxInputSize = 0x7E00_0000

    // MARK: Block decoding

    public static func decompressBlock(_ src: ArraySlice<UInt8>, maxOutput: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(maxOutput)
        var i = src.startIndex
        let end = src.endIndex
        while i < end {
            let token = src[i]
            i += 1
            var literalLength = Int(token >> 4)
            if literalLength == 15 {
                while true {
                    guard i < end else { throw USDError("lz4: truncated literal length") }
                    let b = src[i]
                    i += 1
                    literalLength += Int(b)
                    if b != 255 { break }
                }
            }
            guard i + literalLength <= end else { throw USDError("lz4: literals past end of input") }
            out.append(contentsOf: src[i..<(i + literalLength)])
            i += literalLength
            if i >= end { break } // last sequence has no match
            guard i + 2 <= end else { throw USDError("lz4: truncated offset") }
            let offset = Int(src[i]) | Int(src[i + 1]) << 8
            i += 2
            guard offset > 0, offset <= out.count else { throw USDError("lz4: bad match offset") }
            var matchLength = Int(token & 15)
            if matchLength == 15 {
                while true {
                    guard i < end else { throw USDError("lz4: truncated match length") }
                    let b = src[i]
                    i += 1
                    matchLength += Int(b)
                    if b != 255 { break }
                }
            }
            matchLength += 4
            guard out.count + matchLength <= maxOutput else { throw USDError("lz4: output larger than expected") }
            var from = out.count - offset
            for _ in 0..<matchLength {
                out.append(out[from])
                from += 1
            }
        }
        return out
    }

    // MARK: Block encoding

    /// Greedy single-pass compressor with a 4-byte hash table. Produces a
    /// valid LZ4 block (last 5 bytes literal, no match starting in the last
    /// 12 bytes).
    public static func compressBlock(_ src: [UInt8]) -> [UInt8] {
        let n = src.count
        var out: [UInt8] = []
        out.reserveCapacity(n / 2 + 16)
        let hashBits = 16
        var table = [Int](repeating: -1, count: 1 << hashBits)
        func read32(_ p: Int) -> UInt32 {
            UInt32(src[p]) | UInt32(src[p + 1]) << 8 | UInt32(src[p + 2]) << 16 | UInt32(src[p + 3]) << 24
        }
        func hash(_ v: UInt32) -> Int { Int((v &* 2_654_435_761) >> UInt32(32 - hashBits)) }
        func writeLength(_ length: Int) {
            var l = length - 15
            while l >= 255 {
                out.append(255)
                l -= 255
            }
            out.append(UInt8(l))
        }
        var anchor = 0
        var i = 0
        let matchLimit = n - 12
        let lastLiterals = n - 5
        while i < matchLimit {
            let v = read32(i)
            let h = hash(v)
            let candidate = table[h]
            table[h] = i
            if candidate >= 0, i - candidate <= 0xFFFF, read32(candidate) == v {
                var matchLength = 4
                while i + matchLength < lastLiterals, src[candidate + matchLength] == src[i + matchLength] { matchLength += 1 }
                let literalLength = i - anchor
                let token = UInt8(min(literalLength, 15)) << 4 | UInt8(min(matchLength - 4, 15))
                out.append(token)
                if literalLength >= 15 { writeLength(literalLength) }
                out.append(contentsOf: src[anchor..<i])
                let offset = i - candidate
                out.append(UInt8(offset & 0xFF))
                out.append(UInt8(offset >> 8))
                if matchLength - 4 >= 15 { writeLength(matchLength - 4) }
                i += matchLength
                anchor = i
            } else {
                i += 1
            }
        }
        let literalLength = n - anchor
        out.append(UInt8(min(literalLength, 15)) << 4)
        if literalLength >= 15 { writeLength(literalLength) }
        out.append(contentsOf: src[anchor..<n])
        return out
    }

    // MARK: Chunked wrapper

    public static func compress(_ src: [UInt8]) -> [UInt8] {
        if src.count <= maxInputSize {
            return [0] + compressBlock(src)
        }
        var out: [UInt8] = []
        let chunks = (src.count + maxInputSize - 1) / maxInputSize
        out.append(UInt8(chunks))
        var start = 0
        while start < src.count {
            let block = compressBlock(Array(src[start..<min(start + maxInputSize, src.count)]))
            var size = Int32(block.count).littleEndian
            withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
            out += block
            start += maxInputSize
        }
        return out
    }

    public static func decompress(_ src: ArraySlice<UInt8>, expectedSize: Int) throws -> [UInt8] {
        guard let first = src.first else { throw USDError("lz4: empty input") }
        let chunks = Int(first)
        var i = src.startIndex + 1
        if chunks == 0 {
            return try decompressBlock(src[i...], maxOutput: expectedSize)
        }
        var out: [UInt8] = []
        for _ in 0..<chunks {
            guard i + 4 <= src.endIndex else { throw USDError("lz4: truncated chunk header") }
            let size = Int(Int32(bitPattern: UInt32(src[i]) | UInt32(src[i + 1]) << 8 | UInt32(src[i + 2]) << 16 | UInt32(src[i + 3]) << 24))
            i += 4
            guard size >= 0, i + size <= src.endIndex else { throw USDError("lz4: truncated chunk") }
            out += try decompressBlock(src[i..<(i + size)], maxOutput: min(maxInputSize, expectedSize - out.count))
            i += size
        }
        return out
    }
}

/// The crate format's integer coding: deltas, a most-common value, 2-bit
/// width codes and variable-width integers, then LZ4.
public enum IntegerCoding {
    /// Decodes `count` 32-bit integers (as Int64, sign-extended).
    public static func decode32(_ compressed: ArraySlice<UInt8>, count: Int) throws -> [Int64] {
        try decode(compressed, count: count, wide: false)
    }

    public static func decode64(_ compressed: ArraySlice<UInt8>, count: Int) throws -> [Int64] {
        try decode(compressed, count: count, wide: true)
    }

    static func decode(_ compressed: ArraySlice<UInt8>, count: Int, wide: Bool) throws -> [Int64] {
        guard count > 0 else { return [] }
        let intSize = wide ? 8 : 4
        let encodedMax = intSize + (count * 2 + 7) / 8 + count * intSize
        let data = try LZ4.decompress(compressed, expectedSize: encodedMax)
        var p = 0
        func readSigned(_ size: Int) throws -> Int64 {
            guard p + size <= data.count else { throw USDError("crate: truncated integer data") }
            var v: UInt64 = 0
            for k in 0..<size { v |= UInt64(data[p + k]) << (8 * UInt64(k)) }
            p += size
            let shift = UInt64(64 - 8 * size)
            return Int64(bitPattern: v << shift) >> Int64(shift)
        }
        let common = try readSigned(intSize)
        let codesStart = p
        let codesBytes = (count * 2 + 7) / 8
        guard codesStart + codesBytes <= data.count else { throw USDError("crate: truncated integer codes") }
        p = codesStart + codesBytes
        let small = wide ? 2 : 1
        let medium = wide ? 4 : 2
        var result: [Int64] = []
        result.reserveCapacity(count)
        var previous: Int64 = 0
        for i in 0..<count {
            let code = (data[codesStart + i / 4] >> UInt8(2 * (i % 4))) & 3
            switch code {
            case 0: previous &+= common
            case 1: previous &+= try readSigned(small)
            case 2: previous &+= try readSigned(medium)
            default: previous &+= try readSigned(intSize)
            }
            result.append(wide ? previous : Int64(Int32(truncatingIfNeeded: previous)))
        }
        return result
    }

    public static func encode32(_ values: [Int64]) -> [UInt8] { encode(values, wide: false) }
    public static func encode64(_ values: [Int64]) -> [UInt8] { encode(values, wide: true) }

    static func encode(_ values: [Int64], wide: Bool) -> [UInt8] {
        guard !values.isEmpty else { return LZ4.compress([]) }
        let intSize = wide ? 8 : 4
        var deltas: [Int64] = []
        deltas.reserveCapacity(values.count)
        var previous: Int64 = 0
        for v in values {
            let value = wide ? v : Int64(Int32(truncatingIfNeeded: v))
            deltas.append(wide ? value &- previous : Int64(Int32(truncatingIfNeeded: value &- previous)))
            previous = value
        }
        // Most common delta (ties: the smallest value).
        var counts: [Int64: Int] = [:]
        for d in deltas { counts[d, default: 0] += 1 }
        let common = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
        var out: [UInt8] = []
        func write(_ v: Int64, _ size: Int) {
            let u = UInt64(bitPattern: v)
            for k in 0..<size { out.append(UInt8(truncatingIfNeeded: u >> (8 * UInt64(k)))) }
        }
        write(common, intSize)
        let codesStart = out.count
        out += [UInt8](repeating: 0, count: (values.count * 2 + 7) / 8)
        let (smallMin, smallMax): (Int64, Int64) = wide ? (Int64(Int16.min), Int64(Int16.max)) : (Int64(Int8.min), Int64(Int8.max))
        let (mediumMin, mediumMax): (Int64, Int64) = wide ? (Int64(Int32.min), Int64(Int32.max)) : (Int64(Int16.min), Int64(Int16.max))
        for (i, d) in deltas.enumerated() {
            let code: UInt8
            if d == common {
                code = 0
            } else if d >= smallMin && d <= smallMax {
                code = 1
                write(d, wide ? 2 : 1)
            } else if d >= mediumMin && d <= mediumMax {
                code = 2
                write(d, wide ? 4 : 2)
            } else {
                code = 3
                write(d, intSize)
            }
            out[codesStart + i / 4] |= code << UInt8(2 * (i % 4))
        }
        return LZ4.compress(out)
    }
}
