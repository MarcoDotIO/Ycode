import Foundation

// `LocalizedStringKey` and string-table lookup (08 §3; plan suite T-L10N).
//
// A key keeps the format form used in strings tables (`%@` for strings and
// texts, `%lld` for integers, `%lf` for floating-point values; a literal `%`
// is `%%`) and the interpolated arguments. Lookup happens when the text is
// laid out, in the environment's locale: the table (`Localizable` by
// default) of the bundle (main by default) for the locale's language,
// read from `<language>.lproj/<table>.strings` (string catalogs must be
// compiled to `.strings`; plural rules are not supported). Integer and floating-point
// arguments are formatted for the locale (digits and separators, e.g.
// Arabic-Indic digits for `ar`), strings are inserted as they are.

/// A string key for localized text, with interpolations.
public struct LocalizedStringKey: Equatable, Sendable, ExpressibleByStringInterpolation {
    package enum Argument: Equatable, Sendable {
        case string(String)
        case integer(Int64)
        case floatingPoint(Double)
        case text(Text)
    }

    /// The key as written in a strings table.
    package var key: String
    package var arguments: [Argument]

    public init(_ value: String) {
        key = value
        arguments = []
    }

    public init(stringLiteral value: String) { self.init(value) }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    /// The text with interpolations substituted, unlocalized.
    package var resolved: String {
        LocalizedStringKey.format(key, arguments, locale: nil)
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [Argument] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation(_ string: String) {
            key += "%@"
            arguments.append(.string(string))
        }

        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T) {
            key += "%lld"
            arguments.append(.integer(Int64(value)))
        }

        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T) {
            key += "%lf"
            arguments.append(.floatingPoint(Double(value)))
        }

        public mutating func appendInterpolation(_ text: Text) {
            key += "%@"
            arguments.append(.text(text))
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(.string(String(describing: value)))
        }
    }

    /// Substitutes `arguments` into `format` (`%@`, `%d`/`%ld`/`%lld`,
    /// `%f`/`%lf`, positional `%1$@` forms, `%%`). Numbers are formatted for
    /// `locale` (nil: plain ASCII digits, no grouping).
    package static func format(_ format: String, _ arguments: [Argument], locale: Locale?) -> String {
        var out = ""
        var next = 0
        var i = format.startIndex
        while i < format.endIndex {
            let ch = format[i]
            guard ch == "%" else { out.append(ch); i = format.index(after: i); continue }
            var j = format.index(after: i)
            guard j < format.endIndex else { out.append("%"); break }
            if format[j] == "%" { out.append("%"); i = format.index(after: j); continue }
            // Optional position "n$".
            var digits = ""
            var k = j
            while k < format.endIndex, format[k].isASCII, format[k].isNumber { digits.append(format[k]); k = format.index(after: k) }
            var index = next
            if k < format.endIndex, format[k] == "$", let n = Int(digits) { index = n - 1; j = format.index(after: k) }
            // Length modifiers, then the conversion.
            while j < format.endIndex, "lhqzjt".contains(format[j]) { j = format.index(after: j) }
            guard j < format.endIndex else { break }
            let conversion = format[j]
            let arg = index < arguments.count ? arguments[index] : nil
            next = index + 1
            switch (conversion, arg) {
            case (_, nil): break
            case (_, .string(let s)?): out += s
            case (_, .text(let t)?): out += t.string
            case (_, .integer(let v)?): out += LocalizedStringKey.formatInteger(v, locale: locale)
            case (_, .floatingPoint(let v)?): out += LocalizedStringKey.formatDouble(v, locale: locale)
            }
            i = format.index(after: j)
        }
        return out
    }

    static func formatInteger(_ v: Int64, locale: Locale?) -> String {
        guard let locale else { return String(v) }
        return v.formatted(.number.locale(locale).grouping(.never))
    }

    static func formatDouble(_ v: Double, locale: Locale?) -> String {
        guard let locale else { return String(format: "%f", v) }
        return v.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(6)))
    }
}

/// String-table lookup for `Text`.
package enum TextLocalization {
    /// The string a segment shows in `environment`.
    package static func string(for content: Text.Content, in environment: EnvironmentValues) -> String {
        switch content {
        case .verbatim(let s):
            return s
        case .localized(let key, let table, let bundle):
            let b = bundle?.bundle ?? Bundle.main
            let format = lookup(key.key, table: table ?? "Localizable", bundle: b, locale: environment.locale)
                ?? key.key
            return LocalizedStringKey.format(format, key.arguments, locale: environment.locale)
        }
    }

    private struct TableKey: Hashable { let path: String }
    private static let tables = TableCache()

    /// The localized format for `key`, or nil when no table has it.
    package static func lookup(_ key: String, table: String, bundle: Bundle, locale: Locale) -> String? {
        for language in candidateLanguages(locale) {
            let dir = bundle.bundleURL.appendingPathComponent("\(language).lproj")
            let url = dir.appendingPathComponent("\(table).strings")
            if let value = tables.table(at: url)?[key] { return value }
        }
        return nil
    }

    /// "pt-BR" → ["pt-BR", "pt_BR", "pt", "Base"].
    static func candidateLanguages(_ locale: Locale) -> [String] {
        let id = locale.identifier
        var out: [String] = []
        let lang = locale.language.languageCode?.identifier ?? String(id.prefix { $0 != "_" && $0 != "-" })
        if let region = locale.region?.identifier {
            out.append("\(lang)-\(region)")
            out.append("\(lang)_\(region)")
        }
        out.append(lang)
        out.append("Base")
        return out
    }

    final class TableCache: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [URL: [String: String]?] = [:]

        func table(at url: URL) -> [String: String]? {
            lock.lock()
            defer { lock.unlock() }
            if let t = tables[url] { return t }
            let t = (try? Data(contentsOf: url)).flatMap(StringsFile.parse)
            tables[url] = t
            return t
        }
    }
}

/// `.strings` files: `"key" = "value";` pairs with C-style comments and
/// escapes (UTF-8 or UTF-16 with BOM), or a property list dictionary.
package enum StringsFile {
    package static func parse(_ data: Data) -> [String: String]? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
           data.first == UInt8(ascii: "<") || data.starts(with: [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) {
            return plist
        }
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let t = String(data: data, encoding: .utf16) else { return nil }
            text = t
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        return parse(text)
    }

    package static func parse(_ text: String) -> [String: String]? {
        var result: [String: String] = [:]
        let s = Array(text.unicodeScalars)
        var i = 0
        func skip() {
            while i < s.count {
                if s[i].properties.isWhitespace || s[i] == "\u{FEFF}" { i += 1; continue }
                if s[i] == "/" && i + 1 < s.count && s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count && !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                    i += 2
                    continue
                }
                if s[i] == "/" && i + 1 < s.count && s[i + 1] == "/" {
                    while i < s.count && s[i] != "\n" { i += 1 }
                    continue
                }
                break
            }
        }
        func token() -> String? {
            skip()
            guard i < s.count else { return nil }
            var out = String.UnicodeScalarView()
            if s[i] == "\"" {
                i += 1
                while i < s.count && s[i] != "\"" {
                    if s[i] == "\\" && i + 1 < s.count {
                        i += 1
                        switch s[i] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "r": out.append("\r")
                        case "U", "u":
                            var hex = ""
                            while hex.count < 4 && i + 1 < s.count && s[i + 1].properties.isASCIIHexDigit {
                                i += 1
                                hex.unicodeScalars.append(s[i])
                            }
                            if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.append(u) }
                        default: out.append(s[i])
                        }
                    } else {
                        out.append(s[i])
                    }
                    i += 1
                }
                i += 1
            } else {
                while i < s.count && !s[i].properties.isWhitespace && s[i] != "=" && s[i] != ";" {
                    out.append(s[i])
                    i += 1
                }
            }
            return String(out)
        }
        while true {
            skip()
            guard i < s.count else { break }
            guard let key = token() else { break }
            skip()
            if i < s.count && s[i] == "=" {
                i += 1
                guard let value = token() else { return nil }
                result[key] = value
            } else {
                result[key] = key
            }
            skip()
            if i < s.count && s[i] == ";" { i += 1 } else if i < s.count { return nil }
        }
        return result
    }
}
