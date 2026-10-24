import Foundation
import YcodeBuild
import YcodeProject

/// One preview declared in a Swift file. See `specs/ide/previews.md`.
public struct PreviewDeclaration: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `#Preview { … }`: the closure body.
        case macro(body: String)
        /// A `PreviewProvider` type: its `previews` property is used.
        case provider(type: String)
    }

    public var name: String
    public var kind: Kind
    /// `.fixedLayout(width:height:)`; nil = the view's fitting size.
    public var fixedSize: CGSize?
    /// 1-based line of the declaration.
    public var line: Int
    /// UTF-16 range of the whole `#Preview …` (for blanking it out).
    public var range: NSRange?
    /// Whether the name was written (`#Preview("name")` or a provider).
    public var isNamed: Bool = true

    /// The canvas tab title (reference-ui-4.md §10): the written name,
    /// else the view type the body starts with, else `name`.
    public var tabTitle: String {
        guard !isNamed, case .macro(let body) = kind else { return name }
        return PreviewDiscovery.leadingViewType(body) ?? name
    }
}

public enum PreviewDiscovery {
    /// Finds `#Preview` macros and `PreviewProvider` types. Unnamed macros
    /// are called `Preview`, `Preview 2`, … in file order.
    public static func previews(in text: String) -> [PreviewDeclaration] {
        let s = Array(text.utf16)
        var out: [PreviewDeclaration] = []
        var i = 0
        var unnamed = 0
        func line(_ at: Int) -> Int { s[..<at].filter { $0 == 10 }.count + 1 }
        func skipSpace(_ j: inout Int) { while j < s.count, [32, 9, 10, 13].contains(s[j]) { j += 1 } }
        while i < s.count {
            // Skip comments and string literals.
            if s[i] == 47, i + 1 < s.count, s[i + 1] == 47 { while i < s.count, s[i] != 10 { i += 1 }; continue }
            if s[i] == 47, i + 1 < s.count, s[i + 1] == 42 { i = closeComment(s, i); continue }
            if s[i] == 34 { i = closeString(s, i); continue }
            if matches(s, i, "#Preview"), !isIdent(s, i + 8) {
                let start = i
                var j = i + 8
                skipSpace(&j)
                var name: String?
                var size: CGSize?
                if j < s.count, s[j] == 40 /* ( */ {
                    let close = matching(s, j, open: 40, close: 41)
                    let args = String(utf16CodeUnits: Array(s[(j + 1)..<max(j + 1, close - 1)]), count: max(0, close - 1 - (j + 1)))
                    name = firstStringLiteral(args)
                    size = fixedLayout(args)
                    j = close
                    skipSpace(&j)
                }
                guard j < s.count, s[j] == 123 /* { */ else { i = j; continue }
                let end = matching(s, j, open: 123, close: 125)
                let body = String(utf16CodeUnits: Array(s[(j + 1)..<(end - 1)]), count: end - 1 - (j + 1))
                let named = name != nil
                if name == nil { unnamed += 1; name = unnamed == 1 ? "Preview" : "Preview \(unnamed)" }
                out.append(PreviewDeclaration(name: name!, kind: .macro(body: body), fixedSize: size, line: line(start),
                                              range: NSRange(location: start, length: end - start), isNamed: named))
                i = end
                continue
            }
            i += 1
        }
        // PreviewProvider conformances: `struct X: PreviewProvider`.
        // Searched in a copy with comments and string literals blanked,
        // so a conformance inside either is not a preview.
        let code = codeOnly(text)
        let ns = code as NSString
        if let re = try? NSRegularExpression(pattern: "(?m)^\\s*(?:public\\s+|internal\\s+)?struct\\s+(\\w+)\\s*:[^{]*\\bPreviewProvider\\b") {
            for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let type = ns.substring(with: m.range(at: 1))
                out.append(PreviewDeclaration(name: type, kind: .provider(type: type), fixedSize: nil,
                                              line: ns.substring(to: m.range.location).filter { $0 == "\n" }.count + 1, range: nil))
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    /// The first capitalized identifier of a body that is followed by `(`
    /// or `{` (`Badge(text: "Hi")` → `Badge`), skipping `@Previewable`
    /// lines and `let`/`var` declarations.
    public static func leadingViewType(_ body: String) -> String? {
        let code = codeOnly(body)
        for raw in code.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("@") || line.hasPrefix("let ") || line.hasPrefix("var ") { continue }
            let l = line.hasPrefix("return ") ? String(line.dropFirst(7)) : line
            guard let re = try? NSRegularExpression(pattern: "^([A-Z][A-Za-z0-9_]*)\\s*[({]"),
                  let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) else { return nil }
            return (l as NSString).substring(with: m.range(at: 1))
        }
        return nil
    }

    /// The text with comments and string literals replaced by spaces
    /// (newlines kept), so offsets and line numbers are unchanged.
    static func codeOnly(_ text: String) -> String {
        var s = Array(text.utf16)
        var i = 0
        func blank(_ a: Int, _ b: Int) { for k in a..<min(b, s.count) where s[k] != 10 { s[k] = 32 } }
        while i < s.count {
            if s[i] == 47, i + 1 < s.count, s[i + 1] == 47 {
                var j = i; while j < s.count, s[j] != 10 { j += 1 }; blank(i, j); i = j; continue
            }
            if s[i] == 47, i + 1 < s.count, s[i + 1] == 42 { let j = closeComment(s, i); blank(i, j); i = j; continue }
            if s[i] == 34 { let j = closeString(s, i); blank(i, j); i = j; continue }
            i += 1
        }
        return String(utf16CodeUnits: s, count: s.count)
    }

    static func matches(_ s: [UInt16], _ i: Int, _ word: String) -> Bool {
        let w = Array(word.utf16)
        return i + w.count <= s.count && Array(s[i..<i + w.count]) == w
    }

    static func isIdent(_ s: [UInt16], _ i: Int) -> Bool {
        guard i < s.count, let u = Unicode.Scalar(s[i]) else { return false }
        return CharacterSet.alphanumerics.contains(u) || s[i] == 95
    }

    static func closeComment(_ s: [UInt16], _ i: Int) -> Int {
        var j = i + 2, depth = 1
        while j + 1 < s.count, depth > 0 {
            if s[j] == 47, s[j + 1] == 42 { depth += 1; j += 2 } else if s[j] == 42, s[j + 1] == 47 { depth -= 1; j += 2 } else { j += 1 }
        }
        return j
    }

    /// The index after a string literal starting at `i` (`"…"` or `"""…"""`).
    static func closeString(_ s: [UInt16], _ i: Int) -> Int {
        if matches(s, i, "\"\"\"") {
            var j = i + 3
            while j < s.count, !matches(s, j, "\"\"\"") { j += s[j] == 92 ? 2 : 1 }
            return min(s.count, j + 3)
        }
        var j = i + 1
        while j < s.count, s[j] != 34, s[j] != 10 { j += s[j] == 92 ? 2 : 1 }
        return min(s.count, j + 1)
    }

    /// The index after the bracket matching the one at `i`.
    static func matching(_ s: [UInt16], _ i: Int, open: UInt16, close: UInt16) -> Int {
        var j = i + 1, depth = 1
        while j < s.count {
            if s[j] == 47, j + 1 < s.count, s[j + 1] == 47 { while j < s.count, s[j] != 10 { j += 1 }; continue }
            if s[j] == 47, j + 1 < s.count, s[j + 1] == 42 { j = closeComment(s, j); continue }
            if s[j] == 34 { j = closeString(s, j); continue }
            if s[j] == open { depth += 1 } else if s[j] == close { depth -= 1; if depth == 0 { return j + 1 } }
            j += 1
        }
        return s.count
    }

    static func firstStringLiteral(_ args: String) -> String? {
        guard let a = args.firstIndex(of: "\"") else { return nil }
        // Only when the literal is the first argument (the name).
        guard args[..<a].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var out = ""
        var it = args[args.index(after: a)...].makeIterator()
        while let c = it.next() {
            if c == "\"" { return out }
            if c == "\\", let n = it.next() {
                switch n { case "n": out.append("\n"); case "t": out.append("\t"); default: out.append(n) }
                continue
            }
            out.append(c)
        }
        return nil
    }

    static func fixedLayout(_ args: String) -> CGSize? {
        guard let re = try? NSRegularExpression(pattern: "\\.fixedLayout\\s*\\(\\s*width:\\s*([0-9.]+)\\s*,\\s*height:\\s*([0-9.]+)"),
              let m = re.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)),
              let w = Double((args as NSString).substring(with: m.range(at: 1))),
              let h = Double((args as NSString).substring(with: m.range(at: 2))) else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The text with every `#Preview` block replaced by spaces (newlines
    /// kept), so copied sources compile without the preview macros.
    public static func blankingPreviews(_ text: String) -> String {
        var units = Array(text.utf16)
        for p in previews(in: text) {
            guard let r = p.range else { continue }
            for k in r.location..<(r.location + r.length) where units[k] != 10 { units[k] = 32 }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

