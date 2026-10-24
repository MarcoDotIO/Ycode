import Foundation

/// One edit a text command makes: replace `range` (UTF-16, in the old
/// text) with `replacement`, then select `selection` (in the new text).
public struct TextChange: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// The text after the change (tests).
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// The source editor's text commands behind Editor ▸ Structure, Selection
/// and the Edit menu's symbol items (`specs/ide/reference-ui-5.md` §6.4),
/// as functions of the text. They work on the lexer's view of the text
/// (`SourceTokenizer`), not a parser.
public enum TextCommands {
    // MARK: Lines

    /// The lines the selection touches, with their final newline (a
    /// selection that ends just after a newline does not touch the next line).
    static func touchedLines(_ ns: NSString, _ sel: NSRange) -> NSRange {
        var s = NSRange(location: min(sel.location, ns.length), length: sel.length)
        if s.length > 0, NSMaxRange(s) <= ns.length, ns.character(at: NSMaxRange(s) - 1) == 10 { s.length -= 1 }
        if NSMaxRange(s) > ns.length { s.length = ns.length - s.location }
        return ns.lineRange(for: s)
    }

    /// The touched lines as strings, without newlines, and whether the
    /// block ended with one.
    static func lines(of ns: NSString, _ block: NSRange) -> (lines: [String], trailingNewline: Bool) {
        var s = ns.substring(with: block)
        let trailing = s.hasSuffix("\n")
        if trailing { s.removeLast() }
        return (s.components(separatedBy: "\n"), trailing)
    }

    /// Whether Move Line Up / Down can move the selection's lines (§6.4:
    /// disabled at the first / last line).
    public static func canMoveLines(in text: String, selection: NSRange, up: Bool) -> Bool {
        let ns = text as NSString
        let block = touchedLines(ns, selection)
        return up ? block.location > 0 : NSMaxRange(block) < ns.length
    }

    /// Editor ▸ Structure ▸ Move Line Up / Down (⌥⌘[ / ⌥⌘]): the touched
    /// lines trade places with the line above or below; the selection
    /// stays on them.
    public static func moveLines(in text: String, selection: NSRange, up: Bool) -> TextChange? {
        let ns = text as NSString
        let block = touchedLines(ns, selection)
        if up {
            guard block.location > 0 else { return nil }
            let prev = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var moving = ns.substring(with: block), other = ns.substring(with: prev)
            if !moving.hasSuffix("\n") { moving += "\n"; other.removeLast() }
            return TextChange(range: NSRange(location: prev.location, length: prev.length + block.length), replacement: moving + other,
                              selection: NSRange(location: selection.location - prev.length, length: selection.length))
        }
        guard NSMaxRange(block) < ns.length else { return nil }
        let next = ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        var moving = ns.substring(with: block), other = ns.substring(with: next)
        if !other.hasSuffix("\n") { other += "\n"; moving.removeLast() }
        return TextChange(range: NSRange(location: block.location, length: block.length + next.length), replacement: other + moving,
                          selection: NSRange(location: selection.location + (other as NSString).length, length: selection.length))
    }

    /// Replaces the touched lines with `transform` applied to each line;
    /// the caret follows its line, a selection covers the changed lines.
    static func mapLines(in text: String, selection: NSRange, _ transform: (Int, String) -> String) -> TextChange? {
        let ns = text as NSString
        let block = touchedLines(ns, selection)
        let (old, trailing) = lines(of: ns, block)
        let firstLine = LineIndex(text).line(at: block.location)
        let new = old.enumerated().map { transform(firstLine + $0.offset, $0.element) }
        guard new != old else { return nil }
        let body = new.joined(separator: "\n")
        let replacement = body + (trailing ? "\n" : "")
        let sel: NSRange
        if selection.length == 0 {
            // The caret keeps its place relative to the line's text.
            let lineStart = block.location
            let col = selection.location - lineStart
            let delta = (new[0] as NSString).length - (old[0] as NSString).length
            sel = NSRange(location: lineStart + max(0, min(col + delta, (new[0] as NSString).length)), length: 0)
        } else {
            sel = NSRange(location: block.location, length: (body as NSString).length)
        }
        return TextChange(range: block, replacement: replacement, selection: sel)
    }

    static func leadingWhitespace(_ s: String) -> String { String(s.prefix { $0 == " " || $0 == "\t" }) }

    /// Editor ▸ Structure ▸ Shift Left / Right (⌘[ / ⌘]): one indentation
    /// step off or onto each touched line (empty lines stay empty).
    public static func shift(in text: String, selection: NSRange, right: Bool, unit: String, indentWidth: Int) -> TextChange? {
        mapLines(in: text, selection: selection) { _, line in
            if right { return line.isEmpty ? line : unit + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(spaces, max(1, indentWidth))))
        }
    }

    // MARK: Re-Indent

    /// For each line: the bracket depth at its start (unclosed `{ ( [`
    /// before it), whether its code starts with a closer, whether the
    /// innermost open brace belongs to a `switch`, and whether the line
    /// starts inside a multi-line comment or string.
    struct LineContext { var depth: Int; var startsWithCloser: Bool; var inSwitch: Bool; var inToken: Bool }

    static func lineContexts(_ text: String, language: SourceTokenizer.Language) -> [LineContext] {
        let units = FoldRegions.code(text, language: language)
        let index = LineIndex(text)
        // Lines that start inside a comment or string token.
        var inToken = Set<Int>()
        for t in SourceTokenizer(language: language).tokens(in: text) where [.comment, .docComment, .string].contains(t.kind) {
            let a = index.line(at: t.range.location), b = index.line(at: max(t.range.location, NSMaxRange(t.range) - 1))
            if b > a { for l in (a + 1)...b { inToken.insert(l) } }
        }
        let clean = String(decoding: units, as: UTF16.self)
        let cleanLines = clean.components(separatedBy: "\n")
        var stack: [(UInt16, Bool)] = []   // opener, opened on a `switch` line
        var out: [LineContext] = []
        for (n, line) in cleanLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let first = trimmed.utf16.first
            out.append(LineContext(depth: stack.count, startsWithCloser: first == 125 || first == 41 || first == 93,
                                   inSwitch: stack.last.map { $0.0 == 123 && $0.1 } ?? false, inToken: inToken.contains(n + 1)))
            let isSwitch = FoldRegions.words(trimmed).contains("switch")
            for u in line.utf16 {
                if u == 123 || u == 40 || u == 91 { stack.append((u, u == 123 && isSwitch)) }
                else if u == 125 || u == 41 || u == 93, !stack.isEmpty { stack.removeLast() }
            }
        }
        return out
    }

    /// Editor ▸ Structure ▸ Re-Indent (⌃I): the touched lines get the
    /// indentation their bracket depth gives; `case` / `default` labels sit
    /// at their `switch`'s level; lines inside multi-line comments and
    /// strings are left alone.
    public static func reindent(in text: String, selection: NSRange, language: SourceTokenizer.Language, unit: String) -> TextChange? {
        let ctx = lineContexts(text, language: language)
        return mapLines(in: text, selection: selection) { lineNo, line in
            guard lineNo - 1 < ctx.count else { return line }
            let c = ctx[lineNo - 1]
            let body = line.drop { $0 == " " || $0 == "\t" }
            if c.inToken || body.isEmpty { return body.isEmpty ? "" : line }
            var depth = c.depth - (c.startsWithCloser ? 1 : 0)
            let w = FoldRegions.words(String(body.prefix(20)))
            if c.inSwitch, !c.startsWithCloser, w.first == "case" || w.first == "default" || (w.first == "@unknown" && w.dropFirst().first == "default") {
                depth -= 1
            }
            return String(repeating: unit, count: max(0, depth)) + body
        }
    }

    // MARK: Add Documentation

    static let declarationKeywords: Set<String> = [
        "func", "init", "deinit", "subscript", "var", "let", "class", "struct", "enum", "protocol", "extension", "actor",
        "typealias", "case", "associatedtype", "macro", "operator",
    ]

    /// The 1-based line of the declaration at `line`: that line, else the
    /// nearest declaration line above it.
    static func declarationLine(_ lines: [String], from line: Int) -> Int? {
        var l = min(line, lines.count)
        while l >= 1 {
            let w = FoldRegions.words(lines[l - 1])
            if w.contains(where: { declarationKeywords.contains($0) }) && !lines[l - 1].trimmingCharacters(in: .whitespaces).hasPrefix("//") { return l }
            if line - l > 200 { return nil }
            l -= 1
        }
        return nil
    }

    /// The text from `start` through the first top-level `(…)` and up to a
    /// `{`, `=` (outside parentheses) or the end of the signature.
    static func signature(_ lines: [String], from line: Int) -> String {
        var out = ""
        var depth = 0
        var sawParen = false
        for l in line...min(lines.count, line + 30) {
            for ch in lines[l - 1] {
                if ch == "(" { depth += 1; sawParen = true }
                if ch == ")" { depth -= 1 }
                if depth == 0 && (ch == "{" || (ch == "=" && !out.hasSuffix("-"))) { return out }
                out.append(ch)
            }
            if depth == 0 && (sawParen || l > line) { return out }
            out.append(" ")
        }
        return out
    }

    /// Splits at top-level commas (outside `() [] <> {}` and strings).
    static func topLevelSplit(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var depth = 0
        var inString = false
        for ch in s {
            if ch == "\"" { inString.toggle() }
            if !inString {
                if "([{<".contains(ch) { depth += 1 }
                if ")]}>".contains(ch) { depth -= 1 }
                if ch == ",", depth == 0 { parts.append(cur); cur = ""; continue }
            }
            cur.append(ch)
        }
        parts.append(cur)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The declaration's parameter names (internal names), and whether it
    /// returns a value and throws.
    static func parameters(of signature: String) -> (names: [String], returns: Bool, throws: Bool, isFunction: Bool) {
        let w = FoldRegions.words(signature)
        let isFunction = w.contains("func") || w.contains("init") || w.contains("subscript") || w.contains("macro")
        guard isFunction, let open = signature.firstIndex(of: "(") else { return ([], false, false, isFunction) }
        // The matching parenthesis.
        var depth = 0
        var close = signature.endIndex
        for i in signature[open...].indices {
            if signature[i] == "(" { depth += 1 }
            if signature[i] == ")" { depth -= 1; if depth == 0 { close = i; break } }
        }
        let inner = close > open ? String(signature[signature.index(after: open)..<close]) : ""
        let names = topLevelSplit(inner).compactMap { p -> String? in
            guard let colon = p.firstIndex(of: ":") else { return nil }
            let labels = FoldRegions.words(String(p[..<colon])).filter { $0 != "inout" && !$0.hasPrefix("@") }
            return labels.last
        }
        let tail = close < signature.endIndex ? String(signature[signature.index(after: close)...]) : ""
        let tailWords = FoldRegions.words(tail)
        var returns = false
        if let arrow = tail.range(of: "->") {
            let type = tail[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            returns = !(type.hasPrefix("Void") || type.hasPrefix("()") || type.hasPrefix("Never"))
        }
        return (names, returns, tailWords.contains("throws") || tailWords.contains("rethrows"), true)
    }

    /// Editor ▸ Structure ▸ Add Documentation (⌥⌘/): a Swift Markup
    /// doc-comment template above the declaration at the caret (above its
    /// attribute lines), indented like it: a summary placeholder, then
    /// `- Parameter`/`- Parameters:`, `- Returns:` and `- Throws:` as the
    /// declaration needs. The summary placeholder is selected.
    public static func addDocumentation(in text: String, caretLine: Int) -> TextChange? {
        let lines = text.components(separatedBy: "\n")
        guard let declLine = declarationLine(lines, from: caretLine) else { return nil }
        var insertLine = declLine
        while insertLine > 1, lines[insertLine - 2].trimmingCharacters(in: .whitespaces).hasPrefix("@") { insertLine -= 1 }
        let indent = leadingWhitespace(lines[declLine - 1])
        let sig = signature(lines, from: declLine)
        let p = parameters(of: sig)
        let summary = "<#Description#>"
        var doc = ["/// \(summary)"]
        if p.names.count == 1 {
            doc.append("/// - Parameter \(p.names[0]): <#\(p.names[0]) description#>")
        } else if p.names.count > 1 {
            doc.append("/// - Parameters:")
            doc += p.names.map { "///   - \($0): <#\($0) description#>" }
        }
        if p.returns { doc.append("/// - Returns: <#description#>") }
        if p.throws { doc.append("/// - Throws: <#description#>") }
        let block = doc.map { indent + $0 }.joined(separator: "\n") + "\n"
        let at = LineIndex(text).range(ofLine: insertLine)?.location ?? 0
        let summaryOffset = at + (indent as NSString).length + 4
        return TextChange(range: NSRange(location: at, length: 0), replacement: block,
                          selection: NSRange(location: summaryOffset, length: (summary as NSString).length))
    }

    // MARK: Delimiters

    static let openers: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125]   // ( ) [ ] { }

    /// The innermost delimiter pair strictly around `range` (offsets of the
    /// opener and closer), ignoring comments and strings.
    static func enclosingPair(_ units: [UInt16], around range: NSRange) -> (Int, Int)? {
        var depth: [UInt16: Int] = [41: 0, 93: 0, 125: 0]
        var i = range.location - 1
        while i >= 0 {
            let u = units[i]
            if let close = openers[u] {
                if depth[close]! == 0 {
                    // Its closer after the range.
                    var d = 0
                    var j = i + 1
                    while j < units.count {
                        if units[j] == u { d += 1 } else if units[j] == close { if d == 0 { break }; d -= 1 }
                        j += 1
                    }
                    if j < units.count && j >= NSMaxRange(range) { return (i, j) }
                    return nil
                }
                depth[close]! -= 1
            } else if depth[u] != nil {
                depth[u]! += 1
            }
            i -= 1
        }
        return nil
    }

    /// Editor ▸ Selection ▸ Balance Delimiters: the text between the
    /// nearest enclosing matching delimiters; when that is already
    /// selected, the delimiters too; when they are selected, the next
    /// enclosing pair's contents.
    public static func balance(in text: String, selection: NSRange, language: SourceTokenizer.Language) -> NSRange? {
        let units = FoldRegions.code(text, language: language == .plain ? .swift : language)
        guard let (o, c) = enclosingPair(units, around: selection) else { return nil }
        let inner = NSRange(location: o + 1, length: c - o - 1)
        if selection == inner { return NSRange(location: o, length: c - o + 1) }
        return inner
    }

    // MARK: Format to Multiple Lines

    /// Editor ▸ Structure ▸ Format to Multiple Lines (⌃M): each element of
    /// the argument, parameter or collection list around the caret on its
    /// own line, one indentation step in; the closer on its own line.
    public static func formatToMultipleLines(in text: String, caret: Int, language: SourceTokenizer.Language, unit: String) -> TextChange? {
        let units = FoldRegions.code(text, language: language == .plain ? .swift : language)
        var probe = NSRange(location: caret, length: 0)
        var pair: (Int, Int)?
        // The innermost ( or [ around the caret (not a brace block).
        while let p = enclosingPair(units, around: probe) {
            if units[p.0] != 123 { pair = p; break }
            probe = NSRange(location: p.0, length: p.1 - p.0 + 1)
        }
        guard let (o, c) = pair else { return nil }
        let ns = text as NSString
        let inner = ns.substring(with: NSRange(location: o + 1, length: c - o - 1))
        let elements = topLevelSplit(inner)
        guard !elements.isEmpty else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: o, length: 0)).location
        let base = leadingWhitespace(ns.substring(with: NSRange(location: lineStart, length: o - lineStart)))
        let replacement = "\n" + elements.map { base + unit + $0 }.joined(separator: ",\n") + "\n" + base
        let first = o + 1 + 1 + ((base + unit) as NSString).length
        return TextChange(range: NSRange(location: o + 1, length: c - o - 1), replacement: replacement, selection: NSRange(location: first, length: 0))
    }

    // MARK: Reformat To Width

    /// The comment prefix of a line ("    /// "), or nil.
    static func commentPrefix(_ line: String) -> String? {
        let ws = leadingWhitespace(line)
        let rest = line.dropFirst(ws.count)
        guard rest.hasPrefix("//") else { return nil }
        let slashes = rest.prefix { $0 == "/" }
        let after = rest.dropFirst(slashes.count)
        return ws + slashes + (after.hasPrefix(" ") || after.isEmpty ? " " : "")
    }

    /// Editor ▸ Structure ▸ Reformat To Width (⌃⌥I): re-wraps the `//`
    /// comment paragraph at the selection so no line passes `column`
    /// (the "Reformat code at column" setting, §9.3). A paragraph ends at
    /// an empty comment line or a line with another prefix.
    public static func reformatToWidth(in text: String, selection: NSRange, column: Int) -> TextChange? {
        let lines = text.components(separatedBy: "\n")
        let index = LineIndex(text)
        let a = index.line(at: selection.location)
        guard a <= lines.count, let prefix = commentPrefix(lines[a - 1]) else { return nil }
        func body(_ l: Int) -> String? {
            guard l >= 1, l <= lines.count, commentPrefix(lines[l - 1]) == prefix else { return nil }
            let b = String(lines[l - 1].dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return b.isEmpty ? nil : b
        }
        guard body(a) != nil else { return nil }
        var first = a, last = max(a, index.line(at: max(selection.location, NSMaxRange(selection) - 1)))
        while body(first - 1) != nil { first -= 1 }
        while body(last + 1) != nil { last += 1 }
        let words = (first...last).compactMap(body).flatMap { $0.split(separator: " ").map(String.init) }
        var out: [String] = []
        var cur = ""
        for w in words {
            if cur.isEmpty { cur = w } else if prefix.count + cur.count + 1 + w.count <= column { cur += " " + w } else { out.append(cur); cur = w }
        }
        if !cur.isEmpty { out.append(cur) }
        let replacement = out.map { prefix + $0 }.joined(separator: "\n")
        let start = index.range(ofLine: first)!.location
        let end = NSMaxRange(index.range(ofLine: last)!)
        let range = NSRange(location: start, length: end - start)
        guard (text as NSString).substring(with: range) != replacement else { return nil }
        return TextChange(range: range, replacement: replacement, selection: NSRange(location: start, length: (replacement as NSString).length))
    }

    // MARK: Selections

    /// Editor ▸ Selection ▸ Split Selection By Lines: one range per touched
    /// line, clipped to the selection (an empty line gets an insertion point).
    public static func splitByLines(in text: String, selection: NSRange) -> [NSRange] {
        guard selection.length > 0 else { return [selection] }
        let index = LineIndex(text)
        let a = index.line(at: selection.location), b = index.line(at: NSMaxRange(selection) - 1)
        return (a...b).compactMap { l in
            guard let r = index.range(ofLine: l) else { return nil }
            let lo = max(r.location, selection.location), hi = min(NSMaxRange(r), NSMaxRange(selection))
            return hi >= lo ? NSRange(location: lo, length: hi - lo) : nil
        }
    }

    /// Editor ▸ Selection ▸ Select Column Up / Down: the offset on the line
    /// above or below `offset`, at the same column (clamped to the line end).
    public static func columnOffset(in text: String, from offset: Int, up: Bool) -> Int? {
        let index = LineIndex(text)
        let line = index.line(at: offset)
        guard let r = index.range(ofLine: line), let target = index.range(ofLine: up ? line - 1 : line + 1) else { return nil }
        return target.location + min(offset - r.location, target.length)
    }

    /// The identifier at (or just before) `offset`.
    public static func identifierRange(in text: String, at offset: Int) -> NSRange? {
        let ns = text as NSString
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let s = UnicodeScalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(s) || s == "_"
        }
        var a = offset
        if !isWord(a) && isWord(a - 1) { a -= 1 }
        guard isWord(a) else { return nil }
        var b = a
        while isWord(a - 1) { a -= 1 }
        while isWord(b + 1) { b += 1 }
        let r = NSRange(location: a, length: b - a + 1)
        if let f = UnicodeScalar(ns.character(at: a)), CharacterSet.decimalDigits.contains(f) { return nil }
        return r
    }

    /// Editor ▸ Select All Symbols / Edit All in Scope (⌃⌘E), lexically:
    /// whole-word occurrences of the identifier at `offset` outside
    /// comments and strings, within the innermost function body holding
    /// the caret when the name is declared there, else the whole file.
    /// (The window uses the language server's document highlights when it
    /// has them.)
    public static func occurrences(in text: String, at offset: Int, language: SourceTokenizer.Language) -> [NSRange] {
        guard let id = identifierRange(in: text, at: offset) else { return [] }
        let ns = text as NSString
        let name = ns.substring(with: id)
        let code = String(decoding: FoldRegions.code(text, language: language == .plain ? .swift : language), as: UTF16.self)
        let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [id] }
        var scope = NSRange(location: 0, length: ns.length)
        let index = LineIndex(text)
        let line = index.line(at: id.location)
        if let fn = FoldRegions.functionRegions(in: text, language: language).filter({ $0.contains(line: line) }).max(by: { $0.depth < $1.depth }),
           let s = index.range(ofLine: fn.startLine), let e = index.range(ofLine: fn.endLine) {
            let body = NSRange(location: s.location, length: NSMaxRange(e) - s.location)
            let declared = try? NSRegularExpression(pattern: "\\b(let|var|for|case)\\s+(\\(?[A-Za-z0-9_, ]*\\b)?" + NSRegularExpression.escapedPattern(for: name) + "\\b|\\b"
                                                    + NSRegularExpression.escapedPattern(for: name) + "\\s*:")
            if declared?.firstMatch(in: code, range: body) != nil { scope = body }
        }
        let found = re.matches(in: code, range: scope).map(\.range)
        return found.isEmpty ? [id] : found
    }

    // MARK: Symbol names

    /// Edit ▸ Copy Symbol Name / Copy Qualified Symbol Name: the name at
    /// the caret with its argument labels ("increment(by:)"); qualified,
    /// with the types the caret is declared in ("Counter.increment(by:)").
    public static func symbolName(in text: String, at offset: Int, language: SourceTokenizer.Language, qualified: Bool) -> String? {
        guard let id = identifierRange(in: text, at: offset) else { return nil }
        let ns = text as NSString
        var name = ns.substring(with: id)
        // A following parameter or argument list gives the labels.
        var j = NSMaxRange(id)
        while j < ns.length, ns.character(at: j) == 32 { j += 1 }
        if j < ns.length, ns.character(at: j) == 40 {
            let units = FoldRegions.code(text, language: language == .plain ? .swift : language)
            if let (o, c) = enclosingPair(units, around: NSRange(location: j + 1, length: 0)), o == j {
                let inner = ns.substring(with: NSRange(location: o + 1, length: c - o - 1))
                let labels = topLevelSplit(inner).map { p -> String in
                    guard let colon = p.firstIndex(of: ":") else { return "_" }
                    return FoldRegions.words(String(p[..<colon])).first ?? "_"
                }
                if language == .swift { name += "(" + labels.map { $0 + ":" }.joined() + ")" }
            }
        }
        guard qualified else { return name }
        // Enclosing type declarations of the caret's line.
        let line = LineIndex(text).line(at: id.location)
        let lines = text.components(separatedBy: "\n")
        let typeKeywords: Set<String> = ["class", "struct", "enum", "protocol", "extension", "actor"]
        var path: [String] = []
        for r in FoldRegions.regions(in: text, language: language) where r.contains(line: line) && r.startLine < line {
            let w = FoldRegions.words(lines[r.startLine - 1])
            if let k = w.firstIndex(where: { typeKeywords.contains($0) }), k + 1 < w.count { path.append(w[k + 1]) }
        }
        // The caret on a type's own declaration line names that type.
        if path.last == name { path.removeLast() }
        return (path + [name]).joined(separator: ".")
    }
}
