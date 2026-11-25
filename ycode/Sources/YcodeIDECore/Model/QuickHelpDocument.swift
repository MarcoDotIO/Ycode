import Foundation

/// Quick Help content parsed from a sourcekit-lsp hover (Markdown: a
/// fenced declaration, then the doc comment in Swift Markup). Section order
/// follows `specs/ide/reference-ui-4.md` §7.
public struct QuickHelpDocument: Equatable, Sendable {
    public struct Parameter: Equatable, Sendable {
        public var name: String
        public var text: String
    }
    public struct Callout: Equatable, Sendable {
        /// The callout name as shown, for example "Note" or "Important".
        public var title: String
        public var text: String
    }

    public var title: String = ""
    public var summary: String?
    public var declaration: String = ""
    public var file: String?
    public var parameters: [Parameter] = []
    public var returns: String?
    public var throwsText: String?
    public var discussion: [String] = []
    public var callouts: [Callout] = []
    /// The Discussion as rendered blocks, in the comment's order: paragraphs
    /// and list items with their inline styles, headings, and code blocks
    /// with their line breaks (P-083). `discussion` is their plain text.
    public var discussionBlocks: [QuickHelpBlock] = []
    /// The Swift Markup behind each plain text above (summary, parameters,
    /// returns, callouts), for `runs(for:)`.
    var markup: [String: String] = [:]
    /// Quick Help for a module (an `import`'s module name, `popovers.md`
    /// §4.1): the title, the abstract (`summary`), a hairline, Overview and
    /// its blocks, the documentation link; no declaration or file link.
    public var isModule = false
    /// A module's Overview, as rendered blocks.
    public var overview: [QuickHelpBlock] = []

    /// The inline runs of one of the document's plain texts (italic, bold,
    /// code voice), as the reference renders them ("O(n)" with an italic n).
    public func runs(for plain: String) -> [QuickHelpRun] {
        markup[plain].map(QuickHelpRun.parse) ?? [QuickHelpRun(plain)]
    }

    /// The defining file's link: not for an SDK symbol, whose file is a
    /// generated `.swiftinterface` (P-083).
    public var showsFileLink: Bool { !isModule && (file.map { !$0.hasSuffix(".swiftinterface") } ?? false) }
    /// "Open in Developer Documentation": for SDK symbols (an interface
    /// file or none), not for the project's own symbols (P-083).
    public var showsDocumentationLink: Bool { isModule || (file.map { $0.hasSuffix(".swiftinterface") } ?? true) }

    /// The section names present, in display order.
    public var sectionOrder: [String] {
        var s = ["Title"]
        if summary != nil { s.append("Summary") }
        if isModule {
            if !overview.isEmpty { s.append("Overview") }
            s.append("Open in Developer Documentation")
            return s
        }
        if !declaration.isEmpty { s.append("Declaration") }
        if showsFileLink { s.append("File") }
        if !parameters.isEmpty { s.append("Parameters") }
        if returns != nil { s.append("Return Value") }
        if throwsText != nil { s.append("Throws") }
        if !discussion.isEmpty { s.append("Discussion") }
        s += callouts.map(\.title)
        if showsDocumentationLink { s.append("Open in Developer Documentation") }
        return s
    }

    /// Swift Markup callout keywords (public Swift Markup documentation).
    public static let calloutKeywords = [
        "attention", "author", "authors", "bug", "complexity", "copyright", "date", "experiment",
        "important", "invariant", "note", "postcondition", "precondition", "remark", "remarks",
        "requires", "seealso", "since", "tip", "todo", "version", "warning",
    ]

    public init() {}

    public init(hover markdown: String, file: String? = nil) {
        self.file = file
        var lines = markdown.components(separatedBy: "\n")
        // Declaration: the first fenced block.
        if let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }),
           let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            declaration = lines[(open + 1)..<close].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.removeSubrange(open...close)
        }
        title = Self.symbolName(in: declaration)
        // Paragraphs, list items, headings and code blocks of the doc comment.
        enum Item {
            case paragraph(String)
            case bullet(indent: Int, text: String)
            case numbered(marker: String, text: String)
            case heading(String)
            case code(String)
        }
        var items: [Item] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty { items.append(.paragraph(current.joined(separator: " "))); current = [] }
        }
        var fence: [String]?
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if var f = fence {
                if t.hasPrefix("```") {
                    items.append(.code(f.joined(separator: "\n")))
                    fence = nil
                } else {
                    f.append(raw)
                    fence = f
                }
                continue
            }
            let indent = raw.prefix { $0 == " " }.count
            if t.hasPrefix("```") { flush(); fence = []; continue }
            // Thematic breaks ("---", "***") separate nothing in Quick Help.
            if t.isEmpty || t == "---" || t == "***" { flush(); continue }
            if t.hasPrefix("#"), let h = Self.heading(t) { flush(); items.append(.heading(h)); continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                flush()
                items.append(.bullet(indent: indent, text: String(t.dropFirst(2))))
            } else if let (marker, rest) = Self.numbered(t) {
                flush()
                items.append(.numbered(marker: marker, text: rest))
            } else if current.isEmpty, indent > 0, let last = items.last, case .bullet(let i, let text) = last {
                // A continuation line of a list item.
                items[items.count - 1] = .bullet(indent: i, text: text + " " + t)
            } else if current.isEmpty, indent > 0, let last = items.last, case .numbered(let m, let text) = last {
                items[items.count - 1] = .numbered(marker: m, text: text + " " + t)
            } else {
                current.append(t)
            }
        }
        flush()
        if let f = fence { items.append(.code(f.joined(separator: "\n"))) }

        var blocks: [QuickHelpBlock] = []
        var inParameters = false
        var otherBullets: [QuickHelpBlock] = []
        var summaryTaken = false
        func plainText(_ m: String) -> String {
            let p = Self.stripInline(m)
            if p != m { markup[p] = m }
            return p
        }
        for item in items {
            switch item {
            case .paragraph(let m):
                inParameters = false
                if !summaryTaken {
                    summary = plainText(m)
                    summaryTaken = true
                } else {
                    blocks.append(.paragraph(QuickHelpRun.parse(m)))
                }
            case .heading(let h):
                inParameters = false
                blocks.append(.heading(QuickHelpRun.parse(h)))
            case .code(let c):
                inParameters = false
                blocks.append(.code(c))
            case .numbered(let marker, let m):
                inParameters = false
                blocks.append(.listItem(marker: marker, QuickHelpRun.parse(m)))
            case .bullet(let indent, let m):
                let text = plainText(m)
                if inParameters, indent > 0, let (name, desc) = Self.split(text) {
                    parameters.append(.init(name: name, text: desc))
                    if let raw = Self.split(m)?.1 { markup[desc] = raw }
                    continue
                }
                inParameters = false
                guard let (key, rest) = Self.split(text) else { otherBullets.append(.listItem(marker: "•", QuickHelpRun.parse(m))); continue }
                if let raw = Self.split(m)?.1, raw != rest { markup[rest] = raw }
                let lower = key.lowercased()
                if lower == "parameters" { inParameters = true; continue }
                if lower.hasPrefix("parameter ") {
                    parameters.append(.init(name: String(key.dropFirst("parameter ".count)).trimmingCharacters(in: .whitespaces), text: rest))
                } else if lower == "returns" || lower == "return" {
                    returns = rest
                } else if lower == "throws" {
                    throwsText = rest
                } else if Self.calloutKeywords.contains(lower.replacingOccurrences(of: " ", with: "")) {
                    let name = lower == "seealso" ? "See Also" : key.prefix(1).uppercased() + key.dropFirst()
                    callouts.append(.init(title: name, text: rest))
                } else {
                    otherBullets.append(.listItem(marker: "•", QuickHelpRun.parse(m)))
                }
            }
        }
        discussionBlocks = blocks + otherBullets
        discussion = discussionBlocks.map(\.plainText)
    }

    /// "## Title" → "Title".
    static func heading(_ t: String) -> String? {
        let level = t.prefix { $0 == "#" }.count
        guard (1...6).contains(level), t.dropFirst(level).first == " " else { return nil }
        return t.dropFirst(level).trimmingCharacters(in: .whitespaces)
    }

    /// "3. Text" or "3) Text" → ("3.", "Text").
    static func numbered(_ t: String) -> (String, String)? {
        let digits = t.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 4 else { return nil }
        let after = t.dropFirst(digits.count)
        guard let p = after.first, p == "." || p == ")", after.dropFirst().first == " " else { return nil }
        return (digits + ".", after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// "name: text" → (name, text).
    static func split(_ s: String) -> (String, String)? {
        guard let c = s.firstIndex(of: ":") else { return nil }
        let key = s[..<c].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count < 40 else { return nil }
        return (key, s[s.index(after: c)...].trimmingCharacters(in: .whitespaces))
    }

    /// The text without its inline markup (code voice, emphasis, links).
    static func stripInline(_ s: String) -> String {
        QuickHelpRun.parse(s).map(\.text).joined()
    }

    /// The declared name: the identifier after the introducer keyword.
    public static func symbolName(in declaration: String) -> String {
        let introducers: Set<String> = ["func", "var", "let", "struct", "class", "enum", "protocol", "actor", "typealias",
                                        "associatedtype", "case", "init", "subscript", "macro", "extension", "operator"]
        let words = declaration.replacingOccurrences(of: "(", with: " (").split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        if let i = words.firstIndex(where: { introducers.contains($0) }) {
            if words[i] == "init" || words[i] == "subscript" { return words[i] }
            if i + 1 < words.count {
                return String(words[i + 1].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "`" })
            }
        }
        return words.first ?? ""
    }
}
