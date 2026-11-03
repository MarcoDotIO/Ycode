import Foundation

/// Appends fixed-width numbers in either byte order.
struct ByteWriter {
    var bytes: [UInt8] = []

    init() {}
    init(capacity: Int) { bytes.reserveCapacity(capacity) }

    var count: Int { bytes.count }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16le(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    mutating func u32le(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    mutating func i32le(_ v: Int32) { u32le(UInt32(bitPattern: v)) }
    mutating func u64le(_ v: UInt64) { for s in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8((v >> UInt64(s)) & 0xFF)) } }
    mutating func f32le(_ v: Float) { u32le(v.bitPattern) }
    mutating func f64le(_ v: Double) { u64le(v.bitPattern) }
    mutating func u16be(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func u32be(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    mutating func tag(_ s: String) {
        let b = Array(s.utf8)
        precondition(b.count == 4, "a tag has four bytes")
        bytes += b
    }
    mutating func append(_ b: [UInt8]) { bytes += b }
    mutating func append(_ d: Data) { bytes += d }
    /// `s` in UTF-8, NUL-padded (or cut) to `length` bytes.
    mutating func padded(_ s: String, _ length: Int) {
        var b = Array(s.utf8.prefix(length))
        b += [UInt8](repeating: 0, count: length - b.count)
        bytes += b
    }
    mutating func zeros(_ n: Int) { bytes += [UInt8](repeating: 0, count: n) }
    mutating func align(_ n: Int) { while bytes.count % n != 0 { bytes.append(0) } }

    mutating func patchU32be(_ v: UInt32, at o: Int) {
        for k in 0..<4 { bytes[o + k] = UInt8((v >> UInt32(24 - 8 * k)) & 0xFF) }
    }
}

/// Reads fixed-width numbers from a byte range; out-of-range reads throw.
struct ByteReader {
    let bytes: [UInt8]
    var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    struct OutOfRange: Error, CustomStringConvertible {
        var offset: Int
        var description: String { "read past the end at \(offset)" }
    }

    var remaining: Int { bytes.count - offset }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, offset + n <= bytes.count else { throw OutOfRange(offset: offset) }
        defer { offset += n }
        return bytes[offset..<offset + n]
    }
    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u16le() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }
    mutating func u32le() throws -> UInt32 {
        let b = try take(4)
        var v: UInt32 = 0
        for (k, x) in b.enumerated() { v |= UInt32(x) << UInt32(8 * k) }
        return v
    }
    mutating func i32le() throws -> Int32 { Int32(bitPattern: try u32le()) }
    mutating func u64le() throws -> UInt64 {
        let b = try take(8)
        var v: UInt64 = 0
        for (k, x) in b.enumerated() { v |= UInt64(x) << UInt64(8 * k) }
        return v
    }
    mutating func f32le() throws -> Float { Float(bitPattern: try u32le()) }
    mutating func f64le() throws -> Double { Double(bitPattern: try u64le()) }
    mutating func u16be() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
    }
    mutating func u32be() throws -> UInt32 {
        let b = try take(4)
        var v: UInt32 = 0
        for x in b { v = v << 8 | UInt32(x) }
        return v
    }
    mutating func tag() throws -> String { String(decoding: try take(4), as: UTF8.self) }
    /// A NUL-padded string field.
    mutating func padded(_ n: Int) throws -> String {
        let b = try take(n)
        return String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }
}

extension Array where Element == UInt8 {
    func u32be(at o: Int) -> UInt32 {
        guard o + 4 <= count else { return 0 }
        return UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3])
    }
    func u32le(at o: Int) -> UInt32 {
        guard o + 4 <= count else { return 0 }
        return UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    func u16le(at o: Int) -> UInt16 {
        guard o + 2 <= count else { return 0 }
        return UInt16(self[o]) | UInt16(self[o + 1]) << 8
    }
    func u16be(at o: Int) -> UInt16 {
        guard o + 2 <= count else { return 0 }
        return UInt16(self[o]) << 8 | UInt16(self[o + 1])
    }
}
