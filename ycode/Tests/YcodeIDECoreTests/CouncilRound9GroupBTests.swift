import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 9, group B, in the models both IDEs share
/// (`specs/ide/fidelity-council.md` rows 220–222, `editor-area.md` K.1):
/// every momentum delta applied one to one, a stretch of about 35 points
/// for the fast flick at either edge and about 6 for the slow one, the
/// critically damped return at rest by about 730 ms at the top and 560 at
/// the bottom.
@Suite struct CouncilRound9GroupBTests {
    /// The council's flick on the Linux editor's model, timed at 120 Hz:
    /// the crossing (time, applied speed) and each frame's offset.
    static func run(step: Double, points: Double, n: Int, span: Double, edge: EditorFlick.Edge)
        -> (curve: [(t: Double, offset: Double)], flick: EditorFlick) {
        var steps = CouncilRound7GroupBTests.flick(step: step, points: points, n: n, span: span)
        // Towards the bottom: the same events mirrored.
        if edge == .bottom { steps = steps.map { var s = $0; s.dy = -s.dy; return s } }
        let maxOffset = 5000.0
        var flick = EditorFlick()
        var offset = edge == .top ? 600 : maxOffset - 600
        var pending = steps
        let t0 = steps.first?.time ?? 0
        var curve: [(Double, Double)] = []
        for f in 0..<180 {
            let t = t0 + Double(f + 1) / 120
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
            // Travel towards the edge: 600 at the edge, more past it.
            curve.append((t - t0, edge == .top ? 600 - offset : offset - (maxOffset - 600)))
        }
        return (curve, flick)
    }

    /// The deepest point (time, travel) and the time the travel last moved.
    static func summary(_ curve: [(t: Double, offset: Double)]) -> (peakT: Double, peak: Double, rest: Double, crossing: Double?) {
        let peak = curve.max { $0.offset < $1.offset } ?? (0, 0)
        let rest = Array(zip(curve.dropFirst(), curve)).last { abs($0.0.offset - $0.1.offset) > 1e-6 }?.0.t ?? 0
        let crossing = curve.first { $0.offset >= 600 }?.t
        return (peak.t, peak.offset - 600, rest, crossing)
    }

    // MARK: Row 220: the fast flick at the top

    /// Main 04 (8 events of 40 points, then 1544 points of momentum): the
    /// text crosses the top about 124 ms after the first event, stretches
    /// 38 ± 4 (35) with its deepest point near 200 ms, returns without a
    /// second bounce and is at rest by about 730 ms.
    @Test func fastFlickStretches38AndRestsBy730() {
        let (curve, flick) = Self.run(step: 40, points: 1544, n: 173, span: 1.43, edge: .top)
        let s = Self.summary(curve)
        print("R9B row 220 main 04: crossing \(Int((s.crossing ?? 0) * 1000)) ms, stretch \(String(format: "%.1f", s.peak)) at \(Int(s.peakT * 1000)) ms, at rest \(Int(s.rest * 1000)) ms")
        #expect(abs(s.peak - 38) <= 4, "\(s.peak)")
        #expect(abs(s.peakT - 0.200) <= 0.02, "\(s.peakT)")
        #expect(abs(s.rest - 0.730) <= 0.04, "\(s.rest)")
        #expect(!flick.isBouncing)
        // Critically damped: after the peak the travel only falls, never below the edge.
        let after = curve.filter { $0.t >= s.peakT }
        #expect(zip(after, after.dropFirst()).allSatisfy { $1.offset <= $0.offset + 1e-9 })
        #expect(after.allSatisfy { $0.offset >= 600 - 1e-9 })
        #expect(abs((curve.last?.offset ?? 0) - 600) < 1e-6, "exactly the flick's distance")
    }

    // MARK: Row 221: the slow flick

    /// X05 (8 events of 15 points, then 566.7 points of momentum): every
    /// delta applies, so the text reaches the top (round 8's stop 36 short
    /// is superseded), arriving with little speed, and stretches about 6
    /// points.
    @Test func slowFlickReachesTheTopAndStretchesAbout6() {
        let (curve, flick) = Self.run(step: 15, points: 566.7, n: 134, span: 1.11, edge: .top)
        let s = Self.summary(curve)
        let crossing = s.crossing
        // The speed on arriving: the travel over the frame before the crossing.
        let i = curve.firstIndex { $0.offset >= 600 } ?? 1
        let arriving = (curve[i].offset - curve[max(0, i - 2)].offset) / (curve[i].t - curve[max(0, i - 2)].t)
        print("R9B row 221 X05: crossing \(Int((crossing ?? 0) * 1000)) ms at about \(Int(arriving)) points a second, stretch \(String(format: "%.1f", s.peak)) at \(Int(s.peakT * 1000)) ms, at rest \(Int(s.rest * 1000)) ms")
        #expect(crossing != nil)
        #expect(arriving < 600, "\(arriving)")
        #expect(s.peak > 3 && s.peak < 9, "\(s.peak)")
        #expect(!flick.isBouncing)
        #expect(abs((curve.last?.offset ?? 0) - 600) < 1e-6)
    }

    /// The stretch grows with the speed at the edge: about 35 for the fast
    /// flick's crossing, about 6 for the slow one's, monotonic between.
    @Test func stretchLaw() {
        #expect(abs(TopBounce.stretch(forCrossing: 3970) - 35) < 0.01)
        #expect(abs(TopBounce.stretch(forCrossing: 330) - 6) < 0.3)
        var last = 0.0
        for v in stride(from: 100.0, through: 8000, by: 100) {
            let p = TopBounce.stretch(forCrossing: v)
            #expect(p > last)
            last = p
        }
        // The rise still peaks about 71 ms after the crossing.
        #expect(abs(TopBounce.peakTime - 0.0714) < 0.001)
    }

    // MARK: Row 222: the flick to the bottom

    /// X03 (main 04 mirrored, from 600 above the bottom): 32 ± 4 past the
    /// end (35) near 200 ms, at rest by about 560 ms, exactly 600 travelled.
    @Test func bottomFlickPasses32AndRestsBy560() {
        let (curve, flick) = Self.run(step: 40, points: 1544, n: 173, span: 1.43, edge: .bottom)
        let s = Self.summary(curve)
        print("R9B row 222 X03: crossing \(Int((s.crossing ?? 0) * 1000)) ms, past the end \(String(format: "%.1f", s.peak)) at \(Int(s.peakT * 1000)) ms, at rest \(Int(s.rest * 1000)) ms")
        #expect(abs(s.peak - 32) <= 4, "\(s.peak)")
        #expect(abs(s.peakT - 0.210) <= 0.025, "\(s.peakT)")
        #expect(abs(s.rest - 0.560) <= 0.04, "\(s.rest)")
        #expect(!flick.isBouncing)
        #expect(abs((curve.last?.offset ?? 0) - 600) < 1e-6, "exactly the flick's distance")
        let after = curve.filter { $0.t >= s.peakT }
        #expect(after.allSatisfy { $0.offset >= 600 - 1e-9 })
    }

    /// Every momentum delta applies one to one (the gain stays 1, no speed
    /// floor): X05's whole momentum is 566.7 points.
    @Test func momentumAppliesOneToOne() {
        #expect(EditorMomentum.gain(after: 0) == 1)
        #expect(EditorMomentum.gain(after: 5) == 1)
        let events = CouncilRound8GroupBTests.momentum(points: 566.7, n: 134, span: 1.11, t0: 0.066)
        let (distance, _) = EditorMomentum.distance(of: events, gestureSpeed: 15 / 0.0083)
        #expect(abs(distance - 566.7) < 0.5, "\(distance)")
    }

    // MARK: Row 227: instances of the symbol at the caret

    /// A word in a comment or a string highlights nothing; an identifier in
    /// code highlights its instances in code; keywords and numbers nothing.
    @Test func symbolInstancesOnlyInCode() {
        let text = "/* long enough,\n   enough */\nlet enough = 1\nlet x = enough + enough // enough\nlet s = \"enough\"\n"
        let ns = text as NSString
        let inComment = ns.range(of: "enough").location + 1
        #expect(SymbolInstances.ranges(in: text, caret: inComment, language: .swift).isEmpty)
        let inString = ns.range(of: "\"enough").location + 3
        #expect(SymbolInstances.ranges(in: text, caret: inString, language: .swift).isEmpty)
        let decl = ns.range(of: "let enough").location + 5
        let found = SymbolInstances.ranges(in: text, caret: decl, language: .swift)
        #expect(found.count == 3, "\(found)")
        #expect(found.allSatisfy { ns.substring(with: $0) == "enough" })
        // A keyword, a number, whitespace: nothing.
        #expect(SymbolInstances.ranges(in: text, caret: ns.range(of: "let").location + 1, language: .swift).isEmpty)
        #expect(SymbolInstances.ranges(in: text, caret: ns.range(of: "1").location, language: .swift).isEmpty)
        // A part of a longer name is not an instance.
        let t2 = "let a = 1\nlet ab = a + ab\n"
        let r = SymbolInstances.ranges(in: t2, caret: 4, language: .swift)
        #expect(r == [NSRange(location: 4, length: 1), NSRange(location: 19, length: 1)], "\(r)")
    }
}
