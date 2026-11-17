import Foundation

/// When the editor asks the language server for completions on its own,
/// while the user types (`specs/ide/language.md` §Features; parity
/// inventory P-080). Shared by the macOS editor and the Linux editor.
///
/// - A `.` typed in Swift asks for the members of what precedes it.
/// - The first character of a word (a letter or `_` typed after a
///   character that is not part of an identifier) asks for the names that
///   start with it, so typing "Co" on a new line opens the list (CodingKey,
///   Counter, Codable…). The list then filters as the word grows; it is not
///   asked for again within the word.
/// - Never inside a comment or a string literal, after a number, or where a
///   new name is being declared (`let x`, `func f`, `struct S`…).
public enum CompletionTrigger {
    public enum Kind: Equatable, Sendable {
        /// After a `.`: the members of the expression before it.
        case member
        /// At the start of a word: names starting with what was typed.
        case word
    }

    /// Keywords after which the next word is a new name, not a use.
    static let declaringKeywords: Set<String> = [
        "let", "var", "func", "struct", "class", "enum", "protocol", "typealias", "actor",
        "associatedtype", "macro", "precedencegroup", "operator",
    ]

    /// What to ask for after `typed` was inserted, given the text of the
    /// caret's line before the caret (`typed` included); nil for nothing.
    /// `memberAccess` enables the `.` trigger (Swift).
    public static func kind(typed: String, lineBeforeCaret line: String, memberAccess: Bool = true) -> Kind? {
        guard typed.count == 1, let c = typed.unicodeScalars.first, !inCommentOrString(line) else { return nil }
        if c == "." {
            guard memberAccess else { return nil }
            // Not the second dot of a range operator, nor a number's decimal point.
            let before = line.unicodeScalars.dropLast().last
            if before == "." || before.map(CharacterSet.decimalDigits.contains) == true { return nil }
            return .member
        }
        guard isIdentifierStart(c) else { return nil }
        let scalars = Array(line.unicodeScalars.dropLast())
        if let prev = scalars.last, isIdentifierPart(prev) || prev == "$" || prev == "#" || prev == "@" || prev == "\\" { return nil }
        // The word before, skipping blanks: a declaring keyword means a new name.
        var i = scalars.count
        while i > 0, scalars[i - 1] == " " || scalars[i - 1] == "\t" { i -= 1 }
        var j = i
        while j > 0, isIdentifierPart(scalars[j - 1]) { j -= 1 }
        if j < i, i < scalars.count {
            let word = String(String.UnicodeScalarView(scalars[j..<i]))
            if declaringKeywords.contains(word) { return nil }
        }
        return .word
    }

    /// Whether the end of `line` is inside a `//` comment, a `/* */`
    /// comment opened on this line, or a string literal opened on this line.
    public static func inCommentOrString(_ line: String) -> Bool {
        var inString = false, inBlock = false
        let s = Array(line.unicodeScalars)
        var i = 0
        while i < s.count {
            let c = s[i], next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
            if inBlock {
                if c == "*", next == "/" { inBlock = false; i += 2; continue }
            } else if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
            } else {
                if c == "/", next == "/" { return true }
                if c == "/", next == "*" { inBlock = true; i += 2; continue }
                if c == "\"" { inString = true }
            }
            i += 1
        }
        return inString || inBlock
    }

    static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        c == "_" || CharacterSet.letters.contains(c)
    }

    static func isIdentifierPart(_ c: Unicode.Scalar) -> Bool {
        c == "_" || CharacterSet.alphanumerics.contains(c)
    }
}
