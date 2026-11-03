/// XML and property lists (XML 1.0, public W3C recommendation): tags
/// and attribute names, attribute values (over lines), comments, CDATA
/// sections, processing instructions, `<!DOCTYPE …>`, and entity
/// references.
struct XMLLexer: LineLexer {
    enum Mode: UInt8 { case content = 0, comment = 1, cdata = 2, tag = 3, value = 4, instruction = 5, declaration = 6 }

    func lex(_ l: LineText, state: inout LexState, into out: inout [SyntaxToken]) {
        var i = l.start
        while i <= l.end {
            switch Mode(rawValue: state.mode) ?? .content {
            case .comment:
                guard let e = l.find("-->", from: i) else { out.add(.comment, i, l.end); return }
                out.add(.comment, i, e + 3)
                i = e + 3
                state = .initial
            case .cdata:
                guard let e = l.find("]]>", from: i) else { out.add(.string, i, l.end); return }
                out.add(.string, i, e + 3)
                i = e + 3
                state = .initial
            case .instruction:
                guard let e = l.find("?>", from: i) else { out.add(.preprocessor, i, l.end); return }
                out.add(.preprocessor, i, e + 2)
                i = e + 2
                state = .initial
            case .declaration:
                // `<!DOCTYPE …>`, with an optional `[ … ]` internal subset.
                var j = i
                while j < l.end {
                    if l[j] == 91 { state.depth += 1 } else if l[j] == 93 { state.depth -= 1 } else if l[j] == 62, state.depth <= 0 { break }
                    j += 1
                }
                if j >= l.end { out.add(.preprocessor, i, l.end); return }
                out.add(.preprocessor, i, j + 1)
                i = j + 1
                state = .initial
            case .value:
                let q = UInt16(state.aux)
                var j = i
                while j < l.end, l[j] != q { j += 1 }
                if j >= l.end { out.add(.string, i, l.end); return }
                out.add(.string, i, j + 1)
                i = j + 1
                state = LexState(mode: Mode.tag.rawValue)
            case .tag:
                // Attributes until `>` or `/>`.
                while i < l.end, isSpace(l[i]) { i += 1 }
                if i >= l.end { return }
                let c = l[i]
                if c == 62 { i += 1; state = .initial; continue }
                if c == 47, l[i + 1] == 62 { i += 2; state = .initial; continue }
                if c == 34 || c == 39 {
                    state = LexState(open: .string, mode: Mode.value.rawValue, aux: Int32(c))
                    var j = i + 1
                    while j < l.end, l[j] != c { j += 1 }
                    if j >= l.end { out.add(.string, i, l.end); return }
                    out.add(.string, i, j + 1)
                    i = j + 1
                    state = LexState(mode: Mode.tag.rawValue)
                    continue
                }
                if isNameStart(c) {
                    let s = i
                    while i < l.end, isNamePart(l[i]) { i += 1 }
                    out.add(.attributeName, s, i)
                    continue
                }
                i += 1
            case .content:
                guard i < l.end else { return }
                let c = l[i]
                let s = i
                if c == 60 {
                    if l.matches("<!--", at: i) { state = LexState(open: .comment, mode: Mode.comment.rawValue); out.add(.comment, s, s); continue }
                    if l.matches("<![CDATA[", at: i) { state = LexState(open: .string, mode: Mode.cdata.rawValue); continue }
                    if l[i + 1] == 63 { state = LexState(open: .preprocessor, mode: Mode.instruction.rawValue); continue }
                    if l[i + 1] == 33 { state = LexState(open: .preprocessor, mode: Mode.declaration.rawValue); continue }
                    if let e = placeholderEnd(l, i) { out.add(.placeholder, s, e); i = e; continue }
                    var j = i + 1
                    if l[j] == 47 { j += 1 }
                    if isNameStart(l[j]) {
                        let n = j
                        while j < l.end, isNamePart(l[j]) { j += 1 }
                        out.add(.tagName, n, j)
                        i = j
                        state = LexState(mode: Mode.tag.rawValue)
                        continue
                    }
                    i += 1
                    continue
                }
                if c == 38 {   // &entity;
                    var j = i + 1
                    while j < l.end, j - i < 12, isNamePart(l[j]) || l[j] == 35 { j += 1 }
                    if l[j] == 59 { out.add(.entity, s, j + 1); i = j + 1; continue }
                }
                i += 1
            }
        }
    }

    @inline(__always) func isNameStart(_ c: UInt16) -> Bool { isIdentStart(c) || c == 58 }
    @inline(__always) func isNamePart(_ c: UInt16) -> Bool { isIdentPart(c) || c == 58 || c == 45 || c == 46 }
}

/// Markdown (CommonMark, public specification, with GitHub-style task
/// lists and fences): headings, emphasis, strong, code spans, fenced code
/// blocks, links and images, autolinks, block quotes, list markers,
/// thematic breaks, backslash escapes and HTML comments.
struct MarkdownLexer: LineLexer {
    enum Mode: UInt8 { case plain = 0, fence = 1, comment = 2 }

    func lex(_ l: LineText, state: inout LexState, into out: inout [SyntaxToken]) {
        let first = l.firstNonSpace(from: l.start)
        let indent = first - l.start
        switch Mode(rawValue: state.mode) ?? .plain {
        case .fence:
            // The closing fence: the same character, at least as many, nothing after.
            let ch = UInt16(state.aux)
            var j = first
            while j < l.end, l[j] == ch { j += 1 }
            if indent < 4, j - first >= Int(state.depth), l.firstNonSpace(from: j) == l.end {
                out.add(.codeSpan, l.start, l.end)
                state = .initial
            } else {
                out.add(.codeSpan, l.start, l.end)
            }
            return
        case .comment:
            guard let e = l.find("-->", from: l.start) else { out.add(.comment, l.start, l.end); return }
            out.add(.comment, l.start, e + 3)
            state = .initial
            inline(l, from: e + 3, state: &state, into: &out)
            return
        case .plain:
            break
        }
        guard first < l.end else { return }
        let c = l[first]
        if indent < 4 {
            // A fence opens a code block.
            if c == 96 || c == 126 {
                var j = first
                while j < l.end, l[j] == c { j += 1 }
                if j - first >= 3, c == 126 || l.find("`", from: j) == nil {
                    out.add(.codeSpan, first, l.end)
                    state = LexState(open: .codeSpan, mode: Mode.fence.rawValue, depth: Int32(j - first), aux: Int32(c))
                    return
                }
            }
            // ATX heading.
            if c == 35 {
                var j = first
                while j < l.end, l[j] == 35 { j += 1 }
                if j - first <= 6, j == l.end || isSpace(l[j]) { out.add(.heading, first, l.end); return }
            }
            // Thematic break or setext underline: ---, ***, ___, ===.
            if c == 45 || c == 42 || c == 95 || c == 61 {
                var n = 0
                var j = first
                var only = true
                while j < l.end {
                    if l[j] == c { n += 1 } else if !isSpace(l[j]) { only = false; break }
                    j += 1
                }
                if only, n >= 3 || (c == 61 && n >= 1) { out.add(c == 61 || c == 45 ? .heading : .listMarker, first, l.end); return }
            }
            // Block quote: the whole line.
            if c == 62 { out.add(.quote, first, l.end); return }
        }
        var i = first
        // List marker: -, *, + or 1. / 1) then a space; then a task box.
        if c == 45 || c == 42 || c == 43, isSpace(l[first + 1]) || first + 1 == l.end {
            out.add(.listMarker, first, first + 1)
            i = first + 1
        } else if isDigit(c) {
            var j = first
            while j < l.end, isDigit(l[j]), j - first < 9 { j += 1 }
            if l[j] == 46 || l[j] == 41, isSpace(l[j + 1]) || j + 1 == l.end { out.add(.listMarker, first, j + 1); i = j + 1 }
        }
        if i > first {
            let b = l.firstNonSpace(from: i)
            if l[b] == 91, l[b + 2] == 93, l[b + 1] == 32 || l[b + 1] == 120 || l[b + 1] == 88 { out.add(.listMarker, b, b + 3); i = b + 3 }
        }
        inline(l, from: i, state: &state, into: &out)
    }

    /// Inline spans from `i` to the line's end.
    func inline(_ l: LineText, from start: Int, state: inout LexState, into out: inout [SyntaxToken]) {
        var i = start
        while i < l.end {
            let c = l[i]
            let s = i
            if c == 92, i + 1 < l.end, !isIdentPart(l[i + 1]), l[i + 1] != 32 { out.add(.escape, s, i + 2); i += 2; continue }
            if c == 96 {   // `code` with a matching run of backticks
                var n = 0
                while l[i + n] == 96 { n += 1 }
                var j = i + n
                var found: Int?
                while j < l.end {
                    if l[j] == 96 {
                        var m = 0
                        while l[j + m] == 96 { m += 1 }
                        if m == n { found = j + m; break }
                        j += m
                    } else { j += 1 }
                }
                if let e = found { out.add(.codeSpan, s, e); i = e } else { i += n }
                continue
            }
            if c == 42 || c == 95 {   // *em*, **strong**, _em_, __strong__
                var n = 0
                while l[i + n] == c, n < 3 { n += 1 }
                let open = i + n
                let wordBefore = s > l.start && isIdentPart(l[s - 1])
                if !isSpace(l[open]), open < l.end, !(c == 95 && wordBefore) {
                    var j = open
                    var found: Int?
                    while j < l.end {
                        if l[j] == c, !isSpace(l[j - 1]) {
                            var m = 0
                            while l[j + m] == c { m += 1 }
                            if m >= n { found = j + n; break }
                            j += m
                            continue
                        }
                        if l[j] == 96 { break }
                        j += 1
                    }
                    if let e = found, !(c == 95 && isIdentPart(l[e])) {
                        out.add(n >= 2 ? .strong : .emphasis, s, e)
                        i = e
                        continue
                    }
                }
                i += n
                continue
            }
            if c == 33 || c == 91, let (textEnd, urlEnd) = link(l, c == 33 ? i + 1 : i) {   // [text](url), ![alt](src)
                out.add(.link, s, textEnd)
                if urlEnd > textEnd { out.add(.url, textEnd, urlEnd) }
                i = max(urlEnd, textEnd)
                continue
            }
            if c == 60 {
                if l.matches("<!--", at: i) {
                    guard let e = l.find("-->", from: i + 4) else {
                        out.add(.comment, s, l.end)
                        state = LexState(open: .comment, mode: Mode.comment.rawValue)
                        return
                    }
                    out.add(.comment, s, e + 3)
                    i = e + 3
                    continue
                }
                // <https://…> autolink, <tag> inline HTML.
                var j = i + 1
                while j < l.end, l[j] != 62, !isSpace(l[j]) || l[i + 1] != 104 { j += 1 }
                if l[j] == 62 {
                    let inner = l.string(i + 1, j)
                    if inner.contains("://") || inner.contains("@") { out.add(.url, s, j + 1) }
                    else if let f = inner.unicodeScalars.first, f.properties.isAlphabetic || f == "/" { out.add(.tagName, s, j + 1) }
                    i = j + 1
                    continue
                }
                i += 1
                continue
            }
            if c == 104, l.matches("http://", at: i) || l.matches("https://", at: i), s == l.start || !isIdentPart(l[s - 1]) {
                var j = i
                while j < l.end, !isSpace(l[j]), l[j] != 41, l[j] != 62 { j += 1 }
                out.add(.url, s, j)
                i = j
                continue
            }
            i += 1
        }
    }

    /// `[text](url)` starting at the `[` at `i`: the end of `]` and of `)`;
    /// `[text][ref]` and `[text]` (a reference) end the url part at the text.
    func link(_ l: LineText, _ i: Int) -> (Int, Int)? {
        guard l[i] == 91 else { return nil }
        var j = i + 1
        var depth = 0
        while j < l.end {
            if l[j] == 92 { j += 2; continue }
            if l[j] == 91 { depth += 1 } else if l[j] == 93 { if depth == 0 { break }; depth -= 1 }
            j += 1
        }
        guard l[j] == 93 else { return nil }
        let textEnd = j + 1
        if l[textEnd] == 40 {
            var k = textEnd + 1
            var d = 0
            while k < l.end {
                if l[k] == 40 { d += 1 } else if l[k] == 41 { if d == 0 { return (textEnd, k + 1) }; d -= 1 }
                k += 1
            }
            return nil
        }
        if l[textEnd] == 91, let e = l.find("]", from: textEnd + 1) { return (textEnd, e + 1) }
        return textEnd - i > 2 && l[textEnd] == 58 ? (textEnd, textEnd) : nil   // [ref]: url definition
    }
}
