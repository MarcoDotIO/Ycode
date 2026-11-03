import Foundation
@testable import YcodeSyntax

/// "kind text" for each token of `text` (line pieces of multi-line tokens).
func snapshot(_ text: String, _ language: SyntaxLanguage, parser: Bool = true) -> [String] {
    let d = SyntaxDocument(text: text, language: language, usesParser: parser)
    return snapshot(d)
}

func snapshot(_ d: SyntaxDocument) -> [String] {
    let ns = d.text as NSString
    return (0..<d.lineCount).flatMap { d.tokens(onLine: $0) }.map { "\($0.kind) \(ns.substring(with: $0.range))" }
}

/// All tokens of a document, line by line.
func allTokens(_ d: SyntaxDocument) -> [[SyntaxToken]] { (0..<d.lineCount).map { d.tokens(onLine: $0) } }

/// The text with `|` marking the selection start (and a second `|` its end) removed, and the selection.
func marked(_ s: String) -> (String, NSRange) {
    let parts = s.components(separatedBy: "|")
    let a = (parts[0] as NSString).length
    if parts.count == 3 { return (parts.joined(), NSRange(location: a, length: (parts[1] as NSString).length)) }
    return (parts.joined(), NSRange(location: a, length: 0))
}

/// Applies an edit and renders the result with `|` at the insertion point.
func render(_ text: String, _ e: TypingEdit?) -> String? {
    guard let e else { return nil }
    let new = e.applied(to: text) as NSString
    if e.selection.length == 0 { return new.replacingCharacters(in: NSRange(location: e.selection.location, length: 0), with: "|") }
    let withEnd = new.replacingCharacters(in: NSRange(location: NSMaxRange(e.selection), length: 0), with: "|") as NSString
    return withEnd.replacingCharacters(in: NSRange(location: e.selection.location, length: 0), with: "|")
}
