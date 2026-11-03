/// C, C++, Objective-C and Metal (`specs/ide/source-editor.md`, "Ycode
/// implementation"): comments and doc comments (`///`, `//!`, `/** */`,
/// `/*! */`), string and character literals (with `L`, `u`, `U`, `u8`
/// prefixes, ObjC `@"…"`, C++ raw strings `R"d(…)d"` over lines),
/// numbers (with `'` separators), preprocessor lines (with `\`
/// continuations), C++ / Metal `[[attributes]]`, ObjC `@keywords`,
/// placeholders, keywords per dialect, and type names (capitalized,
/// `…_t`, the dialect's built-in types). Lexical rules: the public C, C++,
/// Objective-C and Metal Shading Language documentation.
struct CFamilyLexer: LineLexer {
    let dialect: SyntaxLanguage

    static let c: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
        "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed",
        "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool",
        "true", "false", "NULL", "_Bool", "_Atomic", "_Alignas", "_Alignof", "_Noreturn", "_Static_assert",
        "_Thread_local", "_Generic", "alignas", "alignof", "static_assert", "thread_local", "typeof", "nullptr", "constexpr",
    ]
    static let cpp: Set<String> = c.union([
        "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "new", "delete",
        "this", "using", "noexcept", "operator", "friend", "explicit", "mutable", "override", "final", "try", "catch",
        "throw", "const_cast", "static_cast", "dynamic_cast", "reinterpret_cast", "decltype", "concept", "requires",
        "co_await", "co_return", "co_yield", "consteval", "constinit", "export", "import", "module", "wchar_t",
        "char8_t", "char16_t", "char32_t", "and", "or", "not", "xor", "bitand", "bitor", "compl", "not_eq", "and_eq",
        "or_eq", "xor_eq", "typeid",
    ])
    static let objc: Set<String> = cpp.union([
        "self", "super", "nil", "Nil", "YES", "NO", "id", "instancetype", "SEL", "BOOL", "IMP", "Class",
        "nonatomic", "atomic", "strong", "weak", "copy", "assign", "retain", "readonly", "readwrite", "nullable", "nonnull",
        "null_resettable", "null_unspecified", "getter", "setter", "__block", "__weak", "__strong", "__unsafe_unretained",
        "__autoreleasing", "__kindof", "_Nullable", "_Nonnull", "_Null_unspecified", "in", "out", "inout", "oneway", "bycopy", "byref",
    ])
    static let metal: Set<String> = cpp.union([
        "kernel", "vertex", "fragment", "device", "constant", "threadgroup", "thread", "threadgroup_imageblock",
        "ray_data", "object_data", "visible", "stitchable", "object", "mesh", "half", "uint", "ushort", "uchar", "ulong",
        "sampler", "intersection",
    ])

    var keywords: Set<String> {
        switch dialect {
        case .cpp: Self.cpp
        case .objc: Self.objc
        case .metal: Self.metal
        default: Self.c
        }
    }

    /// Metal's vector and matrix types (`float4`, `half3x3`, `uint2`) and
    /// texture / atomic types.
    func isMetalType(_ w: String) -> Bool {
        if w.hasPrefix("texture") || w.hasPrefix("depth") || w.hasPrefix("atomic") || w.hasPrefix("packed_")
            || w.hasPrefix("simd_") || w == "array" || w == "metal" || w.hasPrefix("sampler") { return true }
        let bases = ["float", "half", "int", "uint", "short", "ushort", "char", "uchar", "bool", "long", "ulong", "bfloat"]
        for b in bases where w.hasPrefix(b) {
            let rest = w.dropFirst(b.count)
            if rest.count == 1, let d = rest.first, ("2"..."4").contains(d) { return true }
            if rest.count == 3, rest.dropFirst().first == "x", let a = rest.first, let z = rest.last, ("2"..."4").contains(a), ("2"..."4").contains(z) { return true }
        }
        return false
    }

    enum Mode: UInt8 { case plain = 0, blockComment = 1, rawString = 2, preprocessor = 3, string = 4 }

    func lex(_ l: LineText, state: inout LexState, into out: inout [SyntaxToken]) {
        var i = l.start
        let continued = l.end > l.start && l[l.end - 1] == 92   // ends with a backslash
        switch Mode(rawValue: state.mode) ?? .plain {
        case .blockComment:
            let kind = state.open ?? .comment
            if let e = l.find("*/", from: i) {
                out.add(kind, l.start, e + 2)
                i = e + 2
                state = .initial
            } else {
                out.add(kind, l.start, l.end)
                return
            }
        case .rawString:
            if let e = rawStringEnd(l, from: i, delimiter: state.delimiter) {
                out.add(.string, l.start, e)
                i = e
                state = .initial
            } else {
                out.add(.string, l.start, l.end)
                return
            }
        case .preprocessor:
            out.add(.preprocessor, l.start, l.end)
            if !continued { state = .initial }
            return
        case .string:
            let (e, closed) = quotedEnd(l, from: i, quote: 34)
            out.add(.string, l.start, e)
            i = e
            if !closed { if !continued { state = .initial }; return }
            state = .initial
        case .plain:
            break
        }
        // A preprocessor directive: `#` first on the line, up to a comment.
        let first = l.firstNonSpace(from: i)
        if i == l.start, l[first] == 35 {
            var j = first + 1
            var commentAt: Int?
            while j < l.end {
                if l[j] == 47 && (l[j + 1] == 47 || l[j + 1] == 42) { commentAt = j; break }
                if l[j] == 34 { j = quotedEnd(l, from: j + 1, quote: 34).0; continue }
                j += 1
            }
            out.add(.preprocessor, first, commentAt ?? l.end)
            if commentAt == nil {
                if continued { state = LexState(open: .preprocessor, mode: Mode.preprocessor.rawValue) }
                return
            }
            i = commentAt!
        }
        let keywords = self.keywords
        while i < l.end {
            let c = l[i]
            let s = i
            if isSpace(c) { i += 1; continue }
            if c == 47, l[i + 1] == 47 {
                let doc = (l[i + 2] == 47 && l[i + 3] != 47) || l[i + 2] == 33
                out.add(doc ? .docComment : .comment, s, l.end)
                return
            }
            if c == 47, l[i + 1] == 42 {
                let doc = (l[i + 2] == 42 && l[i + 3] != 42 && l[i + 3] != 47) || l[i + 2] == 33
                let kind: SyntaxTokenKind = doc ? .docComment : .comment
                if let e = l.find("*/", from: i + 2) {
                    i = e + 2
                    out.add(kind, s, i)
                } else {
                    out.add(kind, s, l.end)
                    state = LexState(open: kind, mode: Mode.blockComment.rawValue)
                    return
                }
                continue
            }
            // String prefixes: L"", u"", U"", u8"", R"(…)", @"".
            if let q = stringStart(l, i) {
                if q.raw {
                    // R"delim( … )delim"
                    var j = q.quote + 1
                    while j < l.end, l[j] != 40, j - q.quote <= 17 { j += 1 }
                    let delimiter = Array(UnsafeBufferPointer(rebasing: l.units[(q.quote + 1)..<j]))
                    if let e = rawStringEnd(l, from: j + 1, delimiter: delimiter) {
                        out.add(.string, s, e)
                        i = e
                    } else {
                        out.add(.string, s, l.end)
                        state = LexState(open: .string, mode: Mode.rawString.rawValue, delimiter: delimiter)
                        return
                    }
                    continue
                }
                let (e, closed) = quotedEnd(l, from: q.quote + 1, quote: l[q.quote])
                out.add(l[q.quote] == 39 ? .character : .string, s, e)
                i = e
                if !closed, continued, l[q.quote] == 34 { state = LexState(open: .string, mode: Mode.string.rawValue); return }
                continue
            }
            if isDigit(c) || (c == 46 && isDigit(l[i + 1])) {
                i = numberEnd(l, i, separator: 39)
                out.add(.number, s, i)
                continue
            }
            if c == 91, l[i + 1] == 91, dialect != .objc || l[i + 2] != 91 {   // [[attribute]]
                var j = i + 2
                var depth = 0
                while j < l.end {
                    if l[j] == 91 { depth += 1 } else if l[j] == 93 { if depth == 0 && l[j + 1] == 93 { j += 2; break }; depth -= 1 }
                    j += 1
                }
                if j <= l.end, l[j - 1] == 93 {
                    out.add(.attribute, s, j)
                    i = j
                    continue
                }
                i += 1
                continue
            }
            if c == 64, isIdentStart(l[i + 1]) {   // @interface, @end, @property
                i += 1
                while i < l.end, isIdentPart(l[i]) { i += 1 }
                out.add(.keyword, s, i)
                continue
            }
            if c == 60, let e = placeholderEnd(l, i) {
                out.add(.placeholder, s, e)
                i = e
                continue
            }
            if c == 95, l.matches("__attribute__", at: i) {
                i += 13
                out.add(.attribute, s, i)
                continue
            }
            if isIdentStart(c) {
                i += 1
                while i < l.end, isIdentPart(l[i]) { i += 1 }
                if l.word(s, i, in: keywords) {
                    out.add(.keyword, s, i)
                } else if isUpper(c) {
                    out.add(.typeName, s, i)
                } else if i - s > 2, l[i - 2] == 95, l[i - 1] == 116 {   // …_t
                    out.add(.typeName, s, i)
                } else if dialect == .metal, isMetalType(l.string(s, i)) {
                    out.add(.typeName, s, i)
                }
                continue
            }
            i += 1
        }
    }

    /// A string or character literal starting at `i`: where its quote is
    /// and whether it is a C++ raw string.
    func stringStart(_ l: LineText, _ i: Int) -> (quote: Int, raw: Bool)? {
        let c = l[i]
        if c == 34 || c == 39 {
            // Not a C++14 digit separator (1'000 is lexed with the number).
            return (i, false)
        }
        if c == 64, l[i + 1] == 34, dialect == .objc { return (i + 1, false) }
        guard dialect != .c || c == 76 || c == 117 || c == 85 else { return nil }
        // Encoding prefix, then optional R.
        var j = i
        if c == 117, l[j + 1] == 56 { j += 2 }               // u8
        else if c == 76 || c == 117 || c == 85 { j += 1 }    // L u U
        if i > l.start, isIdentPart(l[i - 1]) { return nil }
        if l[j] == 82, l[j + 1] == 34, dialect != .c { return (j + 1, true) }   // R"
        if j > i, l[j] == 34 || l[j] == 39 { return (j, false) }
        return nil
    }

    /// The end of a quoted literal whose body starts at `i`, and whether it closed.
    func quotedEnd(_ l: LineText, from i: Int, quote: UInt16) -> (Int, Bool) {
        var j = i
        while j < l.end {
            if l[j] == 92 { j += 2; continue }
            if l[j] == quote { return (j + 1, true) }
            j += 1
        }
        return (l.end, false)
    }

    /// The end of a raw string body: `)delimiter"`.
    func rawStringEnd(_ l: LineText, from i: Int, delimiter: [UInt16]) -> Int? {
        var j = i
        while j < l.end {
            if l[j] == 41 {
                var k = 0
                while k < delimiter.count, l[j + 1 + k] == delimiter[k] { k += 1 }
                if k == delimiter.count, l[j + 1 + k] == 34 { return j + 2 + k }
            }
            j += 1
        }
        return nil
    }
}
