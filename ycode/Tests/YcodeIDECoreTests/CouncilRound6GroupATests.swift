import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 6, group A, the shared models (both IDEs): the space rule
/// (row 142), the jump bar's spacing and collapse order (rows 143–144), the
/// merge sheet's word runs (row 146), the current change's rules (row 147)
/// and the ruler's line count (row 148). `specs/ide/editor-area.md` H.4,
/// `merge-sheet.md` §15.1–§15.3.
@Suite struct CouncilRound6GroupATests {
    // MARK: Row 142: the space after a word must fit

    /// Line 6 at the split in the 1100 window: 17 columns, continuation rows
    /// from column 5 (one space of indentation plus four).
    @Test func spaceRuleAtTheSplit() {
        let line = Array(" Block 00, line 0: a comment line 0 that keeps going on")
        let starts = EditorTextGeometry.rowStarts(of: line, firstColumns: 17, continuationColumns: 17 - 5)
        // " Block 00, line" / "0: a" / "comment" / "line 0 that" / ...
        #expect(starts.prefix(3) == [16, 21, 29], "\(starts)")
        // "import Foundation" ends its logical line at column 17: one row.
        #expect(EditorTextGeometry.rowStarts(of: Array("import Foundation"), firstColumns: 17, continuationColumns: 13).isEmpty)
    }

    // MARK: Rows 143–144: the jump bar's path

    typealias L = JumpBarPathLayout

    /// H.4's ink widths: the project and group icons and titles, the file's
    /// icon and "Long", "No Selection".
    let parts = [L.Part(icon: 13, title: 57), L.Part(icon: 12.5, title: 57), L.Part(icon: 11.5, title: 24)]
    let last = 65.0

    @Test func pathSpacing() {
        let gaps: [Double] = [L.iconToTitle, L.titleToChevron, L.chevronToIcon, L.chevronToTitle, L.chevronWidth]
        #expect(gaps == [6, 7, 10.5, 9.5, 2])
        // The whole path: 13+6+57, 7+2+10.5, 12.5+6+57, 7+2+10.5, 11.5+6+24,
        // 7+2+9.5, 65 (the reference's 316.5 with its file icon 7 from "Long").
        #expect(L.width(parts: parts, titles: parts.map(\.title), last: last) == 315.5)
        let fit = L.fit(parts: parts, last: last, room: 400)
        #expect(fit.titles == [57, 57, 24] && fit.last == 65)
    }

    /// At 1100 (179 points of ink): the project's and group's titles go,
    /// "Long" is cut to about 13, "No Selection" stays whole.
    @Test func collapseOrderAt1100() {
        let fit = L.fit(parts: parts, last: last, room: 179)
        #expect(fit.titles[0] == nil && fit.titles[1] == nil)
        #expect(fit.titles[2].map { abs($0 - 13.5) < 0.01 } == true, "\(fit)")
        #expect(fit.last == 65 && fit.width <= 179)
    }

    /// The group's title is cut first, with a fade (E.2's "Gla"); the
    /// project's and the file's stay.
    @Test func middleTitleGivesWayFirst() {
        let fit = L.fit(parts: parts, last: last, room: 280)
        #expect(fit.titles[0] == 57 && fit.titles[2] == 24 && fit.last == 65)
        #expect(fit.titles[1].map { abs($0 - 21.5) < 0.01 } == true, "\(fit)")
        // A little narrower: the group's title goes, then the project's is cut.
        let next = L.fit(parts: parts, last: last, room: 240)
        #expect(next.titles[1] == nil && next.titles[0].map { $0 < 57 } == true && next.titles[2] == 24, "\(next)")
    }

    /// The last item is cut only when everything before it is reduced.
    @Test func lastItemCutLast() {
        let fit = L.fit(parts: parts, last: last, room: 120)
        #expect(fit.titles == [nil, nil, nil])
        #expect(fit.last.map { $0 < 65 && $0 >= L.minimumCut } == true, "\(fit)")
    }

    // MARK: Row 146: changed-word runs

    @Test func wordRunsFollowTokens() {
        func cells(_ s: String, _ r: [Range<Int>]) -> [String] { let c = Array(s); return r.map { String(c[$0]) } }
        let l9 = "        return \"Good morning, \" + name", r9 = "        return \"Welcome aboard, \" + name"
        let w9 = MergeSheetLayout.changedWords(l9, r9)
        #expect(cells(l9, w9.left) == ["Good", "morning"])
        #expect(cells(r9, w9.right) == ["Welcome", "aboard"])
        let l13 = "        return \"Farewell, \" + name", r13 = "        return \"See you soon, \" + name"
        let w13 = MergeSheetLayout.changedWords(l13, r13)
        #expect(cells(l13, w13.left) == ["Farewell"])
        // One run, its two spaces filled.
        #expect(cells(r13, w13.right) == ["See you soon"])
        // "a_1", "+", "=", "  ", the quote, "x", the quote.
        #expect(MergeSheetLayout.tokens(Array("a_1+=  \"x\"")).count == 7)
    }

    // MARK: Row 147: the current change's rules follow the focus

    @Test func changeRuleFollowsFocus() {
        for p in [MergeSheetPalette.light, .dark] {
            #expect(p.changeRule(panesFocused: true) == 0xFF656A)
            #expect(p.changeRule(panesFocused: false) == 0xDA5559)
        }
    }

    // MARK: Row 148: the ruler counts the line after the final break

    @Test func rulerCountsLinesAsAnEditor() {
        // 18 text lines and a final line break: 19 lines, changes at 9, 13, 17.
        func text(_ a: String, _ b: String, _ c: String) -> String {
            (1...18).map { n in n == 9 ? a : n == 13 ? b : n == 17 ? c : "line \(n)" }.joined(separator: "\n") + "\n"
        }
        let doc = MergeDocument(base: text("x", "y", "z"), ours: text("o9", "o13", "z"), theirs: text("t9", "t13", "t17"))
        var s = ConflictEditorState()
        s.files = ["/r/A.swift"]
        s.show(file: "/r/A.swift", document: doc)
        let marks = s.rulerMarks(rows: s.sheetRows).map(\.position)
        let want: [Double] = [8.5 / 19, 12.5 / 19, 16.5 / 19]
        #expect(marks == want, "\(marks)")
        // On the track 105–815 of the 1400 × 880 window's pane 102–818.
        let ys = marks.map { 102 + MergeSheetMetrics.rulerMarkY(share: $0, height: 716) }
        // The reference's 423, 571 and 719, within 2.
        #expect(zip(ys, [423.0, 571, 719]).allSatisfy { abs($0 - $1) <= 2 }, "\(ys)")
        // Without a final line break, 18 lines.
        let bare = MergeDocument(base: "a\nb", ours: "a\nB", theirs: "a\nC")
        #expect(!bare.theirsEndsWithNewline)
    }
}
