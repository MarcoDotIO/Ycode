import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell
import YcodeSyntax

/// Council round 4, group A in the Linux IDE (`editor-area.md` F.1–F.4,
/// F.6; `fidelity-council.md` rows 83–88): the default theme's palette,
/// declaration colours, and the shared text geometry.
@Suite struct EditorThemeR4Tests {
    @Test func defaultDarkPaletteIsTheMeasuredOne() {
        let p = SourcePalette.forAppearance(dark: true, theme: EditorTheme.builtIns[0])
        #expect(p.background.hex == "#262626" && p.foreground.hex == "#FAF1F3")
        #expect(p.currentLine.hex == "#353535" && p.lineNumber.hex == "#706D6E")
        let want: [SyntaxTokenKind.Role: String] = [
            .keyword: "#FF83B4", .comment: "#ABB3CD", .string: "#FF8E7B", .number: "#ECA900", .typeName: "#D997FF",
            .typeDeclaration: "#00CAFB", .otherDeclaration: "#27A7C1", .propertyReference: "#20AD9D",
        ]
        for (role, hex) in want { #expect(p.color(role).hex == hex, "\(role)") }
        // Light: row 10's values; no measured property colour (plain text).
        let l = SourcePalette.forAppearance(dark: false, theme: EditorTheme.builtIns[0])
        #expect(l.foreground.hex == "#322529" && l.color(.keyword).hex == "#C4246E" && l.color(.typeDeclaration).hex == "#007D9E")
        #expect(l.color(.propertyReference) == l.foreground)
    }

    @Test func themesOfTheirOwnKeepTheirLook() throws {
        let paper = try #require(EditorTheme.builtIns.first { $0.name == "Ycode Paper" })
        let p = SourcePalette.forAppearance(dark: true, theme: paper)
        #expect(p.color(.typeDeclaration) == p.color(.typeName))
        #expect(p.color(.otherDeclaration) == p.foreground && p.color(.propertyReference) == p.foreground)
    }

    @Test func declarationRunsReachTheLinuxEditor() {
        let src = "struct Greeting {\n    let name = \"x\"\n    func hi() -> String { \"\\(name)\" }\n}\n"
        let doc = SyntaxDocument(text: src, language: .swift)
        let units = doc.units
        func kind(of word: String, last: Bool = false) -> SyntaxTokenKind? {
            let ts = doc.tokens(in: 0..<units.count).filter { String(decoding: units[$0.location..<$0.end], as: UTF16.self) == word }
            return (last ? ts.last : ts.first)?.kind
        }
        #expect(kind(of: "Greeting") == .typeDeclaration)
        #expect(kind(of: "name") == .declaration)
        #expect(kind(of: "name", last: true) == .propertyReference)
        #expect(kind(of: "hi") == .declaration)
    }

    @Test func sharedGeometry() {
        #expect(EditorTextGeometry.blockInk(rowHeight: 18) == (3.5, 13.5))
        #expect(EditorTextGeometry.isSolidBlock(0x2588) && !EditorTextGeometry.isSolidBlock(0x2591))
        let full = EditorTextGeometry.blockShape(0x2588, x: 10, width: 8.04, top: 3.5, height: 13.5)
        #expect(full?.x == 10 && full?.y == 3.5 && full?.height == 13.5)
        let lower = EditorTextGeometry.blockShape(0x2584, x: 0, width: 8, top: 0, height: 16)
        #expect(lower?.y == 8 && lower?.height == 8)
        let band = Array("// " + String(repeating: "\u{2588}", count: 110))
        #expect(EditorTextGeometry.rowStarts(of: band, firstColumns: 80, continuationColumns: 76) == [3, 79])
    }
}
