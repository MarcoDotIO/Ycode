import Foundation
import Testing
@testable import YcodeSyntax

/// Incremental re-highlighting equals a full pass, and touches only what
/// an edit affects.
@Suite struct IncrementalTests {
    static let samples: [(SyntaxLanguage, String)] = [
        (.swift, "/// d\nstruct A {\n    let s = \"x\\(1)\" // c\n    /* b\n    */ var m = \"\"\"\n  m\n  \"\"\"\n}\n"),
        (.c, "#define A \\\n  1\nint f() { /* x\n y */ return 'c'; }\n"),
        (.cpp, "auto s = R\"(a\nb)\";\n[[nodiscard]] int g();\n"),
        (.objc, "@interface A\n- (void)f { @\"s\"; }\n@end\n"),
        (.metal, "kernel void k(device float4 *o [[buffer(0)]]) {}\n"),
        (.json, "{ \"a\": [1, 2], /* c\n */ \"b\": null }\n"),
        (.xml, "<a x=\"1\n2\"><!-- c\n--><b/></a>\n"),
        (.markdown, "# H\n```\ncode\n```\n*e* `c`\n"),
        (.yaml, "a: |\n  x\n  y\nb: 'q\n  r'\n"),
        (.shell, "#!/bin/sh\necho 'a\nb' \"$x\"\ncat <<E\nz\nE\n"),
        (.xcconfig, "A = $(B) // c\n"),
    ]

    /// A small deterministic generator (tests must not depend on a seed source).
    struct LCG { var s: UInt64; mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(max(1, n))) } }

    @Test(arguments: [false, true]) func randomEditsMatchAFullPass(parser: Bool) {
        let inserts = ["\"", "/*", "*/", "\n", "x", "{", "}", "'", "`", "<!--", "-->", "\"\"\"", "#", " ", "<", ">", "$", ":"]
        var rng = LCG(s: 42)
        for (lang, text) in Self.samples where !parser || lang == .swift {
            let d = SyntaxDocument(text: text, language: lang, usesParser: parser)
            for _ in 0..<120 {
                let len = d.units.count
                let at = rng.next(len + 1)
                let del = rng.next(3) == 0 ? min(rng.next(4), len - at) : 0
                d.replace(NSRange(location: at, length: del), with: rng.next(4) == 0 ? "" : inserts[rng.next(inserts.count)])
                d.refine()
                let fresh = SyntaxDocument(text: d.text, language: lang, usesParser: parser)
                #expect(allTokens(d) == allTokens(fresh), "\(lang): \(d.text.debugDescription)")
                if allTokens(d) != allTokens(fresh) { print("MISMATCH", lang, d.text.debugDescription, snapshot(d), snapshot(fresh)); return }
            }
        }
    }

    @Test func typingInALineRelexesThatLine() {
        let text = SyntaxBenchmark.swiftSource(lines: 2_000)
        let d = SyntaxDocument(text: text, language: .swift)
        let at = (text as NSString).range(of: "var name = \"item 100\"").location
        let changed = d.replace(NSRange(location: at, length: 0), with: "x")
        #expect(d.lastUpdate.linesLexed == 1)
        #expect(changed == d.lineStart(d.line(containing: at))..<d.lineStart(d.line(containing: at) + 1))
        #expect(d.needsRefinement)
        _ = d.refine()
        #expect(!d.needsRefinement && d.lastUpdate.linesLexed <= 3)
    }

    @Test func openingABlockCommentRelexesToItsEnd() {
        let text = "a\nb\n/* old */\nc\nd\n"
        let d = SyntaxDocument(text: text, language: .c)
        d.replace(NSRange(location: 0, length: 0), with: "/*")
        // Lines 0…2 change (2 now ends the comment); 3 starts as before.
        #expect(d.lastUpdate.linesLexed == 3)
        #expect(d.isInsideCommentOrString(3))
        d.replace(NSRange(location: 0, length: 2), with: "")
        #expect(!d.isInsideCommentOrString(3))
    }

    @Test func nonASCIIOffsetsStayUTF16() {
        let text = "let é = \"ü😀\" // ñ\nlet b = 1\n"
        let d = SyntaxDocument(text: text, language: .swift)
        let ns = text as NSString
        #expect(snapshot(d).contains("string \"ü😀\"") && snapshot(d).contains("comment // ñ") && snapshot(d).contains("number 1"))
        d.replace(NSRange(location: ns.range(of: "1").location, length: 1), with: "2")
        d.refine()
        #expect(snapshot(d).contains("number 2"))
        #expect(allTokens(d) == allTokens(SyntaxDocument(text: d.text, language: .swift)))
    }

    @Test func deferredParseShowsLexicalTokensFirst() {
        let d = SyntaxDocument(text: "let x: Foo = .init()\n", language: .swift, deferParse: true)
        #expect(d.needsRefinement)
        #expect(snapshot(d).contains("typeName Foo"))
        #expect(d.refine() != nil && !d.needsRefinement)
    }
}
