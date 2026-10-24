import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// 05-animation.md §1 and §4 on the headless host with a manual 60 Hz clock
// (T-ANIM: frames, v@ samples, completion times; ±1 frame, ±0.01 unless the
// conformance checklist (I-3, I-6) allows ±3 frames for values measured
// while rendering on the loaded reference host).

@MainActor
@Suite("05 §1 the model: frames and model values")
struct AnimationModelTests {
    @Test("05 §1: a 1 s linear animation evaluates the animatable body 61 times (once at the change, then once per 60 Hz frame)")
    func linearFrames() {
        let run = AnimRun()
        run.animate(.linear(duration: 1))
        #expect(run.samples.count == 61)
        #expect(run.samples.last == 1)
    }

    @Test("05 §1: the model value is the new value at once; the presented value starts at the old one")
    func modelImmediately() {
        let run = AnimRun()
        run.animate(.linear(duration: 1), settle: false)
        #expect(run.control.value == 1)
        #expect(run.samples.entries.first?.value == 0)
    }

    @Test("05 §4: start latency: the first changed frame is one display frame after the state change")
    func startLatency() {
        let run = AnimRun()
        run.animate(.linear(duration: 1))
        #expect(withinFrames(run.samples.changeTimes.first, frame, 0))
    }

    @Test("05 §4 checklist I-3: .linear(duration: 1).speed(2) has 31 frames")
    func speedFrames() {
        let run = AnimRun()
        run.animate(.linear(duration: 1).speed(2))
        #expect(run.samples.count == 31)
    }

    @Test("05 §4 checklist I-3: .default has ≈ 77 frames (±3)")
    func defaultFrames() {
        let run = AnimRun()
        run.animate(.default)
        #expect(abs(run.samples.count - 77) <= 3, "frames=\(run.samples.count)")
    }

    @Test("05 §4: with no animation the value changes in one evaluation (frames=1)")
    func noAnimation() {
        let run = AnimRun()
        let (logical, _) = run.animate(nil)
        #expect(run.samples.count == 1 && run.samples.last == 1)
        #expect(logical == 0)
    }
}

@MainActor
@Suite("05 §4 animation values while rendering (T-ANIM)")
struct AnimationSampleTests {
    @Test("05 §4: .linear(duration: 1): v@0.25 = 0.2465, v@0.5 = 0.4959; at the target at 1.00 s")
    func linearSamples() {
        let run = AnimRun()
        run.animate(.linear(duration: 1))
        #expect(run.samples.matches(0.2465, at: 0.25))
        #expect(run.samples.matches(0.4959, at: 0.5))
        #expect(withinFrames(run.samples.firstTime(at: 1), 1.00, 3))
    }

    @Test("05 §4: .easeInOut(duration: 1): v@0.25 = 0.119, v@0.75 = 0.860; at the target at 1.01 s")
    func easeInOutSamples() {
        let run = AnimRun()
        run.animate(.easeInOut(duration: 1))
        #expect(run.samples.matches(0.119, at: 0.25))
        #expect(run.samples.matches(0.860, at: 0.75))
        #expect(withinFrames(run.samples.firstTime(at: 1), 1.01, 3))
    }

    @Test("05 §4: curves without a duration last 0.35 s (easeInOut at the target at 0.37 s)", arguments: [
        Animation.linear, .easeIn, .easeOut, .easeInOut,
    ])
    func defaultCurveDuration(animation: Animation) {
        let run = AnimRun()
        run.animate(animation)
        #expect(withinFrames(run.samples.firstTime(at: 1), 0.37, 3))
        #expect(withinFrames(run.samples.firstTime(at: 1), 0.35, 0))
    }

    @Test("05 §4: .linear(duration: 1).delay(0.5): no frames during the delay; ramp from 0.5 to 1.5 s")
    func delay() {
        let run = AnimRun()
        run.animate(.linear(duration: 1).delay(0.5))
        let during = run.samples.entries.filter { $0.time > 0 && $0.time < 0.5 - 1e-9 }
        #expect(during.isEmpty)
        #expect(run.samples.matches(0.5, at: 1.0))
        #expect(withinFrames(run.samples.firstTime(at: 1), 1.51, 3))
    }

    @Test("05 §4: .linear(duration: 0.5).repeatCount(2, autoreverses: true): 0 → 1 in 0.5 s, back to 0 at 1.0 s, then jumps to the model value")
    func repeatCount() {
        let run = AnimRun()
        run.animate(.linear(duration: 0.5).repeatCount(2, autoreverses: true))
        #expect(run.samples.matches(1, at: 0.5))
        #expect(run.samples.matches(0.5, at: 0.75))
        #expect(run.samples.matches(0, at: 1.0, frames: 1))
        #expect(run.samples.last == 1)
        #expect(withinFrames(run.samples.entries.last?.time, 1.04, 3))
    }

    @Test("05 §4: .linear(duration: 1).speed(2) takes half the duration (0.51 s)")
    func speed() {
        let run = AnimRun()
        run.animate(.linear(duration: 1).speed(2))
        #expect(run.samples.matches(0.5, at: 0.25))
        #expect(withinFrames(run.samples.firstTime(at: 1), 0.51, 3))
    }

    @Test("05 §4: spring animations reach the target (4 decimals) at the measured times", arguments: [
        (Animation.default, 1.03), (.spring(), 1.01), (.smooth, 1.02), (.snappy, 0.85), (.bouncy, 0.94),
        (.interactiveSpring(), 0.26),
    ])
    func springRenderedDuration(animation: Animation, measured: Double) {
        let run = AnimRun()
        run.animate(animation)
        #expect(withinFrames(run.samples.firstTime(at: 1), measured, 3), "\(String(describing: run.samples.firstTime(at: 1)))")
    }

    @Test("05 §4: .default tracks the response-0.5 critically damped spring")
    func defaultTracksSpring() {
        let run = AnimRun()
        run.animate(.default)
        for t in stride(from: 0.05, through: 0.5, by: 0.05) {
            #expect(run.samples.matches(Spring.smooth.value(target: 1.0, time: t), at: t, tolerance: 1e-4, frames: 0))
        }
    }

    @Test("05 §4: overshoot: .bouncy 1.0419, .snappy 1.0044 (±0.01)")
    func overshoot() {
        let bouncy = AnimRun()
        bouncy.animate(.bouncy)
        #expect(abs(bouncy.samples.maximum - 1.0419) <= 0.01)
        let snappy = AnimRun()
        snappy.animate(.snappy)
        #expect(abs(snappy.samples.maximum - 1.0044) <= 0.01)
    }

    @Test("05 §4: .interpolatingSpring uses mass 1, stiffness 157.9137, damping 25.1327")
    func interpolatingSpring() {
        let run = AnimRun()
        run.animate(.interpolatingSpring)
        #expect(run.samples.matches(Spring(mass: 1, stiffness: 157.9137, damping: 25.1327).value(target: 1.0, time: 0.2),
                                    at: 0.2, tolerance: 1e-4, frames: 0))
    }

    @Test("repeatForever never finishes")
    func repeatForever() {
        let run = AnimRun()
        run.animate(.linear(duration: 0.5).repeatForever(), settle: false)
        run.graph.advance(seconds: 3)
        #expect(run.graph.isAnimating)
        #expect(run.samples.matches(1, at: 2.5) && run.samples.matches(0, at: 3.0))
    }
}

@MainActor
@Suite("05 §4 completion criteria (T-ANIM, checklist I-6)")
struct CompletionTimingTests {
    @Test("05 §4: logical completion at the nominal duration; .removed when the animation is removed", arguments: [
        (Animation.default, 0.53, nil as Double?), (.linear, 0.37, nil), (.linear(duration: 1), 1.02, 1.02),
        (.easeInOut(duration: 1), 1.03, 1.03), (.spring(), 0.51, 1.28), (.bouncy, 0.51, nil), (.smooth, 0.52, nil),
        (.snappy, 0.51, nil), (.interactiveSpring(), 0.18, nil), (.linear(duration: 1).delay(0.5), 1.53, nil),
        (.linear(duration: 0.5).repeatCount(2, autoreverses: true), 1.04, nil), (.linear(duration: 1).speed(2), 0.52, nil),
    ])
    func completion(animation: Animation, logical: Double, removed: Double?) {
        let run = AnimRun()
        let c = run.animate(animation)
        #expect(withinFrames(c.logical, logical, 3), "logical \(String(describing: c.logical))")
        if let removed { #expect(withinFrames(c.removed, removed, 3), "removed \(String(describing: c.removed))") }
    }

    @Test("05 §4: nil animation completes at once (0.01 s)")
    func nilCompletes() {
        let run = AnimRun()
        let c = run.animate(nil)
        #expect(withinFrames(c.logical, 0.01, 1) && withinFrames(c.removed, 0.01, 1))
    }

    @Test("05 §4: withAnimation(_:completionCriteria:_:completion:) fires at the criterion")
    func withAnimationCompletion() {
        let run = AnimRun()
        var logical: Double?, removed: Double?
        let g = run.graph
        withAnimation(.spring(), completionCriteria: .logicallyComplete) { run.control.value = 1 } completion: {
            logical = g.currentTime
        }
        g.update()
        g.settle()
        withAnimation(.spring(), completionCriteria: .removed) { run.control.value = 0 } completion: {
            removed = g.currentTime
        }
        let start = g.currentTime
        g.update()
        g.settle()
        #expect(withinFrames(logical, 0.5, 1))
        #expect(withinFrames(removed.map { $0 - start }, 1.28, 3))
    }

    @Test("Animation.logicallyComplete(after:) moves the logical completion")
    func logicallyCompleteAfter() {
        let run = AnimRun()
        let c = run.animate(.linear(duration: 1).logicallyComplete(after: 0.25))
        #expect(withinFrames(c.logical, 0.25, 0))
        #expect(withinFrames(c.removed, 1.0, 0))
    }
}

@MainActor
@Suite("05 §4.1 transaction scoping, animated (T-ANIM, checklist I-5)")
struct TransactionScopingAnimationTests {
    struct Probe: View {
        let a: Samples, b: Samples
        let ca: Controls<Double>, cb: Controls<Double>
        var implicitA: Animation? = .linear(duration: 1)
        var bOverride: Animation?? = .none
        @State var va = 0.0
        @State var vb = 0.0

        var body: some View {
            let _ = { ca.binding = $va; cb.binding = $vb }()
            VStack {
                Color.red.recording(va, a).animation(implicitA, value: va)
                if case .some(let o) = bOverride {
                    Color.blue.recording(vb, b).transaction { $0.animation = o }
                } else {
                    Color.blue.recording(vb, b)
                }
            }
        }
    }

    private func run(_ probe: (Samples, Samples, Controls<Double>, Controls<Double>) -> Probe,
                     _ change: (Controls<Double>, Controls<Double>) -> Void) -> (Samples, Samples) {
        let a = Samples(), b = Samples(), ca = Controls<Double>(), cb = Controls<Double>()
        let g = ViewGraph(rootView: probe(a, b, ca, cb))
        a.graph = g
        b.graph = g
        g.update()
        a.clear()
        b.clear()
        change(ca, cb)
        g.update()
        g.settle()
        return (a, b)
    }

    @Test("I-5 anim.implicitOnly: A animates 1 s linear with its own .animation; B jumps (frames=1)")
    func implicitOnly() {
        let (a, b) = run({ Probe(a: $0, b: $1, ca: $2, cb: $3) }) { ca, cb in
            ca.value = 1
            cb.value = 1
        }
        #expect(a.count == 61 && a.matches(0.5, at: 0.5))
        #expect(b.count == 1 && b.last == 1)
    }

    @Test("I-5 explicitEaseIn0.5: A keeps its own 1 s linear; B runs 0.5 s ease-in (v@0.25 = 0.293)")
    func explicitEaseIn() {
        let (a, b) = run({ Probe(a: $0, b: $1, ca: $2, cb: $3) }) { ca, cb in
            withAnimation(.easeIn(duration: 0.5)) {
                ca.value = 1
                cb.value = 1
            }
        }
        #expect(a.count == 61 && a.matches(0.5, at: 0.5))
        #expect(b.matches(0.293, at: 0.25))
        #expect(withinFrames(b.firstTime(at: 1), 0.5, 0))
    }

    @Test("I-5 txOverride: .transaction { $0.animation = .linear(duration: 0.3) } makes B 0.3 s under withAnimation(.linear(1.2))")
    func transactionOverride() {
        let (_, b) = run({ Probe(a: $0, b: $1, ca: $2, cb: $3, bOverride: .some(.linear(duration: 0.3))) }) { _, cb in
            withAnimation(.linear(duration: 1.2)) { cb.value = 1 }
        }
        #expect(withinFrames(b.firstTime(at: 1), 0.3, 0))
        #expect(b.matches(0.5, at: 0.15))
    }

    @Test("05 §4.1: withTransaction(linear 1 s, disablesAnimations): B animates 1 s; A animates 1 s linear")
    func disablesAnimations() {
        var t = Transaction(animation: .linear(duration: 1))
        t.disablesAnimations = true
        let (a, b) = run({ Probe(a: $0, b: $1, ca: $2, cb: $3) }) { ca, cb in
            withTransaction(t) {
                ca.value = 1
                cb.value = 1
            }
        }
        #expect(b.count == 61 && b.matches(0.5, at: 0.5))
        #expect(a.count == 61 && a.matches(0.5, at: 0.5))
    }

    @Test("Inferred: disablesAnimations disables the implicit .animation (A follows the transaction's 1 s, not its own 2 s)")
    func disablesImplicit() {
        var t = Transaction(animation: .linear(duration: 1))
        t.disablesAnimations = true
        let (a, _) = run({ Probe(a: $0, b: $1, ca: $2, cb: $3, implicitA: .linear(duration: 2)) }) { ca, _ in
            withTransaction(t) { ca.value = 1 }
        }
        #expect(withinFrames(a.firstTime(at: 1), 1.0, 0))
    }
}

@MainActor
@Suite("05 §4.2 retargeting")
struct RetargetingTests {
    @Test("05 §4.2: linear 0 → 100 interrupted at 0.5 s by .spring() to 0 continues from 50 (49.2 one frame later, 0.11 × at 0.75 s, 0.0097 × at 1.0 s)")
    func linearThenSpring() {
        let run = AnimRun()
        run.animate(.linear(duration: 1), to: 100, settle: false)
        run.graph.advance(frames: 30)
        #expect(run.samples.last == 50)
        let n = run.samples.count
        withAnimation(.spring()) { run.control.value = 0 }
        run.graph.update()
        // No jump at the change.
        #expect(run.samples.entries[n...].first?.value == 50)
        run.graph.settle()
        #expect(run.samples.matches(49.2, at: 0.5 + frame, tolerance: 1))
        #expect(run.samples.matches(11, at: 0.75, tolerance: 1))
        #expect(run.samples.matches(0.97, at: 1.0, tolerance: 1))
        #expect(run.samples.last == 0)
    }

    @Test("05 §4.2: a spring retargeted by a spring keeps its velocity (no kink)")
    func springThenSpring() {
        let run = AnimRun()
        run.animate(.spring(), to: 100, settle: false)
        run.graph.advance(frames: 6)
        let before = run.samples.entries.suffix(2).map(\.value)
        withAnimation(.spring()) { run.control.value = 0 }
        run.graph.update()
        run.graph.advance()
        let after = run.samples.last!
        // Still moving up one frame later (the velocity carried over).
        #expect(before[1] > before[0])
        #expect(after > before[1])
    }

    @Test("A curve after a curve restarts from the presented value with no velocity")
    func curveThenCurve() {
        let run = AnimRun()
        run.animate(.linear(duration: 1), to: 100, settle: false)
        run.graph.advance(frames: 30)
        withAnimation(.linear(duration: 1)) { run.control.value = 0 }
        run.graph.update()
        run.graph.settle()
        #expect(run.samples.matches(25, at: 1.0, tolerance: 0.01, frames: 0))
    }

    @Test("A change without animation during an animation moves the presented value by the same amount")
    func unanimatedChangeShifts() {
        let run = AnimRun()
        run.animate(.linear(duration: 1), to: 100, settle: false)
        run.graph.advance(frames: 30)
        run.control.value = 200
        run.graph.update()
        #expect(run.samples.last == 150)
        run.graph.settle()
        #expect(run.samples.last == 200)
    }
}
