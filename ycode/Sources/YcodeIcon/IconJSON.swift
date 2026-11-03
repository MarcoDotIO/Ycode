import Foundation

/// A JSON value as read from an `icon.json`. Objects keep every key, known
/// or not, so a document written back keeps what Ycode does not interpret
/// (`specs/formats/icon-format.md` §2).
public indirect enum IconJSON: Equatable, Sendable {
    case object([String: IconJSON])
    case array([IconJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public var objectValue: [String: IconJSON]? { if case .object(let o) = self { o } else { nil } }
    public var arrayValue: [IconJSON]? { if case .array(let a) = self { a } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var numberValue: Double? { if case .number(let n) = self { n } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> IconJSON? { objectValue?[key] }
}

// MARK: Reading

extension IconJSON {
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public var offset: Int
        public var message: String
        public var description: String { "JSON error at byte \(offset): \(message)" }
    }

    /// Parses any valid JSON text (RFC 8259), whatever its layout.
    public static func parse(_ data: Data) throws -> IconJSON {
        var p = JSONParser(bytes: [UInt8](data))
        // A UTF-8 byte-order mark is tolerated.
        if p.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { p.i = 3 }
        let v = try p.value()
        p.skipSpace()
        guard p.i == p.bytes.count else { throw p.error("text after the end of the document") }
        return v
    }

    public static func parse(_ text: String) throws -> IconJSON { try parse(Data(text.utf8)) }
}

private struct JSONParser {
    let bytes: [UInt8]
    var i = 0
    var depth = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    func error(_ m: String) -> IconJSON.ParseError { IconJSON.ParseError(offset: i, message: m) }

    mutating func skipSpace() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    mutating func value() throws -> IconJSON {
        skipSpace()
        guard i < bytes.count else { throw error("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw error("invalid literal") }
        i += w.count
    }

    mutating func nest() throws {
        depth += 1
        guard depth < 512 else { throw error("nesting too deep") }
    }

    mutating func object() throws -> IconJSON {
        try nest()
        defer { depth -= 1 }
        i += 1
        var out: [String: IconJSON] = [:]
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
        while true {
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected a key") }
            let k = try string()
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected ':'") }
            i += 1
            out[k] = try value()
            skipSpace()
            guard i < bytes.count else { throw error("unexpected end in object") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
            throw error("expected ',' or '}'")
        }
    }

    mutating func array() throws -> IconJSON {
        try nest()
        defer { depth -= 1 }
        i += 1
        var out: [IconJSON] = []
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
        while true {
            out.append(try value())
            skipSpace()
            guard i < bytes.count else { throw error("unexpected end in array") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
            throw error("expected ',' or ']'")
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
            throw error("bad \\u escape")
        }
        i += 4
        return v
    }

    mutating func string() throws -> String {
        i += 1
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw error("unterminated string") }
            let c = bytes[i]
            i += 1
            switch c {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard i < bytes.count else { throw error("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800..<0xDC00).contains(scalar), i + 6 <= bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) { scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00) }
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8))
                default: throw error("bad escape")
                }
            case 0..<0x20:
                throw error("control character in string")
            default:
                out.append(c)
            }
        }
    }

    mutating func number() throws -> Double {
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        func digits() -> Int {
            let s = i
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
            return i - s
        }
        guard digits() > 0 else { throw error("invalid value") }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw error("invalid number") }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw error("invalid exponent") }
        }
        guard let d = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else { throw error("invalid number") }
        return d
    }
}

// MARK: Writing

extension IconJSON {
    /// Icon Composer's layout (`icon-format.md` §2): two-space indentation,
    /// `"key" : value`, keys sorted by their UTF-8 bytes, empty arrays and
    /// objects as an opening bracket, an empty line and the closing bracket,
    /// numbers in their shortest form. No final newline.
    public func formatted() -> String {
        var out = ""
        write(to: &out, indent: 0)
        return out
    }

    public func formattedData() -> Data { Data(formatted().utf8) }

    func write(to out: inout String, indent: Int) {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += Self.format(n)
        case .string(let s): out += Self.quote(s)
        case .array(let a):
            if a.isEmpty { out += "[\n\n\(pad)]"; return }
            out += "[\n"
            for (k, v) in a.enumerated() {
                out += inner
                v.write(to: &out, indent: indent + 2)
                out += k == a.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        case .object(let o):
            if o.isEmpty { out += "{\n\n\(pad)}"; return }
            out += "{\n"
            let keys = o.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (k, key) in keys.enumerated() {
                out += inner + Self.quote(key) + " : "
                o[key]!.write(to: &out, indent: indent + 2)
                out += k == keys.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        }
    }

    /// The shortest text that reads back as the same number: integers
    /// without a fraction, others in Swift's shortest round-trip form.
    public static func format(_ n: Double) -> String {
        guard n.isFinite else { return "0" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        var s = "\(n)"
        // Swift writes 1e-05; JSON allows it, and so does every reader.
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
