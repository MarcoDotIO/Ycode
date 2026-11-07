import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 5, group A: the editor's text layout and minimap (rows
/// 115, 116), the file switch (136) and the jump-bar issue stepper (139);
/// `specs/ide/editor-area.md` G.2, G.3, G.6, G.8. Windows are never
/// ordered in: they lay out off every display.
@MainActor
@Suite(.serialized) struct CouncilRound5EditorTests {
    let fc = FidelityCouncilTests()

    func window(_ name: String, width: CGFloat = 1400) throws -> (WorkspaceWindowController, URL) {
        Theme.backingScaleOverride = 2
        let dir = try fc.project("r5e-\(name)")
        let wc = try fc.window(dir)
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: width, height: 880), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (wc, dir)
    }

    func layout(_ wc: WorkspaceWindowController) {
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        for e in wc.editorArea.allEditors { e.view.layoutSubtreeIfNeeded() }
    }

    /// The columns a pane's text container holds.
    func columns(_ e: SourceEditorController) -> Int {
        Int(((e.textView.textContainer?.size.width ?? 0) + 0.01) / Theme.advance)
    }

    // MARK: Row 115: each pane wraps before its own minimap

    @Test func splitPanesWrapBeforeTheirOwnMinimaps() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, dir) = try window("wrap")
        defer { wc.window?.close() }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.split(sideBySide: true)
        layout(wc)
        // The step: 1400 → 1100 with the split up.
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: false)
        layout(wc)
        let panes = wc.editorArea.tab.editors
        #expect(panes.count == 2)
        for e in panes {
            // The container ends 10 before the minimap's separator.
            let minimapLeft = e.minimapLeftEdge
            let end = e.textView.convert(NSPoint(x: e.textContainerEnd, y: 0), to: e.view).x
            #expect(abs(minimapLeft - CGFloat(EditorMetrics.textToMinimap - EditorMetrics.wrapTolerance) - end) < 0.5, "end \(end), minimap \(minimapLeft)")
        }
        let widths = panes.map { $0.view.bounds.width }
        #expect(abs(widths[0] - widths[1]) < 2, "\(widths)")
        #expect(columns(panes[0]) == columns(panes[1]), "\(panes.map(columns))")
        // G.2: 17 columns in both panes at 1100.
        #expect(columns(panes[0]) == 17, "\(panes.map(columns))")
    }

    // MARK: Row 116: the minimap's rows follow the text's rows

    @Test func minimapRowsFollowTheTextsWrapping() {
        let band = Array("// " + String(repeating: "\u{2588}", count: 110))
        let keys = Array(repeating: 1, count: band.count)
        let joins = Array(repeating: true, count: band.count)
        let w = MinimapRows.wrap(band, columns: 80, indent: 4)
        let rows = MinimapRows.rows(chars: band, keys: keys, joins: joins, starts: w.starts, indent: w.indent)
        // F.1: "//" alone, then 76 and 34 blocks: three 3-point rows (9 points).
        #expect(rows.count == 3)
        #expect(rows.map { $0.map(\.length) } == [[2], [76], [34]])
        #expect(rows[1].first?.column == 4 && rows[2].first?.column == 4)
        // A comment's spaces keep its bar; plain code's break it.
        let line = Array("let x = 1 // a b")
        let k = line.indices.map { $0 >= 10 ? 2 : 0 }
        let j = line.indices.map { $0 >= 10 }
        let r = MinimapRows.rows(chars: line, keys: k, joins: j, starts: [], indent: 0)
        #expect(r == [[.init(column: 0, length: 3, key: 0), .init(column: 4, length: 1, key: 0), .init(column: 6, length: 1, key: 0),
                       .init(column: 8, length: 1, key: 0), .init(column: 10, length: 6, key: 2)]])
    }

    @Test func minimapViewHasOneRowPerVisualRow() throws {
        defer { Theme.backingScaleOverride = nil }
        let storage = NSAttributedString(string: "// " + String(repeating: "\u{2588}", count: 110) + "\nlet x = 1\n",
                                         attributes: [.foregroundColor: NSColor.textColor])
        let rows = MinimapView.rows(of: storage, columns: 80, tabWidth: 4, wraps: true)
        // Three rows for the band, one for the code, one for the empty last line.
        #expect(rows.count == 5)
        #expect(rows[0].map(\.length) == [2] && rows[1].map(\.length) == [76])
    }

    // MARK: Row 116: the minimap meets the scroll lane

    @Test func minimapMeetsTheScrollLane() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, dir) = try window("lane", width: 1100)
        defer { wc.window?.close() }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.split(sideBySide: true)
        layout(wc)
        for e in wc.editorArea.tab.editors {
            let lane = e.scrollerLaneWidth
            let f = e.minimap.frame
            if lane >= CGFloat(EditorMetrics.minimapStrip) {
                // No darker strip: the minimap runs to the 11-point lane.
                #expect(abs(f.maxX - (e.view.bounds.maxX - lane + CGFloat(EditorMetrics.minimapStrip))) < 0.5, "\(f) lane \(lane)")
                #expect(f.width >= 62, "\(f.width)")
            }
            #expect(abs(e.minimapLeftEdge - f.minX) < 0.5)
        }
    }

    // MARK: Row 139: the issue stepper in every pane

    @Test func issueStepperFollowsTheCapsuleCounts() {
        #expect(IssueStepper.kind(errors: 0, warnings: 0) == nil)
        #expect(IssueStepper.kind(errors: 0, warnings: 1) == .warning)
        #expect(IssueStepper.kind(errors: 2, warnings: 1) == .error)
        #expect(IssueStepper.Kind.error.symbol == "xmark.circle.fill")
        #expect(IssueStepper.Kind.warning.symbol == "exclamationmark.triangle.fill")
        // G.8: 40 points wide (x 1084.5–1124.5), 14.5 inside the bar's right edge.
        #expect(IssueStepper.width == 40 && IssueStepper.spacing == 8 && IssueStepper.trailingInset == 14.5)
    }

    @Test func issueStepperShowsInEveryPaneWithAProjectIssue() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, dir) = try window("stepper")
        defer { wc.window?.close() }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.split(sideBySide: true)
        // A warning with no location (a project check), as the council's project had.
        wc.session.packageIssues = [Diagnostic(severity: .warning, message: "Update to recommended settings", location: nil)]
        layout(wc)
        for e in wc.editorArea.tab.editors {
            #expect(e.jumpBarIssueGlyph?.symbol == "exclamationmark.triangle.fill", "\(String(describing: e.jumpBarIssueGlyph))")
            let stack = e.jumpBar.issueStack
            #expect(abs(e.jumpBar.bounds.maxX - stack.frame.maxX - CGFloat(IssueStepper.trailingInset)) < 1, "\(stack.frame)")
        }
        wc.session.packageIssues = []
        layout(wc)
        for e in wc.editorArea.tab.editors { #expect(e.jumpBarIssueGlyph == nil) }
    }
}

// MARK: Row 136: switching files

extension CouncilRound5EditorTests {
    /// From the request to the new file's text, jump bar and minimap laid
    /// out: one pass, well inside the 200 ms the reference takes from the
    /// click (G.6); the old text never stays under the new jump bar.
    @Test func fileSwitchShowsTheNewTextInOnePass() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, dir) = try window("switch")
        defer { wc.window?.close() }
        let long = dir.appendingPathComponent("GlassScroll/Long.swift").path
        let bands = dir.appendingPathComponent("GlassScroll/Bands.swift")
        try (String(repeating: "// " + String(repeating: "\u{2588}", count: 110) + "\n\n", count: 40)).write(to: bands, atomically: true, encoding: .utf8)
        wc.open(path: long, line: nil)
        layout(wc)
        wc.window?.displayIfNeeded()
        var times: [Double] = []
        for path in [bands.path, long, bands.path] {
            let t0 = Date()
            wc.open(path: path, line: nil)
            layout(wc)
            wc.window?.displayIfNeeded()
            times.append(Date().timeIntervalSince(t0) * 1000)
            #expect(wc.editor.fileURL?.path == path)
            #expect(wc.editor.textView.string == (try String(contentsOfFile: path, encoding: .utf8)))
            #expect(wc.editor.jumpBarTitles.contains((path as NSString).deletingPathExtension.components(separatedBy: "/").last!))
        }
        print("R5 file switch ms: \(times.map { Int($0) })")
        // A gross guard only (the Mac is shared and this is a debug build:
        // about 100 ms here, of which the editor's open is about 40).
        #expect(times.dropFirst().allSatisfy { $0 < 500 }, "\(times)")
    }
}

// MARK: The image editor's button (parity §4)

extension CouncilRound5EditorTests {
    /// The flat button's fill follows the window's appearance: #ECECEC in light.
    @Test func previewButtonFillFollowsTheWindowsAppearance() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, dir) = try window("button")
        defer { wc.window?.close() }
        let png = dir.appendingPathComponent("GlassScroll/Stripes.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        for (name, white) in [(NSAppearance.Name.aqua, 0xEC), (.darkAqua, 0x40)] {
            wc.window?.appearance = NSAppearance(named: name)
            wc.open(path: png.path, line: nil)
            layout(wc)
            let b = try #require(wc.imageViewer?.previewButton)
            let c = try #require(b.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceGray) })
            #expect(abs(c.whiteComponent * 255 - CGFloat(white)) < 2, "\(name.rawValue): \(c.whiteComponent * 255)")
        }
    }
}
