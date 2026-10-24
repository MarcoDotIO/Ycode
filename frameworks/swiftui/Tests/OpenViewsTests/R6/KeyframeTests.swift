import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// 05-animation.md §6 (T-KEYFRAME, tolerance 0.01) and the keyframe rules.

@Suite("05 §6 keyframes (T-KEYFRAME)")
struct KeyframeTests {
    /// The measured timeline: Linear(100, 1), Spring(0, 1), Cubic(50, 0.5),
    /// Move(10), Cubic(20, 0.5) from 0.
    static func measuredTimeline() -> KeyframeTimeline<Double> {
        KeyframeTimeline(initialValue: 0.0) {
            LinearKeyframe(100.0, duration: 1)
            SpringKeyframe(0.0, duration: 1)
            CubicKeyframe(50.0, duration: 0.5)
            MoveKeyframe(10.0)
            CubicKeyframe(20.0, duration: 0.5)
        }
    }

    static let measured: [Double] = [
        0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 67.07, 30.08, 11.69, 4.22,
        1.45, 0.49, 0.16, 0.05, 0.02, 0.01, 5.20, 17.60, 32.40, 44.80, 50, 11.04,
        13.52, 16.48, 18.96, 20,
    ]

    @Test("05 §6: the timeline's duration is 3.0 (keyframe durations add up; a move takes no time)")
    func duration() {
        #expect(Self.measuredTimeline().duration == 3.0)
    }

    @Test("05 §6: value every 0.1 s, 31 values within 0.01", arguments: 0...30)
    func value(index: Int) {
        let v = Self.measuredTimeline().value(time: Double(index) / 10)
        #expect(abs(v - Self.measured[index]) <= 0.01, "t=\(Double(index) / 10): \(v) vs \(Self.measured[index])")
    }

    @Test("05 §6: value(progress:) is value(time: progress × duration)")
    func progress() {
        let t = Self.measuredTimeline()
        #expect(abs(t.value(progress: 0.5) - t.value(time: 1.5)) < 1e-12)
        #expect(abs(t.value(progress: 1) - 20) < 1e-9)
    }

    @Test("05 §6: the spring segment starts with the linear segment's velocity (+100/s), so it is above the plain smooth spring")
    func springInheritsVelocity() {
        let t = Self.measuredTimeline()
        let plain = 100 - 100 * Spring.smooth.value(target: 1.0, time: 0.1)
        #expect(t.value(time: 1.1) > plain + 2)
    }

    @Test("05 §6: a cubic segment between zero slopes follows v0 + (v1 − v0)(3u² − 2u³)")
    func cubicHermite() {
        let t = KeyframeTimeline(initialValue: 0.0) { CubicKeyframe(10.0, duration: 1) }
        for u in stride(from: 0.0, through: 1.0, by: 0.125) {
            #expect(abs(t.value(time: u) - 10 * (3 * u * u - 2 * u * u * u)) < 1e-9)
        }
    }

    @Test("Consecutive cubic keyframes join with a Catmull-Rom slope (inferred; the spec leaves it open)")
    func cubicCatmullRom() {
        let t = KeyframeTimeline(initialValue: 0.0) {
            CubicKeyframe(10.0, duration: 1)
            CubicKeyframe(30.0, duration: 1)
        }
        // Slope at t = 1 is (30 − 0) / 2 = 15 from both sides.
        let h = 1e-6
        let left = (t.value(time: 1) - t.value(time: 1 - h)) / h
        let right = (t.value(time: 1 + h) - t.value(time: 1)) / h
        #expect(abs(left - 15) < 1e-3 && abs(right - 15) < 1e-3)
    }

    @Test("Explicit start and end velocities of a cubic keyframe are its slopes")
    func cubicExplicitVelocity() {
        let t = KeyframeTimeline(initialValue: 0.0) { CubicKeyframe(1.0, duration: 1, startVelocity: 2, endVelocity: 0) }
        let h = 1e-6
        #expect(abs((t.value(time: h) - t.value(time: 0)) / h - 2) < 1e-3)
    }

    @Test("A linear keyframe follows its timing curve")
    func linearTimingCurve() {
        let t = KeyframeTimeline(initialValue: 0.0) { LinearKeyframe(1.0, duration: 2, timingCurve: .easeInOut) }
        #expect(abs(t.value(time: 0.5) - UnitCurve.easeInOut.value(at: 0.25)) < 1e-9)
    }

    @Test("A move keyframe jumps without taking time; after the last keyframe the value holds")
    func moveAndHold() {
        let t = KeyframeTimeline(initialValue: 0.0) {
            MoveKeyframe(5.0)
            LinearKeyframe(7.0, duration: 1)
        }
        #expect(t.duration == 1)
        #expect(abs(t.value(time: 0.5) - 6) < 1e-9)
        #expect(t.value(time: 5) == 7)
    }

    struct Pose { var x = 0.0; var scale = 1.0 }

    @Test("Tracks animate key paths of the value independently; the timeline lasts as long as its longest track")
    func tracks() {
        let t = KeyframeTimeline(initialValue: Pose()) {
            KeyframeTrack(\Pose.x) { LinearKeyframe(10.0, duration: 1) }
            KeyframeTrack(\Pose.scale) { LinearKeyframe(2.0, duration: 2) }
        }
        #expect(t.duration == 2)
        let v = t.value(time: 1.5)
        #expect(v.x == 10 && abs(v.scale - 1.75) < 1e-9)
    }

    @Test("Builder: conditionals and loops of keyframes")
    func builder() {
        let flag = Bool.random()
        let t = KeyframeTimeline(initialValue: 0.0) {
            if flag { LinearKeyframe(1.0, duration: 1) } else { LinearKeyframe(2.0, duration: 1) }
            for i in 1...3 { LinearKeyframe(Double(i * 10), duration: 0.5) }
        }
        #expect(t.duration == 2.5)
        #expect(t.value(time: 1) == (flag ? 1 : 2))
        #expect(t.value(time: 2.5) == 30)
    }
}
