import Foundation

/// A parsed build-setting value: literal text mixed with macro references.
/// See `specs/build-settings.md` §2.
public struct MacroExpression: Equatable, Sendable {
    public indirect enum Segment: Equatable, Sendable {
        case literal(String)
        /// `$(NAME:op1:op2=arg)`. The name may itself contain references.
        case reference(name: MacroExpression, operators: [Operator])
    }

    public struct Operator: Equatable, Sendable {
        public var name: String
        public var argument: MacroExpression?
    }

    public var segments: [Segment]

    public init(segments: [Segment]) { self.segments = segments }

    public init(_ text: String) {
        var p = Parser(Array(text.unicodeScalars))
        segments = p.parseSequence(terminators: [])
    }

    /// True if the expression contains no references.
    public var isLiteral: Bool { segments.allSatisfy { if case .literal = $0 { true } else { false } } }

    /// Names referenced directly (not through nested names).
    public var referencedNames: [String] {
        segments.compactMap {
            if case .reference(let name, _) = $0, name.isLiteral { return name.literalText }
            return nil
        }
    }

    var literalText: String {
        segments.map { if case .literal(let s) = $0 { s } else { "" } }.joined()
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        /// Parses until one of `terminators` (unconsumed) or the end.
        mutating func parseSequence(terminators: Set<Unicode.Scalar>) -> [Segment] {
            var out: [Segment] = []
            var lit = ""
            func flush() {
                if !lit.isEmpty { out.append(.literal(lit)); lit = "" }
            }
            while i < s.count {
                let c = s[i]
                if terminators.contains(c) { break }
                if c == "$", i + 1 < s.count {
                    let n = s[i + 1]
                    if n == "$" {
                        lit += "$"
                        i += 2
                        continue
                    }
                    if n == "(" || n == "{" {
                        let save = i
                        i += 2
                        if let ref = parseReference(close: n == "(" ? ")" : "}") {
                            flush()
                            out.append(ref)
                            continue
                        }
                        i = save  // unterminated: keep as literal text
                        lit.unicodeScalars.append(c)
                        i += 1
                        continue
                    }
                    if Self.isIdentStart(n) {
                        var j = i + 1
                        var name = ""
                        while j < s.count, Self.isIdentChar(s[j]) { name.unicodeScalars.append(s[j]); j += 1 }
                        flush()
                        out.append(.reference(name: MacroExpression(segments: [.literal(name)]), operators: []))
                        i = j
                        continue
                    }
                }
                lit.unicodeScalars.append(c)
                i += 1
            }
            flush()
            return out
        }

        /// After `$(` or `${`: parses `name(:op(=arg)?)*` and the closing bracket.
        mutating func parseReference(close: Unicode.Scalar) -> Segment? {
            let name = MacroExpression(segments: parseSequence(terminators: [":", close]))
            var ops: [Operator] = []
            while i < s.count, s[i] == ":" {
                i += 1
                var opName = ""
                while i < s.count, s[i] != "=", s[i] != ":", s[i] != close { opName.unicodeScalars.append(s[i]); i += 1 }
                var arg: MacroExpression?
                if i < s.count, s[i] == "=" {
                    i += 1
                    arg = MacroExpression(segments: parseSequence(terminators: [":", close]))
                }
                ops.append(Operator(name: opName, argument: arg))
            }
            guard i < s.count, s[i] == close else { return nil }
            i += 1
            return .reference(name: name, operators: ops)
        }

        static func isIdentStart(_ c: Unicode.Scalar) -> Bool {
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "_"
        }
        static func isIdentChar(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || (c >= "0" && c <= "9") }
    }
}

// MARK: - Operators

/// The `$(X:op)` retrieval operators, as observed from `xcodebuild`.
public enum MacroOperators {
    public static func apply(_ name: String, argument: String?, to value: String) -> String {
        switch name {
        case "quote": return quote(value)
        case "lower": return value.lowercased()
        case "upper": return value.uppercased()
        case "identifier": return identifier(value, replacement: "_", allowUnicodeLetters: false, allowHyphen: false)
        case "c99extidentifier": return identifier(value, replacement: "_", allowUnicodeLetters: true, allowHyphen: false)
        case "rfc1034identifier": return identifier(value, replacement: "-", allowUnicodeLetters: false, allowHyphen: true)
        case "dir": return dir(value)
        case "file": return file(value)
        case "base":
            let f = file(value)
            return f.lastIndex(of: ".").map { String(f[..<$0]) } ?? f
        case "suffix":
            let f = file(value)
            return f.lastIndex(of: ".").map { String(f[$0...]) } ?? ""
        case "standardizepath": return standardize(value)
        case "absolutepath": return value  // relative inputs observed unchanged
        case "default": return value.isEmpty ? (argument ?? "") : value
        case "not": return isTrue(value) ? "NO" : "YES"
        case "relativeto": return relative(from: value, to: argument ?? "")
        default: return value  // unknown operators leave the value alone
        }
    }

    public static func isTrue(_ v: String) -> Bool {
        ["yes", "true", "1"].contains(v.lowercased())
    }

    /// Backslash-escapes whitespace, quotes, and backslashes only.
    static func quote(_ v: String) -> String {
        var out = ""
        for ch in v.unicodeScalars {
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "'" || ch == "\"" || ch == "\\" {
                out += "\\"
            }
            out.unicodeScalars.append(ch)
        }
        return out
    }

    /// Replaces disallowed characters (and a leading digit) with `replacement`.
    static func identifier(_ v: String, replacement: Character, allowUnicodeLetters: Bool, allowHyphen: Bool) -> String {
        var out = ""
        for (i, ch) in v.enumerated() {
            let asciiAlnum = ch.isASCII && (ch.isLetter || ch.isNumber)
            let isDigit = ch.isASCII && ch.isNumber
            var ok = asciiAlnum || (!allowHyphen && ch == "_") || (allowHyphen && ch == "-")
                || (allowUnicodeLetters && !ch.isASCII && ch.isLetter)
            if i == 0, isDigit { ok = false }
            out.append(ok ? ch : replacement)
        }
        return out
    }

    static func dir(_ v: String) -> String {
        guard let slash = v.lastIndex(of: "/") else { return "./" }
        return String(v[...slash])
    }

    static func file(_ v: String) -> String {
        guard let slash = v.lastIndex(of: "/") else { return v }
        return String(v[v.index(after: slash)...])
    }

    /// Resolves `.`/`..` and drops trailing slashes in absolute paths;
    /// relative paths are returned unchanged.
    static func standardize(_ v: String) -> String {
        guard v.hasPrefix("/") else { return v }
        var parts: [Substring] = []
        for comp in v.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(comp)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `$(X:relativeto=Y)` yields the path of Y relative to X when both are
    /// absolute; otherwise X unchanged.
    static func relative(from base: String, to target: String) -> String {
        guard base.hasPrefix("/"), target.hasPrefix("/") else { return base }
        let a = standardize(base).split(separator: "/")
        let b = standardize(target).split(separator: "/")
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        let ups = Array(repeating: "..", count: a.count - common)
        let rest = b[common...].map(String.init)
        let parts = ups + rest
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
