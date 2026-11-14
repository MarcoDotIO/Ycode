import Foundation
import Testing
import YcodeBuild
import YcodeEditorKit
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Council round 9, group A2, on the Linux IDE's model
/// (`specs/ide/fidelity-council.md` rows 215 and 217): File ▸ Open
/// Quickly… and its keys, and "No Selection" at the end of the path for
/// documents without symbols. The drawing shares `OpenQuicklyLayout`,
/// `AssistantButtonGlyph` and `JumpBarPathLayout` with the macOS IDE
/// (`CouncilRound9GroupA2Tests`).
@MainActor
@Suite(.serialized) struct CouncilR9ToolbarShellTests {
    /// ⇧⌘O is the shell's command, in the File menu; it opens the panel over
    /// the workspace's files; typing, Up and Down, and Return open the
    /// selected file; Escape closes.
    /// Row 211 in the Linux panel: a file result's glyph is group A1's
    /// vector glyph at the 24.5 × 20.5 box, white on the selected row and
    /// its type's tint on the others; the selection carries the white.
    @Test func openQuicklySelectedFileGlyphIsWhite() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.perform(.openQuickly)
        let oq = m.openQuickly
        await oq.indexIdle()
        oq.query = "swift"
        let files = oq.results.indices.filter { oq.results[$0].kind == .file && oq.results[$0].title.hasSuffix(".swift") }
        try #require(files.count >= 2, "\(oq.results.map(\.title))")
        let (a, b) = (files[0], files[1])
        let drawing = try #require(OpenQuicklyLayout.fileGlyph(oq.results[a].title))
        #expect(drawing.width == FileGlyphs.openQuicklyBox.width && drawing.height == FileGlyphs.openQuicklyBox.height)
        #expect(drawing == FileGlyphs.drawing(.logo("swift"), in: FileGlyphs.openQuicklyBox))
        let white = GlyphColor(0xFFFFFF, 0xFFFFFF), swift = GlyphColor(0xF77640, 0xFFA54D)
        oq.select(a)
        #expect(oq.fileGlyphColor(at: a) == white && oq.fileGlyphColor(at: b) == swift)
        oq.select(b)
        #expect(oq.fileGlyphColor(at: a) == swift && oq.fileGlyphColor(at: b) == white)
        // The same colours as the macOS cell's (`OpenQuicklyLayout.fileGlyphColor`).
        #expect(OpenQuicklyLayout.fileGlyphColor("palette.json", selected: false) == GlyphColor(0xEE2C22, 0xFF695E))
        #expect(OpenQuicklyLayout.fileGlyphColor("palette.json", selected: true) == white)
        // A file Ycode shows with a symbol has no glyph (the symbol, as before).
        #expect(OpenQuicklyLayout.fileGlyph("Info.plist") == nil)
    }

    @Test func openQuicklyFindsAndOpensFiles() async throws {
        #expect(ShellCommand.openQuickly.action.selector == "openQuickly:" && ShellCommand.openQuickly.menu == "File")
        #expect(ShellCommand.openQuickly.menuCommand?.title == "Open Quickly…")
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        #expect(m.isEnabled(.openQuickly))
        m.perform(.openQuickly)
        let oq = m.openQuickly
        #expect(oq.isShown && oq.query.isEmpty && oq.results.isEmpty && oq.panelHeight == OpenQuicklyLayout.headerHeight)
        await oq.indexIdle()
        oq.query = "greeting"
        #expect(!oq.results.isEmpty && oq.selectedIndex == 0)
        // The struct Greeting ranks before its file (a shorter name).
        let index = try #require(oq.results.firstIndex { $0.kind == .file && $0.title == "Greeting.swift" })
        #expect(!oq.results[index].groupPath.isEmpty && oq.panelHeight == OpenQuicklyLayout.height(results: oq.results.count))
        oq.move(by: -1)
        #expect(oq.selectedIndex == 0)
        oq.move(by: 1)
        #expect(oq.selectedIndex == min(1, oq.results.count - 1))
        oq.select(index)
        m.openQuicklySelected()
        #expect(!oq.isShown && m.editor?.path == pkg.path("Sources/DemoCore/Greeting.swift"))
        // Escape closes without opening.
        m.perform(.openQuickly)
        await oq.indexIdle()
        oq.query = "package"
        oq.close()
        #expect(!oq.isShown && m.editor?.path == pkg.path("Sources/DemoCore/Greeting.swift"))
    }

    /// A symbol result opens its file at its declaration's line.
    @Test func openQuicklyOpensASymbolAtItsLine() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.perform(.openQuickly)
        await m.openQuickly.indexIdle()
        let symbols = m.openQuickly.candidates.filter { $0.kind == .symbol }
        let s = try #require(symbols.first)
        m.openQuickly.query = s.title
        let index = try #require(m.openQuickly.results.firstIndex { $0.kind == .symbol && $0.title == s.title && $0.path == s.path })
        m.openQuickly.select(index)
        m.openQuicklySelected()
        #expect(m.editor?.path == s.path && m.markedLine == s.line)
    }

    /// Row 217: a Markdown or JSON document ends its path with "No Selection".
    @Test func noSelectionForDocumentsWithoutSymbols() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let notes = pkg.path("NOTES.md"), palette = pkg.path("palette.json")
        try "# Notes\n\nSome text.\n".write(toFile: notes, atomically: true, encoding: .utf8)
        try "{ \"accent\": \"#FF0000\" }\n".write(toFile: palette, atomically: true, encoding: .utf8)
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        for p in [notes, palette] {
            m.open(p)
            #expect(m.editor?.path == p)
            #expect(m.jumpBarLastItem == "No Selection", "\(p): \(m.jumpBarLastItem ?? "nil")")
        }
    }
}
