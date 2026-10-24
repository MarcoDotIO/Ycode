import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// 05-animation.md §1: animatable values are geometry from layout, opacity,
// offsets, scale, rotation and custom `Animatable` views and modifiers; the
// rendered value moves from old to new, the model value is new at once.
// Plus PhaseAnimator, KeyframeAnimator and custom animations (10-plan.md R6).

@MainActor
private func layoutGraph<V: View>(_ view: V) -> ViewGraph {
    let g = ViewGraph(rootView: view, layout: HostLayout(.proposal(ProposedViewSize(width: 300, height: 300))))
    g.update()
    return g
}

@MainActor
@Suite("05 §1 layout geometry animates between layout passes")
struct GeometryAnimationTests {
    struct Probe: View {
        let control: Controls<Bool>
        var implicit = false
        @State var wide = false

        var body: some View {
            let _ = { control.binding = $wide }()
            HStack(spacing: 0) {
                if implicit {
                    Color.red.frame(width: wide ? 200 : 100, height: 10).probe("a").animation(.linear(duration: 1), value: wide)
                } else {
                    Color.red.frame(width: wide ? 200 : 100, height: 10).probe("a")
                }
                Color.blue.frame(width: 50, height: 10).probe("b")
            }
        }
    }

    @Test("A frame change in an animated transaction animates the view's size and its sibling's position")
    func animated() {
        let c = Controls<Bool>()
        let g = layoutGraph(Probe(control: c))
        withAnimation(.linear(duration: 1)) { c.value = true }
        g.update()
        // Layout (model) is final at once; the presentation starts at the old geometry.
        #expect(g.frame(named: "a")?.width == 200)
        #expect(g.presented("a")?.frame.width == 100)
        #expect(g.presented("b")?.frame.minX == 100)
        g.advance(frames: 30)
        #expect(g.presented("a")?.frame.width == 150)
        #expect(g.presented("b")?.frame.minX == 150)
        g.settle()
        #expect(g.presented("a")?.frame == g.frame(named: "a"))
        #expect(g.presented("b")?.frame == CGRect(x: 200, y: 0, width: 50, height: 10))
    }

    @Test("Without an animation the geometry jumps")
    func jump() {
        let c = Controls<Bool>()
        let g = layoutGraph(Probe(control: c))
        c.value = true
        g.update()
        #expect(g.presented("a")?.frame.width == 200)
        #expect(!g.isAnimating)
    }

    @Test("05 §4.1: an implicit .animation animates only its subtree; the sibling outside it jumps")
    func implicitScope() {
        let c = Controls<Bool>()
        let g = layoutGraph(Probe(control: c, implicit: true))
        c.value = true
        g.update()
        g.advance(frames: 30)
        #expect(g.presented("a")?.frame.width == 150)
        #expect(g.presented("b")?.frame.minX == 200)
    }
}

@MainActor
@Suite("05 §1 render effects animate")
struct EffectAnimationTests {
    struct Probe: View {
        let control: Controls<Double>
        @State var x = 0.0

        var body: some View {
            let _ = { control.binding = $x }()
            Color.red.frame(width: 10, height: 10).probe("p")
                .opacity(1 - x).offset(x: 100 * x).scaleEffect(1 + x, anchor: .topLeading)
        }
    }

    @Test("opacity, offset and scale: model values at once in layout, presented values interpolated")
    func effects() {
        let c = Controls<Double>()
        let g = layoutGraph(Probe(control: c))
        withAnimation(.linear(duration: 1)) { c.value = 1 }
        g.update()
        // Layout geometry (geometry readers) sees the model values.
        #expect(g.frame(named: "p") == CGRect(x: 200, y: 0, width: 20, height: 20))
        #expect(g.presented("p") == PresentedLayer(frame: CGRect(x: 0, y: 0, width: 10, height: 10), opacity: 1))
        g.advance(frames: 30)
        let p = g.presented("p")!
        #expect(p.opacity == 0.5)
        #expect(p.frame == CGRect(x: 75, y: 0, width: 15, height: 15))
    }

    @Test("rotationEffect animates the angle (the presented frame is the rotated bounding box)")
    func rotation() {
        struct R: View {
            let control: Controls<Double>
            @State var deg = 0.0
            var body: some View {
                let _ = { control.binding = $deg }()
                Color.red.frame(width: 10, height: 10).probe("p").rotationEffect(.degrees(deg))
            }
        }
        let c = Controls<Double>()
        let g = layoutGraph(R(control: c))
        withAnimation(.linear(duration: 1)) { c.value = 90 }
        g.update()
        g.advance(frames: 30)
        let w = 10 * (2.0).squareRoot()
        #expect(abs(g.presented("p")!.frame.width - w) < 1e-9)
    }
}

@MainActor
@Suite("05 §1 Animatable views and modifiers")
struct AnimatableViewTests {
    struct Bar: View, Animatable {
        var animatableData: Double
        let samples: Samples
        var body: some View {
            let _ = samples.record(animatableData)
            Color.red
        }
    }

    struct Host: View {
        let samples: Samples
        let control: Controls<Double>
        @State var x = 0.0
        var body: some View {
            let _ = { control.binding = $x }()
            Bar(animatableData: x, samples: samples)
        }
    }

    @Test("An Animatable custom view's body runs once per frame with the interpolated data")
    func animatableView() {
        let s = Samples(), c = Controls<Double>()
        let g = ViewGraph(rootView: Host(samples: s, control: c))
        s.graph = g
        g.update()
        s.clear()
        withAnimation(.linear(duration: 1)) { c.value = 10 }
        g.update()
        g.settle()
        #expect(s.count == 61)
        #expect(s.matches(5, at: 0.5, tolerance: 1e-9, frames: 0))
    }

    @Test("A view without animatable data is not re-evaluated per frame")
    func notAnimatable() {
        let log = Log()
        struct Plain: View {
            let log: Log
            let x: Double
            var body: some View {
                let _ = log("body \(x)")
                Color.red
            }
        }
        struct H: View {
            let log: Log
            let control: Controls<Double>
            @State var x = 0.0
            var body: some View {
                let _ = { control.binding = $x }()
                Plain(log: log, x: x)
            }
        }
        let c = Controls<Double>()
        let g = ViewGraph.rendered(H(log: log, control: c))
        _ = log.take()
        withAnimation(.linear(duration: 1)) { c.value = 1 }
        g.update()
        g.settle()
        #expect(log.take() == ["body 1.0"])
    }
}

@MainActor
@Suite("PhaseAnimator and KeyframeAnimator")
struct AnimatorViewTests {
    struct Phases: View {
        let samples: Samples
        let control: Controls<Int>
        var continuous = false
        @State var trigger = 0
        var body: some View {
            let _ = { control.binding = $trigger }()
            if continuous {
                PhaseAnimator([0.0, 1.0, 2.0]) { p in Color.red.recording(p, samples) } animation: { _ in .linear(duration: 0.5) }
            } else {
                PhaseAnimator([0.0, 1.0, 2.0], trigger: trigger) { p in Color.red.recording(p, samples) }
                    animation: { _ in .linear(duration: 0.5) }
            }
        }
    }

    @Test("A trigger change runs the phases once: 0 → 1 → 2 → 0, each with its animation")
    func triggeredPhases() {
        let s = Samples(), c = Controls<Int>()
        let g = ViewGraph(rootView: Phases(samples: s, control: c))
        s.graph = g
        g.update()
        #expect(s.last == 0)
        s.clear()
        c.value += 1
        g.update()
        g.settle()
        #expect(s.matches(0.5, at: 0.25, tolerance: 1e-9, frames: 0))
        #expect(s.matches(1, at: 0.5, tolerance: 1e-9, frames: 0))
        #expect(s.matches(1.5, at: 0.75, tolerance: 1e-9, frames: 0))
        #expect(s.matches(2, at: 1.0, tolerance: 1e-9, frames: 0))
        #expect(s.matches(1, at: 1.25, tolerance: 1e-9, frames: 0))
        #expect(s.last == 0 && withinFrames(s.entries.last?.time, 1.5, 0))
        #expect(!g.isAnimating)
    }

    @Test("Without a trigger the phases cycle from appearance")
    func continuousPhases() {
        let s = Samples(), c = Controls<Int>()
        let g = ViewGraph(rootView: Phases(samples: s, control: c, continuous: true))
        s.graph = g
        g.update()
        g.advance(seconds: 2)
        #expect(s.matches(1, at: 0.5, tolerance: 1e-9, frames: 0))
        #expect(s.matches(0, at: 1.5, tolerance: 1e-9, frames: 0))
        #expect(s.matches(1, at: 2.0, tolerance: 1e-9, frames: 0))
        #expect(g.isAnimating)
    }

    struct Keys: View {
        let samples: Samples
        let control: Controls<Int>
        var repeating = false
        @State var trigger = 0
        var body: some View {
            let _ = { control.binding = $trigger }()
            if repeating {
                KeyframeAnimator(initialValue: 0.0, repeating: true) { v in Color.red.recording(v, samples) } keyframes: { _ in
                    LinearKeyframe(10.0, duration: 1)
                }
            } else {
                KeyframeAnimator(initialValue: 0.0, trigger: trigger) { v in Color.red.recording(v, samples) } keyframes: { _ in
                    LinearKeyframe(10.0, duration: 1)
                    LinearKeyframe(4.0, duration: 0.5)
                }
            }
        }
    }

    @Test("KeyframeAnimator plays its timeline on a trigger change, every frame, and stays at the final value")
    func keyframeAnimator() {
        let s = Samples(), c = Controls<Int>()
        let g = ViewGraph(rootView: Keys(samples: s, control: c))
        s.graph = g
        g.update()
        s.clear()
        c.value += 1
        g.update()
        g.settle()
        #expect(s.matches(5, at: 0.5, tolerance: 1e-9, frames: 0))
        #expect(s.matches(10, at: 1.0, tolerance: 1e-9, frames: 0))
        #expect(s.matches(7, at: 1.25, tolerance: 1e-9, frames: 0))
        #expect(s.last == 4)
        #expect(s.count == 90)  // one evaluation per frame for 1.5 s (nothing changes at the trigger itself)
    }

    @Test("A repeating KeyframeAnimator loops from appearance")
    func keyframeRepeating() {
        let s = Samples(), c = Controls<Int>()
        let g = ViewGraph(rootView: Keys(samples: s, control: c, repeating: true))
        s.graph = g
        g.update()
        g.advance(seconds: 1.5)
        #expect(s.matches(5, at: 1.5, tolerance: 1e-9, frames: 0))
        #expect(g.isAnimating)
    }
}

/// A custom animation: holds the start value for half the duration, then
/// jumps to the target.
private struct StepAnimation: CustomAnimation {
    let duration: TimeInterval
    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        if time >= duration { return nil }
        if time >= duration / 2 { context.isLogicallyComplete = true }
        return time < duration / 2 ? .zero : value
    }
}

@MainActor
@Suite("CustomAnimation")
struct CustomAnimationTests {
    @Test("Animation(_:) runs a custom animation; isLogicallyComplete drives .logicallyComplete")
    func custom() {
        let run = AnimRun()
        let c = run.animate(Animation(StepAnimation(duration: 1)))
        #expect(run.samples.matches(0, at: 0.4, tolerance: 0, frames: 0))
        #expect(run.samples.matches(1, at: 0.6, tolerance: 0, frames: 0))
        #expect(withinFrames(c.logical, 0.5, 0))
        #expect(withinFrames(c.removed, 1.0, 0))
        #expect(Animation(StepAnimation(duration: 1)) == Animation(StepAnimation(duration: 1)))
        #expect(Animation(StepAnimation(duration: 1)) != Animation(StepAnimation(duration: 2)))
    }

    @Test("Animation values compare by their parameters")
    func equality() {
        #expect(Animation.linear(duration: 1).delay(0.5) == .linear(duration: 1).delay(0.5))
        #expect(Animation.linear(duration: 1) != .easeIn(duration: 1))
        #expect(Animation.spring() == .spring(duration: 0.5, bounce: 0))
    }

    @Test("Animation.animate and velocity follow the curve and the spring (05 §2–3)")
    func evaluation() {
        var ctx = AnimationContext<Double>()
        #expect(abs(Animation.easeInOut(duration: 1).animate(value: 1.0, time: 0.3, context: &ctx)! - 0.1874) < 1e-4)
        #expect(Animation.linear(duration: 1).animate(value: 1.0, time: 1, context: &ctx) == nil)
        ctx = AnimationContext<Double>()
        #expect(abs(Animation.bouncy.animate(value: 1.0, time: 0.3, context: &ctx)! - 1.0339) < 1e-4)
        #expect(!ctx.isLogicallyComplete)
        _ = Animation.bouncy.animate(value: 1.0, time: 0.5, context: &ctx)
        #expect(ctx.isLogicallyComplete)
        #expect(abs(Animation.linear(duration: 2).velocity(value: 1.0, time: 1, context: ctx)! - 0.5) < 1e-9)
    }
}

@MainActor
@Suite("matchedGeometryEffect (first cut)")
struct MatchedGeometryTests {
    struct Hero: View {
        let control: Controls<Bool>
        @Namespace var ns
        @State var big = false
        var body: some View {
            let _ = { control.binding = $big }()
            VStack(spacing: 0) {
                if big {
                    Color.red.frame(width: 200, height: 100).probe("big").matchedGeometryEffect(id: "hero", in: ns)
                } else {
                    Color.red.frame(width: 50, height: 50).probe("small").matchedGeometryEffect(id: "hero", in: ns)
                }
            }
            .frame(width: 300, height: 300, alignment: .topLeading)
        }
    }

    @Test("An inserted matched view starts at the frame of the removed one and animates to its own; the removed one follows")
    func hero() {
        let c = Controls<Bool>()
        let g = ViewGraph(rootView: Hero(control: c), layout: HostLayout(.proposal(ProposedViewSize(width: 300, height: 300))))
        g.update()
        withAnimation(.linear(duration: 1)) { c.value = true }
        g.update()
        #expect(g.presented("big")?.frame == CGRect(x: 0, y: 0, width: 50, height: 50))
        g.advance(frames: 30)
        #expect(g.presented("big")?.frame == CGRect(x: 0, y: 0, width: 125, height: 75))
        #expect(g.presented("small")?.frame == CGRect(x: 0, y: 0, width: 125, height: 75))
        g.settle()
        #expect(g.presented("big")?.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(g.presented("small") == nil)
    }

    struct Follower: View {
        @Namespace var ns
        var body: some View {
            HStack(spacing: 0) {
                Color.red.frame(width: 100, height: 100).matchedGeometryEffect(id: 1, in: ns)
                Color.blue.frame(width: 20, height: 20).probe("f").matchedGeometryEffect(id: 1, in: ns, isSource: false)
            }
        }
    }

    @Test("A non-source view is rendered in its source's frame")
    func nonSource() {
        let g = ViewGraph(rootView: Follower(), layout: HostLayout(.proposal(ProposedViewSize(width: 300, height: 300))))
        g.update()
        #expect(g.frame(named: "f") == CGRect(x: 100, y: 40, width: 20, height: 20))
        #expect(g.presented("f")?.frame == CGRect(x: 0, y: 0, width: 100, height: 100))
    }
}
