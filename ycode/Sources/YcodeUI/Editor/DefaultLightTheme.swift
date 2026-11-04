import AppKit
import YcodeIDECore
import YcodeSyntax

/// "Ycode Default" in the light appearance takes the colours measured for
/// the council (`specs/ide/editor-area.md` §C.4, `fidelity-council.md`
/// row 10; the owner's decision): keyword #C4246E, plain #322529, comment
/// #6A7084, string #CA2B1C, number #0178B8, type in use #9D31CF, type
/// declaration #007D9E, other declaration #006178, line number #B8B3B4.
/// The dark appearance keeps the system colours it had; roles the spec did
/// not measure (doc comments, preprocessor, attributes) keep theirs too.
@MainActor
enum DefaultLightTheme {
    /// Whether the selected theme is the built-in default (no colours of
    /// its own).
    static var applies: Bool {
        let t = Theme.current
        return t.name == EditorTheme.builtIns[0].name && t.tokens.isEmpty && t.foreground == nil
    }

    /// The measured light values, by theme role.
    static let lightHex: [SyntaxTokenKind.Role: String] = [
        .keyword: "#C4246E", .comment: "#6A7084", .string: "#CA2B1C", .number: "#0178B8", .typeName: "#9D31CF",
    ]
    static let plainHex = "#322529"
    static let lineNumberHex = "#B8B3B4"
    static let typeDeclarationHex = "#007D9E"
    static let otherDeclarationHex = "#006178"

    /// One instance per colour, so equal colours compare equal.
    private static var cache: [String: NSColor] = [:]

    /// `hex` in the light appearance, `dark` in the dark one.
    static func dynamic(_ hex: String, dark: NSColor) -> NSColor {
        let key = hex + "|" + (dark.colorNameComponentIfAny ?? "\(ObjectIdentifier(dark))")
        if let c = cache[key] { return c }
        let light = EditorTheme.color(hex) ?? dark
        let c = NSColor(name: NSColor.Name("ycode.default." + hex)) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
        cache[key] = c
        return c
    }

    static var plain: NSColor { dynamic(plainHex, dark: .textColor) }
    static var lineNumber: NSColor { dynamic(lineNumberHex, dark: .secondaryLabelColor) }
    static var typeDeclaration: NSColor { dynamic(typeDeclarationHex, dark: .textColor) }
    static var otherDeclaration: NSColor { dynamic(otherDeclarationHex, dark: .textColor) }

    /// Keywords whose next name is a type declaration, or another
    /// declaration.
    static let typeDeclarationKeywords: Set<String> = ["struct", "class", "enum", "protocol", "actor", "typealias", "associatedtype"]
    static let otherDeclarationKeywords: Set<String> = ["let", "var", "func", "case", "macro"]

    /// Colours the name after a declaring keyword (`struct Section00`,
    /// `let value00`, `func describe`).
    static func colorDeclarations(_ tokens: [SyntaxToken], in storage: NSTextStorage, range: NSRange) {
        let ns = storage.string as NSString
        func isName(_ c: unichar, first: Bool) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || (!first && c >= 48 && c <= 57) || c > 127
        }
        for t in tokens where t.kind == .keyword && NSMaxRange(t.range) <= ns.length {
            let k = ns.substring(with: t.range)
            let color: NSColor? = typeDeclarationKeywords.contains(k) ? typeDeclaration
                : (otherDeclarationKeywords.contains(k) ? otherDeclaration : nil)
            guard let color else { continue }
            // The name after the keyword and its spaces (names are not
            // tokens of their own).
            var i = NSMaxRange(t.range)
            while i < ns.length, [32, 9].contains(ns.character(at: i)) { i += 1 }
            let start = i
            while i < ns.length, isName(ns.character(at: i), first: i == start) { i += 1 }
            let r = NSIntersectionRange(NSRange(location: start, length: i - start), range)
            if i > start, r.length > 0 { storage.addAttribute(.foregroundColor, value: color, range: r) }
        }
    }
}

private extension NSColor {
    /// A catalog colour's name, to key the cache.
    var colorNameComponentIfAny: String? { type == .catalog ? catalogNameComponent : nil }
}
