import Foundation

/// Swift symbols for a catalog's manually managed strings (the build
/// setting `STRING_CATALOG_GENERATE_SYMBOLS`; swift-build runs `xcstringstool
/// generate-symbols --language swift`, writing
/// `GeneratedStringSymbols_<table>.swift`). The shape of the generated
/// code is Ycode's: static members of `LocalizedStringResource`, a property
/// for a string without arguments and a function for one with arguments.
/// See `specs/ide/string-catalog.md`, "Ycode implementation".
public enum StringSymbolGenerator {
    public static func fileName(table: String) -> String { "GeneratedStringSymbols_\(table).swift" }

    /// One generated member.
    public struct Symbol: Equatable, Sendable {
        public var name: String
        public var key: String
        public var arguments: [(label: String, type: String)]
        public var defaultValue: String

        public static func == (a: Symbol, b: Symbol) -> Bool {
            a.name == b.name && a.key == b.key && a.defaultValue == b.defaultValue
                && a.arguments.map(\.label) == b.arguments.map(\.label) && a.arguments.map(\.type) == b.arguments.map(\.type)
        }
    }

    /// The symbols of the catalog's keys with `extractionState` `manual`,
    /// in key order. Keys whose specifiers have no Swift type are skipped.
    public static func symbols(_ catalog: StringCatalog) -> [Symbol] {
        var used = Set<String>()
        var out: [Symbol] = []
        let source = catalog.sourceLanguage
        for (key, entry) in catalog.json["strings"]?.objectPairs ?? [] where entry["extractionState"]?.stringValue == "manual" && !key.isEmpty {
            let loc = entry["localizations"]?[source]
            let value = loc?["stringUnit"]?["value"]?.stringValue ?? key
            let substitutions = loc?["substitutions"]?.objectPairs ?? []
            var args: [(String, String)] = []
            var ok = true
            var argNames = Set<String>()
            for spec in FormatSpecifier.parse(value) where spec.takesArgument {
                let valueType: String
                var label = "arg\(args.count + 1)"
                if let v = spec.variable {
                    valueType = substitutions.first { $0.0 == v }?.1["formatSpecifier"]?.stringValue ?? "lld"
                    label = identifier(v, lowerFirst: true)
                } else {
                    valueType = spec.valueType
                }
                guard let type = swiftType(valueType) else { ok = false; break }
                while !argNames.insert(label).inserted { label += "_" }
                args.append((label, type))
            }
            guard ok else { continue }
            var name = identifier(key, lowerFirst: true)
            if used.contains(name) {
                var i = 2
                while used.contains(name + "\(i)") { i += 1 }
                name += "\(i)"
            }
            used.insert(name)
            out.append(Symbol(name: name, key: key, arguments: args, defaultValue: value))
        }
        return out
    }

    /// The Swift type an argument of a specifier's value type takes.
    public static func swiftType(_ valueType: String) -> String? {
        guard let conv = valueType.last else { return nil }
        let length = String(valueType.dropLast())
        switch conv {
        case "@": return "String"
        case "d", "i": return length.isEmpty || length == "l" || length == "ll" || length == "q" || length == "z" || length == "t" || length == "j" ? "Int" : length == "h" ? "Int16" : "Int8"
        case "u", "o", "x", "X": return "UInt"
        case "f", "F", "e", "E", "g", "G", "a", "A": return length == "L" ? nil : "Double"
        default: return nil
        }
    }

    /// A Swift identifier from free text: words joined in camel case,
    /// format specifiers dropped, `_` before a leading digit, backticks
    /// around keywords.
    public static func identifier(_ text: String, lowerFirst: Bool) -> String {
        var stripped = text
        let specs = FormatSpecifier.parse(text)
        if !specs.isEmpty { stripped = text.replacingUTF16(specs.map { ($0.offset, $0.text.utf16.count, " ") }) }
        var words: [String] = []
        var current = ""
        for c in stripped.unicodeScalars {
            if (c.properties.isAlphabetic || CharacterSet.decimalDigits.contains(c)) && c.isASCII { current.unicodeScalars.append(c) } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return "string" }
        var out = ""
        for (i, w) in words.enumerated() {
            if i == 0 {
                // Keep camelCase keys as they are; lower an initial capital.
                out += lowerFirst ? w.prefix(1).lowercased() + w.dropFirst() : w
            } else {
                out += w.prefix(1).uppercased() + w.dropFirst()
            }
        }
        if out.first?.isNumber == true { out = "_" + out }
        if keywords.contains(out) { out = "`\(out)`" }
        return out
    }

    static let keywords: Set<String> = ["as", "associatedtype", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do",
                                        "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if",
                                        "import", "in", "init", "inout", "internal", "is", "let", "nil", "open", "operator", "private",
                                        "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "static", "struct",
                                        "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"]

    /// A Swift string literal.
    static func literal(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += "\\u{\(String(u.value, radix: 16))}"
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// The default value as a `String.LocalizationValue` literal whose
    /// interpolations give the same format as the key.
    static func defaultValueLiteral(_ value: String, arguments: [(label: String, type: String)]) -> String {
        let specs = FormatSpecifier.parse(value)
        var out = "\""
        var u = Array(value.utf16)[...]
        var offset = 0
        var argIndex = 0
        func text(_ part: ArraySlice<UInt16>) {
            let s = literal(String(decoding: part, as: UTF16.self))
            out += s.dropFirst().dropLast()
        }
        for spec in specs {
            text(u.prefix(spec.offset - offset))
            u = u.dropFirst(spec.offset - offset + spec.text.utf16.count)
            offset = spec.offset + spec.text.utf16.count
            if spec.isLiteralPercent { out += "%"; continue }
            let i = spec.position.map { $0 - 1 } ?? argIndex
            argIndex += 1
            if i < arguments.count { out += "\\(\(arguments[i].label))" }
        }
        text(u)
        return out + "\""
    }

    /// The generated Swift file.
    public static func swiftSource(_ catalog: StringCatalog, table: String) -> String {
        let syms = symbols(catalog)
        let token = "__YcodeStringSymbolsBundle_" + identifier(table, lowerFirst: false).replacingOccurrences(of: "`", with: "")
        var out = """
        // Generated by Ycode from \(table).xcstrings. Do not edit.
        import Foundation

        """
        guard !syms.isEmpty else { return out }
        out += """

        private final class \(token) {}

        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
        extension LocalizedStringResource {

        """
        for s in syms {
            let resource = "LocalizedStringResource(\(literal(s.key)), defaultValue: \(defaultValueLiteral(s.defaultValue, arguments: s.arguments)), "
                + "table: \(literal(table)), bundle: .forClass(\(token).self))"
            out += "    /// \(s.defaultValue.replacingOccurrences(of: "\n", with: " "))\n"
            if s.arguments.isEmpty {
                out += "    static var \(s.name): LocalizedStringResource {\n        \(resource)\n    }\n\n"
            } else {
                let params = s.arguments.map { "\($0.label): \($0.type)" }.joined(separator: ", ")
                out += "    static func \(s.name)(\(params)) -> LocalizedStringResource {\n        \(resource)\n    }\n\n"
            }
        }
        out.removeLast()
        out += "}\n"
        return out
    }
}
