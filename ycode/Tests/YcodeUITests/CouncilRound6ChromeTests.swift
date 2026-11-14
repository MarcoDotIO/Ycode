import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 6, group D, main-window chrome and motion
/// (`specs/ide/fidelity-council.md` rows 157–169; `editor-area.md`
/// H.1–H.3, H.5–H.10; `merge-sheet.md` §15.4), on the macOS IDE.
@MainActor
@Suite(.serialized) struct CouncilRound6ChromeTests {
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    /// A council window at the capture's size with Long.swift open, off
    /// every display.
    func longWindow(_ tag: String, width: CGFloat = 1400) throws -> (WorkspaceWindowController, URL) {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r6d-\(tag)")
        let wc = try fc.window(dir)
        wc.window?.isExcludedFromWindowsMenu = true
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: width, height: 880), display: false)
        wc.window?.orderBack(nil)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.window?.displayIfNeeded()
        return (wc, dir)
    }

    /// The council's project tree at first open (H.6): the project, the
    /// GlassScroll folder with Models inside it, the Plain group with Sub
    /// inside it.
    static func councilTree() -> NavigatorNode {
        NavigatorNode(name: "GlassScroll", kind: .container, path: "/tmp/r6/GlassScroll.xcodeproj", children: [
            NavigatorNode(name: "GlassScroll", kind: .folder, path: "/tmp/r6/GlassScroll", children: [
                NavigatorNode(name: "Models", kind: .folder, path: "/tmp/r6/GlassScroll/Models", children: [
                    NavigatorNode(name: "Model01.swift", kind: .file, path: "/tmp/r6/GlassScroll/Models/Model01.swift"),
                ]),
                NavigatorNode(name: "Long.swift", kind: .file, path: "/tmp/r6/GlassScroll/Long.swift"),
            ]),
            NavigatorNode(name: "Plain", kind: .group, path: "/tmp/r6/Plain", objectID: "PLAIN", children: [
                NavigatorNode(name: "Sub", kind: .group, path: "/tmp/r6/Plain/Sub", objectID: "SUB", children: [
                    NavigatorNode(name: "Inner.swift", kind: .file, path: "/tmp/r6/Plain/Sub/Inner.swift"),
                ]),
                NavigatorNode(name: "Plain.swift", kind: .file, path: "/tmp/r6/Plain/Plain.swift"),
            ]),
            NavigatorNode(name: "README.md", kind: .file, path: "/tmp/r6/README.md"),
        ])
    }

    // MARK: Row 160: first-open expansion

    @Test func firstOpenExpandsEveryGroupOfTheMainGroup() {
        let root = Self.councilTree()
        #expect(NavigatorTree.initiallyExpanded(root) == ["/tmp/r6/GlassScroll.xcodeproj", "/tmp/r6/GlassScroll", "PLAIN"])
        _ = NSApplication.shared
        let nav = NavigatorAreaController()
        let win = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 280, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = nav.view
        nav.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        nav.setProjectTree(root)
        nav.view.layoutSubtreeIfNeeded()
        nav.select(0)
        let o = nav.outlineView
        let rows = (0..<o.numberOfRows).compactMap { o.item(atRow: $0) as? OutlineItem }
        let expanded = rows.filter { o.isItemExpanded($0) }.map(\.title)
        // GlassScroll and Plain open; Models and Sub closed.
        #expect(expanded.count == 3 && expanded.filter { $0 == "GlassScroll" }.count == 2 && expanded.contains("Plain"), "\(expanded)")
        #expect(rows.contains { $0.title == "Sub" } && !rows.contains { $0.title == "Inner" || $0.title == "Inner.swift" })
        #expect(!rows.contains { $0.title.hasPrefix("Model01") })
    }

    // MARK: Row 161: the issue capsule and the stepper in light

    /// The capsule in light (H.5): one warning 61 wide, its count's ink 5
    /// after the symbol and 18 from the right end, black; an error and a
    /// warning 111 wide, a count's ink 24.5 before the next symbol; the
    /// triangle #F5C200.
    @Test func issueCapsuleInLightMatchesTheReference() throws {
        let cap = IssueCapsuleView()
        cap.appearance = NSAppearance(named: .aqua)
        cap.warnings = 1
        cap.frame = NSRect(x: 0, y: 0, width: cap.intrinsicContentSize.width, height: 36)
        cap.layoutSubtreeIfNeeded()
        #expect(abs(cap.capsuleWidth - 61) <= 0.75, "\(cap.capsuleWidth)")
        let one = try inkClusters(cap)
        print("R6CHROME capsule one warning: width \(cap.capsuleWidth), ink clusters \(one)")
        try #require(one.count == 2)
        #expect(abs(one[0].minX - 16.5) <= 1 && abs(one[0].maxX - one[0].minX - 17.5) <= 1, "\(one)")
        #expect(abs(one[1].minX - one[0].maxX - 5) <= 1, "\(one)")
        #expect(abs(cap.capsuleWidth - one[1].maxX - 18) <= 1, "\(one)")
        // Black in light, white in dark.
        #expect(IssueSummary.Capsule.countColor(dark: false) == 0x000000 && IssueSummary.Capsule.countColor(dark: true) == 0xFFFFFF)
        let black = try #require(IssueCapsuleView.countColor.resolved(in: NSAppearance(named: .aqua)!))
        #expect(black.redComponent < 0.01 && black.alphaComponent > 0.99)
        // The triangle's fill in light and dark.
        #expect(IssueSummary.Kind.warning.fill(dark: false) == 0xF5C200 && IssueSummary.Kind.warning.fill(dark: true) == 0xFFE015)
        cap.errors = 1
        cap.frame.size.width = cap.intrinsicContentSize.width
        cap.layoutSubtreeIfNeeded()
        #expect(abs(cap.capsuleWidth - 111) <= 1, "\(cap.capsuleWidth)")
        let two = try inkClusters(cap)
        print("R6CHROME capsule error+warning: width \(cap.capsuleWidth), ink clusters \(two)")
        try #require(two.count == 4)
        #expect(abs(two[2].minX - two[1].maxX - 24.5) <= 1.5, "\(two)")
        #expect(abs(cap.capsuleWidth - two[3].maxX - 17) <= 1.5, "\(two)")
    }

    /// The capsule's ink runs left to right (columns with ink, split at
    /// gaps of a point or more), in points.
    func inkClusters(_ v: NSView) throws -> [(minX: CGFloat, maxX: CGFloat)] {
        let scale: CGFloat = 4
        let size = v.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        v.cacheDisplay(in: v.bounds, to: rep)
        var inked: [Bool] = []
        for x in 0..<rep.pixelsWide {
            var any = false
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.4 { any = true; break }
            inked.append(any)
        }
        var out: [(CGFloat, CGFloat)] = []
        var start: Int?, lastInk = -100
        for (x, on) in inked.enumerated() where on {
            if let s = start, x - lastInk > Int(scale) { out.append((CGFloat(s) / scale, CGFloat(lastInk + 1) / scale)); start = nil }
            if start == nil { start = x }
            lastInk = x
        }
        if let s = start { out.append((CGFloat(s) / scale, CGFloat(lastInk + 1) / scale)) }
        return out
    }

    /// The stepper in light: chevrons #7F7F7F, the triangle #FFCB00 (H.5);
    /// dark keeps G.8's #9D9D9D and #FFE015.
    @Test func issueStepperColoursFollowTheAppearance() throws {
        #expect(IssueStepper.chevronColor(dark: false) == 0x7F7F7F && IssueStepper.chevronColor(dark: true) == 0x9D9D9D)
        #expect(IssueStepper.symbolFill(.warning, dark: false) == 0xFFCB00 && IssueStepper.symbolFill(.warning, dark: true) == 0xFFE015)
        let light = try #require(JumpBarIssueStepper.chevronColor.resolved(in: NSAppearance(named: .aqua)!))
        let dark = try #require(JumpBarIssueStepper.chevronColor.resolved(in: NSAppearance(named: .darkAqua)!))
        #expect(abs(light.redComponent * 255 - 0x7F) < 1 && abs(dark.redComponent * 255 - 0x9D) < 1)
    }
}

// MARK: Row 158: the inspector's curves, cadence and quiet end

extension CouncilRound6ChromeTests {
    /// H.2's reference keyframes, from each motion's own start, against
    /// the slide's curves: the hide's ease-out shape (the reference's best
    /// named fit), within its fit's error. Round 8 (row 204, at a light
    /// load) replaced the durations: the hide's 196 ms of round 6 is scaled
    /// to the 150 ms now used, and the show is an even ease-out over 280
    /// ms (`CouncilRound8MotionTests`).
    @Test func inspectorSlideFollowsTheRound6Curves() {
        let hide: [(Double, Double)] = [(83, 0.02), (98, 0.16), (111, 0.25), (137, 0.38), (164, 0.51), (179, 0.67), (206, 0.82), (219, 0.91),
                                        (235, 0.94), (248, 0.99), (273, 1)]
        let show: [(Double, Double)] = [(102, 0.02), (114, 0.04), (129, 0.12), (155, 0.19), (168, 0.31), (195, 0.44), (208, 0.58), (234, 0.71),
                                        (249, 0.82), (275, 0.91), (287, 0.96), (313, 1)]
        _ = show
        for (table, isShow, start) in [(hide, false, 77.0)] {
            let delay = EditorMetrics.inspectorSlideDelay(show: isShow)
            var squares = 0.0
            for (ms, p) in table {
                let scale = EditorMetrics.inspectorSlideMotion(show: isShow) / 0.196
                let d = EditorMetrics.inspectorSlideProgress(elapsed: delay + (ms - start) / 1000 * scale, show: isShow) - p
                squares += d * d
                #expect(abs(d) < 0.13, "\(isShow ? "show" : "hide") \(ms): \(d)")
            }
            let rms = (squares / Double(table.count)).squareRoot()
            print("R6CHROME inspector \(isShow ? "show" : "hide") rms \(rms)")
            #expect(rms < 0.07)
        }
        // The hide's fast start: 16 % of the travel 21 ms in (H.2).
        let early = EditorMetrics.inspectorSlideProgress(elapsed: EditorMetrics.inspectorSlideDelay(show: false) + 0.021, show: false)
        #expect(early > 0.1 && early < 0.3, "\(early)")
        // Round 10 (row 248): hide 200 ms, show 230 (CouncilRound10InspectorTests).
        #expect(EditorMetrics.inspectorSlideMotion(show: false) == 0.200 && EditorMetrics.inspectorSlideMotion(show: true) == 0.230)
    }

    /// Each frame of the slide (the divider moved, the window laid out and
    /// drawn) takes well under the 27 ms the reference held at most, and
    /// the editor's scrollers stay quiet from the start until after the
    /// end (no repaint after the motion, H.2).
    @Test func inspectorSlideFramesAreCheapAndEndQuietly() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, _) = try longWindow("slide")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        for hide in [true, false] {
            wc.toggleInspector(nil)
            #expect(wc.isInspectorSliding && EditorScrollView.scrollersAreQuiet)
            let state = wc.inspectorSlide
            var times: [Double] = []
            for i in 1...12 where wc.isInspectorSliding {
                let t0 = CACurrentMediaTime()
                state.onFrame?(CGFloat(i) / 13)
                w.contentView?.layoutSubtreeIfNeeded()
                w.displayIfNeeded()
                times.append((CACurrentMediaTime() - t0) * 1000)
            }
            spin(0.6) { !wc.isInspectorSliding }
            if wc.isInspectorSliding { state.onFrame?(1) }
            #expect(!wc.isInspectorSliding)
            // Quiet just after the end, not for long.
            #expect(EditorScrollView.scrollersAreQuiet || CACurrentMediaTime() > EditorScrollView.quietScrollersUntil - EditorScrollView.quietAfterSlide)
            #expect(EditorScrollView.quietScrollersUntil < CACurrentMediaTime() + EditorScrollView.quietAfterSlide + 0.01)
            let sorted = times.sorted()
            let median = sorted[sorted.count / 2]
            print("R6CHROME inspector \(hide ? "hide" : "show") frame ms: median \(String(format: "%.1f", median)), max \(String(format: "%.1f", sorted.last ?? 0)), \(times.map { Int($0) })")
            #expect(median < 27, "\(times)")
        }
    }
}

// MARK: Row 157: the flick at the top

extension CouncilRound6ChromeTests {
    /// The council's flick (H.1) as scroll events: 8 gesture events of 40
    /// points 8.3 ms apart, the gesture's end, then momentum decaying with a
    /// 0.33 s time constant (about 1544 points), timestamps from `t0`.
    static func councilFlick(t0: Double) -> [NSEvent] {
        func event(_ d: Double, phase: Int64, momentum: Int64, at t: Double) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(d.rounded()), wheel2: 0, wheel3: 0) else { return nil }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: d)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: d)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            cg.timestamp = CGEventTimestamp(t * 1e9)
            return NSEvent(cgEvent: cg)
        }
        var out: [NSEvent?] = []
        for i in 0..<8 { out.append(event(40, phase: i == 0 ? 1 : 2, momentum: 0, at: t0 + Double(i) * 0.0083)) }
        out.append(event(0, phase: 4, momentum: 0, at: t0 + 0.062))
        let tau = 0.33, n = 173, total = 1.43
        let dt = total / Double(n)
        let v0 = 1544 / (tau * (1 - exp(-total / tau)))
        for i in 0..<n {
            let a = Double(i) * dt
            out.append(event(v0 * tau * (exp(-a / tau) - exp(-(a + dt) / tau)), phase: 0, momentum: i == 0 ? 1 : 2, at: t0 + 0.066 + a))
        }
        out.append(event(0, phase: 0, momentum: 3, at: t0 + 0.066 + total))
        return out.compactMap { $0 }
    }

    /// The bounce's curve for the flick's crossing (H.1): about 120 points
    /// past the top about 70 ms after the crossing (capped at 0.16 of the
    /// view), the critically damped return at ω 13.5, settled within about
    /// 700 ms of the flick's start.
    @Test func bounceCurveMatchesRound6() {
        // Round 9 (rows 220–222) supersedes the depth and the return: the
        // stretch's law, ω 11.3 at the top; the rise still peaks 71 ms after
        // the crossing.
        #expect(TopBounce.omega == 11.3 && abs(TopBounce.peakTime - 0.0714) < 0.001)
        let visible = 770.0
        for v in [4000.0, 4500, 9000] {
            let e = TopBounce.effectiveVelocity(v, visibleHeight: visible)
            let peak = TopBounce.peak(velocity: e)
            print("R6CHROME bounce v \(v): peak \(peak), at rest after \(TopBounce.duration(velocity: e))")
            #expect(abs(peak - TopBounce.stretch(forCrossing: v)) < 0.01 && peak <= TopBounce.maximumShare * visible + 0.01, "\(v): \(peak)")
            // Reaching the top at 90 ms, at rest by about 700–790 (the reference: −1 at 696, 0 at 782).
            let d = TopBounce.duration(velocity: e)
            #expect(0.090 + d > 0.62 && 0.090 + d < 0.80, "\(d)")
            // No oscillation: never past the top on the way back.
            for t in stride(from: 0.0, through: 1.2, by: 0.005) { #expect(TopBounce.overscroll(velocity: e, at: t) >= 0) }
        }
        // The return from the peak (ω 11.3): half gone about 148 ms after it, 10 % left at about 344.
        let e = TopBounce.effectiveVelocity(4500, visibleHeight: visible)
        let p = TopBounce.peak(velocity: e)
        let half = TopBounce.overscroll(velocity: e, at: TopBounce.peakTime + 0.148) / p
        let tenth = TopBounce.overscroll(velocity: e, at: TopBounce.peakTime + 0.344) / p
        #expect(abs(half - 0.5) < 0.05 && abs(tenth - 0.1) < 0.03, "\(half) \(tenth)")
    }

    /// The flick delivered as a burst of queued events: one call takes the
    /// whole burst (the reference reached the top in one frame), the text
    /// runs about 120 points past the top and comes back without passing
    /// it, and the bounce is over within about 700 ms.
    @Test func flickBurstReachesTheTopInOneFrameAndStretchesAbout120() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, _) = try longWindow("flick", width: 1400)
        defer { wc.window?.orderOut(nil) }
        let scroll = try #require(wc.editor.scrollView as? EditorScrollView)
        let clip = scroll.contentView
        let top = EditorTopBounce.top(of: scroll)
        // Off every display the system's scroll view does not move for
        // synthesized gesture events: start just below the top, so the
        // momentum's first events cross it (on screen the gesture brings
        // the text there in the same call).
        clip.scroll(to: NSPoint(x: 0, y: top + 20))
        scroll.reflectScrolledClipView(clip)
        spin(0.1)
        let visible = clip.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        var burst = Self.councilFlick(t0: ProcessInfo.processInfo.systemUptime)
        let first = burst.removeFirst()
        let saved = EditorScrollView.nextQueuedEvent
        EditorScrollView.nextQueuedEvent = { _ in burst.isEmpty ? nil : burst.removeFirst() }
        defer { EditorScrollView.nextQueuedEvent = saved }
        var frames: [CGFloat] = []
        scroll.topBounce.onFrame = { frames.append($0) }
        let t0 = CACurrentMediaTime()
        scroll.scrollWheel(with: first)
        // The whole burst in one call: at the top (the bounce has begun).
        #expect(burst.isEmpty && scroll.coalescedEvents > 100, "\(scroll.coalescedEvents)")
        #expect(scroll.topBounce.isRunning, "offset \(clip.bounds.minY - top)")
        #expect(abs(clip.bounds.minY - top) < 1 + (frames.first ?? 0), "\(clip.bounds.minY - top)")
        var frameTimes: [Double] = []
        let probe = scroll.topBounce.onFrame
        scroll.topBounce.onFrame = { x in
            let s = CACurrentMediaTime()
            probe?(x)
            wc.window?.displayIfNeeded()
            frameTimes.append((CACurrentMediaTime() - s) * 1000)
        }
        spin(1.5) { !scroll.topBounce.isRunning }
        let took = CACurrentMediaTime() - t0
        let peak = scroll.topBounce.lastPeak
        let sorted = frameTimes.sorted()
        print("R6CHROME flick: visible \(visible), peak \(peak), frames \(frames.count), at rest after \(String(format: "%.3f", took)) s, frame ms median \(sorted.isEmpty ? 0 : sorted[sorted.count / 2]) max \(sorted.last ?? 0)")
        #expect(!scroll.topBounce.isRunning)
        // Round 9 (row 220): about 38 for main 04's crossing; this burst
        // crosses at the gesture's speed (4800 points a second), a little more.
        #expect(peak > 30 && peak < 50, "\(peak)")
        #expect(frames.allSatisfy { $0 >= 0 })
        #expect(abs(clip.bounds.minY - top) < 0.5)
        // Settled within about 700 ms of the crossing (the timer stands in
        // for the display link off screen; a loaded machine stretches it).
        #expect(took < 1.2, "\(took)")
    }
}

// MARK: Row 159: narrowing

extension CouncilRound6ChromeTests {
    /// The size request returns well inside the reference's 222 ms with the
    /// content laid out at the new width (H.3: the content frame within
    /// about 120 ms), and the toolbar's fit settles: a few fits on the next
    /// turns, then none (round 6's 1247 ms return was the toolbar's fit
    /// loop, fixed by B6-TOOLBAR-LIVELOCK).
    @Test func narrowingReturnsAtOnceAndTheFitSettles() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, _) = try longWindow("narrow")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        wc.fitToolbar()
        spin(0.3)
        let runs = wc.toolbarControls.fitRuns
        let t0 = CACurrentMediaTime()
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: true)
        let t1 = CACurrentMediaTime()
        let editorWidth = wc.editor.view.frame.width
        spin(0.4)
        let settled = wc.toolbarControls.fitRuns
        spin(0.4)
        let call = (t1 - t0) * 1000
        print("R6CHROME narrowing: call \(Int(call)) ms, editor \(editorWidth) wide after it, fits \(settled - runs) then \(wc.toolbarControls.fitRuns - settled)")
        #expect(call < 120, "\(call)")
        #expect(wc.toolbarControls.fitRuns == settled && wc.toolbarFit.schemeGlyphsOnly)
        // Laid out in the call: the editor is already the narrower width.
        #expect(abs(wc.editor.view.frame.width - editorWidth) < 1)
    }
}

// MARK: Row 162: the image inspector

extension CouncilRound6ChromeTests {
    /// Stripes.png selected: Dimensions, Resolution, Color Space and Alpha
    /// Channel read "--" even once the image has decoded; the Tags field
    /// #E0E0E1 with its placeholder's ink 6.5 in and centred (H.7).
    @Test func imageInspectorShowsDashesAndACentredTagsPlaceholder() throws {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r6d-image")
        let wc = try fc.window(dir)
        defer { wc.window?.close() }
        let w = try #require(wc.window)
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Stripes.png").path, line: nil)
        spin(0.3)
        wc.inspector.imageProperties = ImageFileProperties(pixelWidth: 80, pixelHeight: 180, dpi: 72, colorSpace: "RGB", hasAlpha: false)
        w.contentView?.layoutSubtreeIfNeeded()
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        // Values carry zero-width spaces (break points); compare without them.
        let labels = all(wc.inspector.view).compactMap { ($0 as? NSTextField)?.stringValue.replacingOccurrences(of: "\u{200B}", with: "") }
        for key in ["Dimensions", "Resolution", "Color Space", "Alpha Channel"] {
            let i = try #require(labels.firstIndex(of: key), "\(key)")
            #expect(labels[i + 1] == "--", "\(key): \(labels[(i + 1)...].prefix(3))")
        }
        #expect(!labels.contains { $0.contains("pixels") })
        let tags = try #require(wc.inspector.fileControls["On Demand Resource Tags"] as? ResourceTagsField)
        #expect(tags.placeholderAttributedString?.string == "Tags")
        // The fill in light.
        var fill: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { fill = ResourceTagsStyle.fill.usingColorSpace(.sRGB) }
        let f = try #require(fill)
        #expect(abs(f.redComponent * 255 - 0xE0) < 0.6 && abs(f.blueComponent * 255 - 0xE1) < 0.6)
        // The placeholder's ink in the field.
        let scale: CGFloat = 4
        let size = tags.bounds.size
        #expect(abs(size.height - 24) < 0.5)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        tags.appearance = NSAppearance(named: .aqua)
        tags.cacheDisplay(in: tags.bounds, to: rep)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.3, c.redComponent < 0.7 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= 0)
        let left = CGFloat(minX) / scale, top = CGFloat(minY) / scale, bottom = CGFloat(maxY + 1) / scale
        print("R6CHROME tags placeholder ink: x \(left), y \(top)–\(bottom) in a \(size.height)-point field")
        #expect(abs(left - 6.5) <= 0.75, "\(left)")
        #expect(abs((top + bottom) / 2 - size.height / 2) <= 1, "\(top)–\(bottom)")
    }
}

// MARK: Row 163: switching files

extension CouncilRound6ChromeTests {
    /// On screen the File inspector follows the editor's frame (H.7): the
    /// switch's own pass shows the new text and jump bar; the inspector is
    /// rebuilt just after, for the file still shown. Off every display it
    /// is rebuilt at once (other tests read it right after an open).
    @Test func inspectorFollowsTheEditorAfterItsFrame() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, dir) = try longWindow("follow")
        defer { wc.window?.orderOut(nil) }
        let long = dir.appendingPathComponent("GlassScroll/Long.swift")
        let content = dir.appendingPathComponent("GlassScroll/ContentView.swift")
        let png = dir.appendingPathComponent("GlassScroll/Stripes.png")
        #expect(wc.inspector.file?.path == long.path && !wc.isInspectorFollowPending)
        // Round 8 (row 206) rebuilds the inspector with the editor; round
        // 6's order is kept behind `isEnabled` and checked here.
        wc.inspectorFollowBox.isEnabled = true
        wc.inspectorFollowBox.defersOffscreen = true
        defer { wc.inspectorFollowBox.defersOffscreen = false; wc.inspectorFollowBox.isEnabled = false }
        var times: [Double] = []
        for (next, before) in [(content, long), (png, content), (long, png)] {
            let t0 = CACurrentMediaTime()
            wc.open(path: next.path, line: nil)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            wc.window?.displayIfNeeded()
            times.append((CACurrentMediaTime() - t0) * 1000)
            #expect(wc.isInspectorFollowPending && wc.inspector.file?.path == before.path, "\(next.lastPathComponent)")
            spin(0.2) { !wc.isInspectorFollowPending }
            #expect(!wc.isInspectorFollowPending && wc.inspector.file?.path == next.path, "\(next.lastPathComponent)")
        }
        print("R6CHROME file switch without the inspector: \(times.map { Int($0) }) ms")
        // A deferred rebuild for a file no longer shown is dropped.
        wc.open(path: content.path, line: nil)
        wc.open(path: long.path, line: nil)
        spin(0.2) { !wc.isInspectorFollowPending }
        #expect(wc.inspector.file?.path == long.path)
    }

    /// The switch's own work (open, layout, draw), timed by part
    /// (`R6_PROFILE=1`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R6_PROFILE"] != nil))
    func profileFileSwitch() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, dir) = try longWindow("switch")
        defer { wc.window?.orderOut(nil) }
        let long = dir.appendingPathComponent("GlassScroll/Long.swift").path
        let bands = dir.appendingPathComponent("GlassScroll/Bands.swift")
        try (String(repeating: "// " + String(repeating: "\u{2588}", count: 110) + "\n\n", count: 40)).write(to: bands, atomically: true, encoding: .utf8)
        let png = dir.appendingPathComponent("GlassScroll/Stripes.png").path
        let loops = Int(ProcessInfo.processInfo.environment["R6_LOOPS"] ?? "1") ?? 1
        let order = Array(repeating: [bands.path, long, bands.path, png, long, png, bands.path], count: loops).flatMap { $0 }
        for path in order {
            let t0 = CACurrentMediaTime()
            wc.open(path: path, line: nil)
            let t1 = CACurrentMediaTime()
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            let t2 = CACurrentMediaTime()
            wc.window?.displayIfNeeded()
            let t3 = CACurrentMediaTime()
            print("R6PROFILE switch to \((path as NSString).lastPathComponent): open \(Int((t1 - t0) * 1000)) layout \(Int((t2 - t1) * 1000)) draw \(Int((t3 - t2) * 1000)) ms")
        }
    }
}

// MARK: Row 165: the navigator filter glyph

extension CouncilRound6ChromeTests {
    /// In light the glyph and its chevron are #777777 (H.9; Ycode drew
    /// black), the circle's ink about 14.5 × 13 with a thin stroke.
    @Test func navigatorFilterGlyphIsGreyAndThin() throws {
        #expect(WorkspaceChrome.filterGlyph(dark: false) == 0x777777 && WorkspaceChrome.filterGlyph(dark: true) == 0xABABAC)
        let b = NavigatorOptionsButton(frame: NSRect(x: 0, y: 0, width: NavigatorFilterField.optionsWidth, height: 20), pullsDown: true)
        b.appearance = NSAppearance(named: .aqua)
        b.contentTintColor = NavigatorBarColors.optionsGlyph
        let scale: CGFloat = 4
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.bounds.width * scale), pixelsHigh: Int(b.bounds.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = b.bounds.size
        b.cacheDisplay(in: b.bounds, to: rep)
        var core: [CGFloat] = []
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        // The circle: columns left of the chevron.
        let circleEnd = Int(15.5 * scale)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.25 else { continue }
                if c.alphaComponent > 0.95 { core.append(c.redComponent * 255) }
                if x < circleEnd { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        try #require(!core.isEmpty)
        let mean = core.reduce(0, +) / CGFloat(core.count)
        let w = CGFloat(maxX - minX + 1) / scale, h = CGFloat(maxY - minY + 1) / scale
        print("R6CHROME filter glyph: core grey \(Int(mean)) over \(core.count) px, circle ink \(w) × \(h)")
        #expect(abs(mean - 0x77) < 6, "\(mean)")
        #expect(abs(w - 14) < 1.5 && abs(h - 13.5) < 1.5, "\(w) × \(h)")
    }
}

// MARK: Row 166: toolbar and Source Control glyphs

extension CouncilRound6ChromeTests {
    /// The leading capsule's list and sparkle; New Conversation's bubble in
    /// its own gradient (row 214's angular one; not tinted by the toolbar); the Changes |
    /// Repositories titles at 11 points ("Changes" about 45 in ink), 2 lower.
    @Test func toolbarAndSourceControlGlyphs() throws {
        #expect(WorkspaceChrome.leftPanes.symbols == ["list.bullet", "sparkles"])
        let image = ToolbarGradientGlyph.newConversation()
        #expect(!image.isTemplate)
        let rep = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        var reds: [CGFloat] = [], blues: [CGFloat] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                reds.append(c.redComponent)
                blues.append(c.blueComponent)
            }
        }
        try #require(!reds.isEmpty)
        // Round 9 (row 214) replaced the pink-to-purple fill with the angular
        // gradient: red-orange at the top, blue at the bottom; nothing black.
        let redSpread = (reds.max() ?? 0) - (reds.min() ?? 0)
        #expect((reds.max() ?? 0) > 0.9 && redSpread > 0.2 && (blues.max() ?? 0) > 0.8, "\(reds.min() ?? 0)…\(reds.max() ?? 0)")
        let f = NSFont.systemFont(ofSize: CGFloat(RepositoriesViewStyle.modeControlFontSize))
        let ink = NSAttributedString(string: "Changes", attributes: [.font: f])
            .boundingRect(with: NSSize(width: 200, height: 40), options: [.usesDeviceMetrics, .usesLineFragmentOrigin]).width
        #expect(abs(ink - 45) < 1, "\(ink)")
        #expect(RepositoriesViewStyle.modeControlDrop == 2)
    }
}

// MARK: Row 167: the navigator scroller

extension CouncilRound6ChromeTests {
    /// In the council window the project navigator's scroller runs from 3
    /// below the selector bar to 11 above the filter capsule (H.10: y
    /// 91.5–849.5 in the reference; Ycode's was 127.5–836).
    @Test func navigatorScrollerSpansTheBars() throws {
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        let (wc, _) = try longWindow("scroller")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        let nav = wc.navigator
        // Rows enough to scroll (step 15 scrolled a long navigator).
        let files = (0..<80).map { NavigatorNode(name: "File\($0).swift", kind: .file, path: "/tmp/r6s/File\($0).swift") }
        nav.setProjectTree(NavigatorNode(name: "Big", kind: .container, path: "/tmp/r6s/Big.xcodeproj", children: [
            NavigatorNode(name: "Big", kind: .group, path: "/tmp/r6s/Big", objectID: "BIG", children: files),
        ]))
        nav.select(0)
        nav.outlineView.expandItem(nil, expandChildren: true)
        w.contentView?.layoutSubtreeIfNeeded()
        nav.updateOutlineInsets()
        let scroll = nav.scrollView
        scroll.tile()
        let scroller = try #require(scroll.verticalScroller)
        func top(_ v: NSView) -> (CGFloat, CGFloat) {
            let r = v.convert(v.bounds, to: nil)
            return (w.frame.height - r.maxY, w.frame.height - r.minY)
        }
        print("R6CHROME navigator scroll \(top(scroll)), insets \(scroll.contentInsets.top)/\(scroll.contentInsets.bottom), scroller insets \(scroll.scrollerInsets.top)/\(scroll.scrollerInsets.bottom), doc \(scroll.documentView?.frame.height ?? 0), hidden \(scroller.isHidden), style \(scroll.scrollerStyle.rawValue), rows \(nav.outlineView.numberOfRows)")
        let track = top(scroller), selector = top(nav.selectorView), filter = top(nav.filterGlass)
        print("R6CHROME navigator scroller y \(track.0)–\(track.1), selector \(selector.0)–\(selector.1), filter \(filter.0)–\(filter.1), window \(w.frame.height)")
        #expect(abs(track.0 - (selector.1 + 3)) <= 1.5, "\(track)")
        #expect(abs(track.1 - (filter.0 - 11)) <= 1.5, "\(track)")
    }
}

// MARK: Row 169: the Welcome window's path

extension CouncilRound6ChromeTests {
    /// The recent project's folder with its links resolved (H.10: the
    /// reference shows "/private/tmp/…" for a project opened as "/tmp/…").
    @Test func welcomeRowShowsTheRealPath() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r6-welcome-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let real = base.appendingPathComponent("real/Project")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("real"))
        let opened = base.appendingPathComponent("link/Project/App.xcodeproj")
        let shown = RecentProjects.folderText(opened)
        let expected = String(cString: realpath(real.path, nil))
        print("R6CHROME welcome folder \(shown)")
        #expect(shown == expected && !shown.contains("/link/"))
        // macOS's temporary folder is itself a link (/var → /private/var).
        #expect(shown.hasPrefix("/private/"))
        // A folder that is not there keeps its stored path.
        #expect(RecentProjects.folderText(URL(fileURLWithPath: "/tmp/r6-missing-\(UUID().uuidString)/App.xcodeproj")).hasPrefix("/tmp/"))
    }
}

extension NSColor {
    /// The colour as the appearance draws it, in sRGB.
    func resolved(in appearance: NSAppearance) -> NSColor? {
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance { out = self.usingColorSpace(.sRGB) }
        return out
    }
}
