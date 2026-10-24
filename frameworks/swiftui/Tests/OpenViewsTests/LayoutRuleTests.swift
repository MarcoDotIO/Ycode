import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Layout rules of 04-layout.md and 08 §3 that the golden table does not
// pin down numerically (T-RTL, safe areas, pixel rounding, the Layout
// protocol), checked with font-independent views.

private func approx(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.01 }
private func approx(_ a: CGRect?, _ b: CGRect) -> Bool {
    guard let a else { return false }
    return approx(a.minX, b.minX) && approx(a.minY, b.minY) && approx(a.width, b.width) && approx(a.height, b.height)
}

private func layout(_ node: LayoutNode, _ w: CGFloat, _ h: CGFloat, rtl: Bool = false, scale: CGFloat = 3) -> LayoutResult {
    var engine = Fixture.engine
    engine.environment.layoutDirection = rtl ? .rightToLeft : .leftToRight
    engine.environment.displayScale = scale
    return engine.layout(node, proposal: ProposedViewSize(width: w, height: h))
}

private func size(_ node: LayoutNode, _ p: ProposedViewSize) -> CGSize { Fixture.engine.sizeThatFits(node, p).size }

@Suite("Right-to-left layout (T-RTL, 08 §3)")
struct RightToLeftTests {
    @Test("Stacks reverse: HStack { a; b } puts b at x = 0 and a at x = 18")
    func stackReverses() {
        let r = layout(hstack { color().frame(width: 10, height: 10).probe("a"); color().frame(width: 10, height: 10).probe("b") }, 300, 500, rtl: true)
        #expect(approx(r.namedFrames["b"], CGRect(0, 0, 10, 10)))
        #expect(approx(r.namedFrames["a"], CGRect(18, 0, 10, 10)))
    }

    @Test("Leading alignment flips: topLeading in a 100-wide frame puts a 39-wide view at x = 61")
    func leadingFlips() {
        let r = layout(text("Hello").probe("t").frame(width: 100, height: 100, alignment: .topLeading), 300, 500, rtl: true)
        #expect(approx(r.namedFrames["t"], CGRect(61, 0, 39, 61.0 / 3)))
        let b = layout(text("Hello").probe("t").frame(width: 100, height: 100, alignment: .bottomTrailing), 300, 500, rtl: true)
        #expect(approx(b.namedFrames["t"]?.minX ?? -1, 0))
    }

    @Test("Horizontal offsets follow the layout direction: offset(x: 20) moves left")
    func offsetNegates() {
        let r = layout(text("Hello").probe("t").offset(x: 20, y: 10), 300, 500, rtl: true)
        #expect(approx(r.namedFrames["t"], CGRect(-20, 10, 39, 61.0 / 3)))
    }

    @Test("padding(.horizontal) stays symmetric")
    func paddingSymmetric() {
        let r = layout(text("Hello").probe("t").padding(.horizontal), 300, 500, rtl: true)
        #expect(approx(r.namedFrames["t"], CGRect(16, 0, 39, 61.0 / 3)))
    }

    @Test("Every frame is the mirror of the left-to-right frame (x' = W − x − w)")
    func mirrorsGolden() {
        let build = {
            hstack { text("Left").probe("l"); spacer().probe("s"); text("Right").probe("r") }
        }
        let ltr = layout(build(), 300, 500).namedFrames
        let rtl = layout(build(), 300, 500, rtl: true).namedFrames
        for (name, f) in ltr {
            #expect(approx(rtl[name], CGRect(300 - f.minX - f.width, f.minY, f.width, f.height)), "\(name)")
        }
    }

    @Test("LazyVGrid columns fill right to left")
    func gridMirrors() {
        let r = layout(lazyVGrid(columns: [GridItem(.fixed(50)), GridItem(.fixed(70))]) {
            forEach(0..<2) { i in color().frame(height: 20).probe("c\(i)") }
        }, 300, 500, rtl: true)
        #expect(approx(r.namedFrames["c0"], CGRect(164, 0, 50, 20)))
        #expect(approx(r.namedFrames["c1"], CGRect(86, 0, 70, 20)))
    }
}

@Suite("Safe areas (04 §7)")
struct SafeAreaTests {
    // Reference device: 466 × 678 window, bottom inset 34, trailing inset 84.
    static let window = CGSize(width: 466, height: 678)
    static let insets = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)

    func run(_ node: LayoutNode, rtl: Bool = false) -> LayoutResult {
        var engine = Fixture.engine
        engine.environment.layoutDirection = rtl ? .rightToLeft : .leftToRight
        let insets = rtl ? EdgeInsets(top: 0, leading: 84, bottom: 34, trailing: 0) : Self.insets
        return engine.layout(node, window: Self.window, safeAreaInsets: insets)
    }

    @Test("The root is proposed the safe-area rectangle (382 × 644)")
    func rootProposal() {
        let r = run(color().named("c"))
        #expect(r.size == CGSize(width: 382, height: 644))
        #expect(approx(r.namedFrames["c"], CGRect(0, 0, 382, 644)))
    }

    @Test("ignoresSafeArea() extends a view that touches the insets to the window")
    func ignores() {
        let r = run(color().ignoresSafeArea().probe("c"))
        let c = r.root.children[0].children[0]  // the colour inside ignoresSafeArea
        #expect(approx(r.frame(of: c), CGRect(0, 0, 466, 678)))
    }

    @Test("ignoresSafeArea(edges: .bottom) extends only downwards")
    func bottomOnly() {
        let root = color().named("c").ignoresSafeArea(edges: .bottom)
        let r = run(root)
        #expect(approx(r.namedFrames["c"], CGRect(0, 0, 382, 678)))
    }

    @Test("A view that does not touch the insets is unaffected")
    func notTouching() {
        let r = run(color().frame(width: 50, height: 50).named("f").ignoresSafeArea())
        #expect(approx(r.namedFrames["f"], CGRect(166, 297, 50, 50)))
    }

    @Test("A bar at the bottom of a VStack grows into the bottom inset")
    func bottomBar() {
        let r = run(vstack(spacing: 0) { spacer(); color().named("bar").ignoresSafeArea(edges: .bottom).frame(height: 50) })
        #expect(approx(r.namedFrames["bar"], CGRect(0, 594, 382, 84)))
    }

    @Test("A geometry reader reports the safe size and the window insets it touches")
    func geometryReaderInsets() {
        let r = run(LayoutNode.geometryReader().named("g"))
        let g = r.node(named: "g")!
        #expect(r.frame(of: g)?.size == CGSize(width: 382, height: 644))
        #expect(r.safeAreaInsets(of: g) == SafeAreaTests.insets)
        let inner = run(color().frame(width: 10, height: 10).background(LayoutNode.geometryReader().named("g")))
        #expect(inner.safeAreaInsets(of: inner.node(named: "g")!) == EdgeInsets())
    }

    @Test("Right-to-left: the device's right-side inset is the leading inset")
    func rtlLeading() {
        let r = run(color().named("c"), rtl: true)
        // Mirrored to absolute coordinates, the content still avoids the right edge.
        #expect(approx(r.namedFrames["c"], CGRect(0, 0, 382, 644)))
        #expect(r.safeAreaInsets(of: r.node(named: "c")!) == EdgeInsets(top: 0, leading: 84, bottom: 34, trailing: 0))
    }
}

@Suite("Pixel rounding (04 §9)")
struct PixelRoundingTests {
    @Test("A divider is one device pixel thick")
    func dividerHairline() {
        #expect(approx(layout(divider(), 300, 500, scale: 3).size.height, 1.0 / 3))
        #expect(layout(divider(), 300, 500, scale: 2).size.height == 0.5)
        #expect(layout(divider(), 300, 500, scale: 1).size.height == 1)
        #expect(layout(hstack { divider() }, 300, 500, scale: 2).size.width == 0.5)
    }

    @Test("Layout arithmetic is not snapped; centring may land on half-thirds")
    func notSnapped() {
        let r = layout(hstack(spacing: 0) { color(); color(); color(); color(); color(); color(); color() }, 300, 10)
        #expect(r.size.width == 300)
        let f = layout(color().frame(width: 10, height: 61.0 / 3).probe("t").frame(width: 100, height: 500), 300, 500).namedFrames["t"]!
        #expect(approx(f.minY, 239.83))
    }
}

/// A user layout: subviews in a row, each at its ideal size, `gap` apart,
/// bottom-aligned; counts cache creation.
private struct BottomRow: Layout {
    var gap: CGFloat
    struct Cache { var made = 0 }
    func makeCache(subviews: Subviews) -> Cache { Cache(made: 1) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.map(\.width).reduce(0, +) + gap * CGFloat(max(sizes.count - 1, 0)),
                      height: sizes.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var x = bounds.minX
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            sv.place(at: CGPoint(x: x, y: bounds.maxY), anchor: .bottomLeading, proposal: .unspecified)
            x += s.width + gap
        }
    }
}

private enum Rank: LayoutValueKey { static let defaultValue = 0 }

/// Places subviews by their `Rank` value, highest first, top to bottom.
private struct RankedColumn: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0,
               height: subviews.map { $0.sizeThatFits(.unspecified).height }.reduce(0, +))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for sv in subviews.sorted(by: { $0[Rank.self] > $1[Rank.self] }) {
            sv.place(at: CGPoint(x: bounds.minX, y: y), proposal: .unspecified)
            y += sv.sizeThatFits(.unspecified).height
        }
    }
}

@Suite("Layout protocol")
struct LayoutProtocolTests {
    @Test("A custom layout is driven like the built-in ones")
    func customLayout() {
        let node = LayoutNode.layout(BottomRow(gap: 5), [
            color().frame(width: 10, height: 30).named("a"), color().frame(width: 20, height: 10).named("b"),
        ])
        let r = layout(node, 300, 500)
        #expect(r.size == CGSize(width: 35, height: 30))
        #expect(approx(r.namedFrames["a"], CGRect(0, 0, 10, 30)))
        #expect(approx(r.namedFrames["b"], CGRect(15, 20, 20, 10)))
        #expect((node.layoutCache as? BottomRow.Cache)?.made == 1)
    }

    @Test("Layout values reach the container")
    func layoutValues() {
        let node = LayoutNode.layout(RankedColumn(), [
            color().frame(width: 10, height: 10).named("low"),
            color().frame(width: 10, height: 10).named("high").layoutValue(key: Rank.self, value: 5),
        ])
        let r = layout(node, 300, 500)
        #expect(approx(r.namedFrames["high"], CGRect(0, 0, 10, 10)))
        #expect(approx(r.namedFrames["low"], CGRect(0, 10, 10, 10)))
    }

    @Test("Default explicit alignment merges the subviews' baselines (first = smallest, last = largest)")
    func mergedBaselines() {
        let node = LayoutNode.layout(BottomRow(gap: 0), [text("Big").font(.largeTitle), text("small").font(.caption)])
        let r = layout(node, 300, 500)
        // "Big" has its baseline at 32.33; "small" (14.33 tall, baseline 11.33)
        // is bottom-aligned in the 40.67-tall row, so its baseline is at 37.67.
        #expect(approx(r.baselines.first, 32.33))
        #expect(approx(r.baselines.last, 37.67))
    }

    @Test("AnyLayout behaves like the layout it wraps, including Spacer orientation")
    func anyLayout() {
        func build(_ l: AnyLayout) -> LayoutNode {
            .layout(l, [text("Left").named("l"), spacer().named("s"), text("Right").named("r")])
        }
        let h = layout(build(AnyLayout(HStackLayout())), 300, 500)
        #expect(approx(h.namedFrames["s"], CGRect(29.67, 10.17, 230.33, 0)))
        let v = layout(build(AnyLayout(VStackLayout())), 300, 500)
        #expect(approx(v.namedFrames["s"], CGRect(20, 61.0 / 3, 0, 500 - 2 * 61.0 / 3)))
    }

    @Test("LayoutSubviews slices keep their indices")
    func subviewSlices() {
        let node = LayoutNode.hstack([color(), color(), color()])
        Fixture.engine.prepare(node)
        let subviews = LayoutSubviews(node.children.map { LayoutSubview(node: $0, sink: nil) })
        let tail = subviews[1..<3]
        #expect(tail.startIndex == 1 && tail.count == 2 && tail[1] == subviews[1])
        let picked = subviews[[2, 0]]
        #expect(picked[0] == subviews[2] && picked[1] == subviews[0])
    }
}

@Suite("Stacks and primitives (04 §2, §4)")
struct StackRuleTests {
    @Test("Explicit spacing replaces every preference")
    func explicitSpacing() {
        #expect(size(hstack(spacing: 20) { color().frame(width: 10, height: 10); color().frame(width: 10, height: 10) }, .unspecified)
                == CGSize(width: 40, height: 10))
        #expect(size(vstack(spacing: 0) { text("A"); text("B") }, .unspecified).height == 2 * 61.0 / 3)
    }

    @Test("EmptyView takes no space and contributes no spacing")
    func emptyViewIsDropped() {
        #expect(size(hstack { color().frame(width: 10, height: 10); emptyView(); color().frame(width: 10, height: 10) }, .unspecified)
                == CGSize(width: 28, height: 10))
    }

    @Test("A spacer is zero across its stack and keeps its minimum along it")
    func spacerInStacks() {
        #expect(size(vstack { spacer() }, ProposedViewSize(width: 300, height: 500)) == CGSize(width: 0, height: 500))
        #expect(size(hstack { spacer(minLength: 20) }, .zero) == CGSize(width: 20, height: 0))
        #expect(size(zstack { spacer() }, .unspecified) == CGSize(width: 8, height: 8))
    }

    @Test("A divider is horizontal in a VStack and vertical in an HStack")
    func dividerOrientation() {
        #expect(approx(size(vstack { divider() }, ProposedViewSize(width: 300, height: 500)).height, 1.0 / 3))
        #expect(size(vstack { divider() }, ProposedViewSize(width: 300, height: 500)).width == 300)
        #expect(approx(size(hstack { divider() }, ProposedViewSize(width: 300, height: 500)).width, 1.0 / 3))
        #expect(size(hstack { divider().padding(4) }, ProposedViewSize(width: 300, height: 500)).height == 500)
    }

    @Test("Modifier order: frame then padding is 132 wide; padding then frame is 100 (03 §6)")
    func modifierOrder() {
        #expect(size(color().frame(width: 100).padding(), ProposedViewSize(width: 300, height: 500)).width == 132)
        #expect(size(color().padding().frame(width: 100), ProposedViewSize(width: 300, height: 500)).width == 100)
    }

    @Test("Circle in a 300 × 100 offer is 100 × 100")
    func circleIsSquare() {
        #expect(size(circle(), ProposedViewSize(width: 300, height: 100)) == CGSize(width: 100, height: 100))
    }

    @Test("aspectRatio with a size ratio")
    func aspectSize() {
        #expect(size(color().aspectRatio(CGSize(width: 4, height: 3), contentMode: .fit), ProposedViewSize(width: 300, height: 500))
                == CGSize(width: 300, height: 225))
    }

    @Test("ViewThatFits checks only the requested axes")
    func viewThatFitsAxes() {
        let node = viewThatFits(in: .vertical) {
            color().frame(width: 500, height: 50).named("wide")
            color().frame(width: 10, height: 10).named("small")
        }
        let r = layout(node, 300, 100)
        #expect(r.namedFrames["wide"] != nil && r.namedFrames["small"] == nil)
    }

    @Test("Higher layout priority is offered everything but the others' minimums")
    func priorityReserve() {
        let r = layout(hstack(spacing: 0) {
            color().named("a")
            color().frame(minWidth: 40).named("b")
            color().layoutPriority(1).named("c")
        }, 300, 10)
        #expect(approx(r.namedFrames["c"]?.width ?? 0, 260))
        #expect(approx(r.namedFrames["b"]?.width ?? 0, 40))
        #expect(approx(r.namedFrames["a"]?.width ?? -1, 0))
    }

    @Test("Text stub rules (04 §3): zero proposal, empty text, explicit newlines")
    func textStubRules() {
        #expect(size(text("Hello"), .zero) == .zero)
        #expect(size(text(""), ProposedViewSize(width: 100, height: nil)) == CGSize(width: 0, height: 14))
        #expect(size(text(""), .zero) == .zero)
        let two = size(text("Hello\nShort"), .unspecified)
        #expect(approx(two.width, 41.67) && approx(two.height, 42.33))
    }

    @Test("Unknown symbols lay out as 0 × 0")
    func unknownSymbol() {
        #expect(size(image(systemName: "doesnotexist.symbol"), .unspecified) == .zero)
    }

    @Test("Answers are memoised per proposal")
    func memoised() {
        let node = hstack { color(); text("Hello") }
        Fixture.engine.prepare(node)
        let a = node.sizeThatFits(ProposedViewSize(width: 200, height: 50))
        let b = node.sizeThatFits(ProposedViewSize(width: 200, height: 50))
        #expect(a == b && a == CGSize(width: 200, height: 50))
    }
}
