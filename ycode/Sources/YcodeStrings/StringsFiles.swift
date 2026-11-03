import Foundation

/// The `.strings` table format (Apple's public documentation: an old-style
/// property list of `"key" = "value";` pairs, with C comments, in UTF-8 or
/// UTF-16). See `specs/ide/string-catalog.md`, "Ycode implementation".
public enum StringsFile {
    /// One `key = value` pair and the comment written before it.
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: String
        public var comment: String?
        public init(key: String, value: String, comment: String? = nil) {
            self.key = key
            self.value = value
            self.comment = comment
        }
    }

    public enum Encoding: String, Sendable { case utf8 = "utf-8", utf16 = "utf-16" }

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public var line: Int
        public var message: String
        public var description: String { "line \(line): \(message)" }
    }

    // MARK: Writing

    /// `"key" = "value";` lines (comments as `/* … */` before their entry).
    public static func text(_ entries: [Entry]) -> String {
        var out = ""
        for e in entries {
            if let c = e.comment, !c.isEmpty { out += "/* " + c.replacingOccurrences(of: "*/", with: "* /") + " */\n" }
            out += quote(e.key) + " = " + quote(e.value) + ";\n"
            if e.comment != nil { out += "\n" }
        }
        return out
    }

    /// The file bytes: UTF-8 without a byte-order mark, or UTF-16
    /// little-endian with one.
    public static func data(_ entries: [Entry], encoding: Encoding = .utf8) -> Data {
        let s = text(entries)
        switch encoding {
        case .utf8: return Data(s.utf8)
        case .utf16:
            var d = Data([0xFF, 0xFE])
            for u in s.utf16 { d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8)) }
            return d
        }
    }

    /// A quoted string with the escapes the format defines.
    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where u.value < 0x20 || u.value == 0x7F: out += String(format: "\\U%04X", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    // MARK: Reading

    /// Decodes a table's bytes: a UTF-16 or UTF-8 byte-order mark, else
    /// UTF-8, else UTF-16 (little-endian unless the zeros say otherwise).
    public static func decode(_ data: Data) -> String? {
        let b = [UInt8](data)
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return String(bytes: b.dropFirst(3), encoding: .utf8) }
        if b.starts(with: [0xFF, 0xFE]) { return utf16(b.dropFirst(2), littleEndian: true) }
        if b.starts(with: [0xFE, 0xFF]) { return utf16(b.dropFirst(2), littleEndian: false) }
        if let s = String(bytes: b, encoding: .utf8) { return s }
        guard b.count % 2 == 0 else { return nil }
        let bigEndian = b.count >= 2 && b[0] == 0 && b[1] != 0
        return utf16(b[...], littleEndian: !bigEndian)
    }

    static func utf16(_ b: ArraySlice<UInt8>, littleEndian: Bool) -> String? {
        let a = Array(b)
        guard a.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(a.count / 2)
        var i = 0
        while i < a.count {
            units.append(littleEndian ? UInt16(a[i]) | UInt16(a[i + 1]) << 8 : UInt16(a[i]) << 8 | UInt16(a[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        guard let s = decode(data) else { throw ParseError(line: 1, message: "the file is neither UTF-8 nor UTF-16") }
        return try parse(s)
    }

    /// Entries in file order. `"key";` alone means the value is the key.
    /// The comment is the last `/* … */` or `//` comment before the entry.
    public static func parse(_ s: String) throws -> [Entry] {
        let u = Array(s.unicodeScalars)
        var i = 0, line = 1
        var comment: String?
        var out: [Entry] = []
        func fail(_ m: String) -> ParseError { ParseError(line: line, message: m) }
        func skipSpaceAndComments() throws {
            while i < u.count {
                let c = u[i]
                if c == "\n" { line += 1; i += 1; continue }
                if c == " " || c == "\t" || c == "\r" || c == "\u{FEFF}" { i += 1; continue }
                if c == "/", i + 1 < u.count, u[i + 1] == "*" {
                    var j = i + 2
                    var text = String.UnicodeScalarView()
                    while j + 1 < u.count, !(u[j] == "*" && u[j + 1] == "/") {
                        if u[j] == "\n" { line += 1 }
                        text.append(u[j])
                        j += 1
                    }
                    guard j + 1 < u.count else { throw fail("unterminated comment") }
                    comment = String(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    i = j + 2
                    continue
                }
                if c == "/", i + 1 < u.count, u[i + 1] == "/" {
                    var j = i + 2
                    var text = String.UnicodeScalarView()
                    while j < u.count, u[j] != "\n" { text.append(u[j]); j += 1 }
                    comment = String(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    i = j
                    continue
                }
                return
            }
        }
        func unquotedChar(_ c: Unicode.Scalar) -> Bool {
            (c.value < 0x80 && (CharacterSet.alphanumerics.contains(c) || "_$+/:.-".unicodeScalars.contains(c)))
        }
        func token() throws -> String {
            guard i < u.count else { throw fail("unexpected end of file") }
            if u[i] == "\"" {
                i += 1
                var out = String.UnicodeScalarView()
                while i < u.count, u[i] != "\"" {
                    var c = u[i]
                    if c == "\n" { line += 1 }
                    if c == "\\", i + 1 < u.count {
                        i += 1
                        c = u[i]
                        switch c {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "r": out.append("\r")
                        case "a": out.append("\u{07}")
                        case "b": out.append("\u{08}")
                        case "f": out.append("\u{0C}")
                        case "v": out.append("\u{0B}")
                        case "U", "u":
                            var hex = ""
                            while hex.count < 4, i + 1 < u.count, u[i + 1].properties.isASCIIHexDigit { i += 1; hex.unicodeScalars.append(u[i]) }
                            var v = UInt32(hex, radix: 16) ?? 0xFFFD
                            // A surrogate pair written as two \U escapes.
                            if (0xD800..<0xDC00).contains(v), i + 6 < u.count, u[i + 1] == "\\", u[i + 2] == "U" || u[i + 2] == "u" {
                                let lowHex = String(String.UnicodeScalarView(u[(i + 3)...(i + 6)]))
                                if let low = UInt32(lowHex, radix: 16), (0xDC00..<0xE000).contains(low) {
                                    v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                                    i += 6
                                }
                            }
                            out.append(Unicode.Scalar(v) ?? "\u{FFFD}")
                        case "0"..."7":
                            var oct = String(c)
                            while oct.count < 3, i + 1 < u.count, ("0"..."7").contains(u[i + 1]) { i += 1; oct.unicodeScalars.append(u[i]) }
                            out.append(Unicode.Scalar(UInt32(oct, radix: 8) ?? 0) ?? "\u{FFFD}")
                        default: out.append(c)
                        }
                    } else {
                        out.append(c)
                    }
                    i += 1
                }
                guard i < u.count else { throw fail("unterminated string") }
                i += 1
                return String(out)
            }
            let start = i
            while i < u.count, unquotedChar(u[i]) { i += 1 }
            guard i > start else { throw fail("unexpected character '\(u[i])'") }
            return String(String.UnicodeScalarView(u[start..<i]))
        }
        while true {
            comment = nil
            try skipSpaceAndComments()
            guard i < u.count else { break }
            let entryComment = comment
            let key = try token()
            try skipSpaceAndComments()
            guard i < u.count else { throw fail("expected ';' after \"\(key)\"") }
            if u[i] == ";" {
                i += 1
                out.append(Entry(key: key, value: key, comment: entryComment))
                continue
            }
            guard u[i] == "=" else { throw fail("expected '=' after \"\(key)\"") }
            i += 1
            try skipSpaceAndComments()
            let value = try token()
            try skipSpaceAndComments()
            guard i < u.count, u[i] == ";" else { throw fail("expected ';' after the value of \"\(key)\"") }
            i += 1
            out.append(Entry(key: key, value: value, comment: entryComment))
        }
        return out
    }
}

/// A `.stringsdict` property list (Apple's public documentation:
/// `NSStringLocalizedFormatKey`, variables with `NSStringFormatSpecTypeKey`
/// `NSStringPluralRuleType` and `NSStringFormatValueTypeKey`, plural
/// categories, and `NSStringDeviceSpecificRuleType`), kept in order.
public indirect enum StringsDictValue: Equatable, Sendable {
    case string(String)
    case dict([(String, StringsDictValue)])

    public static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): x == y
        case (.dict(let x), .dict(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    public subscript(key: String) -> StringsDictValue? {
        if case .dict(let d) = self { return d.first { $0.0 == key }?.1 }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var pairs: [(String, StringsDictValue)] { if case .dict(let d) = self { return d }; return [] }
}

public enum StringsDictFile {
    /// An XML property list of the top-level entries, in their order.
    public static func data(_ entries: [(String, StringsDictValue)]) -> Data {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        write(.dict(entries), indent: 0, into: &out)
        out += "</plist>\n"
        return Data(out.utf8)
    }

    static func write(_ v: StringsDictValue, indent: Int, into out: inout String) {
        let pad = String(repeating: "\t", count: indent)
        switch v {
        case .string(let s): out += pad + "<string>" + escape(s) + "</string>\n"
        case .dict(let d):
            if d.isEmpty { out += pad + "<dict/>\n"; return }
            out += pad + "<dict>\n"
            for (k, x) in d {
                out += pad + "\t<key>" + escape(k) + "</key>\n"
                write(x, indent: indent + 1, into: &out)
            }
            out += pad + "</dict>\n"
        }
    }

    /// XML text: `&`, `<`, `>` escaped; characters XML 1.0 cannot hold
    /// (C0 controls other than tab, newline and return) are dropped.
    public static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case _ where u.value < 0x20 && u != "\t" && u != "\n" && u != "\r": continue
            case "\u{FFFE}", "\u{FFFF}": continue
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// The entries of a `.stringsdict` (any property-list format). Keys of
    /// each dictionary come back sorted, plural categories in CLDR order.
    public static func parse(_ data: Data) throws -> [(String, StringsDictValue)] {
        let any = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = any as? [String: Any] else { throw StringsFile.ParseError(line: 1, message: "the top level is not a dictionary") }
        return root.keys.sorted().compactMap { k in convert(root[k]!).map { (k, $0) } }
    }

    static let categoryOrder = ["zero", "one", "two", "few", "many", "other"]

    static func convert(_ any: Any) -> StringsDictValue? {
        if let s = any as? String { return .string(s) }
        guard let d = any as? [String: Any] else { return nil }
        func rank(_ k: String) -> (Int, String) {
            if k == "NSStringLocalizedFormatKey" || k == "NSStringFormatSpecTypeKey" { return (0, k) }
            if k == "NSStringFormatValueTypeKey" { return (1, k) }
            if let i = categoryOrder.firstIndex(of: k) { return (2 + i, k) }
            return (10, k)
        }
        let keys = d.keys.sorted { rank($0) < rank($1) }
        return .dict(keys.compactMap { k in convert(d[k]!).map { (k, $0) } })
    }
}
