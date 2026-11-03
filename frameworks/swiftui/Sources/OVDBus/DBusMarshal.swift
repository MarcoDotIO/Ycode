import Foundation

// Marshalling (D-Bus Specification 0.43, "Marshaling (Wire Format)"):
// every value is aligned to its type's natural boundary counted from the
// start of the message, padding is nul bytes and the minimum needed,
// structs and dict entries align to 8, strings are a UINT32 length, the
// bytes and a nul, signatures a BYTE length, the bytes and a nul, arrays a
// UINT32 byte length, padding to the element alignment (even when empty),
// then the elements; a variant is a signature and the value.
//
// Encoders and decoders here work on a buffer whose offset 0 is a multiple
// of 8 from the start of the message (the header and the body both are).

/// Writes values in one byte order.
public struct DBusEncoder {
    public private(set) var bytes: [UInt8] = []
    public let bigEndian: Bool
    /// Alignment is counted from this offset of the message (0 for a
    /// message start or a body).
    private let base: Int

    public init(bigEndian: Bool = false, base: Int = 0) {
        self.bigEndian = bigEndian
        self.base = base
    }

    public var count: Int { bytes.count }

    public mutating func pad(to alignment: Int) {
        while (base + bytes.count) % alignment != 0 { bytes.append(0) }
    }

    mutating func appendInteger<T: FixedWidthInteger>(_ v: T) {
        pad(to: MemoryLayout<T>.size)
        let e = bigEndian ? v.bigEndian : v.littleEndian
        withUnsafeBytes(of: e) { bytes.append(contentsOf: $0) }
    }

    mutating func patchUInt32(_ v: UInt32, at offset: Int) {
        let e = bigEndian ? v.bigEndian : v.littleEndian
        withUnsafeBytes(of: e) { raw in
            for i in 0..<4 { bytes[offset + i] = raw[i] }
        }
    }

    public mutating func write(_ values: [DBusValue]) throws {
        for v in values { try write(v) }
    }

    public mutating func write(_ value: DBusValue, depth: Int = 0) throws {
        guard depth <= 64 else { throw DBusError.invalidValue("nested deeper than 64") }
        switch value {
        case .byte(let v): bytes.append(v)
        case .boolean(let v): appendInteger(UInt32(v ? 1 : 0))
        case .int16(let v): appendInteger(v)
        case .uint16(let v): appendInteger(v)
        case .int32(let v): appendInteger(v)
        case .uint32(let v): appendInteger(v)
        case .int64(let v): appendInteger(v)
        case .uint64(let v): appendInteger(v)
        case .double(let v): appendInteger(v.bitPattern)
        case .unixFD(let v): appendInteger(v)
        case .string(let s):
            try writeString(s)
        case .objectPath(let p):
            guard DBusNames.isValidObjectPath(p) else { throw DBusError.invalidValue("object path \"\(p)\"") }
            try writeString(p)
        case .signature(let g):
            _ = try DBusType.parse(g)
            let u = Array(g.utf8)
            bytes.append(UInt8(u.count))
            bytes.append(contentsOf: u)
            bytes.append(0)
        case .array(let element, let items):
            appendInteger(UInt32(0))
            let lengthAt = bytes.count - 4
            pad(to: element.alignment)
            let start = bytes.count
            for item in items {
                guard item.type == element else {
                    throw DBusError.invalidValue("array of \(element.signature) holds a \(item.signature)")
                }
                try write(item, depth: depth + 1)
            }
            let n = bytes.count - start
            guard n <= 1 << 26 else { throw DBusError.invalidValue("array longer than 64 MiB") }
            patchUInt32(UInt32(n), at: lengthAt)
        case .structure(let fields):
            guard !fields.isEmpty else { throw DBusError.invalidValue("empty struct") }
            pad(to: 8)
            for f in fields { try write(f, depth: depth + 1) }
        case .dictEntry(let k, let v):
            guard k.type.isBasic else { throw DBusError.invalidValue("dict entry key \(k.signature)") }
            pad(to: 8)
            try write(k, depth: depth + 1)
            try write(v, depth: depth + 1)
        case .variant(let inner):
            let g = Array(inner.signature.utf8)
            guard g.count <= 255 else { throw DBusError.invalidValue("variant signature too long") }
            bytes.append(UInt8(g.count))
            bytes.append(contentsOf: g)
            bytes.append(0)
            try write(inner, depth: depth + 1)
        }
    }

    private mutating func writeString(_ s: String) throws {
        let u = Array(s.utf8)
        guard !u.contains(0) else { throw DBusError.invalidValue("string with a nul byte") }
        appendInteger(UInt32(u.count))
        bytes.append(contentsOf: u)
        bytes.append(0)
    }
}

/// Reads values in one byte order.
public struct DBusDecoder {
    public let bytes: [UInt8]
    public let bigEndian: Bool
    public var offset: Int
    private let base: Int
    private let end: Int

    /// Decodes `bytes[start..<end]`, counting alignment from `base`
    /// (`start` is at message offset `base + start`).
    public init(_ bytes: [UInt8], bigEndian: Bool = false, start: Int = 0, end: Int? = nil, base: Int = 0) {
        self.bytes = bytes
        self.bigEndian = bigEndian
        offset = start
        self.base = base
        self.end = end ?? bytes.count
    }

    public var isAtEnd: Bool { offset >= end }

    mutating func skipPadding(to alignment: Int) throws {
        while (base + offset) % alignment != 0 {
            guard offset < end else { throw DBusError.malformedMessage("truncated padding") }
            guard bytes[offset] == 0 else { throw DBusError.malformedMessage("non-nul padding at \(offset)") }
            offset += 1
        }
    }

    mutating func readInteger<T: FixedWidthInteger>(_: T.Type) throws -> T {
        try skipPadding(to: MemoryLayout<T>.size)
        let n = MemoryLayout<T>.size
        guard offset + n <= end else { throw DBusError.malformedMessage("truncated \(T.self) at \(offset)") }
        var v: T = 0
        for i in 0..<n { v |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i) }
        offset += n
        // `v` was assembled as if the bytes were little-endian.
        return bigEndian ? v.byteSwapped : v
    }

    /// Reads the values of `signature` in sequence.
    public mutating func read(signature: String) throws -> [DBusValue] {
        try DBusType.parse(signature).map { try read($0) }
    }

    public mutating func read(_ type: DBusType, depth: Int = 0) throws -> DBusValue {
        guard depth <= 64 else { throw DBusError.malformedMessage("nested deeper than 64") }
        switch type {
        case .byte:
            guard offset < end else { throw DBusError.malformedMessage("truncated byte") }
            offset += 1
            return .byte(bytes[offset - 1])
        case .boolean:
            let v = try readInteger(UInt32.self)
            guard v <= 1 else { throw DBusError.malformedMessage("boolean \(v)") }
            return .boolean(v == 1)
        case .int16: return .int16(try readInteger(Int16.self))
        case .uint16: return .uint16(try readInteger(UInt16.self))
        case .int32: return .int32(try readInteger(Int32.self))
        case .uint32: return .uint32(try readInteger(UInt32.self))
        case .int64: return .int64(try readInteger(Int64.self))
        case .uint64: return .uint64(try readInteger(UInt64.self))
        case .double: return .double(Double(bitPattern: try readInteger(UInt64.self)))
        case .unixFD: return .unixFD(try readInteger(UInt32.self))
        case .string:
            return .string(try readString())
        case .objectPath:
            let p = try readString()
            guard DBusNames.isValidObjectPath(p) else { throw DBusError.malformedMessage("object path \"\(p)\"") }
            return .objectPath(p)
        case .signature:
            let g = try readSignatureText()
            _ = try DBusType.parse(g)
            return .signature(g)
        case .array(let element):
            let n = Int(try readInteger(UInt32.self))
            guard n <= 1 << 26 else { throw DBusError.malformedMessage("array longer than 64 MiB") }
            try skipPadding(to: element.alignment)
            let stop = offset + n
            guard stop <= end else { throw DBusError.malformedMessage("array runs past the end") }
            var items: [DBusValue] = []
            while offset < stop { items.append(try read(element, depth: depth + 1)) }
            guard offset == stop else { throw DBusError.malformedMessage("array element runs past the array") }
            return .array(element, items)
        case .structure(let fields):
            try skipPadding(to: 8)
            return .structure(try fields.map { try read($0, depth: depth + 1) })
        case .dictEntry(let k, let v):
            try skipPadding(to: 8)
            return .dictEntry(try read(k, depth: depth + 1), try read(v, depth: depth + 1))
        case .variant:
            let g = try readSignatureText()
            let inner = try DBusType.parseSingle(g)
            return .variant(try read(inner, depth: depth + 1))
        }
    }

    private mutating func readString() throws -> String {
        let n = Int(try readInteger(UInt32.self))
        guard offset + n + 1 <= end else { throw DBusError.malformedMessage("truncated string") }
        let slice = bytes[offset..<(offset + n)]
        guard bytes[offset + n] == 0, !slice.contains(0) else { throw DBusError.malformedMessage("string without its nul") }
        guard let s = String(validating: slice, as: UTF8.self) else { throw DBusError.malformedMessage("string is not UTF-8") }
        offset += n + 1
        return s
    }

    private mutating func readSignatureText() throws -> String {
        guard offset < end else { throw DBusError.malformedMessage("truncated signature") }
        let n = Int(bytes[offset])
        offset += 1
        guard offset + n + 1 <= end, bytes[offset + n] == 0 else { throw DBusError.malformedMessage("truncated signature") }
        let s = String(decoding: bytes[offset..<(offset + n)], as: UTF8.self)
        offset += n + 1
        return s
    }
}

extension DBusValue {
    /// The value marshalled alone at an 8-aligned position.
    public func marshalled(bigEndian: Bool = false) throws -> [UInt8] {
        var e = DBusEncoder(bigEndian: bigEndian)
        try e.write(self)
        return e.bytes
    }
}
