import Foundation
import SwiftParser
import SwiftSyntax

/// A localizable string found in source code.
public struct ExtractedString: Equatable, Sendable {
    public var key: String
    /// The source-language value when the code gives one apart from the key.
    public var defaultValue: String?
    public var comment: String?
    /// The table (the catalog's name); `Localizable` by default.
    public var table: String
    public var file: String
    public var line: Int

    public init(key: String, defaultValue: String? = nil, comment: String? = nil, table: String = "Localizable", file: String = "", line: Int = 0) {
        self.key = key
        self.defaultValue = defaultValue
        self.comment = comment
        self.table = table
        self.file = file
        self.line = line
    }
}

/// Finds localizable strings in Swift (with swift-syntax) and Objective-C
/// or C (a small scanner) sources: what "Refresh from source" and `ycode
/// strings extract` merge into catalogs. The call forms are Apple's public
/// API (`String(localized:)`, `LocalizedStringResource`, `LocalizedStringKey`
/// literals in SwiftUI initializers and modifiers, `NSLocalizedString` and
/// its variants, `CFCopyLocalizedString`). See `specs/ide/string-catalog.md`,
/// "Ycode implementation".
public enum StringExtractor {
    public struct Options: Sendable {
        /// `LOCALIZED_STRING_MACRO_NAMES`: base names of NSLocalizedString-like
        /// functions (the two defaults are always included).
        public var macroNames: [String] = []
        /// `LOCALIZED_STRING_SWIFTUI_SUPPORT`: SwiftUI string literals.
        public var swiftUI = true
        public init(macroNames: [String] = [], swiftUI: Bool = true) {
            self.macroNames = macroNames
            self.swiftUI = swiftUI
        }
        var allMacroNames: [String] { Array(Set(["NSLocalizedString", "CFCopyLocalizedString"] + macroNames)) }
    }

    /// Extracts from a file by its extension (`swift`; `m`, `mm`, `c`, `cpp`, `h`).
    public static func extract(file path: String, options: Options = Options()) -> [ExtractedString] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return extractSwift(text, file: path, options: options)
        case "m", "mm", "c", "cc", "cpp", "h", "hpp": return extractObjC(text, file: path, options: options)
        default: return []
        }
    }

    // MARK: Swift

    /// SwiftUI initializers whose first unlabeled argument is a
    /// `LocalizedStringKey` when written as a literal.
    public static let swiftUIInitializers: Set<String> = [
        "Text", "Button", "Label", "Toggle", "TextField", "SecureField", "Picker", "NavigationLink", "Section", "Link", "Menu",
        "Stepper", "DatePicker", "ColorPicker", "LabeledContent", "GroupBox", "DisclosureGroup", "Tab", "ProgressView",
        "ContentUnavailableView", "ShareLink", "PasteButton", "MultiDatePicker", "Gauge", "Slider", "TextEditor", "ControlGroup",
        "Window", "WindowGroup", "Settings", "MenuBarExtra", "Toolbar", "ToolbarItem", "CommandMenu", "TableColumn", "NavigationStack",
    ]
    /// SwiftUI modifiers whose first unlabeled argument is a `LocalizedStringKey`.
    public static let swiftUIModifiers: Set<String> = [
        "navigationTitle", "navigationSubtitle", "help", "alert", "confirmationDialog", "accessibilityLabel", "accessibilityHint",
        "accessibilityValue", "badge", "searchable", "keyboardShortcut", "contextMenu", "fileExporter", "toolbarTitleMenu",
        "accessibilityAction", "tabItem", "focusedSceneValue",
    ]
    static let stringTypes: Set<String> = ["LocalizedStringKey", "LocalizedStringResource", "String.LocalizationValue"]

    public static func extractSwift(_ source: String, file: String = "", options: Options = Options()) -> [ExtractedString] {
        let tree = Parser.parse(source: source)
        let visitor = SwiftVisitor(converter: SourceLocationConverter(fileName: file, tree: tree), file: file, options: options)
        visitor.collectTypes(tree)
        visitor.walk(tree)
        // In source order (a modifier's call encloses the view it modifies).
        return zip(visitor.found, visitor.offsets).enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    final class SwiftVisitor: SyntaxVisitor {
        let converter: SourceLocationConverter
        let file: String
        let options: Options
        var found: [ExtractedString] = []
        /// The source offset of each found string's literal.
        var offsets: [Int] = []
        /// Declared types of names in the file (annotations and literal initializers).
        var types: [String: String] = [:]

        init(converter: SourceLocationConverter, file: String, options: Options) {
            self.converter = converter
            self.file = file
            self.options = options
            super.init(viewMode: .sourceAccurate)
        }

        func collectTypes(_ tree: SourceFileSyntax) {
            final class TypeCollector: SyntaxVisitor {
                var types: [String: String] = [:]
                override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
                    guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }
                    if let t = node.typeAnnotation?.type { types[name] = t.trimmedDescription }
                    else if let v = node.initializer?.value { types[name] = SwiftVisitor.literalType(v) }
                    return .visitChildren
                }
                override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
                    types[(node.secondName ?? node.firstName).text] = node.type.trimmedDescription
                    return .visitChildren
                }
            }
            let c = TypeCollector(viewMode: .sourceAccurate)
            c.walk(tree)
            types = c.types
        }

        static func literalType(_ e: ExprSyntax) -> String? {
            if e.is(IntegerLiteralExprSyntax.self) { return "Int" }
            if e.is(FloatLiteralExprSyntax.self) { return "Double" }
            if e.is(StringLiteralExprSyntax.self) { return "String" }
            if let call = e.as(FunctionCallExprSyntax.self), let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
               ["Int", "Double", "Float", "String", "UInt", "CGFloat"].contains(name) { return name }
            return nil
        }

        /// The format specifier an interpolated value becomes (what a
        /// `LocalizedStringKey` or `String.LocalizationValue` interpolation
        /// writes for the value's type); `%@` when the type is unknown.
        func specifier(for e: ExprSyntax) -> String {
            var type: String?
            if let t = Self.literalType(e) { type = t }
            else if let r = e.as(DeclReferenceExprSyntax.self) { type = types[r.baseName.text] }
            else if let m = e.as(MemberAccessExprSyntax.self) {
                if m.declName.baseName.text == "count" { type = "Int" }
                else if let b = m.base?.as(DeclReferenceExprSyntax.self), b.baseName.text == "self" { type = types[m.declName.baseName.text] }
            }
            let t = (type ?? "").replacingOccurrences(of: "?", with: "")
            switch t {
            case "Int", "Int64", "Int32", "Int16", "Int8": return "%lld"
            case "UInt", "UInt64", "UInt32", "UInt16", "UInt8": return "%llu"
            case "Double", "CGFloat": return "%lf"
            case "Float": return "%f"
            default: return "%@"
            }
        }

        func line(_ node: some SyntaxProtocol) -> Int { node.startLocation(converter: converter).line }

        /// A string literal's value as a localization key: interpolations
        /// become format specifiers and `%` becomes `%%` (`interpolated`),
        /// or the plain value. Nil when it is not a literal.
        func literalKey(_ e: ExprSyntax?, interpolated: Bool) -> String? {
            guard let lit = e?.as(StringLiteralExprSyntax.self) else { return nil }
            let pounds = lit.openingPounds?.text.count ?? 0
            var out = ""
            var hasInterpolation = false
            for seg in lit.segments {
                if let s = seg.as(StringSegmentSyntax.self) {
                    let v = Self.unescape(s.content.text, pounds: pounds, multiline: lit.openingQuote.tokenKind == .multilineStringQuote)
                    out += interpolated ? v.replacingOccurrences(of: "%", with: "%%") : v
                } else if let x = seg.as(ExpressionSegmentSyntax.self) {
                    hasInterpolation = true
                    if let first = x.expressions.first { out += specifier(for: first.expression) } else { out += "%@" }
                }
            }
            // A literal without interpolation is used as written (a key
            // with a literal `%` stays as typed).
            if !hasInterpolation, interpolated { return out.replacingOccurrences(of: "%%", with: "%") }
            return out
        }

        static func unescape(_ raw: String, pounds: Int, multiline: Bool) -> String {
            let escape = "\\" + String(repeating: "#", count: pounds)
            guard raw.contains(escape) || multiline else { return raw }
            var out = ""
            var u = Substring(raw)
            while let r = u.range(of: escape) {
                out += u[..<r.lowerBound]
                u = u[r.upperBound...]
                guard let c = u.first else { break }
                u = u.dropFirst()
                switch c {
                case "n": out += "\n"
                case "t": out += "\t"
                case "r": out += "\r"
                case "0": out += "\0"
                case "\\": out += "\\"
                case "\"": out += "\""
                case "'": out += "'"
                case "u":
                    if u.first == "{", let close = u.firstIndex(of: "}") {
                        let hex = u[u.index(after: u.startIndex)..<close]
                        if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { out.unicodeScalars.append(s) }
                        u = u[u.index(after: close)...]
                    }
                case "\n", "\r", " ", "\t":
                    // A multi-line string's line continuation.
                    if multiline { u = Substring(u.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) }
                default: out.append(c)
                }
            }
            return out + u
        }

        func plainString(_ e: ExprSyntax?) -> String? { literalKey(e, interpolated: false) }

        func arg(_ call: FunctionCallExprSyntax, _ label: String) -> ExprSyntax? {
            call.arguments.first { $0.label?.text == label }?.expression
        }

        func add(_ key: String?, defaultValue: String? = nil, comment: String? = nil, table: String? = nil, at node: some SyntaxProtocol,
                 literal: (some SyntaxProtocol)? = nil as ExprSyntax?) {
            guard let key else { return }
            offsets.append((literal.map { Syntax($0) } ?? Syntax(node)).positionAfterSkippingLeadingTrivia.utf8Offset)
            found.append(ExtractedString(key: key, defaultValue: defaultValue == key ? nil : defaultValue, comment: comment?.isEmpty == true ? nil : comment,
                                         table: table ?? "Localizable", file: file, line: line(node)))
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            let first = node.arguments.first
            let callee: String?
            let isModifier: Bool
            if let r = node.calledExpression.as(DeclReferenceExprSyntax.self) {
                callee = r.baseName.text
                isModifier = false
            } else if let m = node.calledExpression.as(MemberAccessExprSyntax.self) {
                // `String.LocalizationValue(…)`, `.navigationTitle(…)`, `SwiftUI.Text(…)`.
                // A qualified name (`SwiftUI.Text`, `String.LocalizationValue`)
                // is an initializer; anything else is a modifier call.
                if let base = m.base, Self.isTypeName(base) {
                    let b = base.trimmedDescription
                    callee = b == "SwiftUI" ? m.declName.baseName.text : "\(b).\(m.declName.baseName.text)"
                    isModifier = false
                } else {
                    callee = m.declName.baseName.text
                    isModifier = true
                }
            } else {
                return .visitChildren
            }
            guard let callee else { return .visitChildren }
            let comment = plainString(arg(node, "comment"))
            switch callee {
            case "String", "AttributedString":
                if first?.label?.text == "localized" {
                    add(literalKey(first?.expression, interpolated: true), defaultValue: literalKey(arg(node, "defaultValue"), interpolated: true),
                        comment: comment, table: plainString(arg(node, "table")), at: node, literal: first?.expression)
                }
            case "LocalizedStringResource", "String.LocalizationValue", "LocalizedStringKey":
                if first?.label == nil {
                    add(literalKey(first?.expression, interpolated: true), defaultValue: literalKey(arg(node, "defaultValue"), interpolated: true),
                        comment: comment, table: plainString(arg(node, "table")), at: node, literal: first?.expression)
                }
            case _ where options.allMacroNames.contains(callee):
                // NSLocalizedString(_ key:, tableName:, bundle:, value:, comment:)
                if first?.label == nil {
                    add(plainString(first?.expression), defaultValue: plainString(arg(node, "value")).flatMap { $0.isEmpty ? nil : $0 },
                        comment: comment, table: plainString(arg(node, "tableName")), at: node, literal: first?.expression)
                }
            default:
                guard options.swiftUI, first?.label == nil else { break }
                let name = callee.split(separator: ".").last.map(String.init) ?? callee
                if (!isModifier && Self.swiftUIInitializersSet.contains(name)) || (isModifier && StringExtractor.swiftUIModifiers.contains(name)) {
                    add(literalKey(first?.expression, interpolated: true), comment: comment,
                        table: plainString(arg(node, "tableName")), at: node, literal: first?.expression)
                }
            }
            return .visitChildren
        }

        /// `Name` or `Module.Name` with capitalized or module components.
        static func isTypeName(_ e: ExprSyntax) -> Bool {
            if let r = e.as(DeclReferenceExprSyntax.self) { return r.baseName.text.first?.isUppercase ?? false }
            if let m = e.as(MemberAccessExprSyntax.self), let b = m.base { return isTypeName(b) && (m.declName.baseName.text.first?.isUppercase ?? false) }
            return false
        }

        static var swiftUIInitializersSet: Set<String> { StringExtractor.swiftUIInitializers }

        /// `let title: LocalizedStringKey = "…"` (and `LocalizedStringResource`).
        override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
            if let t = node.typeAnnotation?.type.trimmedDescription, StringExtractor.stringTypes.contains(t),
               let key = literalKey(node.initializer?.value, interpolated: true) {
                add(key, at: node)
            }
            return .visitChildren
        }
    }

    // MARK: Objective-C and C

    /// The argument positions of the NSLocalizedString family, by suffix:
    /// (key, table, value, comment).
    static let macroShapes: [(suffix: String, key: Int, table: Int?, value: Int?, comment: Int)] = [
        ("", 0, nil, nil, 1), ("FromTable", 0, 1, nil, 2), ("FromTableInBundle", 0, 1, nil, 3), ("WithDefaultValue", 0, 1, 3, 4),
    ]

    public static func extractObjC(_ source: String, file: String = "", options: Options = Options()) -> [ExtractedString] {
        let tokens = CTokenizer.tokens(source)
        var out: [ExtractedString] = []
        var i = 0
        while i < tokens.count {
            defer { i += 1 }
            guard case .identifier(let name) = tokens[i].kind, i + 1 < tokens.count, tokens[i + 1].kind == .punct("(") else { continue }
            guard let base = options.allMacroNames.first(where: { name.hasPrefix($0) }),
                  let shape = macroShapes.first(where: { base + $0.suffix == name }) else { continue }
            // Arguments split at top-level commas; each a string or not.
            let line = tokens[i].line
            var args: [String?] = []
            var depth = 0
            var current: String?
            var plain = true
            var j = i + 2
            while j < tokens.count {
                let t = tokens[j]
                if depth == 0, t.kind == .punct(")") { args.append(plain ? current : nil); break }
                if depth == 0, t.kind == .punct(",") {
                    args.append(plain ? current : nil)
                    current = nil
                    plain = true
                    j += 1
                    continue
                }
                switch t.kind {
                case .string(let s): current = (current ?? "") + s
                case .punct("@"), .identifier("CFSTR"): break
                case .punct("("):
                    depth += 1
                    if tokens[j - 1].kind != .identifier("CFSTR") { plain = false }
                case .punct(")"): depth -= 1
                default: plain = false
                }
                j += 1
            }
            i = j
            guard args.count > shape.comment, let key = args[shape.key] else { continue }
            out.append(ExtractedString(key: key, defaultValue: shape.value.flatMap { args[$0] }.flatMap { $0.isEmpty || $0 == key ? nil : $0 },
                                       comment: args[shape.comment].flatMap { $0.isEmpty ? nil : $0 },
                                       table: shape.table.flatMap { args[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? "Localizable",
                                       file: file, line: line))
        }
        return out
    }
}

/// A C-family tokenizer good enough for finding string arguments: it skips
/// comments, character literals and `#if 0` blocks, joins nothing.
enum CTokenizer {
    enum Kind: Equatable { case identifier(String), string(String), punct(String), other }
    struct Token { var kind: Kind; var line: Int }

    static func tokens(_ s: String) -> [Token] {
        let u = Array(s.unicodeScalars)
        var out: [Token] = []
        var i = 0, line = 1
        var atLineStart = true
        var skipDepth = 0 // inside `#if 0`
        var ifDepth = 0
        func isIdent(_ c: Unicode.Scalar) -> Bool { c == "_" || c == "$" || (c.isASCII && CharacterSet.alphanumerics.contains(c)) }
        while i < u.count {
            let c = u[i]
            if c == "\n" { line += 1; i += 1; atLineStart = true; continue }
            if c == " " || c == "\t" || c == "\r" { i += 1; continue }
            if c == "/", i + 1 < u.count, u[i + 1] == "/" { while i < u.count, u[i] != "\n" { i += 1 }; continue }
            if c == "/", i + 1 < u.count, u[i + 1] == "*" {
                i += 2
                while i + 1 < u.count, !(u[i] == "*" && u[i + 1] == "/") { if u[i] == "\n" { line += 1 }; i += 1 }
                i += 2
                continue
            }
            if c == "#", atLineStart {
                // A preprocessor line: track #if 0 … #endif.
                var j = i + 1
                var text = ""
                while j < u.count, u[j] != "\n" {
                    if u[j] == "\\", j + 1 < u.count, u[j + 1] == "\n" { line += 1; j += 2; continue }
                    text.unicodeScalars.append(u[j])
                    j += 1
                }
                let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                switch words.first {
                case "if", "ifdef", "ifndef":
                    if skipDepth > 0 { skipDepth += 1 } else if words.first == "if", words.count > 1, words[1] == "0" { skipDepth = 1 } else { ifDepth += 1 }
                case "else", "elif":
                    if skipDepth == 1 { skipDepth = 0; ifDepth += 1 }
                case "endif":
                    if skipDepth > 0 { skipDepth -= 1 } else { ifDepth = max(0, ifDepth - 1) }
                default: break
                }
                i = j
                continue
            }
            atLineStart = false
            if skipDepth > 0 {
                if c == "\"" || c == "'" {
                    i += 1
                    while i < u.count, u[i] != c, u[i] != "\n" { if u[i] == "\\" { i += 1 }; i += 1 }
                }
                i += 1
                continue
            }
            if c == "\"" {
                var j = i + 1
                var v = String.UnicodeScalarView()
                while j < u.count, u[j] != "\"" {
                    if u[j] == "\\", j + 1 < u.count {
                        j += 1
                        switch u[j] {
                        case "n": v.append("\n")
                        case "t": v.append("\t")
                        case "r": v.append("\r")
                        case "\\": v.append("\\")
                        case "\"": v.append("\"")
                        case "'": v.append("'")
                        case "a": v.append("\u{07}")
                        case "0"..."7":
                            var oct = String(u[j])
                            while oct.count < 3, j + 1 < u.count, ("0"..."7").contains(u[j + 1]) { j += 1; oct.unicodeScalars.append(u[j]) }
                            v.append(Unicode.Scalar(UInt32(oct, radix: 8) ?? 0) ?? "\u{FFFD}")
                        case "u", "U":
                            let n = u[j] == "u" ? 4 : 8
                            var hex = ""
                            while hex.count < n, j + 1 < u.count, u[j + 1].properties.isASCIIHexDigit { j += 1; hex.unicodeScalars.append(u[j]) }
                            v.append(Unicode.Scalar(UInt32(hex, radix: 16) ?? 0xFFFD) ?? "\u{FFFD}")
                        case "\n": line += 1
                        default: v.append(u[j])
                        }
                    } else {
                        if u[j] == "\n" { line += 1 }
                        v.append(u[j])
                    }
                    j += 1
                }
                out.append(Token(kind: .string(String(v)), line: line))
                i = j + 1
                continue
            }
            if c == "'" {
                i += 1
                while i < u.count, u[i] != "'", u[i] != "\n" { if u[i] == "\\" { i += 1 }; i += 1 }
                i += 1
                out.append(Token(kind: .other, line: line))
                continue
            }
            if isIdent(c) {
                var j = i
                var name = ""
                while j < u.count, isIdent(u[j]) { name.unicodeScalars.append(u[j]); j += 1 }
                out.append(Token(kind: .identifier(name), line: line))
                i = j
                continue
            }
            out.append(Token(kind: .punct(String(c)), line: line))
            i += 1
        }
        return out
    }
}
