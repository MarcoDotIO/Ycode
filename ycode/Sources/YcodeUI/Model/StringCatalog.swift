import Foundation

/// JSON that keeps object key order and number spelling, so an untouched
/// document writes back byte for byte. See `specs/ide/string-catalog.md`.
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.array(let x), .array(let y)): x == y
        case (.string(let x), .string(let y)), (.number(let x), .number(let y)): x == y
        case (.bool(let x), .bool(let y)): x == y
        case (.null, .null): true
        default: false
        }
    }

    public subscript(key: String) -> OrderedJSON? {
        get { if case .object(let o) = self { return o.first { $0.0 == key }?.1 }; return nil }
        set {
            guard case .object(var o) = self else { return }
            if let i = o.firstIndex(where: { $0.0 == key }) {
                if let newValue { o[i].1 = newValue } else { o.remove(at: i) }
            } else if let newValue {
                // New keys go in sorted position (the writer's key order).
                let i = o.firstIndex { OrderedJSON.keyOrder(key, $0.0) } ?? o.count
                o.insert((key, newValue), at: i)
            }
            self = .object(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var objectPairs: [(String, OrderedJSON)] { if case .object(let o) = self { return o }; return [] }

    /// Key order for inserted keys: code-unit order (OPEN QUESTION in the spec).
    static func keyOrder(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

    // MARK: Parsing

    public struct ParseError: Error, CustomStringConvertible {
        public var offset: Int
        public var description: String { "JSON syntax error at byte \(offset)" }
    }

    public static func parse(_ data: Data) throws -> OrderedJSON {
        var p = Parser(bytes: Array(data))
        p.skip()
        let v = try p.value()
        p.skip()
        guard p.i == p.bytes.count else { throw ParseError(offset: p.i) }
        return v
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        mutating func skip() { while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 } }
        mutating func expect(_ c: UInt8) throws { guard i < bytes.count, bytes[i] == c else { throw ParseError(offset: i) }; i += 1 }
        mutating func value() throws -> OrderedJSON {
            guard i < bytes.count else { throw ParseError(offset: i) }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1; skip()
                var out: [(String, OrderedJSON)] = []
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
                while true {
                    skip()
                    let k = try string()
                    skip(); try expect(UInt8(ascii: ":")); skip()
                    out.append((k, try value()))
                    skip()
                    if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    try expect(UInt8(ascii: "}"))
                    return .object(out)
                }
            case UInt8(ascii: "["):
                i += 1; skip()
                var out: [OrderedJSON] = []
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
                while true {
                    skip(); out.append(try value()); skip()
                    if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    try expect(UInt8(ascii: "]"))
                    return .array(out)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default:
                let start = i
                while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
                guard i > start else { throw ParseError(offset: i) }
                return .number(String(decoding: bytes[start..<i], as: UTF8.self))
            }
        }
        mutating func literal(_ s: String) throws {
            for c in s.utf8 { try expect(c) }
        }
        mutating func string() throws -> String {
            try expect(UInt8(ascii: "\""))
            var out = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]; i += 1
                if c == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                guard c == UInt8(ascii: "\\") else { out.append(c); continue }
                guard i < bytes.count else { break }
                let e = bytes[i]; i += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    out += Array(String(Character(Unicode.Scalar(code) ?? "\u{FFFD}")).utf8)
                default: out.append(e)
                }
            }
            throw ParseError(offset: i)
        }
        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { throw ParseError(offset: i) }
            i += 4
            return v
        }
    }

    // MARK: Writing

    /// The layout of catalogs written by the reference: two-space indent,
    /// `"key" : value`, empty containers as `{\n\n}` / `[\n\n]`, slashes
    /// and non-ASCII unescaped.
    public func written(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1), end = String(repeating: "  ", count: indent)
        switch self {
        case .object(let o):
            if o.isEmpty { return "{\n\n" + end + "}" }
            return "{\n" + o.map { pad + Self.quote($0.0) + " : " + $0.1.written(indent: indent + 1) }.joined(separator: ",\n") + "\n" + end + "}"
        case .array(let a):
            if a.isEmpty { return "[\n\n" + end + "]" }
            return "[\n" + a.map { pad + $0.written(indent: indent + 1) }.joined(separator: ",\n") + "\n" + end + "]"
        case .string(let s): return Self.quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
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
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

/// A String Catalog (`.xcstrings`), per Apple's public format description.
public struct StringCatalog {
    public var json: OrderedJSON
    /// Whether the file ended with a newline (kept on save).
    public var trailingNewline: Bool
    /// Languages added in the editor that have no strings yet.
    public var extraLanguages: [String] = []

    public init(data: Data) throws {
        json = try OrderedJSON.parse(data)
        trailingNewline = data.last == 0x0A
    }

    public init(sourceLanguage: String = "en") {
        json = .object([("sourceLanguage", .string(sourceLanguage)), ("strings", .object([])), ("version", .string("1.0"))])
        trailingNewline = true
    }

    public func data() -> Data { Data((json.written() + (trailingNewline ? "\n" : "")).utf8) }

    public var sourceLanguage: String { json["sourceLanguage"]?.stringValue ?? "en" }
    public var keys: [String] { json["strings"]?.objectPairs.map(\.0) ?? [] }

    /// Source language first, then every other language with a
    /// localization or added in the editor, by code.
    public var languages: [String] {
        var set = Set(extraLanguages)
        for (_, entry) in json["strings"]?.objectPairs ?? [] {
            for (lang, _) in entry["localizations"]?.objectPairs ?? [] { set.insert(lang) }
        }
        set.remove(sourceLanguage)
        return [sourceLanguage] + set.sorted()
    }

    public mutating func addLanguage(_ code: String) {
        if !languages.contains(code) { extraLanguages.append(code) }
    }

    public enum State: String, Sendable {
        case translated, needsReview = "needs_review", new, stale, dontTranslate = "dont_translate", variesByPlural = "varies"
    }

    public struct Row: Equatable, Sendable {
        public var key: String
        /// The source-language value (the key when none is written).
        public var defaultValue: String
        public var comment: String
        public var translation: String
        public var state: State
        /// Plural / device variations: shown, not edited.
        public var variations: [String]
    }

    func entry(_ key: String) -> OrderedJSON? { json["strings"]?[key] }

    /// Rows for a language, in file order.
    public func rows(language: String) -> [Row] {
        keys.map { k in
            let e = entry(k) ?? .object([])
            let src = e["localizations"]?[sourceLanguage]?["stringUnit"]?["value"]?.stringValue ?? k
            let loc = e["localizations"]?[language]
            let unit = loc?["stringUnit"]
            var variations: [String] = []
            for (kind, cases) in loc?["variations"]?.objectPairs ?? [] {
                for (c, v) in cases.objectPairs { variations.append("\(kind).\(c): \(v["stringUnit"]?["value"]?.stringValue ?? "")") }
            }
            let state: State
            if e["shouldTranslate"] == .bool(false) { state = .dontTranslate }
            else if e["extractionState"]?.stringValue == "stale" { state = .stale }
            else if !variations.isEmpty { state = .variesByPlural }
            else if let s = unit?["state"]?.stringValue { state = State(rawValue: s) ?? (language == sourceLanguage ? .translated : .new) }
            else { state = language == sourceLanguage ? .translated : .new }
            return Row(key: k, defaultValue: src, comment: e["comment"]?.stringValue ?? "",
                       translation: language == sourceLanguage ? src : (unit?["value"]?.stringValue ?? ""), state: state, variations: variations)
        }
    }

    /// Percentage of keys translated in a language (keys marked don't
    /// translate excluded); the source language is always 100.
    public func progress(language: String) -> Int {
        guard language != sourceLanguage else { return 100 }
        let rs = rows(language: language).filter { $0.state != .dontTranslate }
        guard !rs.isEmpty else { return 100 }
        return rs.filter { $0.state == .translated || $0.state == .variesByPlural }.count * 100 / rs.count
    }

    private mutating func edit(_ key: String, _ change: (inout OrderedJSON) -> Void) {
        var strings = json["strings"] ?? .object([])
        var e = strings[key] ?? .object([])
        change(&e)
        strings[key] = e
        json["strings"] = strings
    }

    /// Writes a translation (state `translated`); empty removes it.
    public mutating func setTranslation(_ value: String, key: String, language: String) {
        edit(key) { e in
            var locs = e["localizations"] ?? .object([])
            if value.isEmpty {
                locs[language] = nil
            } else {
                var loc = locs[language] ?? .object([])
                loc["stringUnit"] = .object([("state", .string("translated")), ("value", .string(value))])
                locs[language] = loc
            }
            e["localizations"] = locs.objectPairs.isEmpty ? nil : locs
        }
    }

    public mutating func setState(_ state: State, key: String, language: String) {
        edit(key) { e in
            guard var unit = e["localizations"]?[language]?["stringUnit"] else { return }
            unit["state"] = .string(state.rawValue)
            var locs = e["localizations"]!
            var loc = locs[language]!
            loc["stringUnit"] = unit
            locs[language] = loc
            e["localizations"] = locs
        }
    }

    public mutating func setComment(_ comment: String, key: String) {
        edit(key) { $0["comment"] = comment.isEmpty ? nil : .string(comment) }
    }

    /// Adds a manually managed key.
    public mutating func addKey(_ key: String) {
        guard entry(key) == nil else { return }
        edit(key) { $0["extractionState"] = .string("manual") }
    }

    public mutating func removeKey(_ key: String) {
        var strings = json["strings"] ?? .object([])
        strings[key] = nil
        json["strings"] = strings
    }
}
