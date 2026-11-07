import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI
import YcodeSyntax

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Council round 2 (`specs/ide/fidelity-council.md`): the Welcome window
/// (row 45), the minimap's bars (row 8), the module name after `import`
/// (row 48) and the top bounce (row 40). The toolbar overflow (row 34) is
/// in `ToolbarIssuesR39R41Tests`.
@MainActor
@Suite(.serialized) struct CouncilRound2Glass3Tests {
    func editor(_ text: String, name: String = "Bounce.swift") throws -> (WorkspaceWindowController, SourceEditorController) {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/g3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"G\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                           startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 880), display: false)
        wc.open(path: file.path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.editor.view.layoutSubtreeIfNeeded()
        return (wc, wc.editor)
    }

    // MARK: Row 45: Welcome window

    @Test func welcomeTitleIsCapHeight13() throws {
        guard #available(macOS 26, *) else { return }
        _ = NSApplication.shared
        let td = TestDefaults("g3-welcome-title")
        defer { td.remove() }
        let w = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        defer { w.window?.close() }
        let font = try #require(w.nameLabel.font)
        #expect(abs(font.capHeight - 13) < 0.3, "cap height \(font.capHeight) at \(font.pointSize)")
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        let content = try #require(w.window?.contentView)
        content.layoutSubtreeIfNeeded()
        // Baselines 38 (name) and 19 (version) above the buttons' top.
        let top = content.bounds.height
        let nameBaseline = top - (w.nameLabel.frame.minY + w.nameLabel.baselineOffsetFromBottom)
        let versionBaseline = top - (w.versionLabel.frame.minY + w.versionLabel.baselineOffsetFromBottom)
        #expect(abs(nameBaseline - (WelcomeWindowController.buttonsTop - 38)) < 1, "\(nameBaseline)")
        #expect(abs(versionBaseline - (WelcomeWindowController.buttonsTop - 19)) < 1, "\(versionBaseline)")
        // "Ycode" is about as wide as the reference's 49-point name.
        #expect(w.nameLabel.intrinsicContentSize.width < 70)
    }

    @Test func welcomeRowsSeparatorsAndPaths() throws {
        guard #available(macOS 26, *) else { return }
        _ = NSApplication.shared
        let td = TestDefaults("g3-welcome-rows")
        defer { td.remove() }
        let recents = RecentProjects(defaults: td.defaults)
        let base = ycodeDir.appendingPathComponent(".build-ide/g3-recents")
        for n in ["One", "Two", "Three"] {
            let p = base.appendingPathComponent("captures/2026-11-04-council-r2-full/xcode/project/\(n).xcodeproj")
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            recents.note(p)
        }
        let w = WelcomeWindowController(recents: recents)
        defer { w.window?.close() }
        w.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(w.entries.count == 3)
        // 47-point pitch.
        #expect(abs(w.table.rect(ofRow: 1).minY - w.table.rect(ofRow: 0).minY - 47) < 0.01)
        // Separators under the text: from x 56 to 14 before the box's edge,
        // none under the last row, none touching the selected row.
        let width = w.recentsBox.frame.width
        let rows = (0..<3).map { r -> RecentRowView in
            let v = try! #require(w.tableView(w.table, rowViewForRow: r) as? RecentRowView)
            v.frame = NSRect(x: 0, y: 0, width: width, height: 47)
            return v
        }
        rows[1].isSelected = false
        let sep = try #require(rows[1].separatorRect)
        #expect(sep.minX == 56 && sep.maxX == width - 14 && sep.height == 1)
        #expect(rows[2].separatorRect == nil)
        rows[0].isSelected = true
        #expect(rows[0].separatorRect == nil)
        rows[1].isNextRowSelected = true
        #expect(rows[1].separatorRect == nil)
        // The path keeps its end.
        let cell = try #require(w.tableView(w.table, viewFor: nil, row: 0) as? NSTableCellView)
        let path = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first { $0 !== cell.textField })
        #expect(path.lineBreakMode == .byTruncatingHead)
        #expect(path.stringValue.hasSuffix("captures/2026-11-04-council-r2-full/xcode/project"))
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Row 8: one minimap bar per token

    @Test func minimapBarsFollowTokens() throws {
        let text = "// Section 1: a comment block\n    let s = \"two words\"  \nstruct A {}\n"
        let storage = NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.black])
        let doc = SyntaxDocument(text: text, language: .swift)
        let tokens = MinimapView.tokenInteriors(doc.tokens(in: 0..<(text as NSString).length))
        let rows = MinimapView.rows(of: storage, columns: 200, tabWidth: 4, wraps: false, tokens: tokens)
        // The whole comment, spaces included, is one bar.
        #expect(rows[0].count == 1 && rows[0][0].column == 0 && rows[0][0].length == 29, "\(rows[0])")
        // Code breaks between tokens; the string is one bar; indentation
        // and trailing spaces are not drawn.
        #expect(rows[1].map(\.column) == [4, 8, 10, 12] && rows[1].last?.length == 11, "\(rows[1])")
        #expect(rows[2].map(\.column) == [0, 7, 9], "\(rows[2])")
        // Without tokens (plain text) every word is a bar.
        let plain = MinimapView.rows(of: storage, columns: 200, tabWidth: 4, wraps: false)
        #expect(plain[0].count == 6)
    }

    @Test func editorMinimapUsesTheSyntaxTokens() throws {
        let (wc, e) = try editor("import Foundation\n// a comment with several words\nlet x = 1\n")
        defer { wc.window?.close() }
        e.showsMinimap = true
        e.updateMinimapRows()
        #expect(e.minimap.rows.count >= 3)
        #expect(e.minimap.rows[1].count == 1, "\(e.minimap.rows[1])")
        #expect(e.minimap.rows[2].count == 4, "\(e.minimap.rows[2])")
    }

    // MARK: Row 48: `import Foundation`

    @Test func importedModuleIsPlainText() throws {
        let (wc, e) = try editor("import Foundation\nlet d: Date = Date()\n")
        defer { wc.window?.close() }
        let storage = try #require(e.textView.textStorage)
        let ns = storage.string as NSString
        func color(of word: String, from: Int = 0) -> NSColor? {
            let r = ns.range(of: word, range: NSRange(location: from, length: ns.length - from))
            return storage.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor
        }
        let typeColor = Theme.color(for: .typeName)
        let plain = storage.attribute(.foregroundColor, at: ns.range(of: " ").location, effectiveRange: nil) as? NSColor
        #expect(color(of: "Foundation") == plain && color(of: "Foundation") != typeColor)
        #expect(color(of: "Date") == typeColor || color(of: "Date") != plain)
    }

    // MARK: Row 40: the top bounce

    @Test func bounceSpringMatchesTheReference() {
        // Round 3 (editor-area.md E.1) superseded round 2's single spring:
        // a run past the top (peak about 67 ms after the crossing), then
        // the critically damped return at round 2's ω 12.6.
        #expect(TopBounce.omega == 12.6)
        // The reference's 48-point overshoot: a crossing at about 2470 pt/s.
        let v = TopBounce.velocity(forPeak: 48)
        #expect(abs(v - 2470) < 60, "\(v)")
        #expect(abs(TopBounce.peakTime - 0.067) < 0.001)
        #expect(abs(TopBounce.overscroll(velocity: v, at: TopBounce.peakTime) - 48) < 0.01)
        // From the peak it is the critically damped spring peak·(1+ωt)e^(−ωt).
        for t in stride(from: 0.0, through: 0.6, by: 0.05) {
            let spring = 48 * (1 + 12.6 * t) * exp(-12.6 * t)
            #expect(abs(TopBounce.overscroll(velocity: v, at: TopBounce.peakTime + t) - spring) < 0.01)
        }
        // Half gone about 140 ms after the peak; within a point 440 ms after it.
        #expect(TopBounce.overscroll(velocity: v, at: TopBounce.peakTime + 0.15) < 24)
        #expect(TopBounce.overscroll(velocity: v, at: TopBounce.peakTime + 0.44) < 1.3)
        let d = TopBounce.duration(velocity: v)
        #expect(d > 0.55 && d < 0.75, "\(d)")
        // A very fast flick is limited to a quarter of the view.
        #expect(abs(TopBounce.peak(velocity: TopBounce.effectiveVelocity(50_000, visibleHeight: 800)) - 200) < 0.01)
        #expect(TopBounce.effectiveVelocity(v, visibleHeight: 800) == v)
    }

    @Test func velocityTracker() {
        var t = TopBounce.VelocityTracker()
        for i in 0..<10 { t.add(30, at: Double(i) * 0.01) }
        #expect(abs(t.velocity - 3000) < 1 && t.hasSample)
        t.add(0, at: 0.5)   // no motion: ignored
        #expect(abs(t.velocity - 3000) < 1)
        t.reset()
        #expect(t.velocity == 0)
    }

    /// A momentum flick toward the top, as scroll events: the bounce takes
    /// over at the crossing, runs past the top and settles back on it.
    @Test func momentumFlickBouncesAtTheTop() throws {
        var text = ""
        for i in 0..<300 { text += "let value\(i) = \(i)\n" }
        let (wc, e) = try editor(text)
        defer { wc.window?.close() }
        let scroll = try #require(e.scrollView as? EditorScrollView)
        let clip = scroll.contentView
        let top = EditorTopBounce.top(of: scroll)
        clip.scroll(to: NSPoint(x: 0, y: top + 20))   // the first momentum event crosses
        scroll.reflectScrolledClipView(clip)
        var frames: [CGFloat] = []
        // How far past the top each frame drew the text, against the top
        // at that frame (a layout pass may move the top inset meanwhile).
        var deepest: CGFloat = 0
        scroll.topBounce.onFrame = { frames.append($0); deepest = max(deepest, EditorTopBounce.top(of: scroll) - clip.bounds.minY) }
        // Events 10 ms apart: a gesture, then momentum of 30 points each
        // (3000 pt/s) until the top is crossed, then the momentum's tail.
        let t0 = ProcessInfo.processInfo.systemUptime
        var sent = 0
        func send(_ delta: Double, phase: Int64, momentum: Int64) {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: delta)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            cg.timestamp = CGEventTimestamp((t0 + Double(sent) * 0.01) * 1e9)
            sent += 1
            if let ev = NSEvent(cgEvent: cg) {
                scroll.scrollWheel(with: ev)
            }
        }
        send(30, phase: 1, momentum: 0)
        send(30, phase: 2, momentum: 0)
        send(0, phase: 4, momentum: 0)
        send(30, phase: 0, momentum: 1)
        var guardCount = 0
        while !scroll.topBounce.isRunning, guardCount < 40 {
            send(30, phase: 0, momentum: 2)
            guardCount += 1
        }
        #expect(scroll.topBounce.isRunning)
        for _ in 0..<5 { send(10, phase: 0, momentum: 2) }   // swallowed
        send(0, phase: 0, momentum: 3)
        let deadline = Date().addingTimeInterval(2)
        while scroll.topBounce.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        #expect(!scroll.topBounce.isRunning)
        #expect(abs(clip.bounds.minY - top) < 0.5, "rests at \(clip.bounds.minY), top \(top)")
        let peak = scroll.topBounce.lastPeak
        print("bounce: peak \(peak) over \(frames.count) frames, view \(clip.bounds.height)")
        // About 3000 pt/s gives about 57 points (editor-area.md E.1); the
        // frames sample it, so a peak short of it is only possible when the
        // frames are sparse (a loaded machine) and never above it.
        #expect(peak < 65, "peak \(peak)")
        if frames.count >= 15 { #expect(peak > 40, "peak \(peak) over \(frames.count) frames") }
        // The text really moved past the top by the peak, within a device
        // pixel: the clip view's origin snaps to the backing (whole points on
        // a 1x CI runner: 55.0 drawn for a 54.497 peak).
        let pixel = 1 / (scroll.window?.backingScaleFactor ?? 1)
        #expect(abs(deepest - peak) <= pixel, "deepest \(deepest), peak \(peak), pixel \(pixel)")
    }
}
