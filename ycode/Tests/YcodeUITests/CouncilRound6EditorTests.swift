import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 6, group A: the space rule at the split (row 142) and the
/// jump bar's spacing, collapse order and last item's colour (rows
/// 143–145); `specs/ide/editor-area.md` H.4. Windows are never ordered in:
/// they lay out off every display.
@MainActor
@Suite(.serialized) struct CouncilRound6EditorTests {
    let r5 = CouncilRound5EditorTests()

    /// The ink columns of a view's bitmap along its vertical middle band
    /// (x in the view's points): runs of pixels that differ from the
    /// background by more than `threshold`.
    static func inkRuns(_ v: NSView, rows: ClosedRange<CGFloat>? = nil, threshold: Int = 40) -> [(CGFloat, CGFloat)] {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return [] }
        v.cacheDisplay(in: v.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(1, v.bounds.width)
        let ys = rows ?? (0...v.bounds.height)
        let y0 = Int(ys.lowerBound * scale), y1 = min(rep.pixelsHigh - 1, Int(ys.upperBound * scale))
        // Over white: the band may be transparent (the backdrop draws it).
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (255, 255, 255) }
            let a = c.alphaComponent
            func ch(_ v: CGFloat) -> Int { Int(((v * a + (1 - a)) * 255).rounded()) }
            return (ch(c.redComponent), ch(c.greenComponent), ch(c.blueComponent))
        }
        let bg = px(1, (y0 + y1) / 2)
        var ink = [Bool](repeating: false, count: rep.pixelsWide)
        for x in 0..<rep.pixelsWide {
            for y in y0...y1 {
                let c = px(x, y)
                if abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2) > threshold { ink[x] = true; break }
            }
        }
        var out: [(CGFloat, CGFloat)] = []
        var start: Int?
        for x in 0...ink.count {
            let on = x < ink.count && ink[x]
            if on, start == nil { start = x }
            if !on, let s = start { out.append((CGFloat(s) / scale, CGFloat(x) / scale)); start = nil }
        }
        return out
    }

    /// Writes a view's pixels to `.build-ide/b6-shots/<name>.png`.
    static func shot(_ v: NSView, _ name: String) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/b6-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// The council's split: Long.swift in two panes, at `width`.
    func split(_ name: String, width: CGFloat) throws -> (WorkspaceWindowController, URL) {
        let (wc, dir) = try r5.window(name)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.split(sideBySide: true)
        r5.layout(wc)
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: width, height: 880), display: false)
        r5.layout(wc)
        for e in wc.editorArea.tab.editors { e.jumpBar.layoutSubtreeIfNeeded() }
        return (wc, dir)
    }

    // MARK: Row 142: the space after a word must fit, at the split

    @Test func spaceRuleAtTheSplit() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, dir) = try r5.window("r6-wrap")
        defer { wc.window?.close() }
        let file = dir.appendingPathComponent("GlassScroll/Wrap.swift")
        try "import Foundation\n\n Block 00, line 0: a comment line 0 that keeps going on\n".write(to: file, atomically: true, encoding: .utf8)
        wc.open(path: file.path, line: nil)
        wc.split(sideBySide: true)
        r5.layout(wc)
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: false)
        r5.layout(wc)
        for e in wc.editorArea.tab.editors {
            #expect(r5.columns(e) == 17)
            let tlm = try #require(e.textView.textLayoutManager)
            let text = e.textView.string as NSString
            var rows: [String] = []
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
                let o = tlm.offset(from: tlm.documentRange.location, to: f.rangeInElement.location)
                for l in f.textLineFragments {
                    rows.append(text.substring(with: NSRange(location: o + l.characterRange.location, length: l.characterRange.length)))
                }
                return true
            }
            // "import Foundation" fits at column 17; "0: a" / "comment".
            #expect(rows.first == "import Foundation\n")
            #expect(Array(rows.dropFirst(2).prefix(4)) == [" Block 00, line ", "0: a ", "comment ", "line 0 that "], "\(rows)")
        }
        Self.shot(try #require(wc.window?.contentView), "mac-r6-wrap-1100")
    }

    // MARK: Row 143: the path's spacing

    @Test func pathSpacingByInk() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, _) = try split("r6-spacing", width: 1400)
        defer { wc.window?.close() }
        let bar = try #require(wc.editorArea.tab.editors.first).jumpBar
        let ink = bar.pathInk
        // icon title › icon title › icon title › No Selection
        #expect(ink.count == 10, "\(ink.count)")
        guard ink.count == 10 else { return }
        func gap(_ i: Int) -> CGFloat { ink[i + 1].minX - ink[i].maxX }
        let report = ink.map { String(format: "%.1f–%.1f", $0.minX, $0.maxX) }.joined(separator: " ")
        for i in [0, 3, 6] { #expect(abs(gap(i) - 6) <= 0.75, "icon to title \(i): \(report)") }
        for i in [1, 4, 7] { #expect(abs(gap(i) - 7) <= 0.75, "title to chevron \(i): \(report)") }
        for i in [2, 5] { #expect(abs(gap(i) - 10.5) <= 0.75, "chevron to icon \(i): \(report)") }
        #expect(abs(gap(8) - 9.5) <= 0.75, "chevron to No Selection: \(report)")
        for i in [2, 5, 8] { #expect(ink[i].maxX - ink[i].minX == 2, "chevron \(i)") }
        // The pixels agree: the ink runs of the bar hold each element's ink.
        let runs = Self.inkRuns(bar, rows: 4...26)
        for e in ink where e.view is JumpBarChevronView {
            #expect(runs.contains { abs($0.0 - e.minX) <= 0.5 && abs($0.1 - e.maxX) <= 0.5 }, "chevron \(e.minX)")
        }
        // The path starts where it did (+71.5 in the pane, E.2).
        #expect(abs(ink[0].minX - 71.5) <= 0.5, "\(report)")
        Self.shot(bar, "mac-r6-jumpbar-1400")
    }

    // MARK: Rows 144, 145: the collapse order and the last item's colour

    @Test func collapseOrderAt1100() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, _) = try split("r6-collapse", width: 1100)
        defer { wc.window?.close() }
        for (k, e) in wc.editorArea.tab.editors.enumerated() {
            let bar = e.jumpBar
            let parts = bar.pathState.parts
            #expect(parts.count == 3)
            guard parts.count == 3, let last = bar.pathState.last else { continue }
            // (1) the project's and group's titles go, their icons stay.
            #expect(parts[0].title.isHidden && parts[1].title.isHidden)
            #expect(parts.allSatisfy { $0.icon.map { !$0.isHidden } ?? false })
            // (2) the file's title is cut with a fade.
            let cut = parts[2].title.inkCut
            #expect(!parts[2].title.isHidden && cut.map { $0 >= JumpBarPathLayout.minimumCut && $0 < parts[2].title.ink.width } == true, "\(String(describing: cut))")
            #expect(parts[2].title.layer?.mask is CAGradientLayer)
            // (3) "No Selection" whole, its ink 23 inside the pane's edge.
            #expect(last.stringValue == "No Selection" && last.inkCut == nil && !last.isHidden)
            let end = try #require(bar.pathInk.last).maxX
            #expect(end <= bar.bounds.width - 23 + 0.5 && end >= bar.bounds.width - 23 - 2, "ends \(end) in \(bar.bounds.width)")
            // Row 145: in the path's colour, grey in the pane without focus.
            #expect(last.textColor == bar.pathTextColor && parts[2].title.textColor == bar.pathTextColor)
            Self.shot(bar, "mac-r6-jumpbar-1100-pane\(k)")
        }
        // Back at 1400 every title shows whole.
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false)
        r5.layout(wc)
        let bar = try #require(wc.editorArea.tab.editors.first).jumpBar
        bar.layoutSubtreeIfNeeded()
        #expect(bar.pathState.parts.allSatisfy { !$0.title.isHidden && $0.title.inkCut == nil })
    }

    /// Row 145 alone: "No Selection" after a path is in the item colour.
    @Test func noSelectionInThePathColour() throws {
        let (wc, dir) = try r5.window("r6-colour")
        defer { wc.window?.close(); Theme.backingScaleOverride = nil }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Stripes.png").path, line: nil)
        r5.layout(wc)
        let bar = wc.editor.jumpBar
        let last = try #require(bar.pathState.last)
        #expect(last.stringValue == "No Selection" && last.textColor == .labelColor)
    }
}
