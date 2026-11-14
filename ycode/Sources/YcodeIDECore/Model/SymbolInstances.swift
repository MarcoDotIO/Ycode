import Foundation

/// Editing ▸ Display ▸ Highlight instances of selected symbol
/// (`source-editor.md` §Evidence: on by default, after 0.25 s;
/// `fidelity-council.md` row 227). The reference highlights the instances
/// of the **symbol** at the insertion point: a click on a word inside a
/// comment highlights nothing. So only an identifier in code counts, never
/// a word in a comment or a string (nor a keyword or a number), and only
/// its instances in code are highlighted. Both IDEs ask this.
public enum SymbolInstances {
    /// The ranges (UTF-16) to highlight for the caret at `caret` in `text`:
    /// every instance in code of the identifier the caret is in; empty when
    /// the caret is not in an identifier in code.
    public static func ranges(in text: String, caret: Int, language: SourceTokenizer.Language) -> [NSRange] {
        let ns = text as NSString
        guard let word = identifierRange(in: ns, at: caret) else { return [] }
        let excluded = nonSymbolRanges(in: text, language: language)
        guard !excluded.contains(where: { overlaps($0, word) }) else { return [] }
        let name = ns.substring(with: word)
        let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range).filter { r in
            !excluded.contains { overlaps($0, r) }
        }
    }

    /// The identifier around `caret` (letters, digits and underscores, not
    /// starting with a digit), or nil.
    public static func identifierRange(in ns: NSString, at caret: Int) -> NSRange? {
        guard ns.length > 0, caret >= 0, caret <= ns.length else { return nil }
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let u = UnicodeScalar(ns.character(at: i)) else { return false }
            return u == "_" || CharacterSet.alphanumerics.contains(u)
        }
        var a = caret, b = caret
        while isWord(a - 1) { a -= 1 }
        while isWord(b) { b += 1 }
        guard b > a, let first = UnicodeScalar(ns.character(at: a)), !CharacterSet.decimalDigits.contains(first) else { return nil }
        return NSRange(location: a, length: b - a)
    }

    /// The ranges that hold no symbol: comments, strings, keywords, numbers,
    /// preprocessor directives and attributes (`SyntaxTokenKind.Role`).
    static func nonSymbolRanges(in text: String, language: SourceTokenizer.Language) -> [NSRange] {
        SourceTokenizer(language: language).tokens(in: text).compactMap { t in
            switch t.kind {
            case .comment, .docComment, .string, .keyword, .number, .preprocessor, .attribute: t.range
            default: nil
            }
        }
    }

    static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location < b.location + b.length && b.location < a.location + a.length
    }
}
