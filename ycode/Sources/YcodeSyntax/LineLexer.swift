/// The lexer state at a line boundary: everything a line lexer needs to
/// continue on the next line (an open block comment, a multi-line
/// string, a here-document, a fenced code block, …). Two lines that start
/// in equal states lex the same, which is what lets the highlighter stop
/// re-lexing after an edit (`SyntaxHighlighter`).
public struct LexState: Hashable, Sendable {
    /// The kind of the token that continues onto the next line; nil when
    /// the line ends between tokens.
    public var open: SyntaxTokenKind?
    /// Lexer-specific mode (0: plain).
    public var mode: UInt8
    /// Lexer-specific counters: comment nesting, `#` count of a raw
    /// string, a fence length, an indentation column.
    public var depth: Int32
    public var aux: Int32
    /// A delimiter that must be matched (a here-document word, a C++ raw
    /// string delimiter).
    public var delimiter: [UInt16]

    public init(open: SyntaxTokenKind? = nil, mode: UInt8 = 0, depth: Int32 = 0, aux: Int32 = 0, delimiter: [UInt16] = []) {
        self.open = open
        self.mode = mode
        self.depth = depth
        self.aux = aux
        self.delimiter = delimiter
    }

    public static let initial = LexState()
}

/// One line of UTF-16 text inside a larger buffer: `start..<end`, the
/// newline excluded. Reads past the line return 0.
public struct LineText {
    public let units: UnsafeBufferPointer<UInt16>
    public let start: Int
    public let end: Int

    @inline(__always) public subscript(_ i: Int) -> UInt16 { i >= start && i < end ? units[i] : 0 }

    /// Whether `ascii` occurs at `i`.
    @inline(__always) func matches(_ ascii: StaticString, at i: Int) -> Bool {
        let n = ascii.utf8CodeUnitCount
        guard i + n <= end else { return false }
        return ascii.withUTF8Buffer { b in
            for k in 0..<n where units[i + k] != UInt16(b[k]) { return false }
            return true
        }
    }

    /// The first offset at or after `i` where `ascii` occurs, else nil.
    func find(_ ascii: StaticString, from i: Int) -> Int? {
        var j = i
        let n = ascii.utf8CodeUnitCount
        while j + n <= end {
            if matches(ascii, at: j) { return j }
            j += 1
        }
        return nil
    }

    func firstNonSpace(from i: Int) -> Int {
        var j = i
        while j < end, units[j] == 32 || units[j] == 9 { j += 1 }
        return j
    }

    /// The text of `a..<b` as a String (keyword lookups).
    func string(_ a: Int, _ b: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: units[a..<b]), as: UTF16.self)
    }

    /// Whether `a..<b` is in `set` (ASCII words only: faster than building a String).
    func word(_ a: Int, _ b: Int, in set: Set<String>) -> Bool {
        guard b - a <= 24 else { return false }
        return set.contains(string(a, b))
    }

    var isBlank: Bool { firstNonSpace(from: start) == end }
}

/// A lexer that colors one line at a time, carrying `LexState` across
/// line ends.
public protocol LineLexer: Sendable {
    /// Lexes `line`, appending tokens (offsets into `line.units`) and
    /// updating `state` to the state at the line's end.
    func lex(_ line: LineText, state: inout LexState, into tokens: inout [SyntaxToken])
}

// MARK: Character classes

@inline(__always) func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
@inline(__always) func isHexDigit(_ c: UInt16) -> Bool { isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }
@inline(__always) func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
@inline(__always) func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
@inline(__always) func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
@inline(__always) func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }

extension Array where Element == SyntaxToken {
    @inline(__always) mutating func add(_ kind: SyntaxTokenKind, _ a: Int, _ b: Int) {
        if b > a { append(SyntaxToken(kind: kind, location: a, length: b - a)) }
    }
}

/// Scans an editor placeholder `<#…#>` starting at `i` (on one line); its end, or nil.
func placeholderEnd(_ l: LineText, _ i: Int) -> Int? {
    guard l[i] == 60, l[i + 1] == 35 else { return nil }
    var j = i + 2
    while j + 1 < l.end {
        if l[j] == 35 && l[j + 1] == 62 { return j > i + 2 ? j + 2 : nil }
        j += 1
    }
    return nil
}

/// Scans a number starting at `i`: digits, letters (hex digits,
/// suffixes, `0x`), `_` and `'` separators, a fraction and a signed
/// exponent. Returns its end.
func numberEnd(_ l: LineText, _ i: Int, separator: UInt16 = 95) -> Int {
    var j = i
    let hex = l[i] == 48 && (l[i + 1] == 120 || l[i + 1] == 88)
    while j < l.end {
        let c = l[j]
        if isIdentPart(c) || c == separator {
            // A signed exponent: e+ / e- (decimal), p+ / p- (hex).
            if (!hex && (c == 101 || c == 69)) || (hex && (c == 112 || c == 80)), l[j + 1] == 43 || l[j + 1] == 45, isDigit(l[j + 2]) { j += 2 }
            j += 1
        } else if c == 46, isDigit(l[j + 1]) {
            j += 1
        } else {
            break
        }
    }
    return j
}

/// The lexer for a language (nil: plain text).
public enum SyntaxLexers {
    public static func lexer(for language: SyntaxLanguage) -> (any LineLexer)? {
        switch language {
        case .swift: SwiftLineLexer()
        case .c, .cpp, .objc, .metal: CFamilyLexer(dialect: language)
        case .json: JSONLexer()
        case .xml: XMLLexer()
        case .markdown: MarkdownLexer()
        case .yaml: YAMLLexer()
        case .shell: ShellLexer()
        case .xcconfig: XcconfigLexer()
        case .plain: nil
        }
    }

    /// Lexes a whole text line by line: the tokens (line pieces of
    /// multi-line tokens joined into one) in UTF-16 offsets.
    public static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        guard let lexer = lexer(for: language) else { return [] }
        let units = Array(text.utf16)
        return units.withUnsafeBufferPointer { buf in
            var out: [SyntaxToken] = []
            out.reserveCapacity(units.count / 6)
            var state = LexState.initial
            var lineStart = 0
            var open: SyntaxToken?   // a multi-line token being joined
            var scratch: [SyntaxToken] = []
            while lineStart <= buf.count {
                var lineEnd = lineStart
                while lineEnd < buf.count, buf[lineEnd] != 10 { lineEnd += 1 }
                let contentEnd = lineEnd > lineStart && buf[lineEnd - 1] == 13 ? lineEnd - 1 : lineEnd
                scratch.removeAll(keepingCapacity: true)
                lexer.lex(LineText(units: buf, start: lineStart, end: contentEnd), state: &state, into: &scratch)
                var k = 0
                if var o = open {
                    open = nil
                    if let first = scratch.first, first.location == lineStart, first.kind == o.kind {
                        o.length = first.end - o.location
                        k = 1
                    }
                    if k == scratch.count, state.open == o.kind {
                        open = o   // still inside it (an empty line, or the whole line)
                    } else {
                        out.append(o)
                    }
                }
                if k < scratch.count {
                    out.append(contentsOf: scratch[k...])
                    if let o = state.open, let last = out.last, last.kind == o, last.end == contentEnd { open = out.removeLast() }
                }
                if lineEnd >= buf.count { break }
                lineStart = lineEnd + 1
            }
            if let o = open { out.append(o) }
            return out
        }
    }
}
