import Foundation

/// What the Find navigator looks for: the query, its kind, the match style
/// and case. See `specs/ide/navigators.md` §Find navigator, "Ycode
/// implementation".
public struct FindQuery: Equatable, Sendable {
    /// The Kind pop-up, in menu order (`reference-ui-2.md` §3.3).
    public enum Kind: Int, CaseIterable, Sendable {
        case text, multipleWords, regularExpression, symbols, ancestorTypes, descendentTypes, conformingTypes, callHierarchy, assetReferences

        public var title: String {
            switch self {
            case .text: "Text"
            case .multipleWords: "Multiple Words"
            case .regularExpression: "Regular Expression"
            case .symbols: "Symbols"
            case .ancestorTypes: "Ancestor Types"
            case .descendentTypes: "Descendent Types"
            case .conformingTypes: "Conforming Types"
            case .callHierarchy: "Call Hierarchy"
            case .assetReferences: "Asset References"
            }
        }

        /// Kinds searched in file text (Ycode's engine); the others ask the
        /// language server.
        public var isTextual: Bool { self == .text || self == .multipleWords || self == .regularExpression }
        /// Kinds answered by the language server.
        public var isSemantic: Bool { !isTextual && self != .assetReferences }
        /// Replace mode works on textual kinds only.
        public var supportsReplace: Bool { isTextual }
        /// Kinds Ycode implements (Asset References is listed disabled).
        public var isAvailable: Bool { self != .assetReferences }
    }

    /// The Match pop-up for the textual kinds (`reference-ui-2.md` §3.4).
    public enum Match: Int, CaseIterable, Sendable {
        case containing, matchingWord, startingWith, endingWith
        public var title: String {
            switch self {
            case .containing: "Containing"
            case .matchingWord: "Matching Word"
            case .startingWith: "Starting With"
            case .endingWith: "Ending With"
            }
        }
    }

    /// The Match pop-up for the Symbols kind (Ycode's items): where a
    /// symbol is declared, or every use of it.
    public enum SymbolRole: Int, CaseIterable, Sendable {
        case definitions, references
        public var title: String { self == .definitions ? "Definitions" : "References" }
    }

    public var text: String
    public var kind: Kind
    public var match: Match
    public var ignoreCase: Bool
    public var symbolRole: SymbolRole

    public init(_ text: String, kind: Kind = .text, match: Match = .containing, ignoreCase: Bool = true, symbolRole: SymbolRole = .definitions) {
        self.text = text
        self.kind = kind
        self.match = match
        self.ignoreCase = ignoreCase
        self.symbolRole = symbolRole
    }

    /// The query the older options describe (the editor's find bar).
    public init(_ text: String, options o: WorkspaceSearch.Options) {
        self.init(text, kind: o.regularExpression ? .regularExpression : .text,
                  match: o.wholeWord ? .matchingWord : o.anchor == .start ? .startingWith : o.anchor == .end ? .endingWith : .containing,
                  ignoreCase: o.ignoreCase)
    }

    /// The words of a Multiple Words query.
    public var words: [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// The compiled matcher, or nil for an empty query, an invalid regular
    /// expression, or a kind that is not textual.
    public func matcher() -> FindMatcher? {
        guard kind.isTextual, !text.isEmpty else { return nil }
        switch kind {
        case .multipleWords:
            let w = words
            guard !w.isEmpty else { return nil }
            let rs = w.compactMap { Self.expression(NSRegularExpression.escapedPattern(for: $0), match: match, ignoreCase: ignoreCase) }
            guard rs.count == w.count else { return nil }
            return FindMatcher(regexes: rs, allWords: true, needles: w.compactMap(Self.asciiNeedle), ignoreCase: ignoreCase)
        case .regularExpression:
            guard let r = Self.expression(text, match: match, ignoreCase: ignoreCase) else { return nil }
            return FindMatcher(regexes: [r], allWords: false, needles: Self.literal(ofPattern: text).flatMap(Self.asciiNeedle).map { [$0] } ?? [],
                               ignoreCase: ignoreCase)
        default:
            guard let r = Self.expression(NSRegularExpression.escapedPattern(for: text), match: match, ignoreCase: ignoreCase) else { return nil }
            return FindMatcher(regexes: [r], allWords: false, needles: Self.asciiNeedle(text).map { [$0] } ?? [], ignoreCase: ignoreCase)
        }
    }

    /// Word characters for the match styles: letters, digits and "_".
    static let notWordBefore = "(?<![\\p{L}\\p{N}_])"
    static let notWordAfter = "(?![\\p{L}\\p{N}_])"

    /// The pattern with the match style applied. `^` and `$` match at
    /// line boundaries; `.` does not cross a line (use `\n` or `[\s\S]`).
    static func expression(_ pattern: String, match: Match, ignoreCase: Bool) -> NSRegularExpression? {
        var p = pattern
        switch match {
        case .containing: break
        case .matchingWord: p = notWordBefore + "(?:" + p + ")" + notWordAfter
        case .startingWith: p = notWordBefore + "(?:" + p + ")"
        case .endingWith: p = "(?:" + p + ")" + notWordAfter
        }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if ignoreCase { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: p, options: options)
    }

    /// The UTF-8 bytes of an ASCII text, for the byte pre-check; nil when
    /// the text has other characters.
    static func asciiNeedle(_ s: String) -> [UInt8]? {
        let b = Array(s.utf8)
        return !b.isEmpty && b.allSatisfy { $0 < 128 } ? b : nil
    }

    /// The literal a regular expression stands for, when it has no
    /// metacharacters at all (then the byte pre-check applies).
    static func literal(ofPattern p: String) -> String? {
        let meta = Set("\\^$.|?*+()[]{}")
        return p.contains(where: { meta.contains($0) }) ? nil : p
    }
}

/// A compiled query: one expression (Text, Regular Expression) or one per
/// word (Multiple Words), and the ASCII byte strings a file must contain
/// to be worth decoding.
public struct FindMatcher: @unchecked Sendable {
    // NSRegularExpression is immutable and safe to share between threads.
    let regexes: [NSRegularExpression]
    let allWords: Bool
    let needles: [[UInt8]]
    let ignoreCase: Bool

    /// The single expression (Text and Regular Expression kinds).
    public var expression: NSRegularExpression? { allWords ? nil : regexes.first }

    /// Whether the bytes can hold a match: every needle occurs (ASCII case
    /// folded when ignoring case). True when there are no needles.
    public func mayMatch(_ bytes: UnsafeRawBufferPointer) -> Bool {
        needles.allSatisfy { Self.contains(bytes, $0, ignoreCase: ignoreCase) }
    }

    static func contains(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8], ignoreCase: Bool) -> Bool {
        let n = needle.count, h = hay.count
        guard n > 0 else { return true }
        guard h >= n else { return false }
        @inline(__always) func fold(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c | 0x20 : c }
        let first = ignoreCase ? fold(needle[0]) : needle[0]
        let rest = ignoreCase ? needle.map(fold) : needle
        var i = 0
        let last = h - n
        while i <= last {
            let c = hay[i]
            if (ignoreCase ? fold(c) : c) == first {
                var j = 1
                while j < n {
                    let d = hay[i + j]
                    if (ignoreCase ? fold(d) : d) != rest[j] { break }
                    j += 1
                }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }

    /// The matches in a text, in order. Empty matches (such as `^`) are not
    /// results. Multiple Words: on each line that holds every word, each
    /// word's occurrences.
    public func matches(in text: String, limit: Int = .max) -> [WorkspaceSearch.Match] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var ranges: [NSRange] = []
        if allWords {
            var perWord: [[NSRange]] = []
            for r in regexes {
                let found = r.matches(in: text, range: all).map(\.range).filter { $0.length > 0 }
                if found.isEmpty { return [] }
                perWord.append(found)
            }
            let index = LineIndex(text)
            var linesPerWord: [Set<Int>] = perWord.map { Set($0.map { index.line(at: $0.location) }) }
            let common = linesPerWord.removeFirst()
            let lines = linesPerWord.reduce(common) { $0.intersection($1) }
            ranges = perWord.flatMap { $0 }.filter { lines.contains(index.line(at: $0.location)) }
                .sorted { ($0.location, $0.length) < ($1.location, $1.length) }
            return Self.describe(ranges, in: ns, index: index, limit: limit)
        }
        guard let r = regexes.first else { return [] }
        r.enumerateMatches(in: text, range: all) { m, _, stop in
            guard let m, m.range.length > 0 else { return }
            ranges.append(m.range)
            if ranges.count >= limit { stop.pointee = true }
        }
        return ranges.isEmpty ? [] : Self.describe(ranges, in: ns, index: LineIndex(text), limit: limit)
    }

    static func describe(_ ranges: [NSRange], in ns: NSString, index: LineIndex, limit: Int) -> [WorkspaceSearch.Match] {
        ranges.prefix(limit).map { range in
            let line = index.line(at: range.location)
            let lineRange = index.range(ofLine: line) ?? NSRange(location: 0, length: 0)
            let raw = ns.substring(with: lineRange)
            let leading = raw.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let column = range.location - lineRange.location
            let start = max(0, column - leading)
            let len = max(0, min(range.length, (trimmed as NSString).length - start))
            let lastLine = index.line(at: max(range.location, NSMaxRange(range) - 1))
            return WorkspaceSearch.Match(line: line, text: trimmed, range: range, column: column + 1,
                                         highlight: NSRange(location: min(start, (trimmed as NSString).length), length: len),
                                         lineSpan: lastLine - line + 1, matchedText: ns.substring(with: range))
        }
    }
}
