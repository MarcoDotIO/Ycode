import Foundation

/// Finds the function enclosing a line by scanning the source text
/// (a cheap heuristic: Swift `func`/`init`/`subscript` and C-style
/// definitions; "method" when inside a type).
@MainActor
public enum SourceSymbolLocator {
    private static var cache: [String: (Date, [Substring])] = [:]

    public static func symbol(file: String, line: Int) -> (name: String, method: Bool)? {
        let date = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? .distantPast
        let lines: [Substring]
        if let c = cache[file], c.0 == date { lines = c.1 } else {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            cache[file] = (date, lines)
        }
        return symbol(in: lines, line: line)
    }

    public static func symbol(in lines: [Substring], line: Int) -> (name: String, method: Bool)? {
        guard line >= 1, line <= lines.count else { return nil }
        var i = line - 1
        while i >= 0 {
            let l = lines[i]
            if let name = swiftFunction(l) ?? cFunction(l) {
                let indent = l.prefix { $0 == " " || $0 == "\t" }.count
                var method = false
                if indent > 0 {
                    var j = i - 1
                    while j >= 0 {
                        let t = lines[j]
                        let ti = t.prefix { $0 == " " || $0 == "\t" }.count
                        if ti < indent, t.range(of: #"\b(class|struct|enum|extension|actor|protocol)\b"#, options: .regularExpression) != nil { method = true; break }
                        j -= 1
                    }
                }
                return (name, method)
            }
            i -= 1
        }
        return nil
    }

    /// `func name(a: T, _ b: U)` → "name(a:_:)".
    static func swiftFunction(_ l: Substring) -> String? {
        guard let r = l.range(of: #"\b(func\s+[^\s(<]+|init[?!]?|subscript)\s*(<[^>]*>)?\s*\("#, options: .regularExpression) else { return nil }
        var head = l[r].replacingOccurrences(of: "func", with: "").trimmingCharacters(in: .whitespaces)
        head = String(head.prefix { $0 != "(" && $0 != "<" }).trimmingCharacters(in: .whitespaces)
        let rest = l[r.upperBound...]
        var depth = 1
        var params = ""
        for c in rest { if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth == 0 { break } }; params.append(c) }
        let labels = params.split(separator: ",").compactMap { p -> String? in
            let t = p.trimmingCharacters(in: .whitespaces)
            guard let colon = t.firstIndex(of: ":") else { return nil }
            return (t[..<colon].split(separator: " ").first.map(String.init) ?? "_") + ":"
        }
        return head + "(" + labels.joined() + ")"
    }

    /// `int add(int a, int b) {` → "add".
    static func cFunction(_ l: Substring) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), !t.hasPrefix("//"), !l.hasPrefix(" "), !l.hasPrefix("\t"),
              let m = t.range(of: #"^[A-Za-z_][\w\s\*]*\s\**([A-Za-z_]\w*)\s*\([^;]*\)\s*\{?$"#, options: .regularExpression) else { return nil }
        let s = t[m]
        let name = s[..<s.firstIndex(of: "(")!].split(whereSeparator: { $0 == " " || $0 == "*" }).last
        guard let name, !["if", "while", "for", "switch", "return"].contains(String(name)) else { return nil }
        return String(name)
    }
}
