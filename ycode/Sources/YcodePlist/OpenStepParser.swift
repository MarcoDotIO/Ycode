/// Parser for OpenStep-style ASCII property lists (the NeXTSTEP format used by
/// `.pbxproj`, `.strings`, and many legacy defaults files).
///
/// Grammar (see `specs/formats/openstep-plist.md`):
///
///     value      := dictionary | array | data | string
///     dictionary := '{' (string '=' value ';')* '}'
///     array      := '(' (value (',' value)* ','?)? ')'
///     data       := '<' (hexdigit | whitespace)* '>'
///     string     := quoted | unquoted
///
/// `//` and `/* */` comments may appear anywhere whitespace may.
public struct OpenStepParser {
    /// A syntax error, with the 1-based line it was found on.
    public struct Error: Swift.Error, CustomStringConvertible, Equatable {
        public var message: String
        public var line: Int
        public var description: String { "line \(line): \(message)" }
    }

    private let bytes: [UInt8]
    private var pos = 0

    /// Creates a parser over the UTF-8 encoding of `text`.
    public init(_ text: String) { bytes = Array(text.utf8) }
    /// Creates a parser over raw UTF-8 bytes.
    public init(bytes: [UInt8]) { self.bytes = bytes }

    /// Parses one complete document. Throws `Error` on a syntax error or on
    /// content after the top-level value.
    public static func parse(_ text: String) throws(Error) -> PlistValue {
        var p = OpenStepParser(text)
        return try p.parseDocument()
    }

    /// Parses one complete document from UTF-8 bytes. Throws `Error` on a
    /// syntax error or on content after the top-level value.
    public static func parse(bytes: [UInt8]) throws(Error) -> PlistValue {
        var p = OpenStepParser(bytes: bytes)
        return try p.parseDocument()
    }

    /// Parses the whole input as one document: an optional UTF-8 BOM, then
    /// one value surrounded by trivia. Throws `Error` if anything follows.
    public mutating func parseDocument() throws(Error) -> PlistValue {
        // Skip a UTF-8 byte-order mark.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { pos = 3 }
        try skipTrivia()
        let value = try parseValue()
        try skipTrivia()
        if pos < bytes.count { throw error("unexpected content after top-level value") }
        return value
    }

    // MARK: - Values

    private mutating func parseValue() throws(Error) -> PlistValue {
        guard pos < bytes.count else { throw error("unexpected end of input") }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return .dictionary(try parseDictionary())
        case UInt8(ascii: "("): return .array(try parseArray())
        case UInt8(ascii: "<"): return .data(try parseData())
        default: return .string(try parseString())
        }
    }

    private mutating func parseDictionary() throws(Error) -> PlistDictionary {
        pos += 1  // {
        var dict = PlistDictionary()
        while true {
            try skipTrivia()
            guard pos < bytes.count else { throw error("unterminated dictionary") }
            if bytes[pos] == UInt8(ascii: "}") { pos += 1; return dict }
            let key = try parseString()
            try skipTrivia()
            try expect("=")
            try skipTrivia()
            let value = try parseValue()
            try skipTrivia()
            try expect(";")
            dict[key] = value
        }
    }

    private mutating func parseArray() throws(Error) -> [PlistValue] {
        pos += 1  // (
        var items: [PlistValue] = []
        while true {
            try skipTrivia()
            guard pos < bytes.count else { throw error("unterminated array") }
            if bytes[pos] == UInt8(ascii: ")") { pos += 1; return items }
            items.append(try parseValue())
            try skipTrivia()
            guard pos < bytes.count else { throw error("unterminated array") }
            if bytes[pos] == UInt8(ascii: ",") {
                pos += 1
            } else if bytes[pos] != UInt8(ascii: ")") {
                throw error("expected ',' or ')' in array")
            }
        }
    }

    private mutating func parseData() throws(Error) -> [UInt8] {
        pos += 1  // <
        var out: [UInt8] = []
        var high: UInt8?
        while pos < bytes.count {
            let c = bytes[pos]
            pos += 1
            if c == UInt8(ascii: ">") {
                if high != nil { throw error("odd number of hex digits in data") }
                return out
            }
            if isWhitespace(c) { continue }
            guard let nibble = hexValue(c) else { throw error("invalid character in data") }
            if let h = high {
                out.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        throw error("unterminated data")
    }

    private mutating func parseString() throws(Error) -> String {
        guard pos < bytes.count else { throw error("expected string") }
        let c = bytes[pos]
        if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { return try parseQuoted(c) }
        let start = pos
        while pos < bytes.count, OpenStepCharacters.isUnquotedParseable(bytes[pos]) { pos += 1 }
        if pos == start { throw error("unexpected character '\(Character(Unicode.Scalar(c)))'") }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    private mutating func parseQuoted(_ quote: UInt8) throws(Error) -> String {
        pos += 1
        var units: [UInt16] = []  // UTF-16 so that \U escapes and surrogates compose naturally
        var runStart = pos
        func flush(_ end: Int) {
            if end > runStart {
                units.append(contentsOf: String(decoding: bytes[runStart..<end], as: UTF8.self).utf16)
            }
        }
        while pos < bytes.count {
            let c = bytes[pos]
            if c == quote {
                flush(pos)
                pos += 1
                return String(decoding: units, as: UTF16.self)
            }
            if c == UInt8(ascii: "\\") {
                flush(pos)
                pos += 1
                guard pos < bytes.count else { break }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "a"): units.append(0x07)
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "v"): units.append(0x0B)
                case UInt8(ascii: "U"), UInt8(ascii: "u"):
                    var v: UInt16 = 0
                    var n = 0
                    while n < 4, pos < bytes.count, let h = hexValue(bytes[pos]) {
                        v = v << 4 | UInt16(h)
                        pos += 1
                        n += 1
                    }
                    if n == 0 { throw error("\\U escape without hex digits") }
                    units.append(v)
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var v = UInt16(e - UInt8(ascii: "0"))
                    var n = 1
                    while n < 3, pos < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[pos]) {
                        v = v << 3 | UInt16(bytes[pos] - UInt8(ascii: "0"))
                        pos += 1
                        n += 1
                    }
                    units.append(v)
                default:
                    // \" \' \\ and any other character stand for themselves.
                    runStart = pos - 1
                    continue
                }
                runStart = pos
                continue
            }
            pos += 1
        }
        throw error("unterminated quoted string")
    }

    // MARK: - Trivia

    private mutating func skipTrivia() throws(Error) {
        while pos < bytes.count {
            let c = bytes[pos]
            if isWhitespace(c) {
                pos += 1
            } else if c == UInt8(ascii: "/"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "/") {
                while pos < bytes.count, bytes[pos] != 0x0A, bytes[pos] != 0x0D { pos += 1 }
            } else if c == UInt8(ascii: "/"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "*") {
                pos += 2
                while true {
                    guard pos + 1 < bytes.count else { throw error("unterminated comment") }
                    if bytes[pos] == UInt8(ascii: "*"), bytes[pos + 1] == UInt8(ascii: "/") { pos += 2; break }
                    pos += 1
                }
            } else {
                return
            }
        }
    }

    private mutating func expect(_ ch: Unicode.Scalar) throws(Error) {
        guard pos < bytes.count, bytes[pos] == UInt8(ascii: ch) else { throw error("expected '\(ch)'") }
        pos += 1
    }

    private func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C
    }

    private func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private func error(_ message: String) -> Error {
        var line = 1
        for b in bytes[..<min(pos, bytes.count)] where b == 0x0A { line += 1 }
        return Error(message: message, line: line)
    }
}

/// Character classes shared by the parser and the writers.
public enum OpenStepCharacters {
    /// Characters the parser accepts in an unquoted string.
    public static func isUnquotedParseable(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "$"), UInt8(ascii: "+"), UInt8(ascii: "/"),
             UInt8(ascii: ":"), UInt8(ascii: "."), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }
}
