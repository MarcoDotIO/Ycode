import Foundation
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
            guard b > a else { continue }
            // Names: declarations and references inside interpolations
            // (`editor-area.md` F.3) need the token's place in the tree.
            if c.kind == .identifier || c.kind == .type, let token = tree.token(at: AbsolutePosition(utf8Offset: a)) {
                if let d = Self.declarationKind(of: token) { out.append((d, a, b)); continue }
                // A module name after `import` is plain text, not a type
                // (`editor-area.md` §D.1).
                if c.kind == .identifier, token.parent?.is(ImportPathComponentSyntax.self) == true { continue }
            }
            guard let kind = Self.kind(c.kind, firstByte: source[a]) else { continue }
            out.append((kind, a, b))
        }
    }

    /// The names that declare a type, and the other declared names.
    nonisolated(unsafe) static let typeDeclarationNames: Set<AnyKeyPath> = [
        \StructDeclSyntax.name, \ClassDeclSyntax.name, \EnumDeclSyntax.name, \ProtocolDeclSyntax.name, \ActorDeclSyntax.name,
        \TypeAliasDeclSyntax.name, \AssociatedTypeDeclSyntax.name,
    ]
    nonisolated(unsafe) static let otherDeclarationNames: Set<AnyKeyPath> = [
        \FunctionDeclSyntax.name, \EnumCaseElementSyntax.name, \MacroDeclSyntax.name, \IdentifierPatternSyntax.identifier,
    ]

    /// What a name token is: a type declaration's name, another
    /// declaration's, a property named inside a string interpolation, or
    /// nil (a use, coloured as before).
    static func declarationKind(of token: TokenSyntax) -> SyntaxTokenKind? {
        guard let path = token.keyPathInParent else { return nil }
        if typeDeclarationNames.contains(path) { return .typeDeclaration }
        if otherDeclarationNames.contains(path) { return .declaration }
        if path == \DeclReferenceExprSyntax.baseName, isPropertyInInterpolation(token) { return .propertyReference }
        return nil
    }

    /// A lower-case name in `\( … )` that is not called, and that a
    /// stored or computed property of an enclosing type (or a file-level
    /// variable) declares, unless a parameter of the enclosing function
    /// has the same name.
    static func isPropertyInInterpolation(_ token: TokenSyntax) -> Bool {
        guard case .identifier(let name) = token.tokenKind, let first = name.unicodeScalars.first,
              !CharacterSet.uppercaseLetters.contains(first), let ref = token.parent else { return false }
        if let call = ref.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == ref.id { return false }
        // Inside an interpolation, not counting the closures and nested
        // declarations on the way.
        var node: Syntax? = ref.parent
        var inSegment = false
        while let n = node {
            if n.is(ExpressionSegmentSyntax.self) { inSegment = true; break }
            if n.is(CodeBlockSyntax.self) || n.is(MemberBlockSyntax.self) || n.is(SourceFileSyntax.self) { break }
            node = n.parent
        }
        guard inSegment else { return false }
        var scope: Syntax? = node
        while let n = scope {
            if let f = n.as(FunctionDeclSyntax.self),
               f.signature.parameterClause.parameters.contains(where: { ($0.secondName ?? $0.firstName).text == name }) { return false }
            if let members = n.asProtocol((any DeclGroupSyntax).self)?.memberBlock.members {
                if members.contains(where: { declares(name, $0.decl) }) { return true }
            }
            if let file = n.as(SourceFileSyntax.self) {
                return file.statements.contains { $0.item.as(DeclSyntax.self).map { declares(name, $0) } ?? false }
            }
            scope = n.parent
        }
        return false
    }

    /// Whether a variable declaration declares `name`.
    static func declares(_ name: String, _ decl: DeclSyntax) -> Bool {
        guard let v = decl.as(VariableDeclSyntax.self) else { return false }
        return v.bindings.contains { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name }
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
