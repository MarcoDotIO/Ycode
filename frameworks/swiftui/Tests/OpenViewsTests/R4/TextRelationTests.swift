import Foundation
import Testing
import OVText
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// T-LAYOUT-T (10-plan.md §3.2): the text-dependent golden cases checked as
// *relations* with a real open font (the bundled Noto Sans), whose glyph
// widths differ from the reference font's. The golden runner checks these
// cases exactly where the spec's measurements allow and skips answers that
// depend on how the probe's unknown `longText` wraps; here the same cases
// run with a real 43-character, 9-word sentence of our own.

private let sentence = "The quick brown fox jumps over the lazy dog"

@MainActor
private func notoLayout<V: View>(_ view: V, _ proposal: ProposedViewSize = ProposedViewSize(width: 300, height: 500))
    -> LayoutResult {
    let g = ViewGraph(rootView: view, layout: HostLayout(.proposal(proposal), textMeasurer: notoMeasurer,
                                                         symbols: Fixture.symbols))
    g.update()
    return g.layoutResult!
}

@MainActor
private func notoSize<V: View>(_ view: V, _ w: CGFloat?, _ h: CGFloat?) -> CGSize {
    notoLayout(view, ProposedViewSize(width: w, height: h)).size
}

private func ceilPx(_ v: Double) -> CGFloat { CGFloat((v * 3 - 1e-4).rounded(.up) / 3) }

private let body = notoMeasurer.fonts.face(for: .body).lineMetrics(size: 17)
private let oneLine = ceilPx(body.lineHeight)
private let pitch = body.lineHeight + body.leading
private func lines(_ n: Int) -> CGFloat { ceilPx(body.lineHeight + Double(n - 1) * pitch) }

@MainActor
@Suite("T-LAYOUT-T: text cases as relations (Noto Sans)")
struct TextRelationTests {
    @Test("text.long: ideal = one line; wrapped width ≤ proposal and = longest line; height = first line + (n − 1) × pitch")
    func wrapping() {
        let ideal = notoSize(Text(sentence), nil, nil)
        #expect(ideal.height == oneLine && ideal.width > 300)
        #expect(notoSize(Text(sentence), .infinity, .infinity) == ideal)
        for w: CGFloat in [100, 300] {
            let s = notoSize(Text(sentence), w, nil)
            let l = notoMeasurer.layout(ResolvedText(sentence), width: w, height: nil)
            #expect(s.width <= w && s.width == ceilPx(l.lines.map(\.width).max()!))
            #expect(l.lines.count >= 2 && s.height == lines(l.lines.count))
            // The proposed height does not matter while the lines fit.
            #expect(notoSize(Text(sentence), w, 1000) == s)
        }
    }

    @Test("A zero proposal gives 0 × 0; a zero width breaks after every character (fixedSize.vertical)")
    func zero() {
        #expect(notoSize(Text(sentence), 0, 0) == .zero)
        let v = notoSize(Text(sentence).fixedSize(horizontal: false, vertical: true), 0, 0)
        #expect(v.width == 0 && v.height == lines(35))
    }

    @Test("lineLimit: one line truncated with an ellipsis; at most two lines")
    func lineLimits() {
        let one = notoSize(Text(sentence).lineLimit(1), 100, nil)
        #expect(one.height == oneLine && one.width <= 100)
        let two = notoSize(Text(sentence).lineLimit(2), 100, nil)
        #expect(two.height == lines(2) && two.width <= 100)
        #expect(notoMeasurer.layout(ResolvedText(sentence, lineLimit: 1), width: 100, height: nil).isTruncated)
    }

    @Test("The proposed height limits the lines (at least one): equalTexts fit[100×100], frame.tooSmall")
    func heightLimit() {
        let s = notoSize(Text(sentence), 60, 100)
        #expect(s.height <= 100 && s.width <= 60)
        let r = notoLayout(Text(sentence).probe("t").frame(width: 50, height: 20))
        let t = r.namedFrames["t"]!
        #expect(Golden.close(t.height, oneLine) && t.width <= 50)
        #expect(Golden.close(t.minX, (50 - t.width) / 2) && Golden.close(t.minY, (20 - t.height) / 2))
    }

    @Test("Horizontal spacing between texts is 8; vertical spacing between texts is 2")
    func spacing() {
        let h = notoLayout(HStack { Text("A").probe("a"); Text("B").probe("b") }).namedFrames
        #expect(Golden.close(h["b"]!.minX, h["a"]!.maxX + 8))
        let v = notoLayout(VStack { Text("A").probe("a"); Text("B").probe("b") }).namedFrames
        #expect(Golden.close(v["b"]!.minY, v["a"]!.maxY + 2))
    }

    @Test("Centring offsets are (container − child) / 2 (zstack, frame.fixed)")
    func centring() {
        let z = notoLayout(ZStack { Color.red.frame(width: 100, height: 50); Text("Hi").probe("b") }).namedFrames["b"]!
        #expect(Golden.close(z.minX, (100 - z.width) / 2) && Golden.close(z.minY, (50 - z.height) / 2))
        let f = notoLayout(Text("Hello").probe("t").frame(width: 100, height: 100)).namedFrames["t"]!
        #expect(Golden.close(f.minX, (100 - f.width) / 2) && Golden.close(f.minY, (100 - f.height) / 2))
    }

    @Test("hstack.priority: the priority text gets everything but the other's minimum; the other gets the rest")
    func priority() {
        let r = notoLayout(HStack {
            Text(sentence).probe("a")
            Text(sentence).layoutPriority(1).probe("b")
        })
        let a = r.namedFrames["a"]!, b = r.namedFrames["b"]!
        #expect(Golden.close(b.width, notoSize(Text(sentence), 292, 500).width))
        #expect(Golden.close(a.width, 300 - 8 - b.width))   // squeezed: answers its offer
        #expect(Golden.close(r.size.width, 300) && a.height <= 500 && a.height > b.height)
    }

    @Test("hstack.equalTexts: the less flexible text goes first and keeps its single line")
    func equalTexts() {
        let r = notoLayout(HStack {
            Text(sentence).probe("a")
            Text("short words here").probe("b")
        })
        let a = r.namedFrames["a"]!, b = r.namedFrames["b"]!
        #expect(Golden.close(b.width, notoSize(Text("short words here"), nil, nil).width)
                && Golden.close(b.height, oneLine))
        #expect(a.width <= 300 - 8 - b.width && r.size.width <= 300)
        #expect(Golden.close(b.minY, (r.size.height - b.height) / 2))
    }

    @Test("Baselines: first = rounded ascent, last = first + (n − 1) × pitch; firstTextBaseline alignment lines them up")
    func baselines() {
        let m = notoMeasurer.measure(ResolvedText(sentence), proposal: ProposedViewSize(width: 100, height: nil))
        let n = notoMeasurer.layout(ResolvedText(sentence), width: 100, height: nil).lines.count
        #expect(Golden.close(m.firstBaseline!, (body.ascent * 3).rounded() / 3))
        #expect(Golden.close(m.lastBaseline!, ((body.ascent + Double(n - 1) * pitch) * 3).rounded() / 3))
        let r = notoLayout(HStack(alignment: .firstTextBaseline) {
            Text("Big").font(.largeTitle).probe("a")
            Text("small").font(.caption).probe("b")
        })
        let a = r.namedFrames["a"]!, b = r.namedFrames["b"]!
        let ba = notoMeasurer.measure(ResolvedText("Big", font: .style(.largeTitle)), proposal: .unspecified).firstBaseline!
        let bb = notoMeasurer.measure(ResolvedText("small", font: .style(.caption)), proposal: .unspecified).firstBaseline!
        #expect(Golden.close(a.minY + ba, b.minY + bb))
    }

    @Test("viewThatFits: the fixed-size sentence is chosen only when it fits")
    func viewThatFits() {
        let ideal = notoSize(Text(sentence), nil, nil).width
        let narrow = notoLayout(ViewThatFits { Text(sentence).fixedSize().probe("a"); Text("short").probe("b") })
        #expect(narrow.namedFrames["b"] != nil && narrow.namedFrames["a"] == nil)
        let wide = notoLayout(ViewThatFits { Text(sentence).fixedSize().probe("a"); Text("short").probe("b") },
                              ProposedViewSize(width: ideal + 1, height: 500))
        #expect(wide.namedFrames["a"] != nil)
    }

    @Test("Empty text: width 0, a shorter line; Dynamic Type grows text live")
    func emptyAndDynamicType() {
        #expect(notoSize(Text(""), nil, nil) == CGSize(width: 0, height: 14))
        let large = notoSize(Text("Ag"), nil, nil)
        let ax2 = notoSize(Text("Ag").dynamicTypeSize(.accessibility2), nil, nil)
        #expect(ax2.width > large.width && ax2.height > large.height)
    }
}
