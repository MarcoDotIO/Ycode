import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 9, group B (`specs/ide/fidelity-council.md` rows 220–227)
/// in the macOS IDE: the editor's top line while the inspector slides (row
/// 223, the regression), the slide's pacing and the show's start (224), the
/// caret and scroll position kept per document (226) and instance
/// highlighting only for symbols in code (227).
@MainActor
@Suite(.serialized) struct CouncilRound9MotionTests {
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    /// The council's window (1400 × 880) off every display with Long.swift open.
    func window(_ tag: String) throws -> (WorkspaceWindowController, URL) {
        let dir = try CouncilRound8MotionTests.project("r9-\(tag)")
        let wc = try CouncilRound8MotionTests.window(dir)
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        spin(0.2)
        return (wc, dir)
    }

    /// The first visible character's place: its logical line (1-based) and
    /// the points from its first row's top to the visible area's top (at
    /// or below 0 with line 1 at the top).
    func firstVisible(_ e: SourceEditorController) -> (line: Int, y: CGFloat) {
        guard let a = e.textView.topAnchor() else { return (0, 0) }
        return (a.line, a.into)
    }

    /// One frame of the slide, as a display steps it.
    func frame(_ wc: WorkspaceWindowController, _ p: CGFloat) {
        wc.inspectorSlide.onFrame?(p)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.window?.displayIfNeeded()
        RunLoop.main.run(until: Date())
    }

    // MARK: Row 223: the top line stays while the editor's width changes

    /// Main 10 with line 1 at the top: through the hide, frame by frame, and
    /// after its end the first line stays at the top and the text re-wraps
    /// on every frame (the container's width follows the editor's).
    @Test func hideKeepsLineOneAtTheTop() throws {
        let (wc, _) = try window("top")
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let e = wc.editor
        let start = firstVisible(e)
        let origin = e.scrollView.contentView.bounds.minY
        #expect(start.line == 1)
        InspectorSlideState.defersEndOffscreen = true
        defer { InspectorSlideState.defersEndOffscreen = false }
        wc.toggleInspector(nil)
        #expect(wc.isInspectorSliding)
        wc.inspectorSlide.link?.invalidate()
        wc.inspectorSlide.link = nil
        var widths: [CGFloat] = []
        for p in stride(from: 0.1, through: 1.0, by: 0.1) {
            frame(wc, CGFloat(p))
            widths.append(e.textView.textContainer?.size.width ?? 0)
            #expect(firstVisible(e).line == 1, "progress \(p)")
            #expect(abs(e.scrollView.contentView.bounds.minY - origin) < 0.5, "progress \(p): \(e.scrollView.contentView.bounds.minY)")
        }
        spin(0.5) { !wc.isInspectorSliding }
        spin(0.2)
        let end = firstVisible(e)
        print("R9B row 223 hide at the top: widths \(widths.map { Int($0) }); first line \(start) → \(end); origin \(origin) → \(e.scrollView.contentView.bounds.minY)")
        #expect(end.line == 1)
        #expect(abs(e.scrollView.contentView.bounds.minY - origin) < 0.5)
        // A re-wrap on every frame: the container widens with each one.
        #expect(zip(widths, widths.dropFirst()).filter { $1 > $0 + 0.5 }.count >= 7, "\(widths)")
        // The show brings it back under the same top line.
        wc.toggleInspector(nil)
        wc.inspectorSlide.link?.invalidate()
        wc.inspectorSlide.link = nil
        for p in stride(from: 0.1, through: 1.0, by: 0.1) {
            frame(wc, CGFloat(p))
            #expect(firstVisible(e).line == 1, "show \(p)")
        }
        spin(0.5) { !wc.isInspectorSliding }
        spin(0.2)
        #expect(firstVisible(e).line == 1)
        #expect(abs(e.scrollView.contentView.bounds.minY - origin) < 0.5)
    }

    /// A scroll the system makes during the slide or just after it (its
    /// insertion point scrolled into view under the jump bar: the top line
    /// became line 6, about 93 points, on screen) is undone: line 1 is at
    /// the top again by the slide's end, and stays.
    @Test func aSystemScrollDuringTheSlideIsUndone() throws {
        let (wc, _) = try window("system-scroll")
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let e = wc.editor
        let clip = e.scrollView.contentView
        let origin = clip.bounds.minY
        InspectorSlideState.defersEndOffscreen = true
        defer { InspectorSlideState.defersEndOffscreen = false }
        wc.toggleInspector(nil)
        wc.inspectorSlide.link?.invalidate()
        wc.inspectorSlide.link = nil
        for p in stride(from: 0.1, through: 1.0, by: 0.1) {
            frame(wc, CGFloat(p))
            if abs(p - 0.3) < 0.01 {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: origin + 93))
                e.scrollView.reflectScrolledClipView(clip)
            }
        }
        spin(0.5) { !wc.isInspectorSliding }
        spin(0.02)
        // And once more just after the end.
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: origin + 93))
        e.scrollView.reflectScrolledClipView(clip)
        let moved = clip.bounds.minY
        spin(0.2)
        print("R9B row 223 system scroll: origin \(origin), after the slide \(clip.bounds.minY) (moved to \(moved) after its end)")
        #expect(abs(clip.bounds.minY - origin) < 0.5, "\(clip.bounds.minY)")
        #expect(firstVisible(e).line == 1)
    }

    /// The same mid-file: the first visible logical line stays at the top,
    /// at the same depth into its first row.
    @Test func hideKeepsTheTopLineMidFile() throws {
        let (wc, _) = try window("mid")
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let e = wc.editor
        let clip = e.scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 900))
        e.scrollView.reflectScrolledClipView(clip)
        let start = firstVisible(e)
        InspectorSlideState.defersEndOffscreen = true
        defer { InspectorSlideState.defersEndOffscreen = false }
        wc.toggleInspector(nil)
        wc.inspectorSlide.link?.invalidate()
        wc.inspectorSlide.link = nil
        for p in stride(from: 0.1, through: 1.0, by: 0.1) {
            frame(wc, CGFloat(p))
            #expect(firstVisible(e).line == start.line, "progress \(p)")
        }
        spin(0.5) { !wc.isInspectorSliding }
        spin(0.2)
        let end = firstVisible(e)
        print("R9B row 223 hide mid-file: \(start) → \(end)")
        #expect(end.line == start.line)
        #expect(abs(end.y - start.y) < 1)
    }

    // MARK: Row 226: each document keeps its caret and scroll position

    /// Owner 08, 09: Long.swift's caret at line 9, column 46, the text
    /// scrolled; another file shown, then Long.swift again: the caret, the
    /// status bar's line and column and the top line come back. A file shown
    /// for the first time starts at line 1, column 1.
    @Test func showingAFileAgainRestoresItsCaretAndTopLine() throws {
        let (wc, dir) = try window("caret")
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let e = wc.editor
        let long = dir.appendingPathComponent("GlassScroll/Long.swift").path
        let bands = dir.appendingPathComponent("GlassScroll/Bands.swift").path
        // Line 11 is a long comment line in this fixture (column 46 exists).
        let line9 = try #require(e.textView.lineIndex.range(ofLine: 11))
        let caret = NSRange(location: line9.location + min(45, line9.length), length: 0)
        e.textView.setSelectedRange(caret)
        let clip = e.scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 1200))
        e.scrollView.reflectScrolledClipView(clip)
        let top = firstVisible(e)
        wc.open(path: bands, line: nil)
        #expect(e.textView.selectedRange() == NSRange(location: 0, length: 0), "a first open starts at line 1, column 1")
        #expect(e.caretPosition.line == 0 && e.caretPosition.character == 0)
        wc.open(path: long, line: nil)
        let atOpen = firstVisible(e)
        spin(0.1)
        let p = e.caretPosition
        print("R9B row 226: top at the open \(atOpen), remembered \(String(describing: e.places.byPath.mapValues { $0.top }))")
        print("R9B row 226: caret \(e.textView.selectedRange()) (line \(p.line + 1), col \(p.character + 1)); top \(top) → \(firstVisible(e))")
        #expect(e.textView.selectedRange() == caret)
        #expect(p.line == 10 && p.character == 45)
        #expect(firstVisible(e).line == top.line)
        #expect(abs(firstVisible(e).y - top.y) < 1)
        // Bands.swift kept its own (line 1, at the top).
        wc.open(path: bands, line: nil)
        #expect(e.textView.selectedRange() == NSRange(location: 0, length: 0))
        #expect(firstVisible(e).line == 1)
    }

    // MARK: Row 227: instances of a symbol, never words in comments

    /// Owner 04: a click on "enough" inside a comment highlights nothing; a
    /// click on an identifier in code highlights its instances in code
    /// only (not the same word in a comment or a string).
    @Test func instanceHighlightingOnlyForSymbolsInCode() throws {
        let (wc, dir) = try window("instances")
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let e = wc.editor
        let url = dir.appendingPathComponent("GlassScroll/Comments.swift")
        let text = """
        /* This block comment is long enough
           to hold the word enough on enough lines. */
        let enough = 1
        let total = enough + enough // enough
        let label = "enough"

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        wc.open(path: url.path, line: nil)
        let ns = e.textView.string as NSString
        // The caret inside "enough" on the comment's first line.
        let inComment = ns.range(of: "enough").location + 2
        e.textView.setSelectedRange(NSRange(location: inComment, length: 0))
        e.applySymbolHighlight("enough")
        #expect(e.highlightedSymbol == nil)
        #expect(e.highlightedOccurrences.isEmpty, "\(e.highlightedOccurrences)")
        // The caret in the declaration "let enough".
        let decl = ns.range(of: "let enough").location + 6
        e.textView.setSelectedRange(NSRange(location: decl, length: 0))
        e.applySymbolHighlight("enough")
        let found = e.highlightedOccurrences
        print("R9B row 227: in a comment none; in code \(found.count) instances: \(found)")
        #expect(e.highlightedSymbol == "enough")
        #expect(found.count == 3, "\(found)")
        #expect(found.allSatisfy { ns.substring(with: $0) == "enough" && $0.location > ns.range(of: "*/").location })
        #expect(!found.contains { $0.location > ns.range(of: "//").location })
    }

    // MARK: Stills (R9_SHOTS=1): .build-ide/b9-shots

    /// The new states drawn off screen in dark: line 1 at the top mid-hide
    /// and after it, the caret restored, the instances of a symbol in code
    /// and none for a word in a comment.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R9_SHOTS"] != nil))
    func stills() throws {
        let (wc, dir) = try window("shots")
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/b9-shots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot(_ name: String) {
            guard let v = wc.window?.contentView?.superview ?? wc.window?.contentView else { return }
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            print("R9B shot \(out.appendingPathComponent("\(name).png").path)")
        }
        let e = wc.editor
        InspectorSlideState.defersEndOffscreen = true
        defer { InspectorSlideState.defersEndOffscreen = false }
        shot("mac-r9-223-rest")
        wc.toggleInspector(nil)
        wc.inspectorSlide.link?.invalidate()
        wc.inspectorSlide.link = nil
        for p in stride(from: 0.1, through: 0.5, by: 0.1) { frame(wc, CGFloat(p)) }
        shot("mac-r9-223-hide-mid")
        for p in stride(from: 0.6, through: 1.0, by: 0.1) { frame(wc, CGFloat(p)) }
        spin(0.5) { !wc.isInspectorSliding }
        spin(0.2)
        shot("mac-r9-223-hidden")
        // Row 227.
        let url = dir.appendingPathComponent("GlassScroll/Comments.swift")
        try "/* This block comment is long enough\n   to hold the word enough on enough lines. */\nlet enough = 1\nlet total = enough + enough // enough\nlet label = \"enough\"\n"
            .write(to: url, atomically: true, encoding: .utf8)
        wc.open(path: url.path, line: nil)
        let ns = e.textView.string as NSString
        e.textView.setSelectedRange(NSRange(location: ns.range(of: "enough").location + 2, length: 0))
        e.applySymbolHighlight("enough")
        shot("mac-r9-227-comment")
        e.textView.setSelectedRange(NSRange(location: ns.range(of: "let enough").location + 6, length: 0))
        e.applySymbolHighlight("enough")
        shot("mac-r9-227-code")
        // Row 226.
        let long = dir.appendingPathComponent("GlassScroll/Long.swift").path
        wc.open(path: long, line: nil)
        if let r = e.textView.lineIndex.range(ofLine: 11) { e.textView.setSelectedRange(NSRange(location: r.location + 45, length: 0)) }
        wc.open(path: url.path, line: nil)
        wc.open(path: long, line: nil)
        spin(0.2)
        shot("mac-r9-226-caret-restored")
    }
}
