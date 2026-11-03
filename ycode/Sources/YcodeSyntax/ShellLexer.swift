/// POSIX shell, bash and zsh scripts (the POSIX Shell Command Language,
/// public): comments, `#!` lines, single- and double-quoted strings (over
/// lines), `$VAR` / `${…}` / `$(` expansions, here-documents, keywords and
/// built-ins, `NAME=` assignments, numbers.
struct ShellLexer: LineLexer {
    static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function",
        "select", "time", "return", "exit", "export", "local", "readonly", "declare", "typeset", "unset", "source",
        "alias", "break", "continue", "shift", "trap", "eval", "exec", "set", "true", "false",
    ]

    enum Mode: UInt8 { case plain = 0, single = 1, double = 2, heredoc = 3, started = 4 }

    func lex(_ l: LineText, state: inout LexState, into out: inout [SyntaxToken]) {
        var i = l.start
        // `#!` on the first line (the initial state is the only one with
        // mode 0 before any line was lexed; later lines carry `started`).
        let firstLine = state == .initial
        defer { if state == .initial { state.mode = Mode.started.rawValue } }
        if firstLine, l.matches("#!", at: i) { out.add(.preprocessor, i, l.end); return }
        switch Mode(rawValue: state.mode) ?? .plain {
        case .single:
            guard let e = l.find("'", from: i) else { out.add(.string, i, l.end); return }
            out.add(.string, i, e + 1)
            i = e + 1
            state = LexState(mode: Mode.started.rawValue)
        case .double:
            let (e, closed) = doubleQuoted(l, from: i, segmentStart: i, into: &out)
            if !closed { return }
            i = e
            state = LexState(mode: Mode.started.rawValue)
        case .heredoc:
            // The terminator line: the word alone (leading tabs allowed with <<-).
            var s = l.start
            if state.aux != 0 { while l[s] == 9 { s += 1 } }
            if l.end - s == state.delimiter.count, (0..<state.delimiter.count).allSatisfy({ l[s + $0] == state.delimiter[$0] }) {
                out.add(.keyword, s, l.end)
                state = LexState(mode: Mode.started.rawValue)
            } else {
                out.add(.string, l.start, l.end)
            }
            return
        case .plain, .started:
            break
        }
        var pendingHeredoc: LexState?
        var wordStart = true
        while i < l.end {
            let c = l[i]
            let s = i
            if isSpace(c) || c == 59 || c == 124 || c == 38 || c == 40 || c == 41 {   // space ; | & ( )
                wordStart = true
                i += 1
                continue
            }
            if c == 35, wordStart { out.add(.comment, s, l.end); break }
            if c == 39 {
                guard let e = l.find("'", from: i + 1) else {
                    out.add(.string, s, l.end)
                    state = LexState(open: .string, mode: Mode.single.rawValue)
                    return
                }
                out.add(.string, s, e + 1)
                i = e + 1
                wordStart = false
                continue
            }
            if c == 34 {
                let (e, closed) = doubleQuoted(l, from: i + 1, segmentStart: s, into: &out)
                if !closed { state = LexState(open: .string, mode: Mode.double.rawValue); return }
                i = e
                wordStart = false
                continue
            }
            if c == 36 {
                i = expansionEnd(l, i)
                out.add(.variable, s, i)
                wordStart = false
                continue
            }
            if c == 60, l[i + 1] == 60, l[i + 2] != 60 {   // <<WORD, <<-WORD, <<'WORD'
                var j = i + 2
                let strip = l[j] == 45
                if strip { j += 1 }
                j = l.firstNonSpace(from: j)
                let quote = l[j] == 39 || l[j] == 34 ? l[j] : 0
                if quote != 0 { j += 1 }
                let w = j
                while j < l.end, isIdentPart(l[j]) || l[j] == 45 || l[j] == 46 { j += 1 }
                if j > w {
                    pendingHeredoc = LexState(open: .string, mode: Mode.heredoc.rawValue, aux: strip ? 1 : 0,
                                              delimiter: Array(UnsafeBufferPointer(rebasing: l.units[w..<j])))
                    if quote != 0, l[j] == quote { j += 1 }
                    out.add(.keyword, w - (quote != 0 ? 1 : 0), j)
                    i = j
                    continue
                }
            }
            if isIdentStart(c) || isDigit(c) {
                var j = i
                while j < l.end, isIdentPart(l[j]) || l[j] == 45 || l[j] == 46 || l[j] == 47 { j += 1 }
                if l[j] == 61, wordStart, isIdentStart(c), (i..<j).allSatisfy({ isIdentPart(l[$0]) }) {
                    out.add(.variable, s, j)   // NAME=value
                } else if wordStart, l.word(s, j, in: Self.keywords), j == l.end || !isIdentPart(l[j]) {
                    out.add(.keyword, s, j)
                } else if isDigit(c), (i..<j).allSatisfy({ isDigit(l[$0]) }) {
                    out.add(.number, s, j)
                }
                i = j
                wordStart = false
                continue
            }
            wordStart = false
            i += 1
        }
        if let h = pendingHeredoc { state = h }
    }

    /// The end of `$NAME`, `${…}`, `$(`, `$1`, `$@`, … at `i`.
    func expansionEnd(_ l: LineText, _ i: Int) -> Int {
        let n = l[i + 1]
        if n == 123 {   // ${…}
            var j = i + 2
            while j < l.end, l[j] != 125 { j += 1 }
            return min(j + 1, l.end)
        }
        if n == 40 { return i + 2 }   // $( — the command follows
        if isIdentStart(n) {
            var j = i + 1
            while j < l.end, isIdentPart(l[j]) { j += 1 }
            return j
        }
        if isDigit(n) || n == 64 || n == 42 || n == 35 || n == 63 || n == 36 || n == 33 || n == 45 { return i + 2 }
        return i + 1
    }

    /// A double-quoted string body from `i`: string pieces and `$`
    /// expansions inside it. Returns the end and whether it closed.
    func doubleQuoted(_ l: LineText, from i: Int, segmentStart: Int, into out: inout [SyntaxToken]) -> (Int, Bool) {
        var j = i
        var seg = segmentStart
        while j < l.end {
            let c = l[j]
            if c == 92 { j += 2; continue }
            if c == 36, l[j + 1] != 34, l[j + 1] != 0 {
                out.add(.string, seg, j)
                let e = expansionEnd(l, j)
                out.add(.variable, j, e)
                j = e
                seg = e
                continue
            }
            if c == 34 { out.add(.string, seg, j + 1); return (j + 1, true) }
            j += 1
        }
        out.add(.string, seg, l.end)
        return (l.end, false)
    }
}
