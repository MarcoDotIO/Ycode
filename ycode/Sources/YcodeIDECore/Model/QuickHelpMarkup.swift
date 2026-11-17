import Foundation

/// A run of Quick Help text with one inline style (P-083): Swift Markup's
/// emphasis, strong text and code voice rendered rather than shown as
/// asterisks and backticks. Both IDEs draw the same runs.
public struct QuickHelpRun: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case plain, emphasis, strong, code
    }

    public var text: String
    public var style: Style

    public init(_ text: String, _ style: Style = .plain) {
        self.text = text
        self.style = style
    }

    /// The runs of one paragraph of Markdown: `code`, *emphasis* or
    /// _emphasis_, **strong** or __strong__, [links](…) as their text,
    /// backslash escapes, the common HTML entities, and "---" as an em
    /// dash. Unclosed markers stay as text.
    public static func parse(_ s: String) -> [QuickHelpRun] {
        let c = Array(s)
        var out: [QuickHelpRun] = []
        var plain = ""
        func emit(_ text: String, _ style: Style) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.style == style { out[out.count - 1].text += text } else { out.append(.init(text, style)) }
        }
        func flushPlain() {
            emit(typography(plain), .plain)
            plain = ""
        }
        // The index of the closing `marker` after `from` (nil: none).
        func close(_ marker: [Character], from: Int) -> Int? {
            var j = from
            while j + marker.count <= c.count {
                if c[j] == "\\" { j += 2; continue }
                if Array(c[j..<(j + marker.count)]) == marker, j > from { return j }
                j += 1
            }
            return nil
        }
        func isWord(_ i: Int) -> Bool { i >= 0 && i < c.count && (c[i].isLetter || c[i].isNumber) }
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count, "\\`*_[]()#+-.!{}<>".contains(c[i + 1]) {
                plain.append(c[i + 1])
                i += 2
                continue
            }
            if ch == "`" {
                let ticks = c[i...].prefix { $0 == "`" }.count
                let marker = Array(repeating: Character("`"), count: ticks)
                if let j = close(marker, from: i + ticks) {
                    flushPlain()
                    emit(String(c[(i + ticks)..<j]).trimmingCharacters(in: .whitespaces), .code)
                    i = j + ticks
                    continue
                }
            }
            if ch == "*" || ch == "_" {
                let double = i + 1 < c.count && c[i + 1] == ch
                let marker = double ? [ch, ch] : [ch]
                // An underscore inside a word (snake_case) is not emphasis.
                let opens = ch == "*" || !isWord(i - 1)
                if opens, i + marker.count < c.count, !c[i + marker.count].isWhitespace,
                   let j = close(marker, from: i + marker.count), !c[j - 1].isWhitespace,
                   ch == "*" || !isWord(j + marker.count) {
                    flushPlain()
                    let inner = parse(String(c[(i + marker.count)..<j]))
                    for r in inner { emit(r.text, r.style == .plain ? (double ? .strong : .emphasis) : r.style) }
                    i = j + marker.count
                    continue
                }
            }
            if ch == "[", let j = close(["]"], from: i + 1), j + 1 < c.count, c[j + 1] == "(", let k = close([")"], from: j + 2) {
                flushPlain()
                for r in parse(String(c[(i + 1)..<j])) { emit(r.text, r.style) }
                i = k + 1
                continue
            }
            plain.append(ch)
            i += 1
        }
        flushPlain()
        return out
    }

    /// Entities and dashes in plain text.
    static func typography(_ s: String) -> String {
        guard s.contains("&") || s.contains("---") else { return s }
        var t = s
        for (e, r) in [("&mdash;", "—"), ("&ndash;", "–"), ("&nbsp;", "\u{00A0}"), ("&lt;", "<"), ("&gt;", ">"),
                       ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: e, with: r)
        }
        return t.replacingOccurrences(of: "---", with: "—")
    }
}

/// One block of a Quick Help Discussion (P-083).
public enum QuickHelpBlock: Equatable, Sendable {
    case paragraph([QuickHelpRun])
    case heading([QuickHelpRun])
    /// A code block, its line breaks kept.
    case code(String)
    /// A numbered ("1.") or bulleted ("•") list item.
    case listItem(marker: String, [QuickHelpRun])

    /// The block as plain text ("1. Text", "• Text").
    public var plainText: String {
        switch self {
        case .paragraph(let r), .heading(let r): r.map(\.text).joined()
        case .code(let s): s
        case .listItem(let m, let r): m + " " + r.map(\.text).joined()
        }
    }
}
