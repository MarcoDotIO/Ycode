/// A lexical Swift lexer (no parser): comments (nested block comments),
/// doc comments, strings (multi-line, raw, with interpolations), numbers,
/// keywords, `@attributes`, `#directives`, placeholders and capitalized
/// identifiers as type names. The structure model and the typing rules
/// use it; highlighting uses swift-syntax's parser (`SwiftClassifier`)
/// and falls back to this. Lexical structure: The Swift Programming
/// Language, "Lexical Structure" (public).
struct SwiftLineLexer: LineLexer {
    static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
        "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
        "where", "while", "as", "Any", "await", "false", "is", "nil", "self", "Self", "super", "throws", "true",
        "try", "async", "actor", "some", "any", "convenience", "dynamic", "final", "lazy", "mutating",
        "nonmutating", "optional", "override", "required", "weak", "unowned", "indirect", "consume", "borrowing",
        "consuming", "nonisolated", "isolated", "package", "macro", "get", "set", "willSet", "didSet", "then",
        "each", "repeat", "sending", "discard",
    ]
    /// `#` words that are compiler directives (the rest, `#selector`,
    /// `#Preview`, `#expect`, are expressions or macros: keywords).
    static let directives: Set<String> = ["#if", "#elseif", "#else", "#endif", "#sourceLocation", "#warning", "#error"]

    enum Mode: UInt8 { case plain = 0, blockComment = 1, multilineString = 2 }

    func lex(_ l: LineText, state: inout LexState, into out: inout [SyntaxToken]) {
        var i = l.start
        // Continue a token from the previous line.
        if state.mode == Mode.blockComment.rawValue {
            let kind = state.open ?? .comment
            i = blockCommentEnd(l, from: i, depth: &state.depth)
            out.add(kind, l.start, i)
            if state.depth > 0 { return }
            state = .initial
        } else if state.mode == Mode.multilineString.rawValue {
            let (end, closed) = multilineStringEnd(l, from: i, hashes: Int(state.aux))
            out.add(.string, l.start, end)
            i = end
            if !closed { return }
            state = .initial
        }
        while i < l.end {
            let c = l[i]
            let s = i
            if isSpace(c) { i += 1; continue }
            if c == 47, l[i + 1] == 47 {   // //
                let doc = l[i + 2] == 47 && l[i + 3] != 47
                out.add(doc ? .docComment : .comment, s, l.end)
                return
            }
            if c == 47, l[i + 1] == 42 {   // /*
                let doc = l[i + 2] == 42 && l[i + 3] != 42 && l[i + 3] != 47
                var depth: Int32 = 1
                i = blockCommentEnd(l, from: i + 2, depth: &depth)
                out.add(doc ? .docComment : .comment, s, i)
                if depth > 0 { state = LexState(open: doc ? .docComment : .comment, mode: Mode.blockComment.rawValue, depth: depth) }
                continue
            }
            if c == 34 || (c == 35 && hashesThenQuote(l, i) != nil) {   // " or #"
                var hashes = 0
                if c == 35 { hashes = hashesThenQuote(l, i)!; i += hashes }
                if l[i + 1] == 34 && l[i + 2] == 34 {   // """
                    i += 3
                    let (end, closed) = multilineStringEnd(l, from: i, hashes: hashes)
                    out.add(.string, s, end)
                    i = end
                    if !closed { state = LexState(open: .string, mode: Mode.multilineString.rawValue, aux: Int32(hashes)) }
                    continue
                }
                i = stringEnd(l, from: i + 1, hashes: hashes)
                out.add(.string, s, i)
                continue
            }
            if isDigit(c) {
                i = numberEnd(l, i)
                out.add(.number, s, i)
                continue
            }
            if c == 64, isIdentStart(l[i + 1]) {   // @attribute
                i += 1
                while i < l.end, isIdentPart(l[i]) { i += 1 }
                out.add(.attribute, s, i)
                continue
            }
            if c == 35, isIdentStart(l[i + 1]) {   // #directive, #keyword
                i += 1
                while i < l.end, isIdentPart(l[i]) { i += 1 }
                out.add(l.word(s, i, in: Self.directives) ? .preprocessor : .keyword, s, i)
                continue
            }
            if c == 60, let e = placeholderEnd(l, i) {
                out.add(.placeholder, s, e)
                i = e
                continue
            }
            if c == 96 {   // `identifier`
                i += 1
                while i < l.end, l[i] != 96 { i += 1 }
                i = min(i + 1, l.end)
                continue
            }
            if isIdentStart(c) || c == 36 {
                i += 1
                while i < l.end, isIdentPart(l[i]) { i += 1 }
                if c != 36 {
                    if l.word(s, i, in: Self.keywords) {
                        // `.default`, `.init` after a dot are member names.
                        if s > l.start, l[s - 1] == 46, l.string(s, i) != "init", l.string(s, i) != "self" { continue }
                        out.add(.keyword, s, i)
                    } else if isUpper(c), !inImportPath(l, before: s) {
                        out.add(.typeName, s, i)
                    }
                }
                continue
            }
            i += 1
        }
    }

    /// Declaration kinds an `import` can name (`import struct M.T`).
    static let importKinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let", "actor", "macro"]

    /// Whether the name at `s` is a component of an `import` path
    /// (`import Foundation`, `import struct Foundation.Date`): the module
    /// path is plain text, not a type (`editor-area.md` §D.1).
    func inImportPath(_ l: LineText, before s: Int) -> Bool {
        var j = s - 1
        func skipSpaces() { while j >= l.start, isSpace(l[j]) { j -= 1 } }
        // The word ending at `j` (inclusive), moving `j` before it.
        func previousWord() -> String? {
            let e = j + 1
            while j >= l.start, isIdentPart(l[j]) { j -= 1 }
            return e > j + 1 ? l.string(j + 1, e) : nil
        }
        skipSpaces()
        // Earlier components: `Name.` before this one.
        while j >= l.start, l[j] == 46 {
            j -= 1
            skipSpaces()
            guard previousWord() != nil else { return false }
            skipSpaces()
        }
        guard let w = previousWord() else { return false }
        if w == "import" { return true }
        guard Self.importKinds.contains(w) else { return false }
        skipSpaces()
        return previousWord() == "import"
    }

    /// The number of `#` before a `"` at `i`, or nil.
    func hashesThenQuote(_ l: LineText, _ i: Int) -> Int? {
        var j = i
        while l[j] == 35 { j += 1 }
        return l[j] == 34 && j > i ? j - i : nil
    }

    /// The end of a block comment whose body starts at `i` (nesting).
    func blockCommentEnd(_ l: LineText, from i: Int, depth: inout Int32) -> Int {
        var j = i
        while j < l.end {
            if l[j] == 47 && l[j + 1] == 42 { depth += 1; j += 2 }
            else if l[j] == 42 && l[j + 1] == 47 { depth -= 1; j += 2; if depth == 0 { return j } }
            else { j += 1 }
        }
        return l.end
    }

    /// Whether `"` followed by `hashes` `#` closes a string at `j`.
    @inline(__always) func closes(_ l: LineText, _ j: Int, hashes: Int) -> Bool {
        for k in 0..<hashes where l[j + 1 + k] != 35 { return false }
        return true
    }

    /// The end of a single-line string whose body starts at `i`.
    func stringEnd(_ l: LineText, from i: Int, hashes: Int) -> Int {
        var j = i
        while j < l.end {
            let c = l[j]
            if c == 92, closes(l, j, hashes: hashes) {   // \ (or \#)
                if l[j + 1 + hashes] == 40 { j = interpolationEnd(l, from: j + 2 + hashes); continue }
                j += 2 + hashes
                continue
            }
            if c == 34, closes(l, j, hashes: hashes) { return j + 1 + hashes }
            j += 1
        }
        return l.end
    }

    /// The end of a multi-line string body starting at `i`, and whether it closed.
    func multilineStringEnd(_ l: LineText, from i: Int, hashes: Int) -> (Int, Bool) {
        var j = i
        while j < l.end {
            let c = l[j]
            if c == 92, closes(l, j, hashes: hashes) {
                if l[j + 1 + hashes] == 40 { j = interpolationEnd(l, from: j + 2 + hashes); continue }
                j += 2 + hashes
                continue
            }
            if c == 34, l[j + 1] == 34, l[j + 2] == 34, closes(l, j + 2, hashes: hashes) { return (j + 3 + hashes, true) }
            j += 1
        }
        return (l.end, false)
    }

    /// The end of `\( … )` whose body starts at `i` (nested parentheses and strings).
    func interpolationEnd(_ l: LineText, from i: Int) -> Int {
        var depth = 1
        var j = i
        while j < l.end {
            let c = l[j]
            if c == 40 { depth += 1 }
            else if c == 41 { depth -= 1; if depth == 0 { return j + 1 } }
            else if c == 34 { j = stringEnd(l, from: j + 1, hashes: 0); continue }
            j += 1
        }
        return l.end
    }
}
