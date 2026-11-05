import SwiftIDEUtils
import SwiftParser
import SwiftSyntax

/// Swift highlighting through swift-syntax (Apache-2.0): `SwiftParser`
/// parses the file, incrementally after an edit (nodes outside the edit
/// and the parser's look-ahead are reused), and `SwiftIDEUtils`'
/// syntax classification names each token's role (keyword, type,
/// comment, …). Offsets here are UTF-8 bytes; `SyntaxDocument` converts.
final class SwiftClassifier {
    private var result: IncrementalParseResult?

    /// Parses `source` from scratch.
    func parse(_ source: [UInt8]) {
        result = source.withUnsafeBufferPointer { Parser.parseIncrementally(source: $0, parseTransition: nil) }
    }

    /// Re-parses after `edits` (sequential, in the previous source's UTF-8 offsets).
    func reparse(_ source: [UInt8], edits: [SourceEdit]) {
        guard let previous = result else { return parse(source) }
        let transition = IncrementalParseTransition(previousIncrementalParseResult: previous, edits: ConcurrentEdits(fromSequential: edits))
        result = source.withUnsafeBufferPointer { Parser.parseIncrementally(source: $0, parseTransition: transition) }
    }

    /// Classified ranges overlapping `bytes`, as (kind, UTF-8 start, UTF-8 end),
    /// in order. Ranges with no role are left out.
    func classify(_ bytes: Range<Int>, source: [UInt8], into out: inout [(SyntaxTokenKind, Int, Int)]) {
        guard let tree = result?.tree else { return }
        let range = AbsolutePosition(utf8Offset: bytes.lowerBound)..<AbsolutePosition(utf8Offset: bytes.upperBound)
        for c in tree.classifications(in: range) {
            let a = c.range.lowerBound.utf8Offset, b = c.range.upperBound.utf8Offset
            guard b > a, let kind = Self.kind(c.kind, firstByte: source[a]) else { continue }
            // A module name after `import` is plain text, not a type
            // (`editor-area.md` §D.1).
            if kind == .typeName, c.kind == .identifier,
               tree.token(at: AbsolutePosition(utf8Offset: a))?.parent?.is(ImportPathComponentSyntax.self) == true { continue }
            out.append((kind, a, b))
        }
    }

    /// The token kind for a classification; nil for no color.
    static func kind(_ c: SyntaxClassification, firstByte: UInt8) -> SyntaxTokenKind? {
        switch c {
        case .keyword: .keyword
        case .attribute: .attribute
        case .blockComment, .lineComment: .comment
        case .docBlockComment, .docLineComment: .docComment
        case .stringLiteral: .string
        case .regexLiteral: .regex
        case .integerLiteral, .floatLiteral: .number
        case .ifConfigDirective: .preprocessor
        case .type: .typeName
        case .editorPlaceholder: .placeholder
        // Capitalized identifiers read as type names (initializer calls,
        // static members), as the lexical lexer colors them.
        case .identifier: firstByte >= 65 && firstByte <= 90 ? .typeName : nil
        case .dollarIdentifier, .operator, .argumentLabel, .none: nil
        @unknown default: nil
        }
    }
}
