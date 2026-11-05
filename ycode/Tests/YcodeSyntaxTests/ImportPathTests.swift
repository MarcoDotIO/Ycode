import Foundation
import Testing
@testable import YcodeSyntax

/// Checklist row 48 (`editor-area.md` §D.1): a module name after `import`
/// is plain text, not a type, through the parser and lexically.
@Suite struct ImportPathTests {
    static let source = """
    import Foundation
    @testable import YcodeSyntax
    import struct Foundation.Date
    import os.log
    let d = Foundation.Date()
    """

    @Test(arguments: [true, false]) func moduleNamesArePlain(parser: Bool) {
        let t = snapshot(Self.source, .swift, parser: parser)
        #expect(!t.contains("typeName Foundation") || t.filter { $0 == "typeName Foundation" }.count == 1, "\(t)")
        #expect(!t.contains("typeName YcodeSyntax"), "\(t)")
        #expect(t.contains("keyword import"))
        // Outside an import a capitalized name is still a type.
        #expect(t.contains("typeName Date"), "\(t)")
        let lines = (0..<SyntaxDocument(text: Self.source, language: .swift, usesParser: parser).lineCount)
        let d = SyntaxDocument(text: Self.source, language: .swift, usesParser: parser)
        let ns = Self.source as NSString
        // Lines 0–3 (the imports) hold no type names at all.
        for line in lines.prefix(4) {
            let kinds = d.tokens(onLine: line).map { "\($0.kind) \(ns.substring(with: $0.range))" }
            #expect(!kinds.contains { $0.hasPrefix("typeName") }, "line \(line): \(kinds)")
        }
        // Line 4: `Foundation.Date()` in an expression keeps its type colour.
        let last = d.tokens(onLine: 4).map { "\($0.kind) \(ns.substring(with: $0.range))" }
        #expect(last.contains("typeName Foundation") && last.contains("typeName Date"), "\(last)")
    }

    @Test func lexerImportPathRule() {
        let t = snapshot("return Foo\ncase let Bar\nimport  A . B\n", .swift, parser: false)
        #expect(t.contains("typeName Foo") && t.contains("typeName Bar"), "\(t)")
        #expect(!t.contains("typeName A") && !t.contains("typeName B"), "\(t)")
    }
}
