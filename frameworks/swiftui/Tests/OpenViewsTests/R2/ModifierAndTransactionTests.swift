import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// 03-architecture.md §6 (modifier order) and 05-animation.md §4.1
// (transaction scoping), on views lowered to the R3 engine.

@MainActor
func layoutFrames<V: View>(_ view: V, proposal: ProposedViewSize = ProposedViewSize(width: 300, height: 500))
    -> (size: CGSize, frames: [String: CGRect]) {
    let g = ViewGraph(rootView: view, layout: HostLayout(.proposal(proposal), textMeasurer: Fixture.measurer,
                                                         symbols: Fixture.symbols))
    g.update()
    return (g.layoutResult!.size, g.layoutResult!.namedFrames)
}

@MainActor
@Suite("03 §6 modifier order")
struct ModifierOrderTests {
    @Test(".padding().frame(width: 100) pads first, then fixes the width; .frame(width: 100).padding() is 132 wide")
    func paddingFrameOrder() {
        #expect(layoutFrames(Text("Hello").padding().frame(width: 100)).size == CGSize(width: 100, height: 20 + 1.0 / 3 + 32))
        #expect(layoutFrames(Text("Hello").frame(width: 100).padding()).size.width == 132)
    }

    @Test(".padding().background colours the padded area (71 × 52.33); .background().padding() only the text (39 × 20.33)")
    func backgroundExtent() {
        let padded = layoutFrames(Text("Hello").padding().background(Color.red.probe("b"))).frames["b"]!
        #expect(Golden.close(padded.width, 71) && Golden.close(padded.height, 52.33))
        let inner = layoutFrames(Text("Hello").background(Color.red.probe("b")).padding()).frames["b"]!
        #expect(Golden.close(inner.width, 39) && Golden.close(inner.height, 20.33))
        #expect(inner.origin == CGPoint(x: 16, y: 16))
    }

    @Test("render-only modifiers do not change layout")
    func renderOnly() {
        let r = layoutFrames(Text("Hello").offset(x: 20).opacity(0.5).scaleEffect(2).rotationEffect(.degrees(45)))
        #expect(Golden.close(r.size.width, 39) && Golden.close(r.size.height, 20.33))
    }

    @Test("a modifier on a Group applies to each of its views")
    func groupModifier() {
        let r = layoutFrames(HStack(spacing: 0) {
            Group {
                Color.red.probe("a")
                Color.blue.probe("b")
            }
            .frame(width: 10, height: 10)
        })
        #expect(r.frames["a"] == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(r.frames["b"] == CGRect(x: 10, y: 0, width: 10, height: 10))
        #expect(r.size == CGSize(width: 20, height: 10))
    }

    @Test("EmptyView and a false `if` produce no layout children (no spacing)")
    func emptyChildren() {
        let flag = false
        let r = layoutFrames(HStack {
            Color.red.frame(width: 10, height: 10)
            EmptyView()
            if flag { Color.green.frame(width: 10, height: 10) }
            Color.blue.frame(width: 10, height: 10).probe("b")
        })
        #expect(r.frames["b"]?.minX == 18)
    }
}

// MARK: - Transactions

@MainActor
final class SeenTransactions {
    var a: [Animation?] = []
    var b: [Animation?] = []
}

struct TransactionProbe: View {
    let seen: SeenTransactions
    let a: Controls<Int>
    let b: Controls<Int>
    var bOverride: Animation?? = .none
    var implicitA: Animation? = .linear(duration: 1)
    @State var va = 0
    @State var vb = 0

    var body: some View {
        let _ = { a.binding = $va; b.binding = $vb }()
        VStack {
            Text("\(va)")
                .transaction { seen.a.append($0.animation) }
                .animation(implicitA, value: va)
            if case .some(let o) = bOverride {
                Text("\(vb)")
                    .transaction { seen.b.append($0.animation) }
                    .transaction { $0.animation = o }
            } else {
                Text("\(vb)")
                    .transaction { seen.b.append($0.animation) }
            }
        }
    }
}

@MainActor
@Suite("05 §4.1 transaction scoping")
struct TransactionTests {
    let seen = SeenTransactions()
    let a = Controls<Int>(), b = Controls<Int>()

    private func run(_ probe: TransactionProbe, _ change: () -> Void) -> (Animation?, Animation?) {
        let g = ViewGraph.rendered(probe)
        seen.a = []
        seen.b = []
        change()
        g.update()
        return (seen.a.last ?? nil, seen.b.last ?? nil)
    }

    @Test("no withAnimation: A animates with its own .animation (1 s linear), B jumps")
    func implicitOnly() {
        let (ta, tb) = run(TransactionProbe(seen: seen, a: a, b: b)) {
            a.value += 1
            b.value += 1
        }
        #expect(ta == .linear(duration: 1))
        #expect(tb == nil)
    }

    @Test("withAnimation(.easeIn(0.5)): the view's own modifier wins in its subtree; B gets ease-in")
    func explicitAndImplicit() {
        let (ta, tb) = run(TransactionProbe(seen: seen, a: a, b: b)) {
            withAnimation(.easeIn(duration: 0.5)) {
                a.value += 1
                b.value += 1
            }
        }
        #expect(ta == .linear(duration: 1))
        #expect(tb == .easeIn(duration: 0.5))
    }

    @Test(".transaction { $0.animation = 0.3 s } on B rewrites what reaches B")
    func transactionModifier() {
        let (_, tb) = run(TransactionProbe(seen: seen, a: a, b: b, bOverride: .some(.linear(duration: 0.3)))) {
            withAnimation(.linear(duration: 1.2)) { b.value += 1 }
        }
        #expect(tb == .linear(duration: 0.3))
    }

    @Test("disablesAnimations keeps the transaction's own animation and disables implicit .animation modifiers")
    func disablesAnimations() {
        var t = Transaction(animation: .linear(duration: 1))
        t.disablesAnimations = true
        let (ta, tb) = run(TransactionProbe(seen: seen, a: a, b: b, implicitA: .easeOut(duration: 2))) {
            withTransaction(t) {
                a.value += 1
                b.value += 1
            }
        }
        #expect(tb == .linear(duration: 1))
        #expect(ta == .linear(duration: 1))
    }

    @Test("Binding.animation(_:) writes in an animated transaction")
    func bindingAnimation() {
        let (_, tb) = run(TransactionProbe(seen: seen, a: a, b: b)) {
            b.binding!.animation(.snappy).wrappedValue += 1
        }
        #expect(tb == .snappy)
    }

    @Test("withAnimation completion runs when the update completes")
    func completion() {
        var done = 0
        let g = ViewGraph.rendered(TransactionProbe(seen: seen, a: a, b: b))
        withAnimation(.default, completionCriteria: .logicallyComplete) { b.value += 1 } completion: { done += 1 }
        #expect(done == 0)
        g.update()
        #expect(done == 1)
    }

    @Test("05 §4: animation parameters")
    func animationValues() {
        #expect(Animation.linear == .linear(duration: 0.35))
        #expect(Animation.easeInOut == .easeInOut(duration: 0.35))
        func spring(_ a: Animation) -> (Spring, TimeInterval)? {
            (a.base as? SpringAnimation).map { ($0.spring, $0.blendDuration) }
        }
        guard let (s, _) = spring(.default), let (sp, _) = spring(.spring), let (bouncy, _) = spring(.bouncy),
              let (snappy, _) = spring(.snappy), let (interactive, blend) = spring(.interactiveSpring),
              let (ip, _) = spring(.interpolatingSpring) else {
            Issue.record("unexpected animation kinds")
            return
        }
        #expect(abs(s.response - 0.5) < 1e-9 && abs(s.dampingRatio - 1) < 1e-9)
        #expect(abs(sp.response - 0.5) < 1e-9 && abs(sp.dampingRatio - 1) < 1e-9)
        #expect(abs(bouncy.dampingRatio - 0.7) < 1e-9 && abs(snappy.dampingRatio - 0.85) < 1e-9)
        #expect(abs(interactive.response - 0.15) < 1e-9 && abs(interactive.dampingRatio - 0.85) < 1e-9 && blend == 0.25)
        #expect(abs(ip.stiffness - 157.9137) < 1e-9 && abs(ip.damping - 25.1327) < 1e-9 && ip.mass == 1)
    }
}
