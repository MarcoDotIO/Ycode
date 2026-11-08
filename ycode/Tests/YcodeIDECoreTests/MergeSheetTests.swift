import Foundation
import Testing
@testable import YcodeIDECore

/// The merge sheet's shared model (`specs/ide/merge-sheet.md`): its
/// geometry, the aligned rows, the shading inputs, the tokens, the Choose
/// behaviour, Merge's enablement and the motion.
struct MergeSheetTests {
    /// Two conflicts and one clean change, as in the spec's capture.
    func greeting() -> MergeDocument {
        MergeDocument(base: "a\nlet greeting = \"Hello\"\nc\nd\ne\nf\nlet name = \"x\"\nh\ni\n",
                      ours: "a\nlet greeting = \"Hi there\"\nc\nd\ne\nf\nlet name = \"main\"\nh\ni\n",
                      theirs: "a\nlet greeting = \"Hello, world\"\nc\nd\ne\nf\nlet name = \"feature\"\nh\nI\n",
                      oursLabel: "main", theirsLabel: "feature")
    }

    @Test func sheetGeometryMatchesTheSpec() {
        typealias M = MergeSheetMetrics
        let sheet = M.sheetFrame(window: (1400, 880), toolbarBottom: 52.5)
        #expect(sheet.x == 24 && sheet.width == 1352 && sheet.y == 52.5)
        let box = M.contentBox(sheet: (sheet.width, sheet.height))
        #expect(box.x == 20 && box.y == 11.5 && box.width == 1312)
        // Round 4 (§13.3): the box from y 64 to 847, 33 above the window's
        // bottom; the button row runs past the window.
        #expect(sheet.y + box.y == 64 && sheet.y + box.maxY == 847)
        // Round 5 (§14.1): Cancel 19 below the box (y 866), the sheet's
        // bottom 22 below the 20-point buttons, at y 908.
        #expect(sheet.maxY == 908 && sheet.y + box.maxY + M.buttonGap == 866)
        for h in [700.0, 1000, 1200] {
            let f = M.sheetFrame(window: (1400, h), toolbarBottom: 52)
            #expect(f.y + M.contentBox(sheet: (f.width, f.height)).maxY == h - 33)
        }
        #expect(box.maxY + M.buttonGap + M.buttonHeight + M.bottomMargin == sheet.height)
        // Window coordinates of §2's columns: the box starts at x 44.
        let c = M.columns(boxWidth: box.width)
        #expect(44 + c.fileList.start == 45 && c.fileList.length == 198)
        #expect(44 + c.left.start == 244 && c.left.length == 523)
        #expect(44 + c.gutter.start == 768 && c.gutter.length == 46)
        #expect(44 + c.right.start == 815 && c.right.length == 540)
        #expect(44 + c.ruler.start == 1338 && c.ruler.length == 17)
        let alert = M.alertFrame(window: (1400, 880))
        #expect(alert.x == 490 && alert.y == 373 && alert.width == 420 && alert.height == 133)
    }

    @Test func rowsAlignBothVersionsAndMarkTheChanges() {
        var s = ConflictEditorState()
        s.files = ["/r/Merger/Greeting.swift"]
        s.show(file: "/r/Merger/Greeting.swift", document: greeting())
        let rows = s.sheetRows
        #expect(rows.count == 9)
        // Every line sits at the same row in both panes.
        #expect(rows.allSatisfy { $0.left?.number == $0.right?.number })
        #expect(rows.map(\.kind) == [.same, .conflict, .same, .same, .same, .same, .conflict, .same, .clean])
        #expect(rows[1].isFirstOfHunk && rows[1].hunk == 0 && rows[8].hunk == 2)
        // The left pane is the current branch's version with the clean
        // change applied; no conflict markers.
        #expect(s.leftLines.last == "I" && !s.leftLines.contains { $0.hasPrefix("<<<<<<<") })
        // Changed runs, cell-exact (§15.1): the quotes match, so they are
        // not filled; "Hello" and its comma are one run.
        #expect(rows[1].left?.words == [16..<18, 19..<24])
        #expect(rows[1].right?.words == [16..<22, 23..<28])
        #expect(s.stepperText == "1/3" && s.currentHunk == 0)
        #expect(s.rulerMarks(rows: rows).map(\.isConflict) == [true, true, false])
    }

    @Test func blocksOfDifferentLengthsArePadded() {
        let doc = MergeDocument(base: "a\nb\nc\n", ours: "a\nB\nc\n", theirs: "a\nB1\nB2\nB3\nc\n")
        let rows = MergeSheetLayout.rows(doc)
        #expect(rows.count == 5)
        #expect(rows[1...3].map { $0.left?.text } == ["B", nil, nil])
        #expect(rows[1...3].map { $0.right?.text } == ["B1", "B2", "B3"])
        #expect(rows[4].left?.number == 3 && rows[4].right?.number == 5)
        #expect(rows[3].isLastOfHunk && !rows[2].isLastOfHunk)
    }

    @Test func chooseRewritesTheLeftPaneAndKeepsTheSelection() {
        var s = ConflictEditorState()
        s.files = ["/r/G.swift"]
        s.show(file: "/r/G.swift", document: greeting())
        #expect(s.token(forHunk: 0) == .init(glyph: "?", isDecided: false, isSelected: true, isConflict: true))
        #expect(s.token(forHunk: 2) == .init(glyph: "3", isDecided: true, isSelected: false, isConflict: false))
        s.chooseKeepingSelection(.theirs)
        #expect(s.currentHunk == 0 && s.stepperText == "1/3")
        #expect(s.sheetRows[1].left?.text == "let greeting = \"Hello, world\"")
        #expect(s.token(forHunk: 0)?.glyph == "1" && s.token(forHunk: 0)?.isDecided == true)
        // The word fills stay at the cells they had (as captured).
        #expect(s.sheetRows[1].left?.words == [16..<18, 19..<24])
        #expect(!s.canMerge)
        s.choose(.ours, forHunk: 1)
        #expect(s.currentHunk == 1 && s.token(forHunk: 1)?.glyph == "2" && s.token(forHunk: 1)?.isSelected == true)
        #expect(s.canMerge && s.primaryTitle == "Resolve")
        s.choose(.oursThenTheirs, forHunk: 1)
        #expect(s.sheetRows.filter { $0.hunk == 1 }.compactMap { $0.left?.text } == ["let name = \"main\"", "let name = \"feature\""])
        #expect(s.token(forHunk: 1)?.glyph == "4")
        s.choose(.theirsThenOurs, forHunk: 1)
        #expect(s.token(forHunk: 1)?.glyph == "5")
        s.integration = .merging(branch: "feature")
        #expect(s.primaryTitle == "Merge")
        s.integration = .rebasing(branch: "t", onto: "abc", step: 1, total: 1)
        #expect(s.primaryTitle == "Continue Rebase")
    }

    @Test func choicesSurviveSwitchingFilesAndMergeNeedsEveryFile() {
        var s = ConflictEditorState()
        s.integration = .merging(branch: "feature")
        s.files = ["/r/A.swift", "/r/B.swift"]
        s.show(file: "/r/A.swift", document: greeting())
        s.prefetch(file: "/r/B.swift", document: greeting())
        s.chooseKeepingSelection(.ours)
        s.choose(.ours, forHunk: 1)
        #expect(s.isDecided(file: "/r/A.swift") && !s.isDecided(file: "/r/B.swift") && !s.canMerge)
        s.show(file: "/r/B.swift", document: nil)
        #expect(s.currentFile == "/r/B.swift" && s.document != nil && s.currentHunk == 0)
        s.chooseKeepingSelection(.theirs)
        s.choose(.theirs, forHunk: 1)
        #expect(s.canMerge && s.resolutions.map(\.file) == ["/r/A.swift", "/r/B.swift"])
        s.show(file: "/r/A.swift", document: greeting())
        #expect(s.token(forHunk: 0)?.glyph == "2")
        // Showing the shown file again keeps its choices.
        s.show(file: "/r/A.swift", document: nil)
        #expect(s.token(forHunk: 0)?.glyph == "2" && s.isDecided(file: "/r/A.swift"))
        // A file resolved elsewhere drops out of the list.
        _ = s.update(integration: .merging(branch: "feature"), conflicted: ["/r/A.swift"])
        #expect(s.otherDocuments.isEmpty)
        // The file list.
        s.files = ["/r/Merger/Greeting.swift", "/r/Merger/Colors.swift", "/r/README.md"]
        #expect(s.fileRows(root: "/r", flat: false).map(\.title) == ["Merger", "Colors.swift", "Greeting.swift", "r", "README.md"])
        #expect(s.fileRows(root: "/r", flat: true).map(\.depth) == [0, 0, 0])
        #expect(s.fileRows(root: "/r", flat: true, filter: "col").map(\.title) == ["Colors.swift"])
        s.show(file: "/r/Merger/Greeting.swift", document: greeting())
        #expect(s.jumpPath(root: "/r") == ["r", "Merger", "Greeting"])
        // Round 4 (§13.7): the path starts with the workspace's project,
        // from the project's folder.
        #expect(s.jumpPath(root: "/r", project: MergeSheetProject(name: "Merger", folder: "/r")) == ["Merger", "Merger", "Greeting"])
        #expect(s.jumpPath(root: "/r", project: MergeSheetProject(name: "App", folder: "/r/Merger")) == ["App", "Greeting"])
        #expect(s.jumpPath(root: "/r", project: MergeSheetProject(name: "App", folder: "/elsewhere")) == ["App", "Merger", "Greeting"])
    }

    /// Round 4 (§13.4, §13.5): the dark colours and the token's rims.
    @Test func darkPaletteAndTokens() {
        let d = MergeSheetPalette.dark, l = MergeSheetPalette.light
        #expect(d.sheet == 0x1D1E1F && d.sheetRim == 0x2D2E2F && d.pane == 0x262627 && d.boxBorder == 0x171718)
        #expect(d.gutter == 0x313131 && d.gutterRule == 0x484848 && d.gutterConflict == 0x613D3F && d.gutterClean == 0x394C61)
        #expect(d.conflictRow == 0x583436 && d.conflictWord == 0x9B3A3C && d.selectedRule == 0xDA5559 && d.cleanRow == 0x2F4457)
        #expect(d.token == 0x575757 && d.tokenRim == 0x6A6A6A && d.selectedToken == 0x6D2A2D && d.selectedTokenRim == 0xDA5559)
        // The veil takes the window to about 0.70 of its value.
        #expect(d.veilOpacity == 0.30)
        // Light: no rim on the sheet or the unselected token, white panes.
        #expect(l.sheetRim == l.sheet && l.pane == 0xFFFFFF && l.tokenRim == l.token && l.gutterRule == 0xD7D7D7)
        #expect(MergeSheetToken.rimWidth == 0.5 && MergeSheetToken.selectedRimWidth == 1 && MergeSheetToken.chevronLineWidth == 1)
        #expect(MergeSheetToken.chevronHalfWidth * 2 == 6 && MergeSheetToken.chevronHeight == 3.5)
        #expect(MergeModalTone.text == 0.63 && MergeModalTone.glyph == 0.33)
    }

    @Test func wrappingContinuesPastTheIndentation() {
        let text = "    // " + String(repeating: "word ", count: 20)
        let segs = MergeSheetLayout.wrap(text, columns: 40)
        #expect(segs.count >= 3)
        #expect(segs[0].column == 0 && segs[1].column == 8)
        #expect(segs.allSatisfy { $0.cells.count + $0.column <= 40 })
        #expect(MergeSheetLayout.wrap("short", columns: 40) == [.init(cells: 0..<5, column: 0)])
        #expect(MergeSheetLayout.expandTabs("\tx\ty") == "    x   y")
    }

    @Test func tokenGlyphs() {
        #expect(MergeSheetToken.glyph(choice: .unresolved, kind: .conflict) == "?")
        #expect(MergeSheetToken.glyph(choice: .theirs, kind: .conflict) == "1")
        #expect(MergeSheetToken.glyph(choice: .theirs, kind: .theirsOnly) == "3")
        #expect(MergeSheetToken.glyph(choice: .ours, kind: .theirsOnly) == "2")
        #expect(MergeSheetToken.glyph(choice: .custom(["x"]), kind: .conflict) == "7")
    }

    @Test func theSheetFadesInAndSlidesDown() {
        typealias M = MergeSheetMotion
        #expect(M.sheetFade == 0.09 && M.sheetSlide == 0.2 && M.slideDistance == 32)
        #expect(M.sheetOpacity(at: 0) == 0 && M.sheetOpacity(at: 0.045) == 0.5 && M.sheetOpacity(at: 0.09) == 1)
        #expect(abs(M.sheetOffset(at: 0) + 32) < 0.001 && abs(M.sheetOffset(at: 0.2)) < 0.001)
        // §10's keyframes (top edge, resting at 52.5), within 3 points.
        for (ms, top) in [(25.0, 26.0), (50, 30), (67, 34), (92, 38), (108, 42), (133, 45), (158, 48), (187, 51)] {
            let y = 52.5 + M.sheetOffset(at: ms / 1000)
            #expect(abs(y - top) <= 3, "at \(ms) ms: \(y) against \(top)")
        }
        // Reduce Motion: it fades only.
        #expect(M.sheetOffset(at: 0, reduceMotion: true) == 0)
        #expect(M.veilIn == 0.255 && M.veilProgress(at: 0) == 0 && M.veilProgress(at: 0.255) == 1)
        #expect(MergeSheetPalette.light.conflictRow == 0xFFDCDD && MergeSheetPalette.light.cleanRow == 0xD6EBFE)
        #expect(MergeSheetPalette.light.gutterConflict == 0xF9D5D5 && MergeSheetPalette.light.selectedRule == 0xDA5559)
    }

    @Test func alertTexts() {
        #expect(MergeSheetText.alertTitle(branch: "feature") == "Are you sure you want to merge from \u{201C}feature\u{201D}?")
        #expect(MergeSheetText.alertMessage(branch: "feature", current: "main")
                == "Changes from \u{201C}feature\u{201D} will be merged into your current branch (\u{201C}main\u{201D}).")
        #expect(MergeSheetText.chooseTitles.count == 4)
        let f = MergeSheetFooter(repository: "project", branch: "main", date: Date(timeIntervalSince1970: 1_767_441_600), author: "Capture Test",
                                 shortHash: "1a2b3c4", isHead: true)
        #expect(f.commitText.hasSuffix("Capture Test  1a2b3c4 (HEAD)") && f.dateText.hasSuffix("/26"))
    }
}
