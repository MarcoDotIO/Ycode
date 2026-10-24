// A small JSON value model, parser and writer for `.storekit` files
// (configuration-file.md §1).
//
// Why not Foundation's JSONSerialization: the file must round-trip byte for
// byte, so numbers keep their literal text, objects remember nothing about
// key order (the writer always sorts), and the writer reproduces the
// published pretty-print style exactly on every platform.
import Foundation

/// A JSON number kept as its literal text so that it is written back unchanged.
public struct JSONNumber: Hashable, Sendable, CustomStringConvertible {
    /// The number exactly as it appeared in the source (or as created).
    public let literal: String

    public init(literal: String) { self.literal = literal }
    public init(_ value: Int) { self.literal = String(value) }

    public var intValue: Int? { Int(literal) }
    public var doubleValue: Double? { Double(literal) }
    public var decimalValue: Decimal? { Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")) }
    public var description: String { literal }
}

/// A JSON value. Objects are unordered; the writer sorts keys.
public enum JSONValue: Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(JSONNumber)
    case bool(Bool)
    case null

    public static func int(_ value: Int) -> JSONValue { .number(JSONNumber(value)) }

    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var numberValue: JSONNumber? { if case .number(let n) = self { return n } else { return nil } }
    public var intValue: Int? { numberValue?.intValue }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

// MARK: - Parsing

/// A syntax error with its position (1-based line and column, 0-based byte offset).
public struct JSONSyntaxError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public let line: Int
    public let column: Int
    public var description: String { "line \(line), column \(column): \(message)" }
}

public enum JSONParser {
    /// Parses one JSON value; surrounding whitespace is allowed, anything else is an error.
    public static func parse(_ data: Data) throws -> JSONValue {
        var p = Parser(bytes: Array(data))
        p.skipWhitespace()
        // A UTF-8 byte order mark is tolerated.
        if p.bytes.starts(with: [0xEF, 0xBB, 0xBF]) && p.index == 0 { p.index = 3; p.skipWhitespace() }
        let value = try p.parseValue(depth: 0)
        p.skipWhitespace()
        if p.index != p.bytes.count { throw p.error("unexpected text after the top-level value") }
        return value
    }

    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ message: String) -> JSONSyntaxError {
            var line = 1, column = 1
            for b in bytes[0..<min(index, bytes.count)] {
                if b == 0x0A { line += 1; column = 1 } else { column += 1 }
            }
            return JSONSyntaxError(message: message, offset: index, line: line, column: column)
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            let lit = Array(literal.utf8)
            guard index + lit.count <= bytes.count, Array(bytes[index..<index + lit.count]) == lit else {
                throw error("expected \(literal)")
            }
            index += lit.count
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw error("nesting too deep") }
            guard index < bytes.count else { throw error("unexpected end of data") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
            default: throw error("unexpected character")
            }
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            index += 1
            var result: [String: JSONValue] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(result) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key string") }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
                index += 1
                skipWhitespace()
                result[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(result) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            index += 1
            var result: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(result) }
            while true {
                skipWhitespace()
                result.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(result) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func parseNumber() throws -> JSONNumber {
            let start = index
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            func digits() -> Int {
                let s = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - s
            }
            guard index < bytes.count else { throw error("bad number") }
            if bytes[index] == UInt8(ascii: "0") { index += 1 } else if digits() == 0 { throw error("bad number") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                if digits() == 0 { throw error("bad number fraction") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                if digits() == 0 { throw error("bad number exponent") }
            }
            return JSONNumber(literal: String(decoding: bytes[start..<index], as: UTF8.self))
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw error("bad \\u escape") }
            var v: UInt32 = 0
            for b in bytes[index..<index + 4] {
                v <<= 4
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): v |= UInt32(b - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): v |= UInt32(b - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): v |= UInt32(b - UInt8(ascii: "A") + 10)
                default: throw error("bad \\u escape")
                }
            }
            index += 4
            return v
        }

        mutating func parseString() throws -> String {
            index += 1
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let b = bytes[index]
                if b == UInt8(ascii: "\"") { index += 1; break }
                if b < 0x20 { throw error("control character in string") }
                if b != UInt8(ascii: "\\") { out.append(b); index += 1; continue }
                index += 1
                guard index < bytes.count else { throw error("unterminated escape") }
                let e = bytes[index]
                index += 1
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
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
                        else { throw error("unpaired surrogate") }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("unpaired surrogate") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw error("unpaired surrogate")
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw error("bad scalar") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default: throw error("unknown escape")
                }
            }
            guard let s = String(validating: out, as: UTF8.self) else { throw error("invalid UTF-8 in string") }
            return s
        }
    }
}

// MARK: - Writing

/// The pretty-print style of configuration-file.md §1: two-space indent,
/// `"key" : value`, keys sorted, empty containers as open, blank line, close.
public struct JSONWriter: Sendable {
    /// Escape `/` as `\/` (the Foundation writer's default). Spec question 1 in the README.
    public var escapeSlashes: Bool = true
    /// Write a newline after the closing brace of the top-level value.
    public var trailingNewline: Bool = false

    public init(escapeSlashes: Bool = true, trailingNewline: Bool = false) {
        self.escapeSlashes = escapeSlashes
        self.trailingNewline = trailingNewline
    }

    public func string(_ value: JSONValue) -> String {
        var out = ""
        write(value, indent: 0, into: &out)
        if trailingNewline { out += "\n" }
        return out
    }

    public func data(_ value: JSONValue) -> Data { Data(string(value).utf8) }

    /// Keys are sorted by their UTF-16 code units, the order of a literal
    /// string comparison (identical to byte order for the ASCII keys of the format).
    public static func sortedKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    func write(_ value: JSONValue, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch value {
        case .object(let object):
            if object.isEmpty { out += "{\n\n" + pad + "}"; return }
            out += "{\n"
            let keys = JSONWriter.sortedKeys(object.keys)
            for (i, key) in keys.enumerated() {
                out += inner
                out += quoted(key)
                out += " : "
                write(object[key]!, indent: indent + 1, into: &out)
                out += i == keys.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        case .array(let array):
            if array.isEmpty { out += "[\n\n" + pad + "]"; return }
            out += "[\n"
            for (i, element) in array.enumerated() {
                out += inner
                write(element, indent: indent + 1, into: &out)
                out += i == array.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        case .string(let s): out += quoted(s)
        case .number(let n): out += n.literal
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "/": out += escapeSlashes ? "\\/" : "/"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Compact form

extension JSONWriter {
    /// The compact form with sorted keys and no whitespace, as used for
    /// signed payloads (design.md §5 item 2: keys sorted). Slashes are not escaped.
    public static func compact(_ value: JSONValue) -> String {
        let writer = JSONWriter(escapeSlashes: false)
        var out = ""
        writer.writeCompact(value, into: &out)
        return out
    }

    func writeCompact(_ value: JSONValue, into out: inout String) {
        switch value {
        case .object(let object):
            out += "{"
            for (i, key) in JSONWriter.sortedKeys(object.keys).enumerated() {
                if i > 0 { out += "," }
                out += quoted(key)
                out += ":"
                writeCompact(object[key]!, into: &out)
            }
            out += "}"
        case .array(let array):
            out += "["
            for (i, element) in array.enumerated() {
                if i > 0 { out += "," }
                writeCompact(element, into: &out)
            }
            out += "]"
        default:
            write(value, indent: 0, into: &out)
        }
    }
}
