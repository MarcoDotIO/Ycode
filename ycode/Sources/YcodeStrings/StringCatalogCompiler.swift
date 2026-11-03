import Foundation

/// Compiles a String Catalog into per-language `.strings` and
/// `.stringsdict` tables: `ycode strings compile`, which swift-build runs
/// as `xcstringstool compile`. See `specs/ide/string-catalog.md`, "Ycode
/// implementation" (the rules for languages, states, variations and
/// substitutions are Ycode's, from Apple's public documentation).
public enum StringCatalogCompiler {
    public struct Options: Sendable {
        /// Only these languages (`-l`); nil compiles every language.
        public var languages: [String]?
        /// `--force-build-all-strings`: also compile units in state `new`.
        public var forceBuildAllStrings = false
        /// The encoding of the `.strings` files written.
        public var stringsEncoding: StringsFile.Encoding = .utf8
        public init(languages: [String]? = nil, forceBuildAllStrings: Bool = false, stringsEncoding: StringsFile.Encoding = .utf8) {
            self.languages = languages
            self.forceBuildAllStrings = forceBuildAllStrings
            self.stringsEncoding = stringsEncoding
        }
    }

    public struct Diagnostic: Equatable, Sendable, CustomStringConvertible {
        public enum Severity: String, Sendable { case warning, error }
        public var severity: Severity
        public var message: String
        public var language: String?
        public var key: String?
        /// swift-build's String Catalog output format:
        /// `error: <message> (<language>: <key>)` after `<file>: `.
        public var description: String {
            "\(severity.rawValue): \(message)" + (language.map { " (\($0): \(key ?? ""))" } ?? "")
        }
    }

    /// One language's compiled table.
    public struct Table: Equatable, Sendable {
        public var language: String
        public var strings: [StringsFile.Entry] = []
        public var stringsdict: [(String, StringsDictValue)] = []

        public static func == (a: Table, b: Table) -> Bool {
            a.language == b.language && a.strings == b.strings && a.stringsdict.count == b.stringsdict.count
                && zip(a.stringsdict, b.stringsdict).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    public struct Result: Sendable {
        public var tables: [Table]
        public var diagnostics: [Diagnostic]
        public var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }

        /// The files `write` creates under `directory`
        /// (`<language>.lproj/<table>.strings|.stringsdict`), in order.
        public func outputPaths(directory: String, tableName: String) -> [String] {
            tables.flatMap { t -> [String] in
                let dir = (directory as NSString).appendingPathComponent("\(t.language).lproj")
                return (t.strings.isEmpty ? [] : [(dir as NSString).appendingPathComponent("\(tableName).strings")])
                    + (t.stringsdict.isEmpty ? [] : [(dir as NSString).appendingPathComponent("\(tableName).stringsdict")])
            }
        }

        /// Writes the tables; returns the paths written.
        @discardableResult
        public func write(directory: String, tableName: String, encoding: StringsFile.Encoding = .utf8) throws -> [String] {
            let fm = FileManager.default
            var written: [String] = []
            for t in tables where !t.strings.isEmpty || !t.stringsdict.isEmpty {
                let dir = (directory as NSString).appendingPathComponent("\(t.language).lproj")
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if !t.strings.isEmpty {
                    let p = (dir as NSString).appendingPathComponent("\(tableName).strings")
                    try StringsFile.data(t.strings, encoding: encoding).write(to: URL(fileURLWithPath: p), options: .atomic)
                    written.append(p)
                }
                if !t.stringsdict.isEmpty {
                    let p = (dir as NSString).appendingPathComponent("\(tableName).stringsdict")
                    try StringsDictFile.data(t.stringsdict).write(to: URL(fileURLWithPath: p), options: .atomic)
                    written.append(p)
                }
            }
            return written
        }
    }

    /// The plural categories (CLDR) and device names a catalog may use.
    public static let pluralCategories = ["zero", "one", "two", "few", "many", "other"]
    public static let deviceNames = ["iphone", "ipad", "ipod", "mac", "applewatch", "appletv", "applevision", "other"]

    /// Compiles every language of `catalog` (or `options.languages`).
    public static func compile(_ catalog: StringCatalog, options: Options = Options()) -> Result {
        var diagnostics: [Diagnostic] = []
        let source = catalog.sourceLanguage
        let languages = options.languages.map { requested in requested.filter { !$0.isEmpty } } ?? catalog.languages
        var tables: [Table] = []
        let entries = catalog.json["strings"]?.objectPairs ?? []
        for lang in languages {
            var table = Table(language: lang)
            for (key, entry) in entries where !key.isEmpty {
                let isSource = lang == source
                if entry["shouldTranslate"] == .bool(false), !isSource { continue }
                let loc = entry["localizations"]?[lang]
                guard let loc else {
                    // The source language falls back to the key itself.
                    if isSource { table.strings.append(StringsFile.Entry(key: key, value: key)) }
                    continue
                }
                var context = Context(key: key, language: lang, isSource: isSource, force: options.forceBuildAllStrings, diagnostics: [])
                switch context.compile(loc) {
                case .none:
                    if isSource { table.strings.append(StringsFile.Entry(key: key, value: key)) }
                case .plain(let value): table.strings.append(StringsFile.Entry(key: key, value: value))
                case .dict(let d): table.stringsdict.append((key, d))
                }
                diagnostics += context.diagnostics
            }
            tables.append(table)
        }
        return Result(tables: tables, diagnostics: diagnostics)
    }

    // MARK: One localization

    enum Compiled { case none, plain(String), dict(StringsDictValue) }

    struct Context {
        var key: String
        var language: String
        var isSource: Bool
        var force: Bool
        var diagnostics: [Diagnostic]

        mutating func warn(_ m: String) { diagnostics.append(Diagnostic(severity: .warning, message: m, language: language, key: key)) }
        mutating func error(_ m: String) { diagnostics.append(Diagnostic(severity: .error, message: m, language: language, key: key)) }

        /// A string unit's value when it is to be compiled: source-language
        /// units always; others unless they are `new` (`--force-build-all-strings`
        /// compiles those too).
        func unitValue(_ node: OrderedJSON) -> String? {
            guard let unit = node["stringUnit"], let value = unit["value"]?.stringValue else { return nil }
            if !isSource, !force, unit["state"]?.stringValue == "new" { return nil }
            return value
        }

        mutating func compile(_ loc: OrderedJSON) -> Compiled {
            let substitutions = loc["substitutions"]?.objectPairs ?? []
            if let variations = loc["variations"], !variations.objectPairs.isEmpty {
                guard let d = variationDict(variations, substitutions: substitutions) else { return .none }
                return .dict(d)
            }
            guard let value = unitValue(loc) else { return .none }
            if substitutions.isEmpty, !FormatSpecifier.parse(value).contains(where: { $0.variable != nil }) { return .plain(value) }
            return formatDict(value, substitutions: substitutions).map { .dict($0) } ?? .none
        }

        /// `NSStringLocalizedFormatKey` = `format` plus one variable per
        /// substitution the format names.
        mutating func formatDict(_ format: String, substitutions: [(String, OrderedJSON)]) -> StringsDictValue? {
            let specs = FormatSpecifier.parse(format)
            var pairs: [(String, StringsDictValue)] = []
            var edits: [(offset: Int, length: Int, text: String)] = []
            // Sequential argument numbers, for substitutions without argNum.
            var sequential = 0
            let positional = specs.contains { $0.position != nil }
            var used = Set<String>()
            for spec in specs where spec.takesArgument {
                sequential += 1
                guard let name = spec.variable else { continue }
                guard let sub = substitutions.first(where: { $0.0 == name })?.1 else {
                    error("Referencing undefined substitution '\(name)'")
                    return nil
                }
                guard used.insert(name).inserted else { continue }
                let arg = sub["argNum"].flatMap { if case .number(let n) = $0 { return Int(n) }; return nil } ?? spec.position ?? sequential
                // Make the variable positional when its argument is not the
                // one it would take in order.
                if spec.position == nil, arg != sequential || positional {
                    edits.append((spec.offset, spec.text.utf16.count, "%\(arg)$#@\(name)@"))
                }
                guard let rule = substitutionRule(name: name, sub, argument: arg, positionalCases: positional || arg != sequential) else { return nil }
                pairs.append((name, rule))
            }
            for (name, _) in substitutions where !used.contains(name) {
                warn("Substitution '\(name)' is not used in the string")
            }
            let key = edits.isEmpty ? format : format.replacingUTF16(edits)
            return .dict([("NSStringLocalizedFormatKey", .string(key))] + pairs)
        }

        /// A substitution's plural rule; `%arg` in its cases becomes the
        /// substitution's own specifier.
        mutating func substitutionRule(name: String, _ sub: OrderedJSON, argument: Int, positionalCases: Bool) -> StringsDictValue? {
            let spec = sub["formatSpecifier"]?.stringValue ?? "lld"
            let argText = positionalCases ? "%\(argument)$\(spec)" : "%\(spec)"
            guard let variations = sub["variations"], let (kind, cases) = variations.objectPairs.first else {
                error("Substitution '\(name)' has no variations")
                return nil
            }
            guard kind == "plural" else {
                error("Substitution '\(name)' varies by \(kind); only plural substitutions can be compiled")
                return nil
            }
            var rule: [(String, StringsDictValue)] = [("NSStringFormatSpecTypeKey", .string("NSStringPluralRuleType")),
                                                      ("NSStringFormatValueTypeKey", .string(spec))]
            for (category, node) in ordered(cases.objectPairs, Self.pluralOrder) {
                guard StringCatalogCompiler.pluralCategories.contains(category) else {
                    warn("Unknown plural category '\(category)' in substitution '\(name)'")
                    continue
                }
                if node["variations"] != nil { warn("Nested variations in substitution '\(name)' are not compiled") }
                guard let v = unitValue(node) else { continue }
                rule.append((category, .string(v.replacingOccurrences(of: "%arg", with: argText))))
            }
            guard rule.contains(where: { $0.0 == "other" }) else {
                error("Substitution '\(name)' has no 'other' plural case")
                return nil
            }
            return .dict(rule)
        }

        static let pluralOrder = StringCatalogCompiler.pluralCategories
        static let deviceOrder = StringCatalogCompiler.deviceNames

        func ordered(_ pairs: [(String, OrderedJSON)], _ order: [String]) -> [(String, OrderedJSON)] {
            pairs.enumerated().sorted { a, b in
                (order.firstIndex(of: a.element.0) ?? order.count, a.offset) < (order.firstIndex(of: b.element.0) ?? order.count, b.offset)
            }.map(\.element)
        }

        /// A localization that varies by plural category or device.
        mutating func variationDict(_ variations: OrderedJSON, substitutions: [(String, OrderedJSON)]) -> StringsDictValue? {
            let kinds = variations.objectPairs
            if kinds.count > 1 { warn("More than one kind of variation at one level; only '\(kinds[0].0)' is compiled") }
            let (kind, cases) = kinds[0]
            switch kind {
            case "plural":
                var rule: [(String, StringsDictValue)] = []
                var sample: String?
                for (category, node) in ordered(cases.objectPairs, Self.pluralOrder) {
                    guard StringCatalogCompiler.pluralCategories.contains(category) else {
                        warn("Unknown plural category '\(category)'")
                        continue
                    }
                    if node["variations"] != nil { warn("Variations inside plural case '\(category)' are not compiled") }
                    guard let v = unitValue(node) else { continue }
                    if category == "other" || sample == nil { sample = v }
                    rule.append((category, .string(v)))
                }
                guard !rule.isEmpty else { return nil }
                guard rule.contains(where: { $0.0 == "other" }) else {
                    error("The plural variations have no 'other' case")
                    return nil
                }
                // The value type is the first numeric specifier of the
                // `other` case; the rule takes that specifier's argument.
                let numeric = FormatSpecifier.parse(sample ?? "").first { $0.variable == nil && $0.takesArgument && $0.valueType != "@" }
                let valueType = numeric?.valueType ?? "lld"
                let name = variableName(avoiding: substitutions.map(\.0))
                let token = numeric?.position.map { "%\($0)$#@\(name)@" } ?? "%#@\(name)@"
                var pairs: [(String, StringsDictValue)] = [("NSStringLocalizedFormatKey", .string(token)),
                                                           (name, .dict([("NSStringFormatSpecTypeKey", .string("NSStringPluralRuleType")),
                                                                         ("NSStringFormatValueTypeKey", .string(valueType))] + rule))]
                // Substitutions referenced from the cases.
                for (sub, json) in substitutions {
                    let referenced = rule.contains { ($0.1.string ?? "").contains("@\(sub)@") }
                    guard referenced, let r = substitutionRule(name: sub, json, argument: (json["argNum"].flatMap { if case .number(let n) = $0 { return Int(n) }; return nil }) ?? 1, positionalCases: true) else { continue }
                    pairs.append((sub, r))
                }
                return .dict(pairs)
            case "device":
                var rule: [(String, StringsDictValue)] = []
                for (device, node) in ordered(cases.objectPairs, Self.deviceOrder) {
                    if !StringCatalogCompiler.deviceNames.contains(device) { warn("Unknown device '\(device)'") }
                    let subs = node["substitutions"]?.objectPairs ?? substitutions
                    if let inner = node["variations"], !inner.objectPairs.isEmpty {
                        // A nested rule (device, then plural): a dictionary
                        // with its own format key.
                        if let d = variationDict(inner, substitutions: subs) { rule.append((device, d)) }
                    } else if let v = unitValue(node) {
                        if subs.isEmpty || !FormatSpecifier.parse(v).contains(where: { $0.variable != nil }) {
                            rule.append((device, .string(v)))
                        } else if let d = formatDict(v, substitutions: subs) {
                            rule.append((device, d))
                        }
                    }
                }
                guard !rule.isEmpty else { return nil }
                return .dict([("NSStringDeviceSpecificRuleType", .dict(rule))])
            default:
                error("Unknown variation kind '\(kind)'")
                return nil
            }
        }

        func variableName(avoiding names: [String]) -> String {
            var n = "count", i = 1
            while names.contains(n) { i += 1; n = "count\(i)" }
            return n
        }
    }
}

extension StringCatalog {
    /// A catalog file's table name: its file name without `.xcstrings`.
    public static func tableName(forPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
