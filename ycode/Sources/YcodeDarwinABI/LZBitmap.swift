// LZBITMAP streams and the decmpfs container (`specs/simulator/lzbitmap.md`).
//
// The mobile-asset extractor writes files compressed by the file system
// (decmpfs types 13 and 14, LZBITMAP; `boot-profile.md` §18.3). Ycode's
// volume decodes them when the file is marked compressed (`Decmpfs`), so the
// file reads back as its uncompressed bytes. Written from the spec's format
// description (§2, §3); no other source.

/// An LZBITMAP decoder (`lzbitmap.md` §2).
public enum LZBitmap {
    /// The largest output of one chunk.
    public static let maxChunkOutput = 32_768

    /// Decodes one stream. `limit`: stop with nil when the output would grow
    /// past it (decmpfs knows the size). Returns nil for a stream the
    /// format rejects (§2.7, §2.8).
    public static func decode(_ input: [UInt8], limit: Int = Int.max) -> [UInt8]? {
        input.withUnsafeBufferPointer { decode($0, limit: limit) }
    }

    public static func decode(_ input: UnsafeBufferPointer<UInt8>, limit: Int = Int.max) -> [UInt8]? {
        // Magic `ZBM` + 0x09; 0x08 is accepted too (§2.8: same coding, stored
        // chunks of at most 16 384 bytes). 0x0C and 0x0D are not supported.
        guard input.count >= 4, input[0] == 0x5A, input[1] == 0x42, input[2] == 0x4D,
              input[3] == 0x09 || input[3] == 0x08 else { return nil }
        let storedLimit = input[3] == 0x08 ? 16_384 : maxChunkOutput
        var out: [UInt8] = []
        var pos = 4
        while true {
            guard pos + 6 <= input.count else { return nil }
            let chunkLen = u24(input, pos), outLen = u24(input, pos + 3)
            guard chunkLen >= 6, pos + chunkLen <= input.count, outLen <= maxChunkOutput else { return nil }
            if outLen == 0 {
                // The end chunk; bytes after it are ignored.
                return chunkLen == 6 ? out : nil
            }
            guard out.count + outLen <= limit else { return nil }
            if chunkLen == outLen + 6 {
                guard outLen <= storedLimit else { return nil }
                out.append(contentsOf: input[(pos + 6)..<(pos + chunkLen)])
            } else {
                guard decodeChunk(input, at: pos, length: chunkLen, outLen: outLen, into: &out) else { return nil }
            }
            pos += chunkLen
        }
    }

    @inline(__always) static func u24(_ b: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16
    }

    /// One compressed chunk (§2.3–§2.6), appended to `out` (which also holds
    /// the earlier chunks' output: copies may reach into it).
    static func decodeChunk(_ input: UnsafeBufferPointer<UInt8>, at base: Int, length: Int, outLen: Int,
                            into out: inout [UInt8]) -> Bool {
        guard length >= 32 else { return false }
        let end = base + length
        let periodOff = base + u24(input, base + 6), bitmapOff = base + u24(input, base + 9)
        let selectorOff = base + u24(input, base + 12)
        let tableOff = end - 17
        guard periodOff >= base + 15, periodOff <= end, bitmapOff >= base, bitmapOff <= end,
              selectorOff >= base, selectorOff <= tableOff else { return false }
        // The bitmap table: 12 entries of 10 bits in the last 17 bytes (§2.4).
        var table = [(bitmap: UInt8, periodBytes: Int)]()
        table.reserveCapacity(12)
        for k in 0..<12 {
            let bit = 10 * k
            var v = 0
            for j in 0..<2 where tableOff + bit / 8 + j < end { v |= Int(input[tableOff + bit / 8 + j]) << (8 * j) }
            v = (v >> (bit % 8)) & 0x3FF
            let periodBytes = v >> 8
            guard periodBytes != 3 else { return false }
            table.append((UInt8(v & 0xFF), periodBytes))
        }
        var literal = base + 15, period = periodOff, bitmapPos = bitmapOff
        var nibble = selectorOff * 2   // nibble index: byte = nibble / 2, low nibble first
        let nibbleEnd = tableOff * 2
        func nextNibble() -> Int? {
            guard nibble < nibbleEnd else { return nil }
            let b = input[nibble / 2]
            let v = nibble & 1 == 0 ? Int(b & 0x0F) : Int(b >> 4)
            nibble += 1
            return v
        }
        func peekNibble() -> Int? {
            guard nibble < nibbleEnd else { return nil }
            let b = input[nibble / 2]
            return nibble & 1 == 0 ? Int(b & 0x0F) : Int(b >> 4)
        }
        let start = out.count
        let target = start + outLen
        var distance = 8
        out.reserveCapacity(target)
        while out.count < target {
            guard let selector = nextNibble(), selector != 15 else { return false }
            // A repeat count follows when more than 8 bytes remain (§2.5).
            var count = 1
            if target - out.count > 8, peekNibble() == 15 {
                _ = nextNibble()
                count = 4
                while true {
                    guard let n = nextNibble() else { return false }
                    count += n
                    if n != 15 { break }
                }
            }
            for _ in 0..<count where out.count < target {
                let bitmap: UInt8, periodBytes: Int
                if selector < 3 {
                    guard bitmapPos < selectorOff, bitmapPos < end else { return false }
                    bitmap = input[bitmapPos]
                    bitmapPos += 1
                    periodBytes = selector
                } else {
                    (bitmap, periodBytes) = table[selector - 3]
                }
                if periodBytes > 0 {
                    guard period + periodBytes <= bitmapOff else { return false }
                    distance = periodBytes == 1 ? Int(input[period]) : Int(input[period]) | Int(input[period + 1]) << 8
                    period += periodBytes
                    guard distance > 0 else { return false }
                }
                for i in 0..<8 where out.count < target {
                    if bitmap & (1 << i) != 0 {
                        guard literal < periodOff else { return false }
                        out.append(input[literal])
                        literal += 1
                    } else {
                        guard distance <= out.count else { return false }
                        out.append(out[out.count - distance])
                    }
                }
            }
        }
        return true
    }
}

/// The decmpfs container (`lzbitmap.md` §3).
public enum Decmpfs {
    public static let attributeName = "com.apple.decmpfs"
    public static let resourceForkName = "com.apple.ResourceFork"
    /// `UF_COMPRESSED`.
    public static let compressedFlag: UInt32 = 0x20
    /// `MAX_DECMPFS_XATTR_SIZE`.
    public static let maxAttributeSize = 3_802
    /// `XATTR_SHOWCOMPRESSION`.
    public static let showCompression: Int32 = 0x20
    public static let blockSize = 65_536

    /// The header's compression type and uncompressed size, when `attr` is
    /// a decmpfs attribute the flag may take effect with (§4.2).
    public static func header(_ attr: [UInt8]) -> (type: UInt32, size: UInt64)? {
        guard attr.count >= 16, attr.count <= maxAttributeSize,
              attr[0] == 0x66, attr[1] == 0x70, attr[2] == 0x6D, attr[3] == 0x63 else { return nil }
        var type: UInt32 = 0, size: UInt64 = 0
        for i in 0..<4 { type |= UInt32(attr[4 + i]) << (8 * i) }
        for i in 0..<8 { size |= UInt64(attr[8 + i]) << (8 * i) }
        return (type, size)
    }

    /// Why a file cannot be decoded (§3.4, §4.3).
    public enum Failure: Error, Equatable {
        /// Unknown type: reads fail with EIO.
        case unsupportedType
        /// Type 14 without a fork: ENOATTR.
        case missingFork
        /// A bad offset table or block size: EINVAL.
        case invalid
    }

    /// The file's bytes from its attribute and (type 14) resource fork.
    /// A payload that does not decode gives fewer bytes than the size (the
    /// reference then reads 0 bytes, §4.3: the caller decides).
    public static func decode(attribute attr: [UInt8], fork: [UInt8]?) -> Result<[UInt8], Failure> {
        guard let (type, size64) = header(attr) else { return .failure(.invalid) }
        let size = Int(clamping: size64)
        switch type {
        case 13:
            guard size <= blockSize else { return .success([]) }
            return .success(block(Array(attr[16...]), size: size) ?? [])
        case 14:
            guard let fork else { return .failure(.missingFork) }
            let n = (size + blockSize - 1) / blockSize
            guard fork.count >= 4 * (n + 1) else { return .failure(.invalid) }
            func offset(_ i: Int) -> Int {
                Int(fork[4 * i]) | Int(fork[4 * i + 1]) << 8 | Int(fork[4 * i + 2]) << 16 | Int(fork[4 * i + 3]) << 24
            }
            guard offset(0) == 4 * (n + 1) else { return .failure(.invalid) }
            var out: [UInt8] = []
            out.reserveCapacity(size)
            for i in 0..<n {
                let from = offset(i), to = offset(i + 1)
                guard from <= to, to <= fork.count else { return .failure(.invalid) }
                let want = i == n - 1 ? size - blockSize * (n - 1) : blockSize
                // A block that gives more than its share is invalid; one that
                // gives less (or does not decode) ends the readable bytes.
                guard let bytes = block(Array(fork[from..<to]), size: Int.max) else { return .success(out) }
                guard bytes.count <= want else { return .failure(.invalid) }
                out += bytes
                if bytes.count < want { return .success(out) }
            }
            return .success(out)
        default:
            return .failure(.unsupportedType)
        }
    }

    /// One payload or block: 0xFF + stored bytes, or an LZBITMAP stream
    /// (§3.2). nil when it does not give exactly `size` bytes (a longer
    /// stream gives its first `size` bytes, §4.3).
    static func block(_ payload: [UInt8], size: Int) -> [UInt8]? {
        guard let first = payload.first else { return nil }
        let bytes: [UInt8]?
        switch first {
        case 0xFF: bytes = Array(payload.dropFirst())
        case 0x5A: bytes = LZBitmap.decode(payload)
        default: bytes = nil
        }
        guard let bytes else { return nil }
        if size == Int.max { return bytes }
        if bytes.count == size { return bytes }
        if bytes.count > size { return Array(bytes.prefix(size)) }
        return nil
    }
}
