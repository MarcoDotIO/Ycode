import Foundation

/// Workspace text search for the Find navigator. See
/// `specs/ide/navigators.md` §Find navigator.
public enum WorkspaceSearch {
    public struct Match: Equatable, Sendable {
        public var line: Int
        /// The whole line, trimmed of leading whitespace.
        public var text: String
        /// UTF-16 range of the match within the file.
        public var range: NSRange
    }

    /// Find options: Text or Regular Expression; Containing or Matching
    /// Word; Ignoring or Matching Case.
    public struct Options: Equatable, Sendable {
        public var regularExpression = false
        public var wholeWord = false
        public var ignoreCase = true
        /// Match: Starting With / Ending With (word boundary at one end).
        public enum Anchor: Sendable { case none, start, end }
        public var anchor: Anchor = .none
        public init(regularExpression: Bool = false, wholeWord: Bool = false, ignoreCase: Bool = true, anchor: Anchor = .none) {
            self.regularExpression = regularExpression
            self.wholeWord = wholeWord
            self.ignoreCase = ignoreCase
            self.anchor = anchor
        }

        /// The pattern that implements these options, or nil if the
        /// regular expression is invalid.
        func expression(for query: String) -> NSRegularExpression? {
            var pattern = regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
            if wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
            else if anchor == .start { pattern = "\\b(?:" + pattern + ")" }
            else if anchor == .end { pattern = "(?:" + pattern + ")\\b" }
            return try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        }
    }

    public struct FileResult: Equatable, Sendable {
        public var path: String
        public var matches: [Match]
    }

    /// Files that are searched: text files by extension.
    static let textExtensions: Set<String> = [
        "swift", "h", "m", "mm", "c", "cc", "cpp", "hpp", "metal", "plist", "json", "strings", "xcconfig", "md",
        "txt", "yml", "yaml", "sh", "py", "js", "html", "css", "entitlements", "modulemap", "pch",
    ]

    /// Case-insensitive literal search of every file under `root`, in
    /// navigator order. Stops after `limit` matches.
    public static func search(_ query: String, in root: NavigatorNode, options: Options = Options(), limit: Int = 1000) -> [FileResult] {
        guard !query.isEmpty, let regex = options.expression(for: query) else { return [] }
        var out: [FileResult] = []
        var total = 0
        for file in root.allFiles {
            guard let path = file.path, textExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let matches = search(regex, inText: text)
            if !matches.isEmpty { out.append(FileResult(path: path, matches: matches)) }
            total += matches.count
            if total >= limit { break }
        }
        return out
    }

    /// The matches of `query` in one text, with `options` applied; empty for an
    /// empty or invalid query.
    public static func search(_ query: String, inText text: String, options: Options = Options()) -> [Match] {
        guard !query.isEmpty, let regex = options.expression(for: query) else { return [] }
        return search(regex, inText: text)
    }

    static func search(_ regex: NSRegularExpression, inText text: String) -> [Match] {
        let ns = text as NSString
        let index = LineIndex(text)
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.range.length > 0 else { return nil } // empty matches (e.g. `^`) are not results
            let line = index.line(at: m.range.location)
            let lineText = ns.substring(with: index.range(ofLine: line)!).trimmingCharacters(in: .whitespaces)
            return Match(line: line, text: lineText, range: m.range)
        }
    }
}

/// Declarations for the Symbol navigator, found by a light scan over the
/// lexer's output (not a parser). See `specs/ide/navigators.md`.
public enum SymbolScanner {
    public struct Symbol: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case `class`, `struct`, `enum`, `protocol`, `extension`, actor, function, `typealias`, macro, interface, implementation
            case property, enumCase, initializer
            /// Kinds whose body holds members.
            var isContainer: Bool { [.class, .struct, .enum, .protocol, .extension, .actor].contains(self) }
        }
        public var kind: Kind
        public var name: String
        public var line: Int
        /// Members, for types (Swift only).
        public var children: [Symbol] = []
        public init(kind: Kind, name: String, line: Int, children: [Symbol] = []) {
            self.kind = kind
            self.name = name
            self.line = line
            self.children = children
        }
    }

    /// Top-level declarations (brace depth 0) of a file.
    public static func symbols(in text: String, language: SourceTokenizer.Language) -> [Symbol] {
        guard language != .plain else { return [] }
        // Blank out comments and strings so their braces and words do not count.
        var units = Array(text.utf16)
        for t in SourceTokenizer(language: language).tokens(in: text)
        where [.comment, .docComment, .string, .preprocessor].contains(t.kind) {
            for i in t.range.location..<min(NSMaxRange(t.range), units.count) where units[i] != 10 { units[i] = 32 }
        }
        let clean = String(decoding: units, as: UTF16.self)
        let index = LineIndex(clean)
        let words = scanWords(clean)
        var out: [Symbol] = []
        let swiftKinds: [String: Symbol.Kind] = [
            "class": .class, "struct": .struct, "enum": .enum, "protocol": .protocol, "extension": .extension,
            "actor": .actor, "func": .function, "typealias": .typealias, "macro": .macro,
        ]
        if language == .swift { return swiftSymbols(words, index: index, kinds: swiftKinds) }
        for (i, w) in words.enumerated() where w.depth == 0 {
            do {
                if w.text == "@interface" || w.text == "@implementation", i + 1 < words.count {
                    out.append(Symbol(kind: w.text == "@interface" ? .interface : .implementation, name: words[i + 1].text,
                                      line: index.line(at: w.offset)))
                } else if w.text == "struct" || w.text == "enum", i + 2 < words.count, words[i + 1].isIdentifier, words[i + 2].text == "{" {
                    out.append(Symbol(kind: w.text == "struct" ? .struct : .enum, name: words[i + 1].text, line: index.line(at: w.offset)))
                } else if w.isIdentifier, i + 1 < words.count, words[i + 1].text == "(",
                          let close = words[(i + 1)...].firstIndex(where: { $0.text == ")" && $0.depth == 0 }),
                          close + 1 < words.count, words[close + 1].text == "{",
                          !["if", "while", "for", "switch", "return", "sizeof"].contains(w.text) {
                    out.append(Symbol(kind: .function, name: w.text, line: index.line(at: w.offset)))
                }
            }
        }
        return out
    }

    /// Swift declarations as a tree: types hold the declarations made
    /// directly in their bodies; function bodies are not entered.
    static func swiftSymbols(_ words: [Word], index: LineIndex, kinds: [String: Symbol.Kind]) -> [Symbol] {
        // Open type bodies: (symbol, depth of its members).
        var stack: [(Symbol, Int)] = []
        var top: [Symbol] = []
        var pending: (Symbol, Int)?   // a type whose `{` has not been seen yet
        func add(_ s: Symbol) {
            if stack.isEmpty { top.append(s) } else { stack[stack.count - 1].0.children.append(s) }
        }
        func close() {
            let (s, _) = stack.removeLast()
            add(s)
        }
        for (i, w) in words.enumerated() {
            if w.text == "}" {
                while let last = stack.last, w.depth < last.1 { _ = last; close() }
                continue
            }
            if w.text == "{" {
                if let (s, d) = pending, w.depth == d { stack.append((s, d + 1)); pending = nil }
                continue
            }
            let memberDepth = stack.last?.1 ?? 0
            guard w.depth == memberDepth, pending == nil else { continue }
            let next = i + 1 < words.count ? words[i + 1] : nil
            let line = index.line(at: w.offset)
            if let kind = kinds[w.text], let n = next, n.isIdentifier, !(w.text == "class" && (n.text == "func" || n.text == "var")) {
                let s = Symbol(kind: kind, name: n.text, line: line)
                if kind.isContainer { pending = (s, w.depth) } else { add(s) }
            } else if !stack.isEmpty, ["var", "let"].contains(w.text), let n = next, n.isIdentifier {
                add(Symbol(kind: .property, name: n.text, line: line))
            } else if !stack.isEmpty, w.text == "case", stack.last?.0.kind == .enum, let n = next, n.isIdentifier {
                add(Symbol(kind: .enumCase, name: n.text, line: line))
            } else if !stack.isEmpty, w.text == "init" {
                add(Symbol(kind: .initializer, name: "init", line: line))
            }
        }
        if let (s, _) = pending { add(s) }
        while !stack.isEmpty { close() }
        return top
    }

    struct Word { var text: String; var offset: Int; var depth: Int; var isIdentifier: Bool }

    /// Identifiers (with a leading `@` kept) and the punctuation `{ } ( ) ;`,
    /// each with the brace depth before it.
    static func scanWords(_ s: String) -> [Word] {
        let u = Array(s.utf16)
        var out: [Word] = []
        var depth = 0
        var i = 0
        func isStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
        func isPart(_ c: UInt16) -> Bool { isStart(c) || (c >= 48 && c <= 57) }
        while i < u.count {
            let c = u[i]
            if isStart(c) || (c == 64 && i + 1 < u.count && isStart(u[i + 1])) {
                let start = i
                i += 1
                while i < u.count && isPart(u[i]) { i += 1 }
                let text = String(decoding: u[start..<i], as: UTF16.self)
                out.append(Word(text: text, offset: start, depth: depth, isIdentifier: c != 64))
                continue
            }
            switch c {
            case 123: out.append(Word(text: "{", offset: i, depth: depth, isIdentifier: false)); depth += 1
            case 125: depth = max(0, depth - 1); out.append(Word(text: "}", offset: i, depth: depth, isIdentifier: false))
            case 40: out.append(Word(text: "(", offset: i, depth: depth, isIdentifier: false))
            case 41: out.append(Word(text: ")", offset: i, depth: depth, isIdentifier: false))
            case 59: out.append(Word(text: ";", offset: i, depth: depth, isIdentifier: false))
            default: break
            }
            i += 1
        }
        return out
    }
}

/// One finished build, for the Report navigator.
public struct BuildReport: Equatable, Sendable {
    public var title: String
    public var date: Date
    public var succeeded: Bool
    public var log: [String]
    public var errorCount: Int
    public var warningCount: Int
    /// Where and how it ran (the build log and test report pages).
    public var context = ReportContext()
}
