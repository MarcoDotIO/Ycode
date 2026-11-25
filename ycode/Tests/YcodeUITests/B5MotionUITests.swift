import AppKit
import Foundation
import QuartzCore
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Beta 5's motion layer in the macOS IDE (B5-MOTION; `parity-inventory.md`
/// P-024, P-078, P-137, P-190–P-194), off every display: the navigator's
/// and the debug area's slides frame by frame on their curves, ⌥⌘1/2/3 on
/// the shown inspector, the selector disc's slide and fade, the outline's
/// keyboard collapse, the merge alert's drop, narrow windows and the flick's
/// display profile. The frame-cadence measurements need the main thread to
/// themselves: `R8_TIMING=1`.
@MainActor
@Suite(.serialized) struct B5MotionUITests {
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    static func window(_ tag: String) throws -> (WorkspaceWindowController, URL) {
        let dir = try CouncilRound8MotionTests.project("b5m-\(tag)", lines: 300)
        return (try CouncilRound8MotionTests.window(dir), dir)
    }

    /// Steps `slide` at 120 Hz from its press until it ends, laying the
    /// window out after each frame; returns (ms from the press, size).
    func step(_ slide: PaneSlide, in wc: WorkspaceWindowController, size: () -> CGFloat, layoutAndDraw: Bool = false)
        -> [(ms: Double, size: CGFloat, cost: Double)] {
        let press = slide.clock?.press ?? CACurrentMediaTime()
        var out: [(Double, CGFloat, Double)] = []
        var f = 0
        while slide.running, f < 240 {
            f += 1
            let t0 = CACurrentMediaTime()
            slide.advance(to: press + Double(f) / 120)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            if layoutAndDraw {
                wc.window?.displayIfNeeded()
                RunLoop.main.run(until: Date())
            }
            out.append((Double(f) / 120 * 1000, size(), (CACurrentMediaTime() - t0) * 1000))
        }
        return out
    }

    /// The first and last frame whose size changed (ms from the press).
    static func motion(_ frames: [(ms: Double, size: CGFloat, cost: Double)], from start: CGFloat) -> (first: Double, last: Double, count: Int) {
        var previous = start, first: Double?, last = 0.0, count = 0
        for f in frames where f.size != previous {
            first = first ?? f.ms
            last = f.ms
            count += 1
            previous = f.size
        }
        return (first ?? 0, last, count)
    }

    // MARK: P-190: the navigator

    /// ⌘0's hide and show slide the navigator's divider frame by frame on
    /// `Motion.navigator`: nothing moves before the curve's start, every
    /// frame of the motion a new width, the hide collapses the item with its
    /// last frame and the show opens it with its first.
    @Test func navigatorSlides() throws {
        let (wc, _) = try Self.window("nav")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        PaneSlide.offscreen = true
        defer { PaneSlide.offscreen = false }
        let full = wc.navigator.view.frame.width
        #expect(!wc.navigatorItem.isCollapsed && full > 200)
        for show in [false, true] {
            wc.toggleNavigator(nil)
            #expect(wc.isNavigatorSliding)
            let slide = wc.navigatorSlide
            let c = Motion.navigator(show: show)
            #expect(slide.clock?.curve == c)
            let pane = wc.navigatorItem.viewController.view
            let before = show ? 0 : pane.frame.width
            let frames = step(slide, in: wc) { wc.navigatorItem.isCollapsed ? 0 : pane.frame.width }
            let m = Self.motion(frames, from: before)
            if ProcessInfo.processInfo.environment["B5_DIAG"] != nil {
                print("B5M DIAG navigator \(show ? "show" : "hide"): " + zip(frames, slide.frames).map { String(format: "%.0f:%.2f:%.0f", $0.0.ms, $0.1.progress, Double($0.0.size)) }.joined(separator: " "))
            }
            print(String(format: "B5M navigator %@: moves %.0f → %.0f ms from the press, %d widths", show ? "show" : "hide", m.first, m.last, m.count))
            #expect(!wc.isNavigatorSliding)
            // The first whole point of motion within four frames of the
            // curve's start (an ease-in moves less than a point at first).
            #expect(m.first >= c.delay * 1000 - 0.5 && m.first <= c.delay * 1000 + 4 * 8.4 + 0.5, "\(m.first)")
            #expect(abs(m.last - c.total * 1000) <= 8.4 + 0.5, "\(m.last)")
            // A new width on most frames (the sidebar holds its last 10 points
            // for the hide's ease-out tail, under a point a frame).
            #expect(Double(m.count) >= c.duration * 120 * 0.7, "\(m.count) widths")
            let widths = frames.map(\.size)
            #expect(zip(widths, widths.dropFirst()).allSatisfy { show ? $1 >= $0 : $1 <= $0 }, "\(widths)")
            #expect(wc.navigatorItem.isCollapsed == !show)
            if show { #expect(abs(wc.navigator.view.frame.width - full) <= 1, "\(wc.navigator.view.frame.width) of \(full)") }
            _ = pane
        }
        // The menu's path starts sooner.
        #expect(Motion.navigator(show: true, viaMenu: true).delay < Motion.navigator(show: true).delay)
    }

    // MARK: P-191: the debug area

    @Test func debugAreaSlides() throws {
        let (wc, _) = try Self.window("debug")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        PaneSlide.offscreen = true
        defer { PaneSlide.offscreen = false }
        #expect(wc.debugItem.isCollapsed)
        for show in [true, false] {
            wc.toggleDebugArea(nil)
            #expect(wc.isDebugAreaSliding)
            let slide = wc.debugAreaSlide
            let c = Motion.debugArea(show: show)
            #expect(slide.clock?.curve == c)
            let before = show ? 0 : wc.debugArea.view.frame.height
            let frames = step(slide, in: wc) { wc.debugItem.isCollapsed ? 0 : wc.debugArea.view.frame.height }
            let m = Self.motion(frames, from: before)
            print(String(format: "B5M debug area %@: moves %.0f → %.0f ms from the press, %d heights", show ? "show" : "hide", m.first, m.last, m.count))
            #expect(m.first >= c.delay * 1000 - 0.5 && m.first <= c.delay * 1000 + 4 * 8.4 + 0.5, "\(m.first)")
            #expect(abs(m.last - c.total * 1000) <= 8.4 + 0.5, "\(m.last)")
            #expect(m.count >= Int(c.duration * 120) - 6, "\(m.count) heights")
            #expect(wc.debugItem.isCollapsed == !show)
            if show { #expect(abs(wc.debugArea.view.frame.height - wc.debugAreaOpeningHeight) <= 1.5, "\(wc.debugArea.view.frame.height)") }
        }
    }

    /// Off every display (no `PaneSlide.offscreen`), the panes change at once
    /// as before.
    @Test func hiddenWindowsDoNotSlide() throws {
        let (wc, _) = try Self.window("instant")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        wc.toggleNavigator(nil)
        #expect(!wc.isNavigatorSliding)
        wc.showDebugArea(true)
        #expect(!wc.isDebugAreaSliding && !wc.debugItem.isCollapsed)
    }

    // MARK: P-192: ⌥⌘1/2/3

    /// View ▸ Inspectors ▸ <the inspector shown> hides the inspector on the
    /// selector's curves; the next press shows it again.
    @Test func inspectorSelectorToggles() throws {
        let (wc, _) = try Self.window("insp")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        PaneSlide.offscreen = true
        defer { PaneSlide.offscreen = false }
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        item.tag = wc.inspector.selectedIndex
        wc.showInspector(item)
        #expect(wc.isInspectorSliding && wc.inspectorSlide.clock?.bySelector == true && wc.inspectorSlide.show == false)
        wc.inspectorSlide.onFrame?(1)
        spin(0.05)
        #expect(wc.inspectorItem.isCollapsed && !wc.isInspectorSliding)
        wc.showInspector(item)
        #expect(wc.isInspectorSliding && wc.inspectorSlide.clock?.bySelector == true && wc.inspectorSlide.show == true)
        wc.inspectorSlide.onFrame?(0.5)
        wc.inspectorSlide.onFrame?(1)
        spin(0.05)
        #expect(!wc.inspectorItem.isCollapsed)
        // Another inspector's item only switches.
        let other = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        other.tag = (wc.inspector.selectedIndex + 1) % 3
        wc.showInspector(other)
        #expect(!wc.isInspectorSliding && !wc.inspectorItem.isCollapsed && wc.inspector.selectedIndex == other.tag)
        // The toolbar's toggle keeps its own curves.
        #expect(EditorMetrics.inspectorSlideMotion(show: false) == Motion.inspector(show: false).duration)
    }

    // MARK: P-193: the selector disc

    @Test func selectorDiscSlidesOnClickAndFadesOnCommand1() throws {
        let (wc, _) = try Self.window("disc")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        guard GlassBars.enabled else { return }
        let nav = wc.navigator
        let pill = nav.selectorPill
        #expect(pill.slidesOnClick)
        let buttons = nav.selectorButtons
        try #require(buttons.count >= 3)
        let w = try #require(wc.window)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            type == .keyDown
                ? NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                   characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)
                : NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                     eventNumber: 0, clickCount: 1, pressure: 1)
        }
        #expect(SelectionPillView.discMove(for: event(.leftMouseUp), index: 2) == .slide)
        #expect(SelectionPillView.discMove(for: event(.keyDown), index: 0) == .fade)
        #expect(SelectionPillView.discMove(for: event(.keyDown), index: 2) == .jump)
        func rect(under b: NSView) -> NSRect {
            let r = pill.superview!.convert(b.bounds, from: b)
            return NSRect(x: (r.midX - 15).rounded(), y: (r.midY - 12).rounded(), width: 30, height: 24)
        }
        pill.layer?.removeAllAnimations()
        pill.move(to: rect(under: buttons[2]), target: buttons[2], event: event(.leftMouseUp))
        let slide = try #require(pill.layer?.animation(forKey: "discSlide") as? CABasicAnimation)
        #expect(abs(slide.duration - Motion.selectorDisc.duration) < 1e-9)
        #expect(slide.fillMode == .backwards)
        #expect(abs(pill.frame.midX - rect(under: buttons[2]).midX) < 0.5)
        pill.layer?.removeAllAnimations()
        pill.move(to: rect(under: buttons[0]), target: buttons[0], event: event(.keyDown))
        // A transition is kept under the layer's own transition key.
        #expect(!(pill.layer?.animationKeys() ?? []).isEmpty && pill.layer?.animation(forKey: "discSlide") == nil)
        pill.layer?.removeAllAnimations()
        pill.move(to: rect(under: buttons[1]), target: buttons[1], event: nil)
        #expect(pill.layer?.animationKeys()?.isEmpty ?? true)
    }

    // MARK: P-194: the outline's keyboard collapse

    @Test func leftArrowCollapses() throws {
        let left = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123)
        let cmdLeft = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123)
        #expect(OutlineCollapseMotion.isKeyCollapse(left))
        #expect(!OutlineCollapseMotion.isKeyCollapse(cmdLeft) && !OutlineCollapseMotion.isKeyCollapse(nil))
        #expect(Motion.outlineDuration(expand: false, byKey: true) == 0.075)
    }

    // MARK: P-137: the merge alert

    @Test func mergeAlertDropsIn() async throws {
        let (wc, _) = try Self.window("merge")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        let overlay = try #require(MergeOverlayView.install(in: w))
        defer { overlay.close(animated: false) }
        overlay.reduceMotion = false
        let alert = overlay.showAlert(MergeAlertView(branch: "feature", current: "main"))
        let m = Motion.mergeAlertSheet
        let slide = try #require(alert.layer?.animation(forKey: "alertSlide") as? CABasicAnimation)
        #expect(abs(slide.duration - m.duration) < 1e-9 && abs(abs(slide.fromValue as? Double ?? 0) - Motion.mergeAlertDrop) < 1e-9)
        #expect(slide.toValue as? Double == 0 && slide.fillMode == .backwards)
        var c1: [Float] = [0, 0], c2: [Float] = [0, 0]
        slide.timingFunction?.getControlPoint(at: 1, values: &c1)
        slide.timingFunction?.getControlPoint(at: 2, values: &c2)
        #expect(c1 == [Float(m.bezier.x1), Float(m.bezier.y1)] && c2 == [Float(m.bezier.x2), Float(m.bezier.y2)])
        let veil = try #require(overlay.veil.animation(forKey: "veil") as? CABasicAnimation)
        #expect(abs(veil.duration - m.duration) < 1e-9)
        #expect(!alert.mergeButton.isDefaultLook)
        // The main queue runs between the test's awaits, not inside a spin.
        try await Task.sleep(nanoseconds: UInt64((m.total + 0.2) * 1e9))
        #expect(alert.mergeButton.isDefaultLook)
    }

    // MARK: P-024: narrow windows

    // Round 12's rule (the navigator collapses, never shrinks; the
    // minimum follows the inspector) is checked in `B5FixLayoutUITests`.

    // MARK: P-078: the flick's profile

    /// Main 04's events at 2x: the momentum's share and the stretch of round
    /// 11 (23 points, against round 9's 38); X05 stops short of the top.
    @Test func flickFollowsTheDisplayProfile() throws {
        let (wc, _) = try Self.window("flick")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        let scroll = try #require(wc.editor.scrollView as? EditorScrollView)
        #expect(scroll.topBounce.resolvedProfile(scroll) == FlickProfile.forDisplay(scale: Double(wc.window?.backingScaleFactor ?? 2)))
        scroll.topBounce.profile = .retina
        let clip = scroll.contentView
        let top = EditorTopBounce.top(of: scroll)
        let saved = EditorScrollView.nextQueuedEvent
        EditorScrollView.nextQueuedEvent = { _ in nil }
        defer { EditorScrollView.nextQueuedEvent = saved }
        // Main 04: the gesture's 320 points left 280 to the top.
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top + 280))
        scroll.reflectScrolledClipView(clip)
        for e in CouncilRound7EditorTests.flick(step: 40, count: 8, points: 1544, n: 173, span: 1.43, t0: ProcessInfo.processInfo.systemUptime) {
            scroll.scrollWheel(with: e)
        }
        spin(1.5) { !scroll.topBounce.isRunning }
        let fast = scroll.topBounce.lastPeak
        // X05: 480 from the top after the gesture.
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top + 480))
        scroll.reflectScrolledClipView(clip)
        for e in CouncilRound7EditorTests.flick(step: 15, count: 8, points: 566.7, n: 134, span: 1.11, t0: ProcessInfo.processInfo.systemUptime + 2) {
            scroll.scrollWheel(with: e)
        }
        spin(0.5) { !scroll.topBounce.isRunning }
        let applied = scroll.topBounce.appliedMomentum
        print(String(format: "B5M flick (2x profile): main 04 stretch %.1f; X05 momentum applied %.1f (the reference's 274), %.1f from the top",
                     Double(fast), Double(applied), Double(clip.bounds.minY - top)))
        // The timer that stands in for the display link off screen can miss
        // the deepest frame under load: never past 28, and well past round
        // 9's 6-point slow-flick stretch.
        #expect(fast <= 28 && fast >= 12, "\(fast)")
        #expect(applied > 220 && applied < 330, "\(applied)")
        #expect(clip.bounds.minY - top > 100, "X05 stops short of the top")
    }

    // MARK: Stills (B5_SHOTS=1): .build-ide/b5-shots

    /// The window mid-slide and at rest, the merge alert mid-drop and narrow
    /// windows, drawn off screen in dark.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["B5_SHOTS"] != nil))
    func stills() async throws {
        let (wc, _) = try Self.window("shots")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        w.appearance = NSAppearance(named: .darkAqua)
        PaneSlide.offscreen = true
        defer { PaneSlide.offscreen = false }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/b5-shots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot(_ name: String) {
            guard let v = w.contentView?.superview ?? w.contentView else { return }
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("mac-\(name).png"))
            print("B5M shot \(out.appendingPathComponent("mac-\(name).png").path)")
        }
        func half(_ slide: PaneSlide, _ name: String) {
            guard let c = slide.clock else { return }
            // Frame by frame to the middle (a late first frame would start the curve there).
            var t = c.press
            while t < c.press + c.curve.delay + c.curve.duration / 2 {
                t += 1.0 / 120
                slide.advance(to: t)
            }
            shot(name)
            while slide.running, t < c.press + 2 {
                t += 1.0 / 120
                slide.advance(to: t)
            }
            spin(0.1)
        }
        spin(0.3)
        shot("rest")
        wc.toggleNavigator(nil)
        half(wc.navigatorSlide, "navigator-hide-mid")
        shot("navigator-hidden")
        wc.toggleNavigator(nil)
        half(wc.navigatorSlide, "navigator-show-mid")
        wc.toggleDebugArea(nil)
        half(wc.debugAreaSlide, "debug-show-mid")
        shot("debug-shown")
        wc.toggleDebugArea(nil)
        half(wc.debugAreaSlide, "debug-hide-mid")
        if let overlay = MergeOverlayView.install(in: w) {
            overlay.reduceMotion = false
            _ = overlay.showAlert(MergeAlertView(branch: "feature", current: "main"))
            try await Task.sleep(nanoseconds: UInt64((Motion.mergeAlertSheet.total + 0.2) * 1e9))
            shot("merge-alert")
            overlay.close(animated: false)
        }
        for width in [817.0, 503] as [CGFloat] {
            w.setFrame(NSRect(x: -6000, y: -6000, width: width, height: 880), display: true)
            if width < 800 { wc.narrowWindowDidResize(live: true) }
            w.setFrame(NSRect(x: -6000, y: -6000, width: width, height: 880), display: true)
            spin(0.2)
            shot("narrow-\(Int(width))")
        }
    }

    // MARK: Profiling (R8_PROFILE=1)

    /// A measurement, not a check: one flick frame's work (the clip view
    /// moved by a momentum step, the window laid out and drawn, the run
    /// loop's turn), with parts of the editor hidden to find the cost.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R8_PROFILE"] != nil))
    func profileScrollFrames() throws {
        let (wc, _) = try Self.window("profile-scroll")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        let scroll = try #require(wc.editor.scrollView as? EditorScrollView)
        let clip = scroll.contentView
        let top = EditorTopBounce.top(of: scroll)
        spin(0.3)
        func run(_ label: String) {
            clip.scroll(to: NSPoint(x: 0, y: top + 1200))
            scroll.reflectScrolledClipView(clip)
            w.displayIfNeeded()
            var costs: [Double] = []
            for i in 0..<60 {
                let t0 = CACurrentMediaTime()
                clip.scroll(to: NSPoint(x: 0, y: top + 1200 - CGFloat(i) * 17))
                scroll.reflectScrolledClipView(clip)
                w.contentView?.layoutSubtreeIfNeeded()
                w.displayIfNeeded()
                RunLoop.main.run(until: Date())
                costs.append((CACurrentMediaTime() - t0) * 1000)
            }
            let sorted = costs.sorted()
            print(String(format: "B5M PROFILE scroll %@: median %.2f, p90 %.2f, max %.2f ms", label, sorted[30], sorted[54], sorted.last ?? 0))
        }
        run("all")
        wc.editor.bandBackdrop.isHidden = true
        wc.debugArea.bottomBarBackdrop?.isHidden = true
        run("no bars")
        wc.editor.minimap.isHidden = true
        run("no bars, minimap")
        wc.editor.gutter.isHidden = true
        run("no bars, minimap, gutter")
        EditorBlurMotion.begin()
        wc.editor.bandBackdrop.isHidden = false
        wc.debugArea.bottomBarBackdrop?.isHidden = false
        wc.editor.minimap.isHidden = false
        wc.editor.gutter.isHidden = false
        run("bars held")
        EditorBlurMotion.end()
    }

    // MARK: Timing (R8_TIMING=1)

    /// The navigator's and the debug area's slides stepped as a 120 Hz
    /// display steps them, each frame laid out and drawn off screen: the
    /// first and last move against the curve and each frame's work.
    @Test(.enabled(if: CouncilRound8MotionTests.timing)) func paneSlideTiming() throws {
        let (wc, _) = try Self.window("timing")
        defer { MergeSheetR5UITests.Offscreen.off(); wc.window?.orderOut(nil) }
        PaneSlide.offscreen = true
        defer { PaneSlide.offscreen = false }
        spin(0.3)
        for (name, run) in [("navigator", { wc.toggleNavigator(nil) }), ("debug area", { wc.toggleDebugArea(nil) })] as [(String, () -> Void)] {
            for pass in 0..<2 {
                run()
                let nav = name == "navigator"
                let slide = nav ? wc.navigatorSlide : wc.debugAreaSlide
                let c = try #require(slide.clock?.curve)
                let before = nav ? (wc.navigatorItem.isCollapsed ? 0 : wc.navigator.view.frame.width) : (wc.debugItem.isCollapsed ? 0 : wc.debugArea.view.frame.height)
                let frames = step(slide, in: wc, size: {
                    nav ? (wc.navigatorItem.isCollapsed ? 0 : wc.navigator.view.frame.width) : (wc.debugItem.isCollapsed ? 0 : wc.debugArea.view.frame.height)
                }, layoutAndDraw: true)
                let m = Self.motion(frames, from: before)
                let costs = frames.map(\.cost).sorted()
                print(String(format: "B5M timing %@ %@: moves %.0f → %.0f ms (curve %.0f → %.0f), %d sizes, frame work median %.1f max %.1f ms",
                             name, pass == 0 ? "first" : "second", m.first, m.last, c.delay * 1000, c.total * 1000, m.count,
                             costs[costs.count / 2], costs.last ?? 0))
                #expect(abs(m.last - c.total * 1000) <= 8.4 + 0.5)
                spin(0.2)
            }
        }
    }
}
