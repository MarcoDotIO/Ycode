import Foundation
import Testing
import YcodeBuild
import YcodeProject
@testable import YcodeIDECore

/// R33 (`specs/ide/reference-ui-5.md` §9): the Settings panes, their rows
/// and defaults, and that each setting takes effect; plus destination
/// selection by identifier (Ycode's remote simulator).
@MainActor
@Suite(.serialized) struct SettingsR33Tests {
    @Test func displayModel() {
        let text = """
        struct A {
            // MARK: - Helpers
            func f() {}
        #if false
            let x = 1
        #else
            let y = 2
        #endif
        #if DEBUG
            let z = 3
        #elseif os(iOS)
            let w = 4
        #endif
        }
        """
        #expect(EditorDisplayModel.markSeparatorLines(in: text) == [2])
        #expect(EditorDisplayModel.endifConditions(in: text) == [8: "false", 13: "DEBUG"])
        #expect(EditorDisplayModel.inactiveLines(in: text) == [5...5])
        #expect(EditorDisplayModel.inactiveLines(in: text, defined: ["DEBUG"]) == [5...5, 12...12])
        #expect(EditorDisplayModel.inactiveLines(in: "#if 0\nint a;\n#elif 1\nint b;\n#else\nint c;\n#endif\n") == [2...2, 6...6])
        #expect(EditorDisplayModel.evaluate("!false && (true || os(iOS))", defined: nil) == true)
        #expect(EditorDisplayModel.evaluate("false && os(iOS)", defined: nil) == false)
        #expect(EditorDisplayModel.evaluate("DEBUG || canImport(UIKit)", defined: nil) == nil)
        #expect(EditorDisplayModel.evaluate("defined(FOO)", defined: ["FOO"]) == true)
        let src = "/// Doc\n// plain\n/* block */\n/** doc block */\nlet a = 1\n"
        let tokens = SourceTokenizer(language: .swift).tokens(in: src)
        let d = EditorDisplayModel.commentDelimiters(tokens, in: src as NSString)
        let ns = src as NSString
        #expect(d.doc.map(ns.substring(with:)) == ["///", "/**", "*/"])
        #expect(d.plain.map(ns.substring(with:)) == ["//", "/*", "*/"])
        let lines = text.components(separatedBy: "\n")
        let regions = [FoldRegion(startLine: 1, endLine: 14, depth: 0), FoldRegion(startLine: 3, endLine: 13, depth: 1)]
        #expect(EditorDisplayModel.structureHeaderLines(regions, topLine: 6) { lines[$0 - 1] } == [1, 3])
        #expect(EditorDisplayModel.structureHeaderLines(regions, topLine: 1) { lines[$0 - 1] }.isEmpty)
    }
}
