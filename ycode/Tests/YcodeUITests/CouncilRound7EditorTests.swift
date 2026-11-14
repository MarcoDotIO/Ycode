import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI
import YcodeSyntax

/// Council round 7, group B: editor scrolling and text on the macOS IDE
/// (`specs/ide/fidelity-council.md` rows 176–181; `editor-area.md`
/// I.1–I.6): momentum to the edge, the stretch, the final empty line, the
/// inactive pane across a re-wrap, the jump bar at 1250 and 1180, the
/// scroller knob. Windows lay out off every display; none is ordered in.
@MainActor
@Suite(.serialized) struct CouncilRound7EditorTests {
    let r5 = CouncilRound5EditorTests()
    let r6 = CouncilRound6ChromeTests()

    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    /// Writes a view's pixels to `.build-ide/b7-shots/<name>.png`.
    static func shot(_ v: NSView, _ name: String) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/b7-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    static func event(_ d: Double, phase: Int64, momentum: Int64, at t: Double) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(d.rounded()), wheel2: 0, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: d)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: d)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.timestamp = CGEventTimestamp(t * 1e9)
        return NSEvent(cgEvent: cg)
    }

    /// A gesture of `count` events of `step` points 8.3 ms apart, its end,
    /// then `points` of momentum over `span` seconds in `n` events decaying
    /// with a 0.33 s time constant, and the momentum's end (I.1's inputs;
    /// positive points scroll towards the top).
    static func flick(step: Double, count: Int, points: Double, n: Int, span: Double, t0: Double) -> [NSEvent] {
        var out: [NSEvent?] = []
        for i in 0..<count { out.append(event(step, phase: i == 0 ? 1 : 2, momentum: 0, at: t0 + Double(i) * 0.0083)) }
        let g = t0 + Double(count) * 0.0083
        out.append(event(0, phase: 4, momentum: 0, at: g))
        let tau = 0.33, dt = span / Double(n)
        let v0 = abs(points) / (tau * (1 - exp(-span / tau))) * (points < 0 ? -1 : 1)
        for i in 0..<n {
            let a = Double(i) * dt
            out.append(event(v0 * tau * (exp(-a / tau) - exp(-(a + dt) / tau)), phase: 0, momentum: i == 0 ? 1 : 2, at: g + 0.004 + a))
        }
        out.append(event(0, phase: 0, momentum: 3, at: g + 0.004 + span))
        return out.compactMap { $0 }
    }

    /// Feeds events one call each, as AppKit dispatches them, with the
    /// queue left alone.
    func feed(_ events: [NSEvent], to scroll: EditorScrollView) {
        let saved = EditorScrollView.nextQueuedEvent
        EditorScrollView.nextQueuedEvent = { _ in nil }
        defer { EditorScrollView.nextQueuedEvent = saved }
        for e in events { scroll.scrollWheel(with: e) }
    }

    // MARK: Row 176: momentum to the edge

    /// X05: the slow flick (1800 points per second, 566.7 points of
    /// momentum). Off every display the system's scroll view does not move
    /// for synthesized gesture events, so the text starts where the gesture
    /// would have left it (120 below the reference's 600: 480 from the top).
    /// Round 9 (row 221, superseding round 8's row 205): every momentum
    /// delta applies, so the text reaches the top with little speed and
    /// stretches a few points past it.
    @Test func slowFlickReachesTheTop() throws {
        let (wc, _) = try r6.longWindow("r7-slow")
        defer { wc.window?.orderOut(nil) }
        let scroll = try #require(wc.editor.scrollView as? EditorScrollView)
        let clip = scroll.contentView
        let top = EditorTopBounce.top(of: scroll)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top + 480))
        scroll.reflectScrolledClipView(clip)
        let x05 = Self.flick(step: 15, count: 8, points: 566.7, n: 134, span: 1.11, t0: ProcessInfo.processInfo.systemUptime)
        // These synthesized events carry whole points, cut towards zero
        // (497 of the 566.7 momentum points): the editor applies what
        // `EditorMomentum` makes of them, the share fitted to the reference.
        let mom = x05.filter { !$0.momentumPhase.isEmpty }.map { (time: $0.timestamp, dy: Double($0.scrollingDeltaY)) }
        let model = EditorMomentum.distance(of: mom, gestureSpeed: 15 / 0.0083).distance
        feed(x05, to: scroll)
        let applied = scroll.topBounce.appliedMomentum
        spin(1.5) { !scroll.topBounce.isRunning }
        let peak = scroll.topBounce.lastPeak
        print("R9B X05: applied \(applied) of 480 to the top (the model \(model)), stretch \(peak), at \(clip.bounds.minY - top)")
        // Every delta up to the crossing (the crossing's own delta runs on
        // into the stretch).
        #expect(applied > 440 && applied <= 480.5, "\(applied)")
        #expect(model > 480, "\(model)")
        #expect(peak > 1 && peak < 12 && !scroll.topBounce.isRunning, "\(peak)")
        #expect(abs(clip.bounds.minY - top) < 0.5)
    }

    /// X03: main 04's flick mirrored, from 280 above the bottom (600 less
    /// the gesture's 320): every momentum delta to the bottom, then the
    /// stretch past it (the same law as at the top) and back.
    @Test func bottomFlickReachesTheBottom() throws {
        let (wc, _) = try r6.longWindow("r7-bottom")
        defer { wc.window?.orderOut(nil) }
        let scroll = try #require(wc.editor.scrollView as? EditorScrollView)
        let clip = scroll.contentView
        let bottom = EditorTopBounce.bottom(of: scroll)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom - 280))
        scroll.reflectScrolledClipView(clip)
        var frames: [CGFloat] = []
        scroll.topBounce.onFrame = { frames.append($0) }
        feed(Self.flick(step: -40, count: 8, points: -1544, n: 173, span: 1.43, t0: ProcessInfo.processInfo.systemUptime), to: scroll)
        let applied = scroll.topBounce.appliedMomentum
        #expect(scroll.topBounce.edge == .bottom)
        spin(1.5) { !scroll.topBounce.isRunning }
        let peak = scroll.topBounce.lastPeak
        let visible = clip.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        print("R8B X03: applied \(applied) of 280, stretch \(peak) past the bottom (cap \(visible * TopBounce.maximumShare)), frames \(frames.count)")
        #expect(abs(applied - (280 - 40)) < 1, "\(applied)")
        // Round 9 (row 222): 32 ± 4 past the end (frames sample the peak).
        #expect(peak > 26 && peak < 40, "\(peak)")
        #expect(frames.allSatisfy { $0 >= 0 })
        #expect(abs(clip.bounds.minY - bottom) < 0.5 && !scroll.topBounce.isRunning)
    }

    // MARK: Row 177: the stretch's law

    /// About 35 for main 04's crossing (round 9, row 220, superseding round
    /// 8's 190), a few points for a slow arrival, growing more slowly than
    /// the speed left; the return at ω 11.3 at the top.
    @Test func stretchGrowsWithTheMomentumLeft() {
        #expect(abs(TopBounce.stretch(forCrossing: TopBounce.referenceVelocity) - 35) < 0.01)
        let slow = TopBounce.stretch(forCrossing: 330)
        #expect(slow > 3 && slow < 8, "\(slow)")
        let crossing = TopBounce.referenceVelocity
        let peak = TopBounce.peak(velocity: TopBounce.effectiveVelocity(crossing, visibleHeight: 760))
        print("R8B stretch: main 04 crosses at \(Int(crossing)) points per second, stretch \(peak); slow arrival \(slow)")
        #expect(abs(peak - 35) < 0.5, "\(peak)")
        // Twice the speed less than doubles the stretch: a power below 1.
        let ratio = TopBounce.stretch(forCrossing: 2000) / TopBounce.stretch(forCrossing: 1000)
        #expect(ratio > 1.4 && ratio < 2)
        #expect(TopBounce.omega == 11.3)
    }

    // MARK: Row 178: the final empty line

    /// Long.swift ends with a line break: one more line, numbered, its row
    /// right under the last text row, able to hold the insertion point
    /// (⌘↓), with the current-line band; at the maximum offset its bottom
    /// rises to the text area's middle (within 3 points).
    @Test func finalEmptyLineIsALine() throws {
        let (wc, _) = try r6.longWindow("r7-final")
        defer { wc.window?.orderOut(nil) }
        // Dark, as round 7 was captured (the band #353535 on #252625).
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        let ed = wc.editor
        let tv = ed.textView
        let lines = tv.lineIndex.lineCount
        #expect(tv.endsWithLineBreak && tv.lineIndex.range(ofLine: lines)?.length == 0)
        let last = try #require(tv.lineRect(lines))
        let before = try #require(tv.lineRect(lines - 1))
        #expect(abs(last.minY - before.maxY) < 0.5 && abs(last.height - Theme.lineHeight) < 0.5, "\(before) \(last)")
        // ⌘↓ puts the insertion point on it.
        tv.moveToEndOfDocument(nil)
        #expect(ed.currentLine == lines && tv.caretLine == lines && ed.gutter.caretLine == lines)
        // At the maximum offset.
        let scroll = try #require(ed.scrollView as? EditorScrollView)
        let clip = scroll.contentView
        let bottom = EditorTopBounce.bottom(of: scroll)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
        scroll.reflectScrolledClipView(clip)
        wc.window?.displayIfNeeded()
        let rows = ed.gutter.visibleLines()
        #expect(rows.last?.line == lines, "\(rows.suffix(3).map(\.line))")
        let window = try #require(wc.window)
        let rowInWindow = tv.convert(last, to: nil)
        let rowBottom = window.contentView!.bounds.height - rowInWindow.minY
        let area = scroll.convert(NSRect(x: 0, y: scroll.contentInsets.top, width: 1, height: clip.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom), to: nil)
        let areaTop = window.contentView!.bounds.height - area.maxY, areaBottom = window.contentView!.bounds.height - area.minY
        let middle = (areaTop + areaBottom) / 2
        print("R7B final line: \(lines), row bottom \(rowBottom) at the maximum, text area \(areaTop)–\(areaBottom), middle \(middle)")
        #expect(abs(rowBottom - middle) <= 3.5, "\(rowBottom) against \(middle)")
        // The band on the empty line (#353535 in dark is the theme's band).
        let band = try #require(window.contentView)
        Self.shot(band, "mac-r7-final-line")
    }

    // MARK: Row 181: the knob counts the whole document

    /// Bands.swift (wrapped rows of full blocks): the text view is as tall
    /// as its laid-out text plus the overscroll from the start, so the
    /// knob's length is the visible height over the whole height and stays
    /// that length while the text scrolls (it was 15 % long and shrank).
    @Test func knobCountsTheWholeDocument() throws {
        let (wc, dir) = try r6.longWindow("r7-knob")
        defer { wc.window?.orderOut(nil) }
        let bands = dir.appendingPathComponent("GlassScroll/Bands.swift")
        try (String(repeating: "// " + String(repeating: "\u{2588}", count: 110) + "\n\n", count: 40)).write(to: bands, atomically: true, encoding: .utf8)
        wc.open(path: bands.path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let ed = wc.editor
        let tv = ed.textView
        let scroll = try #require(ed.scrollView as? EditorScrollView)
        let tlm = try #require(tv.textLayoutManager)
        let height0 = tv.frame.height
        let proportion0 = scroll.verticalScroller?.knobProportion ?? 0
        tlm.ensureLayout(for: tlm.documentRange)
        let exact = tlm.usageBoundsForTextContainer.maxY + tv.textContainerOrigin.y + tv.textContainerInset.height
        let expected = tv.heightWithOverscrollPreview(exact)
        // Scroll 1200 points: the knob keeps its length.
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 1200))
        scroll.reflectScrolledClipView(clip)
        wc.window?.displayIfNeeded()
        let proportion1 = scroll.verticalScroller?.knobProportion ?? 0
        let knob = scroll.verticalScroller?.rect(for: .knob).height ?? 0
        print("R7B knob: height \(height0) (exact \(expected)), proportion \(proportion0) then \(proportion1), knob \(knob)")
        #expect(abs(height0 - expected) < 1, "\(height0) against \(expected)")
        #expect(abs(proportion0 - proportion1) < 0.002, "\(proportion0) \(proportion1)")
    }

    // MARK: Row 179: a re-wrap keeps the top line

    /// The text's first visible logical line, from the clip view's top.
    func topLine(_ e: SourceEditorController) -> Int? { e.textView.topAnchor()?.line }

    /// Long.swift scrolled to about line 50, then split (the left pane
    /// narrower: its rows re-wrap) and the window narrowed to 1250: the
    /// left pane, inactive, keeps line 50 at the top each time, and its
    /// gutter draws against the new rows.
    @Test func rewrapKeepsTheTopLine() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, dir) = try r5.window("r7-rewrap")
        defer { wc.window?.close() }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        r5.layout(wc)
        let left = wc.editor
        let tv = left.textView
        let scroll = left.scrollView
        let target = 50
        let r = try #require(tv.lineRect(target))
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: r.minY - scroll.contentInsets.top + 3))
        scroll.reflectScrolledClipView(clip)
        #expect(topLine(left) == target)
        let into = tv.topAnchor()?.into ?? 0
        wc.split(sideBySide: true)
        r5.layout(wc)
        let editors = wc.editorArea.tab.editors
        #expect(editors.count == 2 && editors[0] === left)
        let afterSplit = topLine(left), intoSplit = tv.topAnchor()?.into ?? -1
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1250, height: 880), display: false)
        r5.layout(wc)
        let afterResize = topLine(left)
        wc.window?.displayIfNeeded()
        // The gutter's first row below the jump bar is the same line.
        let gutterRows = left.gutter.visibleLines()
        let barBottom = left.gutter.convert(NSPoint(x: 0, y: scroll.contentInsets.top), from: scroll).y
        let firstGutter = gutterRows.first { $0.rect.maxY > barBottom + 1 }?.line
        print("R7B rewrap: line \(target) (+\(into)) → split \(afterSplit ?? -1) (+\(intoSplit)) → 1250 \(afterResize ?? -1); gutter's first \(firstGutter ?? -1)")
        #expect(afterSplit == target && abs(intoSplit - into) < 1)
        #expect(afterResize == target)
        #expect(firstGutter == target)
        Self.shot(try #require(wc.window?.contentView), "mac-r7-rewrap-1250")
    }

    // MARK: Row 180: the jump bar at 1250 and 1180

    func split(_ name: String, width: CGFloat) throws -> (WorkspaceWindowController, URL) {
        try CouncilRound6EditorTests().split(name, width: width)
    }

    /// The path's ink parts of a bar, as text (reports).
    func report(_ bar: JumpBar) -> String {
        bar.pathInk.map { e in
            if let i = e.view as? JumpBarIconView {
                let ink = i.inkRange
                return String(format: "icon %.1f–%.1f", e.minX + ink.minX, e.minX + ink.maxX)
            }
            if let l = e.view as? FadingTruncationLabel { return String(format: "\"%@\" %.1f–%.1f", l.stringValue, e.minX, e.maxX) }
            return String(format: "› %.1f–%.1f", e.minX, e.maxX)
        }.joined(separator: ", ")
    }

    /// X07 (1250, Long.swift in both panes): icon slots 13 / 12.5 / 12.5
    /// (the file's ink 11.5), "GlassScroll" whole in both panes, the
    /// groups' titles gone, the last item whole; the active pane's
    /// chevrons 3 wide. X09 (1180): the project's title cut to about 23.
    @Test func jumpBarAt1250And1180() throws {
        defer { Theme.backingScaleOverride = nil }
        let (wc, dir) = try split("r7-jump", width: 1250)
        defer { wc.window?.close() }
        let editors = wc.editorArea.tab.editors
        for (k, e) in editors.enumerated() {
            let bar = e.jumpBar
            let parts = bar.pathState.parts
            #expect(parts.count == 3)
            guard parts.count == 3 else { continue }
            print("R7B X07 pane \(k) (\(bar.isActivePane ? "active" : "inactive"), \(bar.bounds.width) wide): \(report(bar))")
            #expect(parts[0].icon?.slotWidth == 13 && parts[1].icon?.slotWidth == 12.5 && parts[2].icon?.slotWidth == 12.5)
            #expect((parts[2].icon?.inkWidth ?? 99) <= 11.5)
            #expect(!parts[0].title.isHidden && parts[0].title.inkCut == nil, "GlassScroll whole: \(report(bar))")
            #expect(parts[1].title.isHidden)
            #expect(bar.pathState.last?.inkCut == nil)
            let chevrons = bar.pathInk.filter { $0.view is JumpBarChevronView }.map { $0.maxX - $0.minX }
            #expect(chevrons.allSatisfy { $0 == (bar.isActivePane ? 3 : 2) }, "\(chevrons)")
            Self.shot(bar, "mac-r7-jumpbar-1250-pane\(k)")
        }
        // X08: Model01.swift (two groups) in the right, active pane.
        let right = editors[1]
        wc.editorArea.focus(right)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Models/Model01.swift").path, line: nil)
        r5.layout(wc)
        right.jumpBar.layoutSubtreeIfNeeded()
        let deep = right.jumpBar.pathState
        print("R7B X08 right pane: \(report(right.jumpBar))")
        #expect(deep.parts.count == 4)
        if deep.parts.count == 4 {
            #expect(deep.parts[1].title.isHidden && deep.parts[2].title.isHidden)
            // The project's title kept, cut to no less than 9 points.
            let t = deep.parts[0].title
            #expect(!t.isHidden && (t.inkCut ?? t.ink.width) >= JumpBarPathLayout.minimumCut, "\(report(right.jumpBar))")
            #expect(deep.last?.inkCut == nil)
        }
        Self.shot(right.jumpBar, "mac-r7-jumpbar-1250-x08")
        // X09: 1180, the left pane: the project's title cut to about 23.
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1180, height: 880), display: false)
        r5.layout(wc)
        let bar = editors[0].jumpBar
        bar.layoutSubtreeIfNeeded()
        let t = bar.pathState.parts[0].title
        print("R7B X09 left pane: \(report(bar))")
        #expect(!t.isHidden && (t.inkCut ?? 0) > 18 && (t.inkCut ?? 0) < 30, "\(report(bar))")
        Self.shot(bar, "mac-r7-jumpbar-1180-pane0")
    }

    // MARK: The default theme's role colours, one table for both IDEs

    /// "Ycode Default" draws every role in the same colour on macOS
    /// (`DefaultTheme`) and Linux (`WorkspaceChrome.defaultThemeColors`),
    /// in light and dark; dark doc comments in the Comments colour (the
    /// reference's #ACB4CE for both), never a system fallback.
    @Test func defaultThemeTablesMatch() {
        for dark in [false, true] {
            let mac = dark ? DefaultTheme.dark : DefaultTheme.light
            let linux = WorkspaceChrome.defaultThemeColors(dark: dark)
            for role in SyntaxTokenKind.Role.allCases where role != .identifier {
                let m = mac.roles[role].flatMap { ThemeColor(hex: $0)?.hex }
                let l = linux.tokens[role.rawValue]?.hex
                #expect(m == l, "\(dark ? "dark" : "light") \(role): macOS \(m ?? "system") Linux \(l ?? "none")")
            }
            #expect(ThemeColor(hex: mac.plain)?.hex == linux.foreground.hex && ThemeColor(hex: mac.lineNumber)?.hex == linux.lineNumber.hex)
            for role in [SyntaxTokenKind.Role.docComment, .preprocessor, .attribute] { #expect(mac.roles[role] != nil, "\(role)") }
        }
        #expect(DefaultTheme.dark.roles[.docComment] == DefaultTheme.dark.roles[.comment])
    }
}
