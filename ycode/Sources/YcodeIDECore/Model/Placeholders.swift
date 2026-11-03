import Foundation

/// Editor placeholders: `<#text#>` tokens in source text. See
/// `specs/ide/source-editor.md` §Placeholders.
public enum Placeholders {
    /// Ranges of every `<#…#>` token (UTF-16), in order. A token does not
    /// span lines and is not empty.
    public static func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let open = ns.range(of: "<#", range: NSRange(location: from, length: ns.length - from))
            guard open.location != NSNotFound else { break }
            let rest = NSRange(location: NSMaxRange(open), length: ns.length - NSMaxRange(open))
            let close = ns.range(of: "#>", range: rest)
            guard close.location != NSNotFound else { break }
            let inner = NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
            let body = ns.substring(with: inner)
            if inner.length > 0, !body.contains("\n"), !body.contains("<#") {
                out.append(NSRange(location: open.location, length: NSMaxRange(close) - open.location))
                from = NSMaxRange(close)
            } else {
                from = open.location + 2
            }
        }
        return out
    }

    /// The token's text without the delimiters.
    public static func text(of range: NSRange, in text: String) -> String {
        (text as NSString).substring(with: NSRange(location: range.location + 2, length: range.length - 4))
    }

    /// The token at or containing `offset` (insertion points strictly inside).
    public static func token(containing offset: Int, in text: String) -> NSRange? {
        ranges(in: text).first { offset > $0.location && offset < NSMaxRange($0) }
    }

    /// The next token after the selection (wrapping), or the previous one.
    public static func next(from selection: NSRange, in text: String, backward: Bool = false) -> NSRange? {
        let all = ranges(in: text)
        guard !all.isEmpty else { return nil }
        if backward {
            return all.last { NSMaxRange($0) <= selection.location && $0 != selection } ?? all.last
        }
        return all.first { $0.location >= NSMaxRange(selection) && $0 != selection } ?? all.first
    }

    /// Converts an LSP snippet (`${1:name}`, `$1`, `$0`, `\$`) to text with
    /// `<#…#>` tokens. Numbered stops without a default become `<#value#>`;
    /// `$0` (the final position) is dropped.
    public static func fromLSPSnippet(_ s: String) -> String {
        var out = ""
        let it = Array(s)
        var i = 0
        func parseBody(_ end: inout Int) -> String {
            // Reads to the matching `}` from `end` (already past `${n:`).
            var depth = 1, body = ""
            while end < it.count {
                let c = it[end]
                if c == "\\", end + 1 < it.count { body.append(it[end + 1]); end += 2; continue }
                if c == "$", end + 1 < it.count, it[end + 1] == "{" { depth += 1 }
                if c == "}" { depth -= 1; if depth == 0 { end += 1; return body } }
                body.append(c)
                end += 1
            }
            return body
        }
        while i < it.count {
            let c = it[i]
            if c == "\\", i + 1 < it.count { out.append(it[i + 1]); i += 2; continue }
            if c == "$", i + 1 < it.count {
                if it[i + 1] == "{" {
                    var j = i + 2
                    var num = ""
                    while j < it.count, it[j].isNumber { num.append(it[j]); j += 1 }
                    if !num.isEmpty, j < it.count, it[j] == ":" {
                        j += 1
                        let body = fromLSPSnippet(parseBody(&j))
                        out += body.isEmpty ? "<#value#>" : "<#\(body)#>"
                        i = j
                        continue
                    }
                    if !num.isEmpty, j < it.count, it[j] == "}" {
                        if num != "0" { out += "<#value#>" }
                        i = j + 1
                        continue
                    }
                } else if it[i + 1].isNumber {
                    var j = i + 1
                    var num = ""
                    while j < it.count, it[j].isNumber { num.append(it[j]); j += 1 }
                    if num != "0" { out += "<#value#>" }
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
