import Foundation

/// A JSON value: what JSON-RPC carries for the Model Context Protocol and
/// the Agent Client Protocol (specs/ide/coding-assistant.md, "Ycode
/// implementation"). Decoding keeps booleans and numbers apart on every
/// platform; encoding sorts keys and never writes a newline, so one value
/// is one line of a stdio stream.
public enum AnyJSON: Equatable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    // MARK: Reading

    public subscript(key: String) -> AnyJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> AnyJSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [AnyJSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: AnyJSON]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { self == .null }

    /// An integer, also from a whole double (`3.0`).
    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e15: return Int(d)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// A copy with `key` set (objects only; anything else becomes an object).
    public func setting(_ key: String, _ value: AnyJSON?) -> AnyJSON {
        var o = object ?? [:]
        o[key] = value
        return .object(o)
    }

    // MARK: Text

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String {
            switch self { case .invalid(let s): "invalid JSON: \(s)" }
        }
    }

    public static func parse(_ data: Data) throws -> AnyJSON {
        do {
            return try JSONDecoder().decode(AnyJSON.self, from: data)
        } catch {
            throw ParseError.invalid(String(describing: error).prefix(200).description)
        }
    }

    public static func parse(_ text: String) throws -> AnyJSON { try parse(Data(text.utf8)) }

    /// Compact UTF-8 JSON with sorted keys (no newline anywhere).
    public func data() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a AnyJSON cannot fail except for non-finite doubles,
        // which are written as null.
        return (try? e.encode(self)) ?? Data("null".utf8)
    }

    public var text: String { String(decoding: data(), as: UTF8.self) }

    /// Indented text (for skill files and messages people read).
    public var prettyText: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

extension AnyJSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): if d.isFinite { try c.encode(d) } else { try c.encodeNil() }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension AnyJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: AnyJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AnyJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension AnyJSON {
    /// `.string(s)`, or `.null` for nil.
    public static func optional(_ s: String?) -> AnyJSON { s.map { .string($0) } ?? .null }
    public static func optional(_ i: Int?) -> AnyJSON { i.map { .int($0) } ?? .null }
    public static func strings(_ a: [String]) -> AnyJSON { .array(a.map { .string($0) }) }
}
