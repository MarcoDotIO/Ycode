import Foundation

/// One edit a typing rule makes: replace `range` (UTF-16, in the current
/// text) with `replacement`, then select `selection` (in the new text).
public struct TypingEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// The text after the edit (tests).
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// What Tab does with an insertion point (Settings ▸ Editing ▸
/// Indentation ▸ Tab key).
public enum TabKeyBehavior: String, Sendable, CaseIterable, Codable {
    /// In a line's leading whitespace, Tab indents the line to its
    /// computed indentation (or moves to the text when the line has it, or
    /// adds one step when it is past it); elsewhere it inserts spaces to
    /// the next indentation stop (a tab with tabs). The default.
    case indentsInLeadingWhitespace
    /// Tab re-indents the line wherever the insertion point is.
    case indentsAlways
    /// Tab inserts one indentation step.
    case insertsIndentation

    /// The pop-up's titles.
    public var title: String {
        switch self {
        case .indentsInLeadingWhitespace: "Indents in leading whitespace"
        case .indentsAlways: "Indents always"
        case .insertsIndentation: "Inserts indentation"
        }
    }
}

/// The settings typing follows (Settings ▸ Editing ▸ Indentation and
/// Editing ▸ Typing).
public struct TypingOptions: Equatable, Sendable {
    public var indent: IndentOptions
    /// Return indents by the structure, and closers, `case`, `default` and
    /// `#else` re-indent their line.
    public var autoIndent: Bool
    /// Typing an opening bracket or quote inserts its closer.
    public var autoClose: Bool
    /// Typing a bracket or quote with a selection encloses it.
    public var encloseSelection: Bool
    public var tabKey: TabKeyBehavior

    public init(indent: IndentOptions = IndentOptions(), autoIndent: Bool = true, autoClose: Bool = true,
                encloseSelection: Bool = true, tabKey: TabKeyBehavior = .indentsInLeadingWhitespace) {
        self.indent = indent
        self.autoIndent = autoIndent
        self.autoClose = autoClose
        self.encloseSelection = encloseSelection
        self.tabKey = tabKey
    }
}

/// The source editor's typing rules (`specs/ide/source-editor.md`, "Ycode
/// implementation", Typing), as functions of a `SyntaxDocument`, the
/// selection and the settings. Each returns the edit to make instead of
/// the plain one, or nil to type normally. They are portable: the macOS
/// editor and the Linux editor (EditorKit) share them.
public enum TypingRules {
    static let closers: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125]   // ( ) [ ] { }
    static let closerSet: Set<UInt16> = [41, 93, 125]

    // MARK: Return

    /// Return: a newline indented by the structure. Between a bracket
    /// pair (`{|}`) the closer moves to its own line under the opener and
    /// the insertion point sits indented between them; a whitespace-only
    /// line left behind is emptied; spaces after the insertion point are
    /// dropped. Markdown continues list items and quotes.
    public static func newline(in doc: SyntaxDocument, selection: NSRange, options: TypingOptions) -> TypingEdit {
        let o = options.indent
        let caret = selection.location
        let n = doc.line(containing: caret)
        let r = doc.lineRange(n)
        let u = doc.units
        let selEnd = min(NSMaxRange(selection), r.upperBound)
        var after = selEnd
        while after < r.upperBound, u[after] == 32 || u[after] == 9 { after += 1 }
        let prefix = String(decoding: u[r.lowerBound..<caret], as: UTF16.self)
        let prefixBlank = prefix.allSatisfy { $0 == " " || $0 == "\t" }
        // The edit replaces the selection and the spaces after it; a blank
        // prefix goes too (the line is left empty).
        let start = prefixBlank && options.autoIndent ? r.lowerBound : caret
        let range = NSRange(location: start, length: after - start)
        func edit(_ s: String, caretAt: Int? = nil) -> TypingEdit {
            let c = caretAt ?? (s as NSString).length
            return TypingEdit(range: range, replacement: s, selection: NSRange(location: start + c, length: 0))
        }
        let keep = doc.leadingWhitespace(n)
        let keepPrefix = String(keep.prefix(prefix.count))
        guard options.autoIndent else { return edit("\n" + keepPrefix) }
        if doc.startState(ofLine: n).open?.isCommentOrString == true || doc.isInsideCommentOrString(caret) {
            // Inside a comment or string: keep the line's indentation
            // (`///` doc comments continue).
            let trimmed = prefix.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("///"), doc.language == .swift || doc.language.isCFamily { return edit("\n" + keepPrefix + "/// ") }
            return edit("\n" + keepPrefix)
        }
        switch doc.language {
        case .markdown: return markdownNewline(doc, line: n, prefix: prefix, edit: edit)
        case .yaml:
            var code = prefix
            if let hash = code.range(of: " #") { code = String(code[..<hash.lowerBound]) }
            let t = code.trimmingCharacters(in: .whitespaces)
            let opens = t.hasSuffix(":") || t.hasSuffix("|") || t.hasSuffix(">") || t.hasSuffix("|-") || t.hasSuffix(">-") || t == "-"
            let base = o.column(of: keepPrefix)
            return edit("\n" + o.string(forColumn: opens ? base + o.indentWidth : base))
        default: break
        }
        guard doc.indentsByStructure else { return edit("\n" + keepPrefix) }
        // Swift: a line ending in an opening `"""` gets its closing one.
        if doc.language == .swift, prefix.hasSuffix("\"\"\""), prefix.components(separatedBy: "\"\"\"").count == 2, caret == r.upperBound || after == r.upperBound {
            let ws = o.column(of: keepPrefix)
            let inner = o.string(forColumn: ws)
            return edit("\n" + inner + "\n" + inner + "\"\"\"", caretAt: 1 + (inner as NSString).length)
        }
        let opener = doc.enclosingOpener(before: caret)
        let base = opener.map { o.column(of: doc.leadingWhitespace($0.line)) } ?? 0
        // The text after the insertion point starts by closing the block.
        if let (e, openerLine) = opener, after < r.upperBound, closes(e, doc: doc, at: after) {
            let closerIndent = o.string(forColumn: base)
            let between = String(decoding: u[min(e.offset + 1, caret)..<caret], as: UTF16.self)
            if openerLine == n, between.allSatisfy({ $0 == " " || $0 == "\t" }) || e.kind == .tag {
                let inner = o.string(forColumn: base + o.indentWidth)
                return edit("\n" + inner + "\n" + closerIndent, caretAt: 1 + (inner as NSString).length)
            }
            return edit("\n" + closerIndent)
        }
        guard opener != nil else {
            // Top level: column 0, except that a Swift member chain keeps its indentation.
            let body = prefix.drop { $0 == " " || $0 == "\t" }
            if doc.language == .swift, body.hasPrefix(".") { return edit("\n" + keepPrefix) }
            return edit("\n")
        }
        let body = prefix.drop { $0 == " " || $0 == "\t" }
        // A Swift member-chain line keeps its extra step for the next link.
        if doc.language == .swift, body.hasPrefix("."), o.column(of: keepPrefix) > base { return edit("\n" + keepPrefix) }
        return edit("\n" + o.string(forColumn: base + o.indentWidth))
    }

    /// Whether the text at `offset` closes the block `e` opened.
    static func closes(_ e: BlockEvent, doc: SyntaxDocument, at offset: Int) -> Bool {
        let u = doc.units
        switch e.kind {
        case .bracket(let open): return u[offset] == closers[open]
        case .tag: return u[offset] == 60 && offset + 1 < u.count && u[offset + 1] == 47
        case .keyword:
            let w = SyntaxDocument.words(Substring(doc.lineText(doc.line(containing: offset)).dropFirst(offset - doc.lineStart(doc.line(containing: offset))))).first
            return w.map { ["fi", "done", "esac", "else", "elif"].contains(String($0)) } ?? false
        }
    }

    /// Markdown: `- item` / `* item` / `+ item` / `1. item` / `> quote`
    /// continue on the next line (numbers count up); Return on an empty
    /// item ends the list (the marker is removed).
    static func markdownNewline(_ doc: SyntaxDocument, line n: Int, prefix: String, edit: (String, Int?) -> TypingEdit) -> TypingEdit {
        let ws = String(prefix.prefix { $0 == " " || $0 == "\t" })
        let body = prefix.dropFirst(ws.count)
        var marker: String?
        var next: String?
        if let f = body.first, "-*+".contains(f), body.dropFirst().first == " " {
            var m = String(f) + " "
            if body.dropFirst(2).hasPrefix("[ ] ") || body.dropFirst(2).hasPrefix("[x] ") || body.dropFirst(2).hasPrefix("[X] ") { m += "[ ] " }
            marker = String(body.prefix(m.count == 2 ? 2 : 6))
            next = m
        } else if let digits = Optional(body.prefix { $0.isNumber }), !digits.isEmpty, digits.count < 10,
                  let d = body.dropFirst(digits.count).first, d == "." || d == ")", body.dropFirst(digits.count + 1).first == " " {
            marker = String(body.prefix(digits.count + 2))
            next = "\((Int(digits) ?? 0) + 1)\(d) "
        } else if body.hasPrefix("> ") || body == ">" {
            marker = String(body.prefix(2))
            next = "> "
        }
        guard let marker, let next else { return edit("\n" + ws, nil) }
        if body.trimmingCharacters(in: .whitespaces) == marker.trimmingCharacters(in: .whitespaces) {
            // An empty item: end the list.
            let lineStart = doc.lineStart(n)
            return TypingEdit(range: NSRange(location: lineStart, length: (prefix as NSString).length), replacement: "",
                              selection: NSRange(location: lineStart, length: 0))
        }
        return edit("\n" + ws + next, nil)
    }

    // MARK: Electric characters

    /// After typing `typed` (already in the text, the insertion point at
    /// `caret`): re-indents the line when it now starts with a closer, or
    /// completes a `case …:` / `default:` label, `#else`, `#elseif`,
    /// `#endif`, an XML end tag (`</`), or a shell `fi`, `done`, `esac`,
    /// `else`, `elif`. Nil when nothing changes.
    public static func reindentAfterTyping(_ typed: String, in doc: SyntaxDocument, caret: Int, options: TypingOptions) -> TypingEdit? {
        guard options.autoIndent, doc.indentsByStructure, typed.utf16.count == 1, let c = typed.utf16.first else { return nil }
        let n = doc.line(containing: caret)
        let r = doc.lineRange(n)
        let text = doc.lineText(n)
        let body = text.drop { $0 == " " || $0 == "\t" }
        let beforeCaret = String(decoding: doc.units[r.lowerBound..<caret], as: UTF16.self).drop { $0 == " " || $0 == "\t" }
        let firstWord = SyntaxDocument.words(body.prefix(24)).first.map(String.init)
        var trigger = false
        switch c {
        case 41, 93, 125:   // ) ] }
            trigger = beforeCaret.utf16.count == 1
        case 58, 32:        // : and space after a label word
            if let w = firstWord, w == "case" || w == "default" || w == "@unknown", doc.language == .swift || doc.language.isCFamily {
                trigger = c == 58 || beforeCaret == Substring(w + " ")
            }
        case 47:            // </ in XML
            trigger = doc.language == .xml && beforeCaret == "</"
        default:
            if doc.language == .swift || doc.language.isCFamily {
                trigger = ["#else", "#elseif", "#endif"].contains(String(beforeCaret))
            } else if doc.language == .shell {
                trigger = ["fi", "done", "esac", "else", "elif"].contains(String(beforeCaret))
            }
        }
        guard trigger else { return nil }
        return doc.reindent(lines: n...n, options: options.indent, selection: NSRange(location: caret, length: 0))
    }

    // MARK: Brackets and quotes

    /// The result of typing a character: the edit, and the offsets (in the
    /// new text) of closers it inserted automatically, which typing the
    /// same closer there then steps over.
    public struct Result: Equatable, Sendable {
        public var edit: TypingEdit
        public var insertedClosers: [Int]
        /// The closer at the insertion point was stepped over (its offset is
        /// no longer pending).
        public var steppedOver: Int?
    }

    /// Typing `typed` with `selection`: steps over an automatically
    /// inserted closer, encloses a selection in a bracket pair or quotes,
    /// or inserts an opening bracket or quote with its closer. Nil: type it
    /// normally. `pendingClosers` are the offsets of closers inserted
    /// automatically and not yet typed over.
    public static func insert(_ typed: String, in doc: SyntaxDocument, selection: NSRange, options: TypingOptions,
                              pendingClosers: Set<Int>) -> Result? {
        guard typed.utf16.count == 1, let c = typed.utf16.first else { return nil }
        let u = doc.units
        let caret = selection.location
        let next: UInt16 = caret < u.count ? u[caret] : 0
        let quotes = Set(doc.language.quotes.compactMap { $0.utf16.first })
        let isQuote = quotes.contains(c)
        // Step over an automatic closer.
        if selection.length == 0, next == c, pendingClosers.contains(caret), closerSet.contains(c) || isQuote {
            return Result(edit: TypingEdit(range: NSRange(location: caret, length: 1), replacement: typed, selection: NSRange(location: caret + 1, length: 0)),
                          insertedClosers: [], steppedOver: caret)
        }
        let close: UInt16? = closers[c] ?? (isQuote ? c : nil)
        guard let close else { return nil }
        let closeString = String(decoding: [close], as: UTF16.self)
        // Enclose the selection.
        if selection.length > 0 {
            guard options.encloseSelection else { return nil }
            let inner = (doc.text as NSString).substring(with: selection)
            guard !inner.contains("\n") || closers[c] != nil else { return nil }
            return Result(edit: TypingEdit(range: selection, replacement: typed + inner + closeString,
                                           selection: NSRange(location: selection.location + 1, length: selection.length)),
                          insertedClosers: [], steppedOver: nil)
        }
        guard options.autoClose else { return nil }
        if doc.isInsideCommentOrString(caret) { return nil }
        // Only before whitespace, a line end, a closer or punctuation.
        let okNext: Set<UInt16> = [0, 10, 13, 32, 9, 41, 93, 125, 44, 59, 58, 46]
        guard okNext.contains(next) else { return nil }
        if isQuote {
            let prev: UInt16 = caret > 0 ? u[caret - 1] : 0
            // Not after a word (an apostrophe), a backslash or another quote.
            if isIdentPart(prev) || prev == 92 || prev == c { return nil }
            // In Swift, `'` is not a quote; in Markdown only backticks pair.
        }
        return Result(edit: TypingEdit(range: NSRange(location: caret, length: 0), replacement: typed + closeString,
                                       selection: NSRange(location: caret + 1, length: 0)),
                      insertedClosers: [caret + 1], steppedOver: nil)
    }

    /// Delete Backward between an automatically inserted pair (`(|)`)
    /// deletes both characters. Nil: delete normally.
    public static func deleteBackward(in doc: SyntaxDocument, selection: NSRange, pendingClosers: Set<Int>) -> TypingEdit? {
        let caret = selection.location
        let u = doc.units
        guard selection.length == 0, caret > 0, caret < u.count, pendingClosers.contains(caret) else { return nil }
        let open = u[caret - 1]
        guard closers[open] == u[caret] || (open == u[caret] && doc.language.quotes.contains(Character(UnicodeScalar(open) ?? " "))) else { return nil }
        return TypingEdit(range: NSRange(location: caret - 1, length: 2), replacement: "", selection: NSRange(location: caret - 1, length: 0))
    }

    /// Moves pending closer offsets through an edit (`range` replaced by
    /// `length` characters); closers inside the edited range are dropped.
    public static func adjust(_ closers: Set<Int>, editing range: NSRange, replacementLength length: Int) -> Set<Int> {
        Set(closers.compactMap { o in
            if o < range.location { return o }
            if o >= NSMaxRange(range) { return o + length - range.length }
            return nil
        })
    }

    // MARK: Tab

    /// Tab (or Shift-Tab with `backward`): a selection over several lines
    /// shifts them one step right or left; Shift-Tab shifts the line left;
    /// Tab follows the Tab key setting. Nil: nothing to do.
    public static func tab(in doc: SyntaxDocument, selection: NSRange, backward: Bool, options: TypingOptions) -> TypingEdit? {
        let o = options.indent
        let a = doc.line(containing: selection.location)
        var b = doc.line(containing: NSMaxRange(selection))
        if b > a, NSMaxRange(selection) == doc.lineStart(b) { b -= 1 }
        if b > a || backward {
            return shift(doc, lines: a...b, right: !backward, options: o, selection: selection)
        }
        let r = doc.lineRange(a)
        let caret = selection.location
        let inLeading = doc.units[r.lowerBound..<caret].allSatisfy { $0 == 32 || $0 == 9 } && selection.length == 0
        func insertStep() -> TypingEdit {
            // Spaces up to the next indentation stop; a tab character with tabs.
            let col = o.column(of: String(decoding: doc.units[r.lowerBound..<caret], as: UTF16.self))
            let s = o.usesTabs ? "\t" : String(repeating: " ", count: o.indentWidth - col % o.indentWidth)
            return TypingEdit(range: selection, replacement: s, selection: NSRange(location: selection.location + (s as NSString).length, length: 0))
        }
        switch options.tabKey {
        case .insertsIndentation:
            return TypingEdit(range: selection, replacement: o.unit, selection: NSRange(location: selection.location + (o.unit as NSString).length, length: 0))
        case .indentsAlways:
            guard let target = doc.computedIndent(forLine: a, options: o, blankLines: true) else { return insertStep() }
            if r.isEmpty || doc.units[r].allSatisfy({ $0 == 32 || $0 == 9 }) {
                let ws = doc.leadingWhitespace(a)
                guard target != ws else { return nil }
                return TypingEdit(range: NSRange(location: r.lowerBound, length: (ws as NSString).length), replacement: target,
                                  selection: NSRange(location: r.lowerBound + (target as NSString).length, length: 0))
            }
            return doc.reindent(lines: a...a, options: o, selection: NSRange(location: caret, length: 0))
        case .indentsInLeadingWhitespace:
            guard inLeading else { return insertStep() }
            let ws = doc.leadingWhitespace(a)
            let current = o.column(of: ws)
            let wsEnd = r.lowerBound + (ws as NSString).length
            if let target = doc.computedIndent(forLine: a, options: o, blankLines: true) {
                if o.column(of: target) > current {
                    // The line gets its indentation; the insertion point goes to its end.
                    return TypingEdit(range: NSRange(location: r.lowerBound, length: (ws as NSString).length), replacement: target,
                                      selection: NSRange(location: r.lowerBound + (target as NSString).length, length: 0))
                }
                if o.column(of: target) == current, caret < wsEnd {
                    // Indented already: the insertion point moves to the text.
                    return TypingEdit(range: NSRange(location: caret, length: 0), replacement: "", selection: NSRange(location: wsEnd, length: 0))
                }
            }
            return insertStep()
        }
    }

    /// Shift Right / Left: one step onto or off each line (empty lines stay empty).
    static func shift(_ doc: SyntaxDocument, lines: ClosedRange<Int>, right: Bool, options o: IndentOptions, selection: NSRange) -> TypingEdit? {
        var out: [String] = []
        var deltaFirst = 0
        for n in lines {
            let t = doc.lineText(n)
            let ws = doc.leadingWhitespace(n)
            var new: String
            if right {
                new = t.isEmpty ? t : o.string(forColumn: o.column(of: ws) + o.indentWidth) + t.dropFirst(ws.count)
            } else {
                let col = o.column(of: ws)
                new = o.string(forColumn: max(0, col - o.indentWidth)) + t.dropFirst(ws.count)
            }
            if n == lines.lowerBound { deltaFirst = (new as NSString).length - (t as NSString).length }
            out.append(new)
        }
        let a = doc.lineStart(lines.lowerBound), b = doc.lineRange(lines.upperBound).upperBound
        let body = out.joined(separator: "\n")
        guard body != String(decoding: doc.units[a..<b], as: UTF16.self) else { return nil }
        let sel = lines.count == 1 && selection.length == 0
            ? NSRange(location: max(a, selection.location + deltaFirst), length: 0)
            : NSRange(location: a, length: (body as NSString).length)
        return TypingEdit(range: NSRange(location: a, length: b - a), replacement: body, selection: sel)
    }

    // MARK: Comments

    /// Comment Selection (⌘/): line comments (`// `, `# `) on each touched
    /// non-empty line at its start, or removed when every non-empty line
    /// has one; block comments (`<!-- … -->`) around the touched lines, or
    /// removed when they are there. Nil: the language has no comments.
    public static func toggleComment(in doc: SyntaxDocument, selection: NSRange) -> TypingEdit? {
        guard let style = doc.language.commentStyle else { return nil }
        let a = doc.line(containing: selection.location)
        var b = doc.line(containing: NSMaxRange(selection))
        if b > a, NSMaxRange(selection) == doc.lineStart(b) { b -= 1 }
        let start = doc.lineStart(a), end = doc.lineRange(b).upperBound
        let lines = (a...b).map { doc.lineText($0) }
        var new: [String]
        switch style {
        case .line(let p):
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let uncomment = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(p) }
            new = lines.map { line in
                if uncomment {
                    guard let r = line.range(of: p) else { return line }
                    var after = r.upperBound
                    if after < line.endIndex, line[after] == " " { after = line.index(after: after) }
                    return String(line[..<r.lowerBound]) + line[after...]
                }
                return line.trimmingCharacters(in: .whitespaces).isEmpty ? line : p + " " + line
            }
        case .block(let open, let close):
            let first = lines[0], last = lines[lines.count - 1]
            let t0 = first.drop { $0 == " " || $0 == "\t" }
            if t0.hasPrefix(open), last.trimmingCharacters(in: .whitespaces).hasSuffix(close) {
                new = lines
                var f = String(t0.dropFirst(open.count))
                if f.hasPrefix(" ") { f.removeFirst() }
                new[0] = String(first.prefix(first.count - t0.count)) + f
                var l = new[new.count - 1]
                while l.last == " " || l.last == "\t" { l.removeLast() }
                l.removeLast(close.count)
                if l.hasSuffix(" ") { l.removeLast() }
                new[new.count - 1] = l
            } else {
                new = lines
                new[0] = String(first.prefix(first.count - t0.count)) + open + " " + t0
                new[new.count - 1] += " " + close
            }
        }
        let body = new.joined(separator: "\n")
        let delta = (body as NSString).length - (end - start)
        let sel: NSRange
        if selection.length == 0 {
            let firstDelta = (new[0] as NSString).length - (lines[0] as NSString).length
            let col = selection.location - start
            sel = NSRange(location: start + max(0, min((new[0] as NSString).length, col + firstDelta)), length: 0)
        } else {
            sel = NSRange(location: start, length: max(0, end - start + delta))
        }
        return TypingEdit(range: NSRange(location: start, length: end - start), replacement: body, selection: sel)
    }
}
