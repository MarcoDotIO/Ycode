// The OSSerialize binary property-list format of xnu's libkern
// (libkern/libkern/OSSerializeBinary.h, public open source; level 1), as
// iosurface-remote.md §5.1 restates it: a u32 signature 0x000000D3, then
// records. Each record starts with a u32 key: bit 31 marks the last element
// of the enclosing collection, bits 24–30 are the type, bits 0–23 the length
// or count; the payload follows, padded to 4 bytes. Object references
// (type 0x0C) name an earlier object by its index in decoding order
// (collections, keys and values, root = 0; references are not counted).

public indirect enum OSValue: Equatable, Sendable, CustomStringConvertible {
    case dictionary([(key: String, value: OSValue)])
    case array([OSValue])
    /// A number: its value and bit width (8, 16, 32 or 64).
    case number(UInt64, bits: Int)
    case string(String)
    case data([UInt8])
    case bool(Bool)

    public static func == (a: OSValue, b: OSValue) -> Bool {
        switch (a, b) {
        case let (.dictionary(x), .dictionary(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(x), .array(y)): return x == y
        case let (.number(x, _), .number(y, _)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.data(x), .data(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        default: return false
        }
    }

    /// The value for `key` of a dictionary.
    public subscript(key: String) -> OSValue? {
        if case let .dictionary(pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }

    public var numberValue: UInt64? {
        switch self {
        case let .number(v, _): return v
        case let .bool(b): return b ? 1 : 0
        default: return nil
        }
    }
    public var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    public var boolValue: Bool? {
        switch self {
        case let .bool(b): return b
        case let .number(v, _): return v != 0
        default: return nil
        }
    }
    public var arrayValue: [OSValue]? { if case let .array(a) = self { a } else { nil } }
    public var dictionaryValue: [(key: String, value: OSValue)]? { if case let .dictionary(d) = self { d } else { nil } }

    public var description: String {
        switch self {
        case let .dictionary(pairs): return "{" + pairs.map { "\($0.key) = \($0.value)" }.joined(separator: "; ") + "}"
        case let .array(items): return "(" + items.map(\.description).joined(separator: ", ") + ")"
        case let .number(v, _): return String(v)
        case let .string(s): return "\"\(s)\""
        case let .data(d): return "<\(d.count) bytes>"
        case let .bool(b): return b ? "true" : "false"
        }
    }
}

public enum OSSerializeError: Error, Equatable, Sendable {
    case badSignature
    case truncated
    case badType(UInt32)
    case badReference(Int)
    case badKey
    case tooDeep
}

public enum OSSerialize {
    public static let signature: UInt32 = 0x0000_00D3
    enum Kind {
        static let dictionary: UInt32 = 0x01, array: UInt32 = 0x02, set: UInt32 = 0x03, number: UInt32 = 0x04,
                   symbol: UInt32 = 0x08, string: UInt32 = 0x09, data: UInt32 = 0x0A, boolean: UInt32 = 0x0B,
                   object: UInt32 = 0x0C
    }
    static let endCollection: UInt32 = 0x8000_0000

    // MARK: Decoding

    public static func decode(_ bytes: [UInt8]) throws -> OSValue {
        var r = Reader(bytes: bytes)
        guard try r.u32() == signature else { throw OSSerializeError.badSignature }
        return try r.object(depth: 0)
    }

    struct Reader {
        let bytes: [UInt8]
        var at = 0
        var objects: [OSValue] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func u32() throws -> UInt32 {
            guard at + 4 <= bytes.count else { throw OSSerializeError.truncated }
            defer { at += 4 }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }

        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, at + n <= bytes.count else { throw OSSerializeError.truncated }
            defer { at += (n + 3) & ~3 }
            return Array(bytes[at..<(at + n)])
        }

        /// Reserves the index of a collection before its elements decode.
        mutating func reserve() -> Int {
            objects.append(.bool(false))
            return objects.count - 1
        }

        mutating func object(depth: Int) throws -> OSValue {
            guard depth < 64 else { throw OSSerializeError.tooDeep }
            let key = try u32()
            let kind = (key >> 24) & 0x7F
            let length = Int(key & 0x00FF_FFFF)
            switch kind {
            case Kind.dictionary:
                let index = reserve()
                var pairs: [(key: String, value: OSValue)] = []
                for _ in 0..<length {
                    let k = try object(depth: depth + 1)
                    guard case let .string(name) = k else { throw OSSerializeError.badKey }
                    pairs.append((name, try object(depth: depth + 1)))
                }
                objects[index] = .dictionary(pairs)
                return objects[index]
            case Kind.array, Kind.set:
                let index = reserve()
                var items: [OSValue] = []
                for _ in 0..<length { items.append(try object(depth: depth + 1)) }
                objects[index] = .array(items)
                return objects[index]
            case Kind.number:
                let raw = try take(8)
                var v: UInt64 = 0
                for (i, b) in raw.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
                let bits = length == 0 ? 64 : min(length, 64)
                if bits < 64 { v &= (UInt64(1) << UInt64(bits)) - 1 }
                return record(.number(v, bits: bits))
            case Kind.symbol:
                let raw = try take(length)
                return record(.string(String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)))
            case Kind.string:
                return record(.string(String(decoding: try take(length), as: UTF8.self)))
            case Kind.data:
                return record(.data(try take(length)))
            case Kind.boolean:
                return record(.bool(length != 0))
            case Kind.object:
                guard length < objects.count else { throw OSSerializeError.badReference(length) }
                return objects[length]
            default:
                throw OSSerializeError.badType(kind)
            }
        }

        mutating func record(_ v: OSValue) -> OSValue {
            objects.append(v)
            return v
        }
    }

    // MARK: Encoding (no object references)

    public static func encode(_ value: OSValue) -> [UInt8] {
        var w: [UInt8] = []
        func u32(_ v: UInt32) { w += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        func pad() { while w.count % 4 != 0 { w.append(0) } }
        func write(_ v: OSValue, last: Bool) {
            let end = last ? endCollection : 0
            switch v {
            case let .dictionary(pairs):
                u32(end | Kind.dictionary << 24 | UInt32(pairs.count))
                for (i, p) in pairs.enumerated() {
                    let name = Array(p.key.utf8) + [0]
                    u32(Kind.symbol << 24 | UInt32(name.count))
                    w += name
                    pad()
                    write(p.value, last: i == pairs.count - 1)
                }
            case let .array(items):
                u32(end | Kind.array << 24 | UInt32(items.count))
                for (i, item) in items.enumerated() { write(item, last: i == items.count - 1) }
            case let .number(n, bits):
                u32(end | Kind.number << 24 | UInt32(bits))
                for i in 0..<8 { w.append(UInt8(truncatingIfNeeded: n >> (8 * UInt64(i)))) }
            case let .string(s):
                let b = Array(s.utf8)
                u32(end | Kind.string << 24 | UInt32(b.count))
                w += b
                pad()
            case let .data(d):
                u32(end | Kind.data << 24 | UInt32(d.count))
                w += d
                pad()
            case let .bool(b):
                u32(end | Kind.boolean << 24 | (b ? 1 : 0))
            }
        }
        u32(signature)
        write(value, last: true)
        return w
    }
}
