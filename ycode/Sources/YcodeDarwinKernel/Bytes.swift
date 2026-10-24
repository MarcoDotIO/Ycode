// Little-endian byte helpers and number formatting shared by the kernel
// personality and the process-image builders.

extension Array where Element == UInt8 {
    /// Stores `value` little-endian at `offset`, growing the array with zeros if needed.
    mutating func putLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        let size = MemoryLayout<T>.size
        if count < offset + size { append(contentsOf: [UInt8](repeating: 0, count: offset + size - count)) }
        let v = UInt64(truncatingIfNeeded: value)
        for i in 0..<size { self[offset + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
    }

    /// Appends `value` little-endian.
    @inline(__always) mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    /// Stores raw bytes at `offset`, growing the array with zeros if needed.
    mutating func put(_ bytes: [UInt8], at offset: Int) {
        if count < offset + bytes.count { append(contentsOf: [UInt8](repeating: 0, count: offset + bytes.count - count)) }
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    /// Reads a little-endian integer at `offset` (missing bytes read as 0).
    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size where offset + i < count {
            v |= T(truncatingIfNeeded: self[offset + i]) << (8 * i)
        }
        return v
    }

    /// Pads with NUL bytes to a multiple of `alignment`.
    mutating func padTo(_ alignment: Int) {
        while count % alignment != 0 { append(0) }
    }
}

/// `0x` followed by lowercase hex digits, no padding.
@inline(__always) func hx<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }

/// `0x` followed by exactly `digits` lowercase hex digits (zero padded).
func hxPadded(_ v: UInt64, digits: Int) -> String {
    let s = String(v, radix: 16)
    return "0x" + String(repeating: "0", count: max(0, digits - s.count)) + s
}

/// The UTF-8 bytes of `s` followed by one NUL.
func cString(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

func roundUp(_ v: UInt64, to alignment: UInt64) -> UInt64 {
    let (sum, overflow) = v.addingReportingOverflow(alignment - 1)
    return overflow ? UInt64.max & ~(alignment - 1) : sum & ~(alignment - 1)
}

func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
    var (a, b) = (a, b)
    while b != 0 { (a, b) = (b, a % b) }
    return a
}
