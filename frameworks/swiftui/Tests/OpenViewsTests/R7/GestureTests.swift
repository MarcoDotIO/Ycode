import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// T-GEST (10-plan.md §3.2): synthetic touch streams on the headless host
// against 06-app-and-components.md §7 — taps on touch-up, double tap
// (120 ms) firing only the double-tap action, long press 0.5 s with the
// pressing sequence, drag (minimum distance 10, velocity, predicted end =
// translation + 0.25 × velocity), simultaneous tap + drag; plus the
// arbitration rules of GestureRuntime.swift, hit testing and hover.

/// A 100 × 100 target centred at (100, 100): spans 50…150.
private let target = CGPoint(x: 100, y: 100)

@MainActor
@Suite("R7 gestures (T-GEST)")
struct GestureTests {
    @Test func tapFiresOnTouchUp() {
        let log = EventLog()
        let h = Harness {
            Color.red.frame(width: 100, height: 100).onTapGesture { log.add("tap") }.position(target)
        }
        h.pointer(.down, target, at: 1.0)
        h.run(until: 1.0)
        #expect(log.entries == [])
        h.pointer(.up, target, at: 1.08)
        h.run(until: 1.08)
        #expect(log.entries == ["tap"])
        // Outside the view: nothing.
        h.tap(CGPoint(x: 300, y: 300), at: 2.0)
        #expect(log.entries == ["tap"])
    }

    @Test func tapFailsWhenThePressMoves() {
        let log = EventLog()
        let h = Harness {
            Color.red.frame(width: 100, height: 100).onTapGesture { log.add("tap") }.position(target)
        }
        h.pointer(.down, target, at: 1.0)
        h.pointer(.moved, CGPoint(x: 115, y: 100), at: 1.02)
        h.pointer(.up, CGPoint(x: 115, y: 100), at: 1.05)
        h.run(until: 1.1)
        #expect(log.entries == [])
    }

    @Test func doubleTapFiresOnlyTheDoubleTapAction() {
        let log = EventLog()
        let h = Harness {
            Color.red.frame(width: 100, height: 100)
                .onTapGesture(count: 2) { log.add("double") }
                .onTapGesture { log.add("single") }
                .position(target)
        }
        // Two taps 120 ms apart (06 §7).
        h.tap(target, at: 1.0, duration: 0.04)
        h.tap(target, at: 1.12, duration: 0.04)
        h.run(until: 2.0)
        #expect(log.entries == ["double"])
        // One tap: the single-tap action, once the double tap gave up.
        log.clear()
        h.tap(target, at: 3.0, duration: 0.04)
        h.run(until: 3.2)
        #expect(log.entries == [])
        h.run(until: 3.5)
        #expect(log.entries == ["single"])
    }

    @Test func longPressReportsPressingAndFiresAtTheDuration() {
        let log = EventLog()
        let h = Harness {
            Color.red.frame(width: 100, height: 100)
                .onLongPressGesture(minimumDuration: 0.5, perform: { log.add("action") },
                                    onPressingChanged: { log.add("pressing \($0)") })
                .position(target)
        }
        h.pointer(.down, target, at: 1.0)
        h.run(until: 1.0)
        #expect(log.entries == ["pressing true"])
        h.run(until: 1.49)
        #expect(log.entries == ["pressing true"])
        h.run(until: 1.5)
        #expect(log.entries == ["pressing true", "action"])
        h.pointer(.up, target, at: 1.8)
        h.run(until: 1.8)
        #expect(log.entries == ["pressing true", "action", "pressing false"])
        // Released early: no action.
        log.clear()
        h.pointer(.down, target, at: 3.0)
        h.pointer(.up, target, at: 3.2)
        h.run(until: 4.0)
        #expect(log.entries == ["pressing true", "pressing false"])
    }

    @Test func dragReportsTranslationVelocityAndPredictedEnd() {
        var changes: [DragGesture.Value] = []
        var ended: [DragGesture.Value] = []
        let h = Harness {
            Color.red.frame(width: 100, height: 100)
                .gesture(DragGesture(minimumDistance: 10)
                    .onChanged { changes.append($0) }
                    .onEnded { ended.append($0) })
                .position(target)
        }
        // 20 steps of (6, 0) at 60 Hz: 360 pt/s.
        let start = CGPoint(x: 70, y: 100)
        h.drag(from: start, delta: CGSize(width: 6, height: 0), steps: 20, at: 1.0)
        // First onChanged once the translation reached 10 (third step: 12).
        #expect(changes.first?.translation.width == 12)
        #expect(changes.count == 19)
        #expect(changes.first?.startLocation == CGPoint(x: 20, y: 50))
        #expect(ended.count == 1)
        guard let e = ended.first else { return }
        #expect(e.translation.width == 120)
        #expect(abs(e.velocity.width - 360) < 0.5)
        #expect(abs(e.predictedEndTranslation.width - (e.translation.width + 0.25 * e.velocity.width)) < 0.5)
        #expect(e.location == CGPoint(x: 140, y: 50))
    }

    @Test func dragWithZeroMinimumDistanceStartsAtTouchDown() {
        var changes = 0
        let h = Harness {
            Color.red.frame(width: 100, height: 100)
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in changes += 1 })
                .position(target)
        }
        h.pointer(.down, target, at: 1.0)
        h.run(until: 1.0)
        #expect(changes == 1)
    }

    @Test func simultaneousDragEndsWithoutTheTap() {
        let log = EventLog()
        let h = Harness {
            Color.red.frame(width: 100, height: 100)
                .onTapGesture { log.add("tap") }
                .simultaneousGesture(DragGesture().onEnded { _ in log.add("drag ended") })
                .position(target)
        }
        h.drag(from: CGPoint(x: 60, y: 100), delta: CGSize(width: 5, height: 0), steps: 10, at: 1.0)
        h.run(until: 1.5)
        #expect(log.entries == ["drag ended"])
        // A plain tap still taps (the drag fails without movement).
        log.clear()
        h.tap(target, at: 2.0)
        #expect(log.entries == ["tap"])
    }

    @Test func innerGestureWinsOverOuterUnlessHighPriority() {
        let log = EventLog()
        let h = Harness {
            VStack {
                Color.red.frame(width: 100, height: 100).onTapGesture { log.add("inner") }
                Color.blue.frame(width: 100, height: 100)
                    .onTapGesture { log.add("inner2") }
                    .highPriorityGesture(TapGesture().onEnded { log.add("outer high") })
            }
            .onTapGesture { log.add("outer") }
        }
        guard let red = h.frame(of: .red), let blue = h.frame(of: .blue) else {
            Issue.record("frames")
            return
        }
        h.tap(red.center, at: 1.0)
        #expect(log.entries == ["inner"])
        log.clear()
        h.tap(blue.center, at: 2.0)
        #expect(log.entries == ["outer high"])
    }

    @Test func gestureStateFollowsTheDragAndResets() {
        var seen: [CGFloat] = []
        let h = Harness { StateDragView { seen.append($0) } }
        h.drag(from: CGPoint(x: 60, y: 100), delta: CGSize(width: 5, height: 0), steps: 6, at: 1.0)
        h.run(until: 1.2)
        // Values written while dragging, then the reset to 0 at the end.
        #expect(seen.contains { $0 >= 20 })
        #expect(seen.last == 0)
    }

    @Test func sequencedLongPressThenDrag() {
        var values: [String] = []
        let h = Harness {
            Color.red.frame(width: 100, height: 100)
                .gesture(LongPressGesture(minimumDuration: 0.3).sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { v in
                        switch v {
                        case .first: values.append("first")
                        case .second(let p, let d): values.append("second \(p) \(d.map { Int($0.translation.width) } ?? -1)")
                        }
                    })
                .position(target)
        }
        h.pointer(.down, target, at: 1.0)
        h.pointer(.moved, CGPoint(x: 120, y: 100), at: 1.5)
        h.pointer(.up, CGPoint(x: 120, y: 100), at: 1.6)
        h.run(until: 1.7)
        #expect(values == ["second true 20"])
    }

    @Test func exclusiveGesturePrefersTheFirst() {
        var values: [String] = []
        let h = Harness {
            Color.red.frame(width: 100, height: 100)
                .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { v in
                    switch v {
                    case .first: values.append("double")
                    case .second: values.append("single")
                    }
                })
                .position(target)
        }
        h.tap(target, at: 1.0)
        h.tap(target, at: 1.1)
        h.run(until: 1.5)
        h.tap(target, at: 2.0)
        h.run(until: 2.5)
        #expect(values == ["double", "single"])
    }

    @Test func masksHitTestingAndDisabledViews() {
        let log = EventLog()
        let h = Harness {
            VStack {
                Color.red.frame(width: 100, height: 100).onTapGesture { log.add("red") }
                    .gesture(TapGesture().onEnded { log.add("masked outer") }, including: .gesture)
                ZStack {
                    Color.green.frame(width: 100, height: 100).onTapGesture { log.add("below") }
                    Color.blue.frame(width: 100, height: 100).onTapGesture { log.add("above") }.allowsHitTesting(false)
                }
                Color.orange.frame(width: 100, height: 60).onTapGesture { log.add("disabled") }.disabled(true)
            }
        }
        guard let red = h.frame(of: .red), let green = h.frame(of: .green), let orange = h.frame(of: .orange) else {
            Issue.record("frames")
            return
        }
        h.tap(red.center, at: 1.0)
        h.tap(green.center, at: 2.0)
        h.tap(orange.center, at: 3.0)
        #expect(log.entries == ["masked outer", "below"])
    }

    @Test func contentShapeMakesGapsHittable() {
        let log = EventLog()
        let h = Harness {
            VStack(spacing: 0) {
                HStack { Color.red.frame(width: 20, height: 40); Spacer(); Color.blue.frame(width: 20, height: 40) }
                    .frame(width: 200)
                    .onTapGesture { log.add("plain") }
                HStack { Color.red.frame(width: 20, height: 40); Spacer(); Color.blue.frame(width: 20, height: 40) }
                    .frame(width: 200)
                    .contentShape(Rectangle())
                    .onTapGesture { log.add("shaped") }
            }
        }
        // The window is 400 × 400; the two 40-pt rows are centred.
        let gapTop = CGPoint(x: 200, y: 180), gapBottom = CGPoint(x: 200, y: 220)
        h.tap(gapTop, at: 1.0)
        h.tap(gapBottom, at: 2.0)
        #expect(log.entries == ["shaped"])
    }

    @Test func buttonActsOnReleaseInsideOnly() {
        let log = EventLog()
        let h = Harness {
            Button { log.add("action") } label: { Color.red.frame(width: 100, height: 50) }
                .position(target)
        }
        h.tap(target, at: 1.0)
        #expect(log.entries == ["action"])
        // Dragged away before release: no action.
        h.pointer(.down, target, at: 2.0)
        h.pointer(.moved, CGPoint(x: 300, y: 300), at: 2.05)
        h.pointer(.up, CGPoint(x: 300, y: 300), at: 2.1)
        h.run(until: 2.2)
        #expect(log.entries == ["action"])
    }

    @Test func buttonInsideATapArea() {
        let log = EventLog()
        let h = Harness {
            VStack {
                Button { log.add("button") } label: { Color.red.frame(width: 100, height: 50) }
                Color.blue.frame(width: 100, height: 50)
            }
            .onTapGesture { log.add("container") }
        }
        guard let red = h.frame(of: .red), let blue = h.frame(of: .blue) else {
            Issue.record("frames")
            return
        }
        h.tap(red.center, at: 1.0)
        h.tap(blue.center, at: 2.0)
        #expect(log.entries == ["button", "container"])
    }

    @Test func hoverEntersAndLeaves() {
        let log = EventLog()
        let h = Harness {
            Color.red.frame(width: 100, height: 100)
                .onHover { log.add($0 ? "enter" : "exit") }
                .onContinuousHover { phase in
                    if case .active(let p) = phase { log.add("at \(Int(p.x)),\(Int(p.y))") } else { log.add("ended") }
                }
                .position(target)
        }
        h.hover(CGPoint(x: 10, y: 10), at: 1.0)
        h.hover(CGPoint(x: 60, y: 70), at: 1.1)
        h.hover(CGPoint(x: 70, y: 70), at: 1.2)
        h.hover(CGPoint(x: 300, y: 300), at: 1.3)
        h.run(until: 1.4)
        // The outer modifier (continuous) is nearer the root, so it hears first.
        #expect(log.entries == ["at 10,20", "enter", "at 20,20", "ended", "exit"])
    }

    @Test func scrollWheelReachesTheInnermostHandler() {
        var deltas: [CGFloat] = []
        let h = Harness {
            Color.red.frame(width: 100, height: 100)
                ._onScrollWheel { d, _ in
                    deltas.append(d.height)
                    return true
                }
                .position(target)
        }
        h.backend.post(.scroll(ScrollEvent(window: h.windowID, location: target, delta: CGSize(width: 0, height: -20),
                                           timestamp: 1.0)), at: 1.0)
        h.run(until: 1.1)
        #expect(deltas == [-20])
    }
}

/// A view whose `@GestureState` follows a drag's horizontal translation.
struct StateDragView: View {
    let report: (CGFloat) -> Void
    @GestureState private var offset: CGFloat = 0

    var body: some View {
        let _ = report(offset)
        Color.red.frame(width: 100, height: 100)
            .gesture(DragGesture(minimumDistance: 0).updating($offset) { v, s, _ in s = v.translation.width })
            .position(x: 100, y: 100)
    }
}
