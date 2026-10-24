import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// 05-animation.md §5 (transitions; checklist I-7) and the built-in
// transitions, observed through the presented layers (frame and opacity of
// a probed view).

@MainActor
private final class TransitionHarness {
    let log = Log()
    let control = Controls<Bool>()
    let graph: ViewGraph

    struct Probe: View {
        let log: Log
        let control: Controls<Bool>
        let transition: AnyTransition?
        @State var show = false

        var body: some View {
            let _ = { control.binding = $show }()
            HStack(spacing: 0) {
                Color.green.frame(width: 10, height: 50)
                if show {
                    if let transition {
                        Color.red.frame(width: 50, height: 50).probe("t")
                            .onAppear { log("appear") }.onDisappear { log("disappear") }
                            .transition(transition)
                    } else {
                        Color.red.frame(width: 50, height: 50).probe("t")
                            .onAppear { log("appear") }.onDisappear { log("disappear") }
                    }
                }
            }
        }
    }

    init(_ transition: AnyTransition? = nil, shown: Bool = false) {
        graph = ViewGraph(rootView: EmptyView(), layout: HostLayout(.proposal(ProposedViewSize(width: 300, height: 300))))
        graph.setRootView(Probe(log: log, control: control, transition: transition))
        graph.update()
        if shown {
            control.value = true
            graph.update()
        }
        _ = log.take()
    }

    func set(_ show: Bool, _ animation: Animation?) {
        withAnimation(animation) { control.value = show }
        graph.update()
    }

    var layer: PresentedLayer? { graph.presented("t") }
}

@MainActor
@Suite("05 §5 transitions (T-ANIM, checklist I-7)")
struct TransitionTests {
    @Test("05 §5: insertion: onAppear at the start; the default transition fades in over the animation")
    func insertionDefault() {
        let h = TransitionHarness()
        h.set(true, .linear(duration: 1))
        #expect(h.log.take() == ["appear"])
        #expect(h.layer?.opacity == 0)
        h.graph.advance(frames: 30)
        #expect(abs((h.layer?.opacity ?? -1) - 0.5) < 1e-9)
        h.graph.advance(frames: 30)
        #expect(h.layer?.opacity == 1)
        #expect(!h.graph.isAnimating)
    }

    @Test("05 §5: removal: the view stays rendered until the removal animation ends; onDisappear fires at the end (1.0 s)")
    func removalDeferred() {
        let h = TransitionHarness(shown: true)
        h.set(false, .linear(duration: 1))
        #expect(h.log.take().isEmpty)
        #expect(h.layer?.opacity == 1)
        #expect(h.layer?.frame == CGRect(x: 10, y: 0, width: 50, height: 50))
        h.graph.advance(frames: 30)
        #expect(abs((h.layer?.opacity ?? -1) - 0.5) < 1e-9)
        #expect(h.log.take().isEmpty)
        h.graph.advance(frames: 29)
        #expect(h.log.take().isEmpty)
        h.graph.advance(frames: 1)
        #expect(h.log.take() == ["disappear"])
        #expect(withinFrames(h.graph.currentTime, 1.03, 3))
        #expect(h.layer == nil)
    }

    @Test("05 §5: the removed view leaves layout at once (its siblings take the space)")
    func removalLeavesLayout() {
        let h = TransitionHarness(shown: true)
        #expect(h.graph.layoutResult?.size.width == 60)
        h.set(false, .linear(duration: 1))
        #expect(h.graph.layoutResult?.size.width == 10)
    }

    @Test("05 §5: without an animation insertion and removal are immediate")
    func immediate() {
        let h = TransitionHarness()
        h.set(true, nil)
        #expect(h.log.take() == ["appear"])
        #expect(h.layer?.opacity == 1)
        h.set(false, nil)
        #expect(h.log.take() == ["disappear"])
        #expect(h.layer == nil)
    }

    @Test("05 §5: insertion with a transition counts 0 → 1 over 1 s in 60 frames")
    func insertionFrames() {
        let h = TransitionHarness(.opacity)
        h.set(true, .linear(duration: 1))
        var opacities: [Double] = [h.layer!.opacity]
        while h.graph.isAnimating {
            h.graph.advance()
            opacities.append(h.layer!.opacity)
        }
        #expect(opacities.count == 61)
        #expect(opacities.first == 0 && opacities.last == 1)
    }

    @Test(".scale scales about the centre from 0")
    func scale() {
        let h = TransitionHarness(.scale)
        h.set(true, .linear(duration: 1))
        #expect(h.layer?.frame.width == 0)
        h.graph.advance(frames: 30)
        #expect(h.layer?.frame == CGRect(x: 22.5, y: 12.5, width: 25, height: 25))
        h.graph.settle()
        #expect(h.layer?.frame == CGRect(x: 10, y: 0, width: 50, height: 50))
    }

    @Test(".offset moves from and to the offset")
    func offset() {
        let h = TransitionHarness(.offset(x: 100, y: 0))
        h.set(true, .linear(duration: 1))
        #expect(h.layer?.frame.minX == 110)
        h.graph.advance(frames: 30)
        #expect(h.layer?.frame.minX == 60)
    }

    @Test(".move(edge:) moves by the view's own size towards the edge")
    func move() {
        let h = TransitionHarness(.move(edge: .bottom))
        h.set(true, .linear(duration: 1))
        #expect(h.layer?.frame.minY == 50)
        h.graph.advance(frames: 30)
        #expect(h.layer?.frame.minY == 25)
    }

    @Test(".slide: inserted from the leading edge, removed towards the trailing edge")
    func slide() {
        let h = TransitionHarness(.slide)
        h.set(true, .linear(duration: 1))
        #expect(h.layer?.frame.minX == -40)
        h.graph.settle()
        h.set(false, .linear(duration: 1))
        h.graph.advance(frames: 30)
        #expect(h.layer?.frame.minX == 35)
    }

    @Test(".push(from:) moves in from the edge and fades")
    func push() {
        let h = TransitionHarness(.push(from: .top))
        h.set(true, .linear(duration: 1))
        h.graph.advance(frames: 30)
        #expect(h.layer?.frame.minY == -25)
        #expect(abs((h.layer?.opacity ?? 0) - 0.5) < 1e-9)
        h.graph.settle()
        h.set(false, .linear(duration: 1))
        h.graph.advance(frames: 30)
        #expect(h.layer?.frame.minY == 25)
    }

    @Test(".asymmetric uses the insertion transition on insertion and the removal one on removal")
    func asymmetric() {
        let h = TransitionHarness(.asymmetric(insertion: .scale, removal: .opacity))
        h.set(true, .linear(duration: 1))
        h.graph.advance(frames: 30)
        #expect(h.layer?.frame.width == 25 && h.layer?.opacity == 1)
        h.graph.settle()
        h.set(false, .linear(duration: 1))
        h.graph.advance(frames: 30)
        #expect(h.layer?.frame.width == 50 && abs((h.layer?.opacity ?? 0) - 0.5) < 1e-9)
    }

    @Test(".combined(with:) applies both")
    func combined() {
        let h = TransitionHarness(.opacity.combined(with: .offset(x: 0, y: 40)))
        h.set(true, .linear(duration: 1))
        h.graph.advance(frames: 30)
        #expect(h.layer?.frame.minY == 20 && abs((h.layer?.opacity ?? 0) - 0.5) < 1e-9)
    }

    struct Fade: ViewModifier {
        let amount: Double
        func body(content: Content) -> some View { content.opacity(amount) }
    }

    @Test(".modifier(active:identity:) animates from the active to the identity modifier")
    func modifierTransition() {
        let h = TransitionHarness(.modifier(active: Fade(amount: 0.2), identity: Fade(amount: 1)))
        h.set(true, .linear(duration: 1))
        #expect(abs((h.layer?.opacity ?? 0) - 0.2) < 1e-9)
        h.graph.advance(frames: 30)
        #expect(abs((h.layer?.opacity ?? 0) - 0.6) < 1e-9)
    }

    @Test("A transition's own animation is used instead of the transaction's")
    func transitionAnimation() {
        let h = TransitionHarness(.opacity.animation(.linear(duration: 2)))
        h.set(true, .linear(duration: 1))
        h.graph.advance(frames: 60)
        #expect(abs((h.layer?.opacity ?? 0) - 0.5) < 1e-9)
    }

    @Test(".identity: no visual change; removal ends at once")
    func identity() {
        let h = TransitionHarness(.identity, shown: true)
        h.set(false, .linear(duration: 1))
        #expect(h.log.take() == ["disappear"])
    }

    @Test("Removal completion: .removed fires when the removal transition ends")
    func removalCompletion() {
        let h = TransitionHarness(shown: true)
        var done: Double?
        let g = h.graph
        withAnimation(.linear(duration: 1), completionCriteria: .removed) { h.control.value = false } completion: {
            done = g.currentTime
        }
        g.update()
        g.settle()
        #expect(withinFrames(done, 1.0, 0))
    }

    @Test("A view re-inserted while its removal runs is a new identity; the old one finishes its removal")
    func reinsertDuringRemoval() {
        let h = TransitionHarness(shown: true)
        h.set(false, .linear(duration: 1))
        h.graph.advance(frames: 30)
        h.set(true, .linear(duration: 1))
        #expect(h.log.take() == ["appear"])
        h.graph.settle()
        #expect(h.log.take() == ["disappear"])
        #expect(h.layer?.opacity == 1)
    }

    @Test("Transition protocol: phases and their values")
    func phases() {
        #expect(TransitionPhase.willAppear.value == -1 && TransitionPhase.identity.value == 0 && TransitionPhase.didDisappear.value == 1)
        #expect(TransitionPhase.identity.isIdentity && !TransitionPhase.willAppear.isIdentity)
        #expect(!OpacityTransition.properties.hasMotion && SlideTransition.properties.hasMotion)
    }
}
