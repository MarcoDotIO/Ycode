import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 6 on the merge sheet (`specs/ide/merge-sheet.md` §15.1–
/// §15.3; checklist rows 146–148), in light: the changed-word runs, the
/// current change's rules following the panes' focus, and the ruler's
/// marks. The windows stay off every display.
@MainActor
@Suite(.serialized) struct MergeSheetR6UITests {
    let base = MergeSheetUITests()
    typealias Repo = MergeSheetUITests.Repo

    /// Writes the window and its sheet to `.build-ide/b6-shots/<name>.png`.
    func shot(_ wc: WorkspaceWindowController, _ name: String) {
        guard let s = try? base.snapshot(wc), let png = s.rep.representation(using: .png, properties: [:]) else { return }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/b6-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// A left-button click at a point of a view in the sheet's window.
    func click(_ v: NSView, at p: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: v.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    // MARK: Rows 146, 147: word runs; the rules follow the focus

    @Test func wordRunsAndRulesFollowTheFocus() async throws {
        let r = try Repo("r6-focus")
        defer { r.cleanUp() }
        let wc = try await r.window(dark: false)
        let sheet = try await base.openSheet(wc)
        let p = MergeSheetPalette.light
        let sw = try #require(wc.sourceControl.mergeOverlay?.sheetWindow)
        let canvas = sheet.canvas
        let h = try #require(sheet.state.currentHunk)
        let range = try #require(canvas.rows(ofHunk: h))
        // Row 146: `"Hi"` against `"Hello, there"`: the quotes match; "Hello,
        // there" is one run, its comma and space filled.
        let row = canvas.rows[range.lowerBound]
        let left = try #require(row.left), right = try #require(row.right)
        func cells(_ s: MergeSheetRow.Side) -> [String] { let c = Array(s.text); return s.words.map { String(c[$0]) } }
        #expect(cells(left) == ["Hi"], "\(cells(left))")
        #expect(cells(right) == ["Hello, there"], "\(cells(right))")
        let rowRect = base.windowRect(canvas, canvas.rowRect(range.lowerBound), wc)
        let rightX = base.windowRect(canvas, NSRect(x: canvas.rightX, y: 0, width: 1, height: 1), wc).minX
        let comma = try #require(right.text.firstIndex(of: ","))
        let commaCell = right.text.distance(from: right.text.startIndex, to: comma)
        var s = try base.snapshot(wc)
        for k in [commaCell, commaCell + 1] {
            let x = rightX + CGFloat(MergeSheetMetrics.codeX) + (CGFloat(k) + 0.5) * CGFloat(MergeSheetMetrics.cellWidth)
            // Above the glyphs' ink: the fill itself.
            #expect(base.same(s.color(x, rowRect.minY + 2.5), p.conflictWord), "cell \(k) filled")
        }
        // Row 147: the sheet opens with the list focused: the rules #DA5559.
        let ruleY = rowRect.minY + 0.5, ruleX = rowRect.minX + 120
        #expect(sw.firstResponder === sheet.fileList)
        #expect(base.same(s.color(ruleX, ruleY), p.selectedRule), "list focused")
        shot(wc, "mac-r6-merge-list-focused")
        // A click on the token moves the focus into the panes: #FF656A.
        let t = try #require(canvas.tokenRect(forHunk: h))
        canvas.mouseDown(with: try click(canvas, at: NSPoint(x: t.midX, y: t.midY), in: sw))
        #expect(canvas.hasPanesFocus)
        s = try base.snapshot(wc)
        #expect(base.same(s.color(ruleX, ruleY), p.decidedRule), "panes focused")
        shot(wc, "mac-r6-merge-panes-focused")
        // A choice changes the text, not the rules.
        sheet.choose(.theirs)
        s = try base.snapshot(wc)
        #expect(base.same(s.color(ruleX, ruleY), p.decidedRule), "after the choice")
        // Back in the list: #DA5559, even with the change decided.
        sheet.fileList.mouseDown(with: try click(sheet.fileList, at: NSPoint(x: 5, y: 3), in: sw))
        #expect(sheet.fileList.hasListFocus && !canvas.hasPanesFocus)
        s = try base.snapshot(wc)
        #expect(base.same(s.color(ruleX, ruleY), p.selectedRule), "list focused again")
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await wc.sourceControl.idle(); return wc.sourceControl.mergeOverlay == nil }
    }

    // MARK: Row 148: the ruler in light

    /// The marks at (line − 0.5) ÷ lines of the track 3 inside the pane,
    /// the lines counted as an editor counts them (the empty line after the
    /// final line break too).
    @Test func rulerMarksInLight() async throws {
        let r = try Repo("r6-ruler")
        defer { r.cleanUp() }
        let wc = try await r.window(dark: false)
        let sheet = try await base.openSheet(wc)
        let p = MergeSheetPalette.light
        let ruler = sheet.ruler
        #expect(ruler.knobRect == nil)
        let rows = sheet.canvas.rows
        let lines = rows.compactMap(\.right).count + 1
        let starts = rows.filter(\.isFirstOfHunk).compactMap { $0.right?.number }
        #expect(ruler.marks.map(\.position) == starts.map { (Double($0) - 0.5) / Double(lines) })
        let rr = base.windowRect(ruler, ruler.bounds, wc)
        let pane = base.windowRect(sheet.scrollView, sheet.scrollView.bounds, wc)
        // The ruler spans the pane; its track 3 inside both ends.
        #expect(abs(rr.minY - pane.minY) < 0.5 && abs(rr.maxY - pane.maxY) < 0.5, "\(rr) \(pane)")
        let s = try base.snapshot(wc)
        for m in ruler.marks {
            let y = rr.minY + ruler.markRect(m.position).minY
            #expect(abs(y - (rr.minY + 3 + CGFloat(m.position) * (rr.height - 6)).rounded(.down)) <= 1, "mark at \(y)")
            #expect(base.same(s.color(rr.minX + 6, y + 0.5), m.isConflict ? p.rulerConflict : p.rulerClean), "mark at \(y)")
        }
        shot(wc, "mac-r6-merge-ruler-light")
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await wc.sourceControl.idle(); return wc.sourceControl.mergeOverlay == nil }
    }
}
