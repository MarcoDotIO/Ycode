import Foundation
import Testing
@testable import YcodeIDECore

/// Beta 5's motion layer in the models both IDEs share (B5-MOTION;
/// `specs/ide/parity-inventory.md` P-024, P-078, P-137, P-190–P-197):
/// every curve's timing against the reference's measured start, end and
/// shape, the slide clock, the tooltip fade, the narrow window's panes, and
/// the flicks on both displays from the council's logged input.
@Suite struct B5MotionTests {
    /// The curve's first and last moving times from the press (ms), at 120 Hz.
    static func moving(_ c: Motion.Curve) -> (first: Double, last: Double, frames: Int) {
        var first: Double?, last = 0.0, frames = 0, previous = 0.0
        for f in 0...240 {
            let t = Double(f) / 120
            let p = c.progress(elapsed: t)
            if p != previous {
                first = first ?? t
                last = t
                frames += 1
            }
            previous = p
        }
        return ((first ?? 0) * 1000, last * 1000, frames)
    }

    /// Each curve, against the reference's times from the input: the curve
    /// starts `Motion.inputLatency` sooner (Ycode's own latency adds it
    /// back) and moves for the measured length.
    @Test func everyCurveFollowsTheReference() {
        let rows: [(String, Motion.Curve, start: Double, end: Double)] = [
            // Council round 12 (`window-layout.md` §6.1, §6.2): 240 ms for
            // every navigator trigger, the debug area linear.
            ("navigator hide (key)", Motion.navigator(show: false), 72, 312),
            ("navigator hide (click)", Motion.navigator(show: false, trigger: .click), 84, 324),
            ("navigator show (click)", Motion.navigator(show: true, trigger: .click), 159, 399),
            ("navigator show (menu)", Motion.navigator(show: true, viaMenu: true), 38, 278),
            ("debug hide", Motion.debugArea(show: false), 78, 338),
            ("debug show", Motion.debugArea(show: true), 69, 319),
            ("breakpoints dim", Motion.breakpointDim, 88, 155),
            ("inspector hide", Motion.inspector(show: false), 129, 404),
            ("inspector show", Motion.inspector(show: true), 78, 320),
            ("inspector hide (⌥⌘N)", Motion.inspector(show: false, bySelector: true), 67, 367),
            ("inspector show (⌥⌘N)", Motion.inspector(show: true, bySelector: true), 111, 377),
            ("selector disc", Motion.selectorDisc, 147, 430),
            ("merge alert", Motion.mergeAlertSheet, 85, 368),
            ("scheme sheet exit", Motion.schemeSheetExit, 75, 246),
            ("branch sheet exit", Motion.branchSheetExit, 177, 493),
        ]
        let latency = Motion.inputLatency * 1000
        for (name, c, start, end) in rows {
            let m = Self.moving(c)
            print(String(format: "B5MOTION %@: moves %.0f → %.0f ms from the press (%d frames at 120 Hz), %.0f → %.0f from the input",
                         name, m.first, m.last, m.frames, m.first + latency, m.last + latency))
            // The first moving frame within a frame of the start, the last at the end.
            #expect(abs(c.delay * 1000 - max(0, start - latency)) < 0.5, "\(name)")
            #expect(abs(c.duration * 1000 - (end - start)) < 0.5, "\(name)")
            #expect(m.first + latency <= max(start, latency) + 8.4 + 0.5, "\(name): first \(m.first)")
            #expect(abs(m.last - c.total * 1000) <= 8.4, "\(name): last \(m.last)")
            #expect(c.progress(elapsed: c.total) == 1 && c.progress(elapsed: 0) == 0 || c.delay == 0, "\(name)")
        }
        // The frame counts the inventory gives: the navigator's menu path in
        // 21 frames at 120 Hz (its own recorder ran at about 85), the merge
        // alert's 24 at 85 Hz.
        #expect(Motion.navigator(show: true, viaMenu: true).frames(at: 87) == 21)
        #expect(Motion.mergeAlertSheet.frames(at: 85) == 24)
    }

    /// The shapes: the navigator eases in and out (P-190, round 12); the
    /// debug area is linear (P-191); the disc eases out (P-193); the merge
    /// alert is symmetric (P-137).
    @Test func curveShapes() {
        for show in [false, true] {
            let b = Motion.navigator(show: show).bezier
            #expect(b.progress(0.15) < 0.15 && b.progress(0.85) > 0.85 && abs(b.progress(0.5) - 0.5) < 0.12, "\(show)")
        }
        #expect(Motion.debugArea(show: false).bezier == .linear && Motion.debugArea(show: true).bezier == .linear)
        #expect(Motion.selectorDisc.bezier.progress(0.25) > 0.35)
        let m = Motion.mergeAlertSheet.bezier
        for x in stride(from: 0.05, through: 0.95, by: 0.05) { #expect(abs(m.progress(x) + m.progress(1 - x) - 1) < 1e-6) }
        // Monotonic, 0 to 1, for every curve.
        for b in [Motion.Bezier.navigatorHide, .navigatorShow, .easeIn, .easeOut, .easeInOut, m] {
            var last = 0.0
            for x in stride(from: 0.0, through: 1.0, by: 0.01) {
                let y = b.progress(x)
                #expect(y >= last - 1e-9)
                last = y
            }
            #expect(b.progress(1) == 1 && b.progress(0) == 0)
        }
    }

    /// The inspector's timing goes through `EditorMetrics` (both IDEs'
    /// slides read it there) and its clock.
    @Test func inspectorTimingThroughEditorMetrics() {
        for show in [false, true] {
            for bySelector in [false, true] {
                let c = Motion.inspector(show: show, bySelector: bySelector)
                #expect(EditorMetrics.inspectorSlideDelay(show: show, bySelector: bySelector) == c.delay)
                #expect(EditorMetrics.inspectorSlideMotion(show: show, bySelector: bySelector) == c.duration)
                var clock = InspectorSlideClock(show: show, press: 0, bySelector: bySelector)
                var t = 0.0, p = 0.0
                while !clock.isFinished, t < 2 {
                    t += 1.0 / 120
                    p = clock.progress(at: t)
                }
                #expect(p == 1 && abs(t - c.total) <= 1.0 / 120 + 1e-9, "\(show) \(bySelector): \(t)")
            }
        }
    }

    /// The generic clock: on time it follows the press; a late first frame
    /// starts the motion there; a stall advances one 30 Hz frame at most.
    @Test func motionClock() {
        let c = Motion.debugArea(show: true)
        var on = MotionClock(curve: c, press: 10)
        #expect(on.progress(at: 10 + c.delay) == 0)
        #expect(abs(on.progress(at: 10 + c.delay + c.duration / 2) - min(1, c.progress(elapsed: c.delay + 1.0 / 30))) < 1e-9)
        var late = MotionClock(curve: c, press: 0)
        #expect(late.progress(at: 1) == 0, "a late first frame starts the motion")
        #expect(late.progress(at: 1 + 1.0 / 120) > 0)
        var frames = 0
        var clock = MotionClock(curve: c, press: 0)
        while !clock.isFinished { frames += 1; _ = clock.progress(at: Double(frames) / 120) }
        #expect(abs(Double(frames) / 120 - c.total) <= 1.0 / 120)
    }

    /// P-193: ⌘1 cross-fades over 75 ms; ⌘2–⌘9 change in one frame.
    @Test func selectorKeys() {
        #expect(Motion.selectorKeyFade(index: 0) == 0.075)
        for i in 1..<9 { #expect(Motion.selectorKeyFade(index: i) == 0) }
        #expect(Motion.selectorContentSwap < Motion.selectorDisc.start)
    }

    /// P-194: the keyboard's collapse 75 ms (5 frames at 60 Hz), the
    /// expand and the triangle's collapse 150–200 ms.
    @Test func outlineDurations() {
        #expect(Motion.outlineDuration(expand: false, byKey: true) == 0.075)
        #expect((0.15...0.2).contains(Motion.outlineDuration(expand: true, byKey: true)))
        #expect((0.15...0.2).contains(Motion.outlineDuration(expand: false, byKey: false)))
    }

    /// P-196: sheets leave in 250–315 ms (the scheme sheet's measured 171 ms
    /// of motion is its own); the popover closes in one frame.
    @Test func sheetExits() {
        #expect((0.25...0.315).contains(Motion.sheetExitDuration))
        #expect(abs(Motion.branchSheetExit.duration - 0.316) < 0.001)
        #expect(Motion.popoverClose == 0 && Motion.welcomeFadeLag == 0.1)
        // B5-NEWPROJECT's fades.
        #expect(Motion.newProjectOptionsFadeIn == 0.19 && Motion.welcomeFadeOut == 0.1)
        #expect(TemplateChooserMetrics.optionsFadeDuration == Motion.newProjectOptionsFadeIn)
        // B5-TOOLBAR's Run menu hold.
        #expect(RunButtonMenu.holdDelay == Motion.runMenuHoldDelay && Motion.runMenuHoldDelay == 0.374)
    }

    /// P-197 (round 12): after the pointer leaves, the tooltip stays 350 ms,
    /// then fades over 460 ms.
    @Test func tooltipFade() {
        #expect(Motion.tooltipOpacity(afterLeave: 0) == 1)
        #expect(Motion.tooltipOpacity(afterLeave: 0.35) == 1)
        #expect(abs(Motion.tooltipOpacity(afterLeave: 0.35 + 0.23) - 0.5) < 1e-9)
        #expect(Motion.tooltipOpacity(afterLeave: 0.81) == 0 && abs(Motion.tooltipGone - 0.81) < 1e-9)
    }

    // MARK: P-024: narrow windows

    @Test func narrowWindowPanes() {
        let nav = WorkspaceChrome.navigatorWidth, insp = WorkspaceChrome.inspectorWidth
        // Above the editor's 300 only the editor narrows (window-layout.md §1).
        for w in stride(from: 1400.0, through: 852, by: -25) {
            let p = NarrowWindowLayout.panes(width: w, navigator: nav, inspector: insp)
            #expect(p.navigator == nav && p.inspector == insp && p.editor >= 300, "\(w)")
        }
        #expect(abs(NarrowWindowLayout.contentMinimum - (nav + 300 + insp)) < 1e-9)
        // Round 12 (§4.2): the navigator never shrinks; it collapses once
        // the editor would go below 300, then the inspector narrows.
        let n817 = NarrowWindowLayout.panes(width: 817, navigator: nav, inspector: insp)
        #expect(n817.navigator == nil && n817.inspector == insp && n817.editor >= 300, "\(n817)")
        let n503 = NarrowWindowLayout.panes(width: 503, navigator: nav, inspector: insp)
        #expect(n503.navigator == nil && abs((n503.inspector ?? 0) - 201.5) <= 1 && n503.editor >= 300, "\(n503)")
        for w in stride(from: 400.0, through: 1400, by: 7) {
            let p = NarrowWindowLayout.panes(width: w, navigator: nav, inspector: insp)
            #expect(p.editor >= 300 - 1e-9, "\(w)")
            #expect(p.navigator == nil || p.navigator == nav, "\(w)")
        }
        #expect(!NarrowWindowLayout.liveResizeHidesNavigator(width: 860, inspector: insp))
        #expect(NarrowWindowLayout.liveResizeHidesNavigator(width: 845, inspector: insp))
        #expect(!NarrowWindowLayout.liveResizeHidesNavigator(width: 600, inspector: nil))
        #expect(NarrowWindowLayout.liveResizeHidesNavigator(width: 585, inspector: nil))
    }

    /// P-197's appearance: 1.56 s on the toolbar, the 0.35-s hold chained, 1.1 s on an
    /// editor tab; 18 pt below the pointer, 24 tall.
    @Test func tooltipAppearance() {
        #expect(Motion.tooltipDelay(tab: false, chained: false) == 1.56)
        #expect(Motion.tooltipDelay(tab: false, chained: true) == 0.35 && Motion.tooltipDelay(tab: true, chained: false) == 1.1)
        #expect(Motion.tooltipBelowPointer == 18 && Motion.tooltipLineHeight == 24)
        #expect(Motion.tooltipDarkFill == 0x444446 && Motion.tooltipDarkOutline == 0x101012)
    }

    // MARK: P-078: the flicks on both displays

    /// The council's logged input (the deferred flick study): 8 gesture
    /// events of `step` points over 60 ms, an end, then the momentum.
    static func logged(step: Double, momentum: [(time: Double, dy: Double)], sign: Double = 1) -> [EditorFlick.Step] {
        var out: [EditorFlick.Step] = [.init(dy: 0, phase: .began, time: 0)]
        for i in 0..<8 { out.append(.init(dy: sign * step, phase: .changed, time: Double(i) * 0.060 / 7)) }
        out.append(.init(dy: 0, phase: .ended, time: 0.060))
        for (i, e) in momentum.enumerated() {
            out.append(.init(dy: sign * e.dy, momentumPhase: i == 0 ? .began : .changed, time: e.time))
        }
        out.append(.init(dy: 0, momentumPhase: .ended, time: (momentum.last?.time ?? 0) + 0.0001))
        return out
    }

    /// The flick on the shared model from 600 points before `edge`, drawn
    /// every 120 Hz frame: travel towards the edge per frame.
    static func run(_ steps: [EditorFlick.Step], profile: FlickProfile, edge: EditorFlick.Edge) -> [(t: Double, travel: Double)] {
        let maxOffset = 5000.0
        var flick = EditorFlick(profile: profile)
        var offset = edge == .top ? 600 : maxOffset - 600
        var pending = steps
        var curve: [(Double, Double)] = []
        for f in 0..<240 {
            let t = Double(f + 1) / 120
            while let s = pending.first, s.time <= t {
                pending.removeFirst()
                switch flick.handle(s, offset: offset, maxOffset: maxOffset, visibleHeight: 758.5) {
                case .scroll(let y): offset = y
                case .bounce(let e): offset = e == .top ? 0 : maxOffset
                case .held, .ignored: break
                }
            }
            if let e = flick.bounce?.edge {
                let x = flick.overscroll(at: t, frame: 1.0 / 120) ?? 0
                offset = e == .bottom ? maxOffset + x : -x
            }
            curve.append((t, edge == .top ? 600 - offset : offset - (maxOffset - 600)))
        }
        return curve
    }

    /// Round 11 at 2x / 120 Hz: main 04 stretches 23, X03 passes the end by
    /// 18, X05 travels 394 and stops short. Round 10 at 1x / 100 Hz: 182,
    /// 111, and 552. Each frame a new position until the flick is at rest.
    @Test(arguments: [(FlickProfile.retina, 23.0, 18.0, 394.0), (FlickProfile.standard, 182.0, 111.0, 552.0)])
    func flicksMatchTheirDisplay(profile: FlickProfile, top: Double, bottom: Double, slowTravel: Double) {
        let main04 = Self.run(Self.logged(step: 40, momentum: FlickProfile.mainFlick), profile: profile, edge: .top)
        let x03 = Self.run(Self.logged(step: 40, momentum: FlickProfile.mainFlick, sign: -1), profile: profile, edge: .bottom)
        let x05 = Self.run(Self.logged(step: 15, momentum: FlickProfile.slowFlick), profile: profile, edge: .top)
        func peak(_ c: [(t: Double, travel: Double)]) -> (stretch: Double, at: Double, rest: Double) {
            let p = c.max { $0.travel < $1.travel } ?? (0, 0)
            let rest = Array(zip(c.dropFirst(), c)).last { abs($0.0.travel - $0.1.travel) > 1e-6 }?.0.t ?? 0
            return (p.travel - 600, p.t, rest)
        }
        let a = peak(main04), b = peak(x03), s = peak(x05)
        print(String(format: "B5MOTION flick %@: main 04 stretch %.1f at %.0f ms, rest %.0f; X03 %.1f at %.0f, rest %.0f; X05 travels %.1f, rest %.0f",
                     profile.name, a.stretch, a.at * 1000, a.rest * 1000, b.stretch, b.at * 1000, b.rest * 1000, s.stretch + 600, s.rest * 1000))
        #expect(abs(a.stretch - top) <= max(2, top * 0.05), "main 04: \(a.stretch)")
        #expect(abs(b.stretch - bottom) <= max(2, bottom * 0.05), "X03: \(b.stretch)")
        #expect(abs((s.stretch + 600) - slowTravel) <= 4, "X05: \(s.stretch + 600)")
        #expect(s.stretch < 0, "X05 stops short of the top")
        // The fast flicks come back exactly to the edge.
        #expect(abs((main04.last?.travel ?? 0) - 600) < 1e-6 && abs((x03.last?.travel ?? 0) - 600) < 1e-6)
        // A new position every frame while the text moves (no held frames
        // between the first move and the rest).
        for c in [main04, x03] {
            let moving = c.filter { $0.t <= peak(c).rest }
            let holds = zip(moving.dropFirst(), moving).filter { $0.0.travel == $0.1.travel && $0.0.t > 0.02 }
            #expect(holds.isEmpty, "\(holds.count) held frames")
        }
        // 1x: deepest near +163 ms, at rest by about +830 (the reference).
        if profile == .standard { #expect(a.rest < 0.9) }
    }

    /// The display picks the profile; round 9's stays one to one.
    @Test func profileByDisplay() {
        #expect(FlickProfile.forDisplay(scale: 2) == .retina && FlickProfile.forDisplay(scale: 1) == .standard)
        #expect(EditorMomentum(profile: .round9).gain(after: 3) == 1)
        #expect(EditorMomentum(profile: .retina).gain(after: 0.2818) < 0.37)
        #expect(abs(FlickProfile.round9.stretch(forCrossing: TopBounce.referenceVelocity) - 35) < 1e-9)
        // Faster crossings stretch more, on every profile.
        for p in [FlickProfile.retina, .standard] {
            #expect(p.stretch(forCrossing: 2 * p.referenceCrossing) > p.stretch(forCrossing: p.referenceCrossing))
        }
    }
}
