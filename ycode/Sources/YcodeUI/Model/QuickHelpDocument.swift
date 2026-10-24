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

    /// The section names present, in display order.
    public var sectionOrder: [String] {
        var s = ["Title"]
        if summary != nil { s.append("Summary") }
        if !declaration.isEmpty { s.append("Declaration") }
        if file != nil { s.append("File") }
        if !parameters.isEmpty { s.append("Parameters") }
        if returns != nil { s.append("Return Value") }
        if throwsText != nil { s.append("Throws") }
        if !discussion.isEmpty { s.append("Discussion") }
        s += callouts.map(\.title)
        s.append("Open in Developer Documentation")
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
        // Paragraphs and list items of the doc comment.
        let body = lines.filter { let t = $0.trimmingCharacters(in: .whitespaces); return t != "---" && t != "***" }
        var paragraphs: [String] = []
        var current: [String] = []
        var bullets: [(indent: Int, text: String)] = []
        func flush() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
        }
        var items: [(isBullet: Bool, indent: Int, text: String)] = []
        for raw in body {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " }.count
            if t.isEmpty { flush(); continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                flush()
                for p in paragraphs { items.append((false, 0, p)) }
                paragraphs = []
                items.append((true, indent, String(t.dropFirst(2))))
            } else if let last = items.last, last.isBullet, current.isEmpty, paragraphs.isEmpty, indent > 0 {
                // A continuation line of a list item.
                items[items.count - 1].text += " " + t
            } else {
                current.append(t)
            }
        }
        flush()
        for p in paragraphs { items.append((false, 0, p)) }
        _ = bullets
        bullets = []

        var plain: [String] = []
        var inParameters = false
        var otherBullets: [String] = []
        for item in items {
            let text = Self.stripInline(item.text)
            if !item.isBullet { plain.append(text); inParameters = false; continue }
            if inParameters, item.indent > 0, let (name, desc) = Self.split(text) {
                parameters.append(.init(name: name, text: desc)); continue
            }
            inParameters = false
            guard let (key, rest) = Self.split(text) else { otherBullets.append(text); continue }
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
                otherBullets.append(text)
            }
        }
        if let first = plain.first { summary = first; plain.removeFirst() }
        discussion = plain + otherBullets.map { "• " + $0 }
    }

    /// "name: text" → (name, text).
    static func split(_ s: String) -> (String, String)? {
        guard let c = s.firstIndex(of: ":") else { return nil }
        let key = s[..<c].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count < 40 else { return nil }
        return (key, s[s.index(after: c)...].trimmingCharacters(in: .whitespaces))
    }

    /// Drops inline code backticks and emphasis markers.
    static func stripInline(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
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
