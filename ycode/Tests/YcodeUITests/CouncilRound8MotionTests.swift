import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 8, group B (`specs/ide/fidelity-council.md` rows 204–207):
/// the inspector's slide with every frame drawn, the momentum fitted to the
/// slow flick, the fast flick's stretch, live-resize and selection latency.
@MainActor
@Suite(.serialized) struct CouncilRound8MotionTests {
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    /// The council's GlassScroll with a Long.swift of about `lines` lines
    /// (the capture's file is several hundred lines long; the shared fixture
    /// has 182).
    static func project(_ tag: String, lines: Int = 850) throws -> URL {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r8-\(tag)")
        var long = "import Foundation\n\n"
        var i = 0
        while long.split(separator: "\n", omittingEmptySubsequences: false).count < lines {
            long += "// Section \(i): a comment block that is long enough to wrap in a narrow editor width so that the wrapped-line indentation shows.\n"
            long += "struct Section\(i) {\n    let value: Int = \(i)\n    func describe() -> String {\n        return \"\\(value)\"\n    }\n}\n\n"
            i += 1
        }
        try long.write(to: dir.appendingPathComponent("GlassScroll/Long.swift"), atomically: true, encoding: .utf8)
        var bands = "import SwiftUI\n\n"
        for n in 0..<60 { bands += "let band\(n) = Color(red: \(Double(n) / 60), green: 0.5, blue: 0.5) // a band of colour number \(n) across the canvas\n" }
        try bands.write(to: dir.appendingPathComponent("GlassScroll/Bands.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    /// A council window (1400 × 880) off every display with Long.swift open.
    static func window(_ dir: URL) throws -> WorkspaceWindowController {
        let wc = try FidelityCouncilTests().window(dir)
        MergeSheetR5UITests.Offscreen.on()
        if let w = wc.window { w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false) }
        wc.window?.orderBack(nil)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.window?.displayIfNeeded()
        return wc
    }

    // MARK: Profiling (R8_PROFILE=1)

    /// A measurement, not a check: the per-frame cost of the slide's frames
    /// with a long file, the run loop turning between them as on screen.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R8_PROFILE"] != nil))
    func profileSlideFrames() throws {
        let lines = Int(ProcessInfo.processInfo.environment["R8_LINES"] ?? "") ?? 850
        let dir = try Self.project("profile", lines: lines)
        let wc = try Self.window(dir)
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let split = wc.mainSplit.splitView
        let total = split.bounds.width, divider = split.dividerThickness
        let width = wc.inspector.view.frame.width
        wc.inspectorItem.minimumThickness = 1
        wc.inspector.beginRigidSlide(width: width)
        defer { wc.inspector.endRigidSlide() }
        // As the slide does: the bars hold their blur.
        if ProcessInfo.processInfo.environment["R8_NO_HOLD"] == nil { EditorBlurMotion.begin() }
        defer { if ProcessInfo.processInfo.environment["R8_NO_HOLD"] == nil { EditorBlurMotion.end() } }
        let text = wc.editor.textView
        let env = ProcessInfo.processInfo.environment
        if env["R8_NO_MINIMAP"] != nil { wc.editor.minimap.isHidden = true }
        if env["R8_NO_BARS"] != nil { wc.editor.bandBackdrop.isHidden = true; wc.debugArea.bottomBarBackdrop?.isHidden = true }
        if env["R8_NO_GUTTER"] != nil { wc.editor.gutter.isHidden = true }
        if env["R8_NO_NAV"] != nil { wc.navigator.view.isHidden = true }
        if env["R8_NO_TOOLBAR"] != nil { wc.window?.toolbar?.isVisible = false }
        if env["R8_NO_TEXT"] != nil { text.isHidden = true }
        if env["R8_NO_INSPECTOR"] != nil { wc.inspector.view.subviews.forEach { $0.isHidden = true } }
        print("R8PROFILE depth \(wc.window?.depthLimit.rawValue ?? 0) bps \(wc.window?.depthLimit.bitsPerSample ?? 0) screen \(wc.window?.screen?.localizedName ?? "none")")
        if env["R8_DEPTH24"] != nil { wc.window?.depthLimit = .twentyfourBitRGB; wc.window?.contentView?.superview?.needsDisplay = true; wc.window?.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let rounds = Int(ProcessInfo.processInfo.environment["R8_ROUNDS"] ?? "") ?? 2
        var setT = 0.0, layoutT = 0.0, displayT = 0.0, loopT = 0.0, settleT = 0.0, n = 0
        for i in 0..<(25 * rounds) {
            let p = CGFloat(i % 13) / 12
            let x = (total - divider - width + (width - 1) * ((i / 13) % 2 == 0 ? p : 1 - p)).rounded()
            let t0 = CACurrentMediaTime()
            split.setPosition(x, ofDividerAt: 1)
            let t1 = CACurrentMediaTime()
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            if env["R8_LIST_DIRTY"] != nil, i == 5, let root = wc.window?.contentView?.superview {
                // The views this frame redraws, with their sizes.
                var dirty: [String] = []
                func walk(_ l: CALayer) {
                    if l.needsDisplay(), !l.isHidden { dirty.append("\(l.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: l))) \(Int(l.bounds.width))x\(Int(l.bounds.height))") }
                    l.sublayers?.forEach(walk)
                }
                if let layer = root.layer { walk(layer) }
                print("R8PROFILE dirty: " + dirty.joined(separator: ", "))
            }
            let t2 = CACurrentMediaTime()
            wc.window?.displayIfNeeded()
            let t3 = CACurrentMediaTime()
            RunLoop.main.run(until: Date())
            let t4 = CACurrentMediaTime()
            if ProcessInfo.processInfo.environment["R8_SETTLE"] != nil { text.settleDocumentHeight() }
            let t5 = CACurrentMediaTime()
            setT += t1 - t0; layoutT += t2 - t1; displayT += t3 - t2; loopT += t4 - t3; settleT += t5 - t4; n += 1
        }
        func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000 / Double(n)) }
        // Each view's drawing alone (held as in the slide).
        let views: [(String, NSView?)] = [("jump bar band", wc.editor.bandBackdrop), ("bottom bar", wc.debugArea.bottomBarBackdrop),
                                          ("minimap", wc.editor.minimap), ("gutter", wc.editor.gutter), ("text", text),
                                          ("inspector", wc.inspector.view), ("navigator", wc.navigator.view)]
        for (name, v) in views {
            guard let v else { continue }
            let t0 = CACurrentMediaTime()
            for _ in 0..<10 {
                v.needsDisplay = true
                v.subviews.forEach { $0.needsDisplay = true }
                CATransaction.flush()
            }
            print("R8PROFILE draw \(name) \(v.bounds.size): \(String(format: "%.2f", (CACurrentMediaTime() - t0) * 100)) ms")
        }
        print("R8PROFILE lines \(text.lineIndex.lineCount): setPosition \(ms(setT)) layout \(ms(layoutT)) display \(ms(displayT)) runloop \(ms(loopT)) (extra settle \(ms(settleT))) ms/frame")
    }

    /// A measurement, not a check: narrowing the window from 1400 to 1100
    /// with the editor split (main 17), and selecting Long.swift and
    /// Bands.swift from the navigator (main 01, 07): the call's time and the
    /// run loop's work after it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R8_PROFILE"] != nil))
    func profileResizeAndSelection() throws {
        let dir = try Self.project("profile-resize")
        let wc = try Self.window(dir)
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        let loops = Int(ProcessInfo.processInfo.environment["R8_ROUNDS"] ?? "") ?? 3
        if ProcessInfo.processInfo.environment["R8_SPLIT"] != nil { wc.split(sideBySide: true) }
        spin(0.5)
        let resizes = ProcessInfo.processInfo.environment["R8_ONLY_OPEN"] != nil ? 0 : loops
        for i in 0..<resizes {
            let width: CGFloat = i % 2 == 0 ? 1100 : 1400
            let t0 = CACurrentMediaTime()
            w.setFrame(NSRect(x: -6000, y: -6000, width: width, height: 880), display: true)
            let t1 = CACurrentMediaTime()
            RunLoop.main.run(until: Date())
            let t2 = CACurrentMediaTime()
            print("R8PROFILE resize to \(Int(width)): call \(String(format: "%.1f", (t1 - t0) * 1000)) ms, then \(String(format: "%.1f", (t2 - t1) * 1000)) ms")
            spin(0.3)
        }
        for i in 0..<loops {
            let name = i % 2 == 0 ? "Bands.swift" : "Long.swift"
            let t0 = CACurrentMediaTime()
            wc.open(path: dir.appendingPathComponent("GlassScroll/\(name)").path, line: nil)
            let t1 = CACurrentMediaTime()
            w.displayIfNeeded()
            let t2 = CACurrentMediaTime()
            RunLoop.main.run(until: Date())
            let t3 = CACurrentMediaTime()
            print("R8PROFILE open \(name): call \(String(format: "%.1f", (t1 - t0) * 1000)) display \(String(format: "%.1f", (t2 - t1) * 1000)) then \(String(format: "%.1f", (t3 - t2) * 1000)) ms")
            spin(ProcessInfo.processInfo.environment["R8_ONLY_OPEN"] != nil ? 0.02 : 0.3)
        }
    }

    // MARK: Row 204: the slide's frames

    /// A re-wrap during the slide lays out only what is on screen: the
    /// whole document's exact height waits for the slide's end, then
    /// follows once, under the same top line; the minimap's bars are not
    /// rendered again for a width change. Each frame's work is printed.
    @Test func slideFramesLeaveTheWholeLayoutForTheEnd() throws {
        let dir = try Self.project("slide")
        let wc = try Self.window(dir)
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let text = wc.editor.textView
        let minimap = wc.editor.minimap
        minimap.display()
        let renders = minimap.renders
        let heightBefore = text.frame.height
        wc.toggleInspector(nil)
        #expect(wc.isInspectorSliding)
        let state = wc.inspectorSlide
        var costs: [Double] = []
        for p in [0.2, 0.4, 0.6, 0.8] as [CGFloat] where wc.isInspectorSliding {
            let t0 = CACurrentMediaTime()
            state.onFrame?(p)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            wc.window?.displayIfNeeded()
            minimap.display()
            costs.append((CACurrentMediaTime() - t0) * 1000)
            #expect(text.rowsState.needsSettle, "\(p)")
        }
        #expect(minimap.renders == renders, "the minimap rendered again for a width change")
        spin(0.6) { !wc.isInspectorSliding }
        if wc.isInspectorSliding { state.onFrame?(1) }
        #expect(!wc.isInspectorSliding)
        // The exact height follows the last frame's commit.
        spin(0.1) { !text.rowsState.needsSettle }
        #expect(!text.rowsState.needsSettle)
        // The exact height, as a fresh settle finds it.
        let settled = text.frame.height
        text.settleDocumentHeight()
        #expect(abs(text.frame.height - settled) < 0.5)
        print("R8B slide frames (debug build, off screen): \(costs.map { String(format: "%.1f", $0) }) ms; height \(heightBefore) → \(settled)")
    }

    /// The hide and the show stepped off screen as a 60 Hz display steps
    /// them, each frame doing what it does on screen: the slide's position,
    /// the window's layout and drawing, and the run loop's turn that
    /// commits it. A frame is shown at the first display frame after its
    /// work ends, and the next one starts there. Checked: the show moves
    /// from its first frame (the pane no longer stays collapsed for the
    /// first 40 %: the edge held still, then jumped), each position is a
    /// step on, most frames come one to three display frames apart, and the
    /// last position comes within a few frames of the curve's end (hide 200
    /// ms after the press, 150 of motion, the reference 143; show 425, 280
    /// of motion). Off every display a frame costs about 25–35 ms in a
    /// debug or a release build at a host load of 6–16 (AppKit's layout and
    /// the layer commit, including CPU-drawn materials that the window
    /// server draws on screen), so "a new position on every display frame"
    /// is measured on screen by the council, not here; the values are
    /// printed. Off every display the window's display link does not step
    /// the slide, so the test does.
    @Test(.enabled(if: CouncilRound8MotionTests.timing)) func slideDrawsEveryDisplayFrame() throws {
        func name0(_ hide: Bool) -> String { hide ? "hide" : "show" }
        let dir = try Self.project("every-frame")
        let wc = try Self.window(dir)
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        spin(0.3)
        let period = 1.0 / 60
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let diag = ProcessInfo.processInfo.environment["R8_DIAG"] != nil
        // The slide's end follows its last frame, as on screen.
        InspectorSlideState.defersEndOffscreen = true
        defer { InspectorSlideState.defersEndOffscreen = false }
        let watch = diag ? wc.inspectorItem.observe(\.isCollapsed) { item, _ in
            print("R8DIAG isCollapsed -> \(item.isCollapsed) at \(CACurrentMediaTime())\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n"))
        } : nil
        defer { watch?.invalidate() }
        for hide in [true, false] {
            wc.toggleInspector(nil)
            #expect(wc.isInspectorSliding)
            let state = wc.inspectorSlide
            state.link?.invalidate()
            state.link = nil
            let press = try #require(state.clock?.press)
            if diag { print("R8DIAG press \(name0(hide)) at \(press)") }
            func slot(after t: Double) -> Double { press + (((t - press) / period).rounded(.up)) * period }
            var vsync = slot(after: CACurrentMediaTime())
            // Each frame: when it began and was shown, its work, the edge, and
            // whether it was one of the slide's frames (not after its last).
            var frames: [(vsync: Double, shown: Double, cost: Double, x: CGFloat, slide: Bool)] = []
            while wc.isInspectorSliding, vsync - press < 2 {
                while CACurrentMediaTime() < vsync { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
                let t0 = CACurrentMediaTime()
                let slide = !state.ending
                var clock = try #require(state.clock)
                let p = clock.progress(at: vsync)
                state.clock = clock
                state.onFrame?(CGFloat(p))
                w.contentView?.layoutSubtreeIfNeeded()
                w.displayIfNeeded()
                // The run loop's turn: the display cycle and the commit.
                RunLoop.main.run(until: Date())
                let t1 = CACurrentMediaTime()
                // Where the editor ends: the divider's place as drawn.
                let x = wc.editorArea.view.convert(wc.editorArea.view.bounds, to: nil).maxX
                let shown = slot(after: t1)
                frames.append((vsync, shown, t1 - t0, x, slide))
                if diag {
                    let pane = wc.inspector.view.superview ?? wc.inspector.view
                    print(String(format: "R8DIAG %.0f p %.3f cost %.1f x %.0f", (vsync - press) * 1000, p, (t1 - t0) * 1000, Double(x))
                          + " collapsed \(wc.inspectorItem.isCollapsed) sub \(wc.mainSplit.splitView.isSubviewCollapsed(pane)) pane \(pane.frame)")
                }
                vsync = max(shown, vsync + period)
            }
            #expect(!wc.isInspectorSliding)
            let moving = zip(frames.dropFirst(), frames).filter { $0.0.slide && $0.0.x != $0.1.x }.map(\.0)
            let first = moving.first?.shown ?? press, last = moving.last?.shown ?? press
            let gaps = zip(moving.dropFirst(), moving).map { ($0.0.shown - $0.1.shown) * 1000 }
            let costs = frames.map { $0.cost * 1000 }.sorted()
            let name = hide ? "hide" : "show"
            print("R8B slide \(name) edge (shown ms:x): " + frames.map { String(format: "%.0f:%.0f", ($0.shown - press) * 1000, Double($0.x)) }.joined(separator: " "))
            print(String(format: "R8B slide %@: first motion shown %.0f ms, last %.0f ms after the press; %d positions; gap max %.1f ms; frame work median %.1f max %.1f ms (%@ build, off screen)",
                         name, (first - press) * 1000, (last - press) * 1000, moving.count, gaps.max() ?? 0, costs[costs.count / 2], costs.last ?? 0, build))
            let delay = EditorMetrics.inspectorSlideDelay(show: !hide) * 1000
            let total = EditorMetrics.inspectorSlideTotal(show: !hide) * 1000
            // Moving from about the curve's start (no collapsed stretch; the
            // show's first frame waits for the pane to be laid out).
            #expect((first - press) * 1000 <= delay + 6 * period * 1000 + 1, "\(name): first motion \((first - press) * 1000) ms after the press")
            // Each position a step on towards the end.
            let xs = moving.map(\.x)
            #expect(zip(xs, xs.dropFirst()).allSatisfy { hide ? $1 > $0 : $1 < $0 }, "\(name): \(xs)")
            #expect(moving.count >= (hide ? 4 : 7), "\(name): \(moving.count) positions")
            // Most frames one to three display frames apart (two at a host
            // load under about 10).
            let sortedGaps = gaps.sorted()
            #expect((sortedGaps.isEmpty ? 0 : sortedGaps[sortedGaps.count / 2]) <= 3 * period * 1000 + 1, "\(name): gaps \(gaps)")
            #expect((last - press) * 1000 <= total + 10 * period * 1000, "\(name): ends \((last - press) * 1000) ms after the press")
            spin(0.3)
        }
    }

    /// The pane stays open through the whole slide, frame by frame: a
    /// show's early frames widen it from its first (the split view used to
    /// keep it collapsed until about 40 % of the travel, then jump), and a
    /// hide's late frames narrow it without collapsing it before its last.
    @Test func paneFollowsEveryFrameOfTheSlide() throws {
        let dir = try Self.project("pane")
        let wc = try Self.window(dir)
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        let pane = wc.inspector.view.superview ?? wc.inspector.view
        let full = pane.frame.width
        func step(_ p: CGFloat) -> CGFloat {
            wc.inspectorSlide.onFrame?(p)
            w.contentView?.layoutSubtreeIfNeeded()
            return pane.frame.width
        }
        wc.toggleInspector(nil)   // hide
        #expect(wc.isInspectorSliding)
        var widths: [CGFloat] = []
        for p in [0.25, 0.5, 0.75, 0.9] as [CGFloat] {
            widths.append(step(p))
            #expect(!wc.inspectorItem.isCollapsed, "hide \(p)")
            #expect(abs(widths.last! - full * (1 - p)) <= 12, "hide \(p): \(widths.last!) of \(full)")
        }
        _ = step(1)
        #expect(wc.inspectorItem.isCollapsed && !wc.isInspectorSliding)
        wc.toggleInspector(nil)   // show
        #expect(wc.isInspectorSliding)
        widths = []
        for p in [0.1, 0.2, 0.3, 0.5] as [CGFloat] {
            widths.append(step(p))
            #expect(!wc.inspectorItem.isCollapsed, "show \(p)")
            #expect(abs(widths.last! - full * p) <= 12, "show \(p): \(widths.last!) of \(full)")
        }
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $1 > $0 }, "\(widths)")
        _ = step(1)
        #expect(!wc.isInspectorSliding && abs(pane.frame.width - full) <= 1)
        print("R8B pane widths through the show: \(widths) of \(full)")
    }

    /// The timing measurements need the main thread to themselves (the full
    /// suite runs other suites' main-actor work between their frames):
    /// run them with `R8_TIMING=1`.
    nonisolated static let timing = ProcessInfo.processInfo.environment["R8_TIMING"] != nil

    // MARK: Row 206: live resize

    /// Main 17: the window narrowed from 1400 to 1100 with the editor split,
    /// stepped as a live resize steps it (the text views in layout motion,
    /// as `inLiveResize` makes them; a live resize cannot be started off
    /// every display). The first step's frame is drawn within 100 ms of the
    /// drag (the reference: 83 ms), later steps within a display frame or
    /// two, and the exact document height follows once, at the end.
    @Test(.enabled(if: CouncilRound8MotionTests.timing)) func liveResizeStepsDrawQuickly() throws {
        let dir = try Self.project("resize")
        let wc = try Self.window(dir)
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        wc.split(sideBySide: true)
        w.contentView?.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
        spin(0.3)
        EditorBlurMotion.begin()
        var steps: [Double] = []
        for width in stride(from: 1380, through: 1100, by: -20) {
            let t0 = CACurrentMediaTime()
            w.setFrame(NSRect(x: -6000, y: -6000, width: CGFloat(width), height: 880), display: false)
            w.contentView?.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
            steps.append((CACurrentMediaTime() - t0) * 1000)
            RunLoop.main.run(until: Date())
        }
        let deferred = wc.editorArea.allEditors.contains { $0.textView.rowsState.needsSettle }
        EditorBlurMotion.end()
        spin(0.1) { !wc.editorArea.allEditors.contains { $0.textView.rowsState.needsSettle } }
        let sorted = steps.sorted()
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print(String(format: "R8B live resize 1400 → 1100 (split): first step %.1f ms, median %.1f, max %.1f (%@ build, off screen)", steps[0], sorted[sorted.count / 2],
                     sorted.last ?? 0, build))
        #expect(steps[0] < 100, "\(steps)")
        #expect(sorted[sorted.count / 2] < 34, "\(steps)")
        #expect(deferred, "the whole document laid out during the resize")
        #expect(!wc.editorArea.allEditors.contains { $0.textView.rowsState.needsSettle })
    }

    // MARK: Row 206: selection

    /// Selecting a file changes the editor and the File inspector in the
    /// same pass (one frame), on screen as off it.
    @Test func editorAndInspectorChangeTogether() throws {
        let dir = try Self.project("select")
        let wc = try Self.window(dir)
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        #expect(!wc.inspectorFollowBox.isEnabled)
        for name in ["Bands.swift", "Long.swift", "Stripes.png", "Bands.swift"] {
            let url = dir.appendingPathComponent("GlassScroll/\(name)")
            let t0 = CACurrentMediaTime()
            wc.open(path: url.path, line: nil)
            let t1 = CACurrentMediaTime()
            #expect(wc.inspector.file?.path == url.path && !wc.isInspectorFollowPending, "\(name)")
            #expect(wc.isShowingInEditor(url), "\(name)")
            #if DEBUG
            let build = "debug"
            #else
            let build = "release"
            #endif
            print("R8B select \(name): \(String(format: "%.1f", (t1 - t0) * 1000)) ms (\(build) build)")
        }
    }

    // MARK: Stills (R8_SHOTS=1): .build-ide/b8-shots

    /// The window mid-show, after the show, and after selecting Bands.swift,
    /// drawn off screen at 1x.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R8_SHOTS"] != nil))
    func stills() throws {
        let dir = try Self.project("shots")
        let wc = try Self.window(dir)
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/b8-shots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot(_ name: String) {
            guard let v = wc.window?.contentView?.superview ?? wc.window?.contentView else { return }
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            print("R8B shot \(out.appendingPathComponent("\(name).png").path)")
        }
        spin(0.3)
        shot("r8-rest")
        wc.toggleInspector(nil)   // hide
        let hide = wc.inspectorSlide
        hide.onFrame?(0.5)
        shot("r8-hide-mid")
        hide.onFrame?(1)
        spin(0.2)
        wc.toggleInspector(nil)   // show
        let show = wc.inspectorSlide
        show.onFrame?(0.5)
        shot("r8-show-mid")
        show.onFrame?(1)
        spin(0.3)
        shot("r8-shown")
        wc.open(path: dir.appendingPathComponent("GlassScroll/Bands.swift").path, line: nil)
        spin(0.3)
        shot("r8-select-bands")
    }
}
