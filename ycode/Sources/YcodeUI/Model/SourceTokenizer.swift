import Foundation

/// A lightweight lexer for syntax coloring of Swift, Objective-C and C.
/// It is not a parser: it finds comments, strings, numbers, keywords,
/// preprocessor lines, attributes and capitalized type names. See
/// `specs/ide/source-editor.md` §Syntax coloring.
public struct SourceTokenizer: Sendable {
    public enum Language: String, Sendable, CaseIterable {
        case swift, objc, c, plain

        /// The language for a file name, by extension.
        public init(fileName: String) {
            switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
            case "swift": self = .swift
            case "m", "mm", "h", "hpp", "hh": self = .objc
            case "c", "cc", "cpp", "cxx", "metal": self = .c
            default: self = .plain
            }
        }
    }

    public enum Kind: String, Sendable, Equatable {
        case keyword, comment, docComment, string, number, preprocessor, attribute, typeName, identifier
    }

    public struct Token: Equatable, Sendable {
        public var kind: Kind
        /// UTF-16 range, ready for NSAttributedString.
        public var range: NSRange
    }

    public let language: Language
    public init(language: Language) { self.language = language }

    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
        "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
        "where", "while", "as", "Any", "await", "false", "is", "nil", "self", "Self", "super", "throws", "true",
        "try", "async", "actor", "some", "any", "convenience", "dynamic", "final", "lazy", "mutating",
        "nonmutating", "optional", "override", "required", "weak", "unowned", "indirect", "consume", "borrowing",
        "consuming", "nonisolated", "isolated", "package", "macro", "get", "set", "willSet", "didSet",
    ]
    static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
        "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed",
        "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool",
        "true", "false", "NULL", "_Bool", "class", "namespace", "template", "typename", "public", "private",
        "protected", "virtual", "nullptr", "new", "delete", "this", "using", "constexpr", "noexcept", "operator",
    ]
    static let objcKeywords: Set<String> = cKeywords.union([
        "self", "super", "nil", "Nil", "YES", "NO", "id", "instancetype", "SEL", "BOOL", "IMP",
        "nonatomic", "atomic", "strong", "weak", "copy", "assign", "readonly", "readwrite", "nullable", "nonnull",
        "__block", "__weak", "__strong",
    ])

    var keywords: Set<String> {
        switch language {
        case .swift: Self.swiftKeywords
        case .objc: Self.objcKeywords
        case .c: Self.cKeywords
        case .plain: []
        }
    }

    public func tokens(in text: String) -> [Token] {
        guard language != .plain else { return [] }
        let u = Array(text.utf16)
        let keywords = self.keywords
        var out: [Token] = []
        var i = 0
        var atLineStart = true
        func emit(_ kind: Kind, _ start: Int) { out.append(Token(kind: kind, range: NSRange(location: start, length: i - start))) }
        func at(_ k: Int) -> UInt16 { k < u.count ? u[k] : 0 }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
        func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        let slash: UInt16 = 47, star: UInt16 = 42, quote: UInt16 = 34, newline: UInt16 = 10, backslash: UInt16 = 92

        while i < u.count {
            let c = u[i]
            let start = i
            if c == newline { atLineStart = true; i += 1; continue }
            if c == 32 || c == 9 || c == 13 { i += 1; continue }
            defer { atLineStart = false }

            if c == slash && at(i + 1) == slash {
                let doc = at(i + 2) == slash && at(i + 3) != slash
                while i < u.count && u[i] != newline { i += 1 }
                emit(doc ? .docComment : .comment, start)
            } else if c == slash && at(i + 1) == star {
                let doc = at(i + 2) == star && at(i + 3) != slash
                var depth = 0
                repeat {
                    if u[i] == slash && at(i + 1) == star { depth += language == .swift ? 1 : (depth == 0 ? 1 : 0); i += 2 }
                    else if u[i] == star && at(i + 1) == slash { depth -= 1; i += 2 }
                    else { i += 1 }
                } while i < u.count && depth > 0
                emit(doc ? .docComment : .comment, start)
            } else if c == 35 /* # */ && atLineStart && language != .swift {
                // Preprocessor directive, with backslash continuations.
                while i < u.count && !(u[i] == newline && at(i - 1) != backslash) { i += 1 }
                emit(.preprocessor, start)
            } else if c == quote || (c == 64 /* @ */ && at(i + 1) == quote && language == .objc) {
                if c == 64 { i += 1 }
                let multiline = language == .swift && at(i + 1) == quote && at(i + 2) == quote
                i += multiline ? 3 : 1
                while i < u.count {
                    if u[i] == backslash { i += 2; continue }
                    if multiline {
                        if u[i] == quote && at(i + 1) == quote && at(i + 2) == quote { i += 3; break }
                    } else {
                        if u[i] == quote { i += 1; break }
                        if u[i] == newline { break }
                    }
                    i += 1
                }
                emit(.string, start)
            } else if c == 39 /* ' */ && language != .swift {
                i += 1
                while i < u.count && u[i] != 39 && u[i] != newline { i += u[i] == backslash ? 2 : 1 }
                i = min(i + 1, u.count)
                emit(.string, start)
            } else if c >= 48 && c <= 57 {
                while i < u.count && (isIdentPart(u[i]) || u[i] == 46 && at(i + 1) >= 48 && at(i + 1) <= 57) { i += 1 }
                emit(.number, start)
            } else if (c == 64 || (c == 35 && language == .swift)) && isIdentStart(at(i + 1)) {
                // Swift `@attribute` / `#directive`, ObjC `@keyword`.
                i += 1
                while i < u.count && isIdentPart(u[i]) { i += 1 }
                emit(c == 64 && language == .swift ? .attribute : (c == 35 ? .preprocessor : .keyword), start)
            } else if isIdentStart(c) {
                while i < u.count && isIdentPart(u[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(u[start..<i]), count: i - start)
                if keywords.contains(word) { emit(.keyword, start) }
                else if c >= 65 && c <= 90 { emit(.typeName, start) }
            } else {
                i += 1
            }
        }
        return out
    }
}
