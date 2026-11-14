import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeSyntax
@testable import YcodeUI

/// Council round 4, group A: the editor's text and theme (rows 83–88;
/// `specs/ide/editor-area.md` F.1–F.4, F.6).
@MainActor
@Suite(.serialized) struct CouncilRound4EditorTests {
    let fc = FidelityCouncilTests()
    static let band = "// " + String(repeating: "\u{2588}", count: 110)

    /// An editor on `text` at the 2x backing scale, in `appearance`.
    func editor(_ text: String, name: String = "Bands.swift", dark: Bool = false) throws -> (WorkspaceWindowController, SourceEditorController) {
        Theme.backingScaleOverride = 2
        let (wc, e) = try CouncilRound2Glass3Tests().editor(text, name: name)
        wc.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        e.applyPreferences()
        e.view.layoutSubtreeIfNeeded()
        return (wc, e)
    }

    /// The visual rows of the paragraph starting at `offset`: each row's
    /// character range.
    func rows(_ e: SourceEditorController, paragraphAt offset: Int) throws -> [NSRange] {
        let tlm = try #require(e.textView.textLayoutManager)
        tlm.ensureLayout(for: tlm.documentRange)
        var out: [NSRange] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            if tlm.offset(from: tlm.documentRange.location, to: f.rangeInElement.location) == offset {
                out = f.textLineFragments.map(\.characterRange)
                return false
            }
            return true
        }
        return out
    }

    // MARK: Row 83: a run with no break opportunity moves to the next row

    @Test func wrapRuleModel() {
        let band = Array(Self.band)
        // "//" alone, then 76 blocks on the second row, 34 on the third.
        #expect(EditorTextGeometry.rowStarts(of: band, firstColumns: 80, continuationColumns: 76) == [3, 79])
        // A word that fits an empty row is not broken; one that does not is.
        #expect(EditorTextGeometry.rowStarts(of: Array("ab cdefg"), firstColumns: 5, continuationColumns: 5) == [3])
        #expect(EditorTextGeometry.rowStarts(of: Array("abcdefgh"), firstColumns: 5, continuationColumns: 5) == [5])
        // Row 88: the space after a word must fit; at the line's end it hangs.
        #expect(EditorTextGeometry.rowStarts(of: Array("0: a comment more"), firstColumns: 12, continuationColumns: 12) == [5])
        #expect(EditorTextGeometry.rowStarts(of: Array("import Foundation"), firstColumns: 17, continuationColumns: 13).isEmpty)
        #expect(EditorTextGeometry.rowStarts(of: Array("abcd   "), firstColumns: 4, continuationColumns: 4).isEmpty)
    }

    @Test func bandsWrapToThreeRowsPerLine() throws {
        defer { Theme.backingScaleOverride = nil }
        let text = "import Foundation\n\n" + Self.band + "\n" + Self.band + "\nlet x = 1\n"
        let (wc, e) = try editor(text)
        defer { wc.window?.close() }
        let columns = Int((e.textView.textContainer?.size.width ?? 0) / Theme.advance)
        #expect(columns == 80, "\(columns) columns")
        for start in [19, 19 + 114] {
            let r = try rows(e, paragraphAt: start)
            // The last row's range holds the line's end too.
            #expect(r.map(\.length) == [3, 76, 34 + 1], "\(r)")
        }
        // Words that fit still wrap whole, and a line that fits is one row.
        #expect(try rows(e, paragraphAt: 0).count == 1)
    }

    /// Row 88 through the editor's break rule, on TextKit's own
    /// opportunities.
    @Test func spaceAfterAWordMustFit() {
        let rule = EditorLineBreaks()
        let text = NSAttributedString(string: "0: a comment more\n")
        // 12 cells: "0: a comment" fits but not its space.
        #expect(!rule.allowsBreak(before: 13, in: text, width: 12 * 8.04, advance: 8.04, indents: false, tabWidth: 4))
        #expect(rule.allowsBreak(before: 5, in: text, width: 12 * 8.04, advance: 8.04, indents: false, tabWidth: 4))
        // With room for the space the row keeps "comment".
        #expect(rule.allowsBreak(before: 13, in: text, width: 13 * 8.04, advance: 8.04, indents: false, tabWidth: 4))
        // A hyphen is an opportunity of the text system's (UAX #14).
        let hyphen = NSAttributedString(string: "aa foo-bar\n")
        #expect(rule.allowsBreak(before: 7, in: hyphen, width: 8 * 8.04, advance: 8.04, indents: false, tabWidth: 4))
        // Tabs and wide characters keep the text system's breaks.
        #expect(rule.allowsBreak(before: 3, in: NSAttributedString(string: "a\tb cd\n"), width: 16, advance: 8, indents: false, tabWidth: 4))
    }

    // MARK: Row 84: the cell advance at 2x

    @Test func cellAdvanceFollowsTheBackingScale() throws {
        defer { Theme.backingScaleOverride = nil }
        #expect(EditorTextGeometry.cellAdvance(fontAdvance: 8.0361328125, backingScale: 2) == 8.0361328125)
        #expect(EditorTextGeometry.cellAdvance(fontAdvance: 8.0361328125, backingScale: 1) == 8)
        #expect(EditorTextGeometry.cellAdvance(fontAdvance: 7.8, backingScale: 1) == 8)
        try fc.withPreferences { _ in
            Theme.backingScaleOverride = 2
            #expect(abs(Theme.advance - 8.036) < 0.01, "\(Theme.advance)")
            #expect(abs(Theme.advance(of: Theme.boldFont) - Theme.advance) < 0.001)
            Theme.backingScaleOverride = 1
            #expect(abs(Theme.advance - 8) < 0.001, "\(Theme.advance)")
        }
        // In the editor: 60 characters from column 5 span 59 advances of 8.04.
        let (wc, e) = try editor("let s = 1\n")
        defer { wc.window?.close() }
        let tlm = try #require(e.textView.textLayoutManager)
        let frag = try #require(tlm.textLayoutFragment(for: tlm.documentRange.location))
        let line = try #require(frag.textLineFragments.first)
        let x9 = line.locationForCharacter(at: 9).x - line.locationForCharacter(at: 0).x
        #expect(abs(x9 - 9 * 8.0361) < 0.05, "\(x9)")
        #expect(abs((e.wrapSnapshot.advance) - 8.0361) < 0.001)
    }

    // MARK: Rows 85, 86: the default dark theme

    @Test func defaultDarkThemeUsesTheMeasuredColours() throws {
        try fc.withPreferences { _ in
            func dark(_ c: NSColor) -> String { hexIn(c, dark: true) }
            #expect(dark(Theme.backgroundColor) == "#262626")
            #expect(dark(Theme.textColor) == "#FAF1F3")
            #expect(dark(Theme.color(for: .keyword)) == "#FF83B4")
            #expect(dark(Theme.color(for: .comment)) == "#ABB3CD")
            #expect(dark(Theme.color(for: .string)) == "#FF8E7B")
            #expect(dark(Theme.color(for: .number)) == "#ECA900")
            #expect(dark(Theme.color(for: .typeName)) == "#D997FF")
            #expect(dark(Theme.color(for: .typeDeclaration)) == "#00CAFB")
            #expect(dark(Theme.color(for: .otherDeclaration)) == "#27A7C1")
            #expect(dark(Theme.color(for: .propertyReference)) == "#20AD9D")
            #expect(dark(Theme.lineNumberColor) == "#706D6E")
            // Bands: #353535 focused, #2A2A2A in a split's other pane.
            #expect(dark(Theme.currentLineBandColor(focused: true)) == "#353535")
            #expect(dark(Theme.currentLineBandColor(focused: false)) == "#2A2A2A")
            // Light stays as row 10 set it; light has no measured property colour.
            #expect(fc.hex(Theme.color(for: .typeDeclaration)) == "#007D9E")
            #expect(fc.hex(Theme.color(for: .otherDeclaration)) == "#006178")
            #expect(fc.hex(Theme.color(for: .propertyReference)) == "#322529")
            #expect(fc.hex(Theme.backgroundColor) == fc.hex(.textBackgroundColor))
            // Roles neither appearance measured: one table with the Linux IDE
            // since round 7 (B7-B, `WorkspaceChrome.defaultThemeColors`).
            #expect(dark(Theme.color(for: .preprocessor)) == "#FF9F0A")
            // A theme of its own: declarations as type names and plain text.
            let dusk = try #require(EditorTheme.builtIns.first { $0.name == "Ycode Dusk" })
            Preferences.shared.themeName = dusk.name
            #expect(fc.hex(Theme.color(for: .typeDeclaration)) == dusk.tokens["typeName"])
            #expect(fc.hex(Theme.color(for: .otherDeclaration)) == dusk.foreground)
            #expect(fc.hex(Theme.currentLineBandColor(focused: false)) == fc.hex(Theme.currentLineBandColor(focused: true)))
        }
    }

    @Test func splitPaneWithoutFocusHasTheFaintBand() throws {
        let (wc, e) = try editor("let x = 1\n", dark: true)
        defer { wc.window?.close() }
        #expect(e.isFocusedPane && e.gutter.bandFocused)
        e.isFocusedPane = false
        #expect(!e.gutter.bandFocused)
    }

    /// Declarations and uses, in the editor's storage and through the
    /// merge sheet's runs (the same roles, so the same colours).
    @Test func declarationsAreTold() throws {
        let src = """
        struct Greeting {
            let name: String
            func describe(count: Int) -> String { "Hi \\(name) \\(count)" }
        }
        enum Kind { case plain }
        let farewell = "Bye"
        """
        func kinds(_ doc: SyntaxDocument) -> [String: SyntaxTokenKind] {
            let units = doc.units
            var out: [String: SyntaxTokenKind] = [:]
            for t in doc.tokens(in: 0..<units.count) {
                let s = String(decoding: units[t.location..<t.end], as: UTF16.self)
                if out[s] == nil || t.kind == .propertyReference { out[s] = t.kind }
            }
            return out
        }
        let parsed = kinds(SyntaxDocument(text: src, language: .swift))
        #expect(parsed["Greeting"] == .typeDeclaration)
        #expect(parsed["Kind"] == .typeDeclaration)
        #expect(parsed["name"] == .propertyReference)
        #expect(parsed["describe"] == .declaration)
        #expect(parsed["plain"] == .declaration)
        #expect(parsed["farewell"] == .declaration)
        #expect(parsed["String"] == .typeName && parsed["Int"] == .typeName)
        // A parameter in an interpolation is not a property.
        #expect(parsed["count"] == nil)
        // The lexical pass (before the parse) knows the declarations too.
        let lexical = kinds(SyntaxDocument(text: src, language: .swift, usesParser: false))
        #expect(lexical["Greeting"] == .typeDeclaration && lexical["describe"] == .declaration && lexical["farewell"] == .declaration)
        // The merge sheet's runs.
        let runs = MergeSheetLayout.highlight(["struct Greeting {", "    let defaultName = \"x\""], fileName: "Merger.swift")
        #expect(runs[0].contains { $0.text == "Greeting" && $0.role == .typeDeclaration })
        #expect(runs[1].contains { $0.text == "defaultName" && $0.role == .otherDeclaration })
        // In the editor, dark: the declaration colours.
        try fc.withPreferences { _ in
            let storage = NSTextStorage(string: src)
            Theme.apply(SyntaxDocument(text: src, language: .swift), to: storage)
            let ns = storage.string as NSString
            func color(_ word: String, from: Int = 0) -> String? {
                let r = ns.range(of: word, range: NSRange(location: from, length: ns.length - from))
                guard let c = storage.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor else { return nil }
                return hexIn(c, dark: true)
            }
            #expect(color("Greeting") == "#00CAFB")
            #expect(color("describe") == "#27A7C1")
            #expect(color("name", from: ns.range(of: "\\(").location) == "#20AD9D")
            #expect(color("String") == "#D997FF")
        }
    }

    // MARK: Row 87: full blocks join without seams

    @Test func blockRunsAreOneRectanglePerRow() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, e) = try editor("import Foundation\n\n" + Self.band + "\n", dark: true)
        defer { wc.window?.close() }
        let tlm = try #require(e.textView.textLayoutManager)
        tlm.ensureLayout(for: tlm.documentRange)
        var fragment: BlockRunLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            if let b = f as? BlockRunLayoutFragment { fragment = b; return false }
            return true
        }
        let f = try #require(fragment)
        let runs = f.blockRuns()
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.shapes.count == 1 })
        let widths = runs.map { $0.shapes[0].rect.width / Theme.advance }
        #expect(widths.map { Int($0.rounded()) } == [76, 34], "\(widths)")
        // The ink: 13.5 of the row, its top 3.5 below the row's.
        for r in runs {
            #expect(abs(r.shapes[0].rect.height - 13.5) < 0.01)
            #expect(abs(r.shapes[0].rect.minY - r.cells.minY - 3.5) < 0.01)
        }
        // Drawn: one even colour along the bar (no lighter seam at any cell).
        let tv = e.textView
        let line = try #require(f.textLineFragments.dropFirst().first)
        let y = tv.textContainerOrigin.y + f.layoutFragmentFrame.minY + line.typographicBounds.minY + 10
        let x0 = tv.textContainerOrigin.x + f.layoutFragmentFrame.minX + runs[0].cells.minX
        let rect = NSRect(x: x0, y: y, width: runs[0].cells.width, height: 1)
        let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: rect))
        tv.cacheDisplay(in: rect, to: rep)
        // Device values (the bitmap is tagged with the display's profile):
        // one flat colour, the comment's (F.3: #ABB3CD), within the
        // profile's rounding.
        func raw(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
            var p = [Int](repeating: 0, count: 4)
            r.getPixel(&p, atX: x, y: y)
            return Array(p.prefix(3))
        }
        let mid = rep.pixelsHigh / 2
        let colours = Set((2..<(rep.pixelsWide - 2)).map { raw(rep, $0, mid) })
        #expect(colours.count == 1, "\(colours)")
        let want = [0xAB, 0xB3, 0xCD]
        #expect(colours.allSatisfy { zip($0, want).allSatisfy { abs($0 - $1) <= 3 } }, "\(colours)")
        // The background beside it: #262626.
        let bg = NSRect(x: rect.maxX + 40, y: y, width: 4, height: 1)
        let bgRep = try #require(tv.bitmapImageRepForCachingDisplay(in: bg))
        tv.cacheDisplay(in: bg, to: bgRep)
        #expect(zip(raw(bgRep, 1, 0), [0x26, 0x26, 0x26]).allSatisfy { abs($0 - $1) <= 2 }, "\(raw(bgRep, 1, 0))")
    }
}

extension Theme {
    /// One character's advance in `font`.
    static func advance(of font: NSFont) -> CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }
}

/// `#RRGGBB` of a colour in the light or dark appearance.
private func hexIn(_ c: NSColor, dark: Bool) -> String {
    var out = ""
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { out = EditorTheme.hex(c) }
    return out
}
