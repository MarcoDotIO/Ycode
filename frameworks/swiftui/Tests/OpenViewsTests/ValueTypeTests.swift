import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
#else
@testable import SwiftUICore
#endif

// Round R1: value types and math (10-plan.md §2 R1).

@Suite("R1 geometry")
struct GeometryTests {
    @Test("Angle converts degrees and radians")
    func angle() {
        #expect(abs(Angle(degrees: 180).radians - .pi) < 1e-12)
        #expect(abs(Angle.radians(.pi / 2).degrees - 90) < 1e-12)
        #expect(Angle.zero == Angle())
        #expect(Angle.degrees(10) < Angle.degrees(20))
        var a = Angle.degrees(0)
        a.animatableData = .pi
        #expect(abs(a.degrees - 180) < 1e-12)
    }

    @Test("UnitPoint constants")
    func unitPoint() {
        #expect(UnitPoint.center == UnitPoint(x: 0.5, y: 0.5))
        #expect(UnitPoint.topLeading == .zero)
        #expect(UnitPoint.bottomTrailing == UnitPoint(x: 1, y: 1))
        #expect(UnitPoint.leading == UnitPoint(x: 0, y: 0.5))
        #expect(UnitPoint.top == UnitPoint(x: 0.5, y: 0))
        #expect(UnitPoint.trailing.point(in: CGSize(width: 10, height: 20)) == CGPoint(x: 10, y: 10))
    }

    @Test("EdgeInsets arithmetic and pixel rounding")
    func edgeInsets() {
        let e = EdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)
        #expect(e.inset(by: 1, edges: .horizontal) == EdgeInsets(top: 1, leading: 3, bottom: 3, trailing: 5))
        #expect(EdgeInsets() == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        // Rounding to the pixel grid of a scale-3 display (04 §9).
        let r = EdgeInsets(top: 20.29, leading: 0.2, bottom: 10.4, trailing: -0.2).rounded(toMultipleOf: 1.0 / 3)
        #expect(r.approximates(EdgeInsets(top: 61.0 / 3, leading: 1.0 / 3, bottom: 31.0 / 3, trailing: -1.0 / 3), epsilon: 1e-9))
        let up = EdgeInsets(top: 20.29, leading: 0, bottom: 0, trailing: 0).rounded(.up, toMultipleOf: 1.0 / 3)
        #expect(abs(up.top - 61.0 / 3) < 1e-9)
        #expect(!e.approximates(EdgeInsets(), epsilon: 0.5))
    }

    @Test("ProposedViewSize constants and unspecified replacement")
    func proposedViewSize() {
        #expect(ProposedViewSize.zero == ProposedViewSize(width: 0, height: 0))
        #expect(ProposedViewSize.unspecified == ProposedViewSize(width: nil, height: nil))
        #expect(ProposedViewSize.infinity == ProposedViewSize(width: .infinity, height: .infinity))
        #expect(ProposedViewSize(CGSize(width: 3, height: 4)) == ProposedViewSize(width: 3, height: 4))
        // `nil` becomes 10 by default, the answer shapes give (04 §1).
        #expect(ProposedViewSize(width: 50, height: nil).replacingUnspecifiedDimensions() == CGSize(width: 50, height: 10))
        #expect(ProposedViewSize.unspecified.replacingUnspecifiedDimensions(by: CGSize(width: 1, height: 2)) == CGSize(width: 1, height: 2))
    }

    @Test("Axis and Edge sets")
    func axisAndEdge() {
        #expect(Axis.horizontal.otherAxis == .vertical)
        #expect(Axis.vertical.description == "vertical")
        #expect(Edge.Set.all == [.top, .leading, .bottom, .trailing])
        #expect(Edge.Set(.leading) == .leading)
        #expect(Edge.Set.horizontal.contains(.trailing) && !Edge.Set.horizontal.contains(.top))
        #expect(Axis.Set([.horizontal, .vertical]).contains(.vertical))
        #expect(Axis.horizontal.perpendicularEdges == [.leading, .trailing])
    }

    @Test("Alignment guide defaults and explicit values")
    func guides() {
        let d = ViewDimensions(size: CGSize(width: 40, height: 20))
        #expect(d[HorizontalAlignment.leading] == 0)
        #expect(d[HorizontalAlignment.center] == 20)
        #expect(d[HorizontalAlignment.trailing] == 40)
        #expect(d[VerticalAlignment.top] == 0)
        #expect(d[VerticalAlignment.center] == 10)
        #expect(d[VerticalAlignment.bottom] == 20)
        // Without text, baselines default to the bottom edge (golden `geometryReader`).
        #expect(d[VerticalAlignment.firstTextBaseline] == 20)
        #expect(d[VerticalAlignment.lastTextBaseline] == 20)
        #expect(d[explicit: VerticalAlignment.firstTextBaseline] == nil)
        let e = ViewDimensions(size: CGSize(width: 40, height: 20), guides: ExplicitGuides { key in
            key == VerticalAlignment.firstTextBaseline.key ? 16 : nil
        })
        #expect(e[VerticalAlignment.firstTextBaseline] == 16)
        #expect(e[explicit: VerticalAlignment.firstTextBaseline] == 16)
        #expect(e[VerticalAlignment.lastTextBaseline] == 20)
        #expect(Alignment.bottomTrailing == Alignment(horizontal: .trailing, vertical: .bottom))
        #expect(Alignment.leadingFirstTextBaseline.vertical == .firstTextBaseline)
    }

    @Test("Merging explicit guide values")
    func combine() {
        #expect(VerticalAlignment.firstTextBaseline.combineExplicit([24.5, 32.33]) == 24.5)
        #expect(VerticalAlignment.lastTextBaseline.combineExplicit([24.5, 32.33]) == 32.33)
        #expect(HorizontalAlignment.leading.combineExplicit([10, 20]) == 15)
        #expect(HorizontalAlignment.leading.combineExplicit([CGFloat]()) == nil)
    }

    @Test("Custom alignment identifiers")
    func customGuide() {
        enum ThirdWay: AlignmentID {
            static func defaultValue(in d: ViewDimensions) -> CGFloat { d.width / 3 }
        }
        let g = HorizontalAlignment(ThirdWay.self)
        #expect(g == HorizontalAlignment(ThirdWay.self))
        #expect(g != .leading)
        #expect(ViewDimensions(size: CGSize(width: 30, height: 1))[g] == 10)
    }

    @Test("Vector arithmetic")
    func vectors() {
        var p = AnimatablePair(1.0, AnimatablePair(CGFloat(2), Float(3)))
        p.scale(by: 2)
        #expect(p.first == 2 && p.second.first == 4 && p.second.second == 6)
        #expect(p.magnitudeSquared == 4 + 16 + 36)
        #expect((p - p) == .zero)
        #expect(10.0.interpolated(towards: 20, amount: 0.25) == 12.5)
        #expect(EmptyAnimatableData() + EmptyAnimatableData() == .zero)
        var r = CGRect(x: 0, y: 0, width: 10, height: 10)
        r.animatableData = CGRect(x: 1, y: 2, width: 3, height: 4).animatableData
        #expect(r == CGRect(x: 1, y: 2, width: 3, height: 4))
    }
}

@Suite("R1 colours (T-COLOR)")
struct ColorTests {
    func env(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast = .standard) -> EnvironmentValues {
        var e = EnvironmentValues()
        e.colorScheme = scheme
        e.colorSchemeContrast = contrast
        return e
    }

    /// 07-text-images-color.md §4 (light, dark).
    static let table: [(String, Color, String, String)] = [
        ("primary", .primary, "#000000FF", "#FFFFFFFF"),
        ("secondary", .secondary, "#3C3C4399", "#EBEBF599"),
        ("accentColor", .accentColor, "#0088FFFF", "#0091FFFF"),
        ("red", .red, "#FF383CFF", "#FF4245FF"),
        ("orange", .orange, "#FF8D28FF", "#FF9230FF"),
        ("yellow", .yellow, "#FFCC00FF", "#FFD600FF"),
        ("green", .green, "#34C759FF", "#30D158FF"),
        ("mint", .mint, "#00C8B3FF", "#00DAC3FF"),
        ("teal", .teal, "#00C3D0FF", "#00D2E0FF"),
        ("cyan", .cyan, "#00C0E8FF", "#3CD3FEFF"),
        ("blue", .blue, "#0088FFFF", "#0091FFFF"),
        ("indigo", .indigo, "#6155F5FF", "#6D7CFFFF"),
        ("purple", .purple, "#CB30E0FF", "#DB34F2FF"),
        ("pink", .pink, "#FF2D55FF", "#FF375FFF"),
        ("brown", .brown, "#AC7F5EFF", "#B78A66FF"),
        ("white", .white, "#FFFFFFFF", "#FFFFFFFF"),
        ("black", .black, "#000000FF", "#000000FF"),
        ("gray", .gray, "#8E8E93FF", "#8E8E93FF"),
        ("clear", .clear, "#00000000", "#00000000"),
    ]

    @Test("Named colours resolve per colour scheme", arguments: table.map { $0.0 })
    func named(_ name: String) {
        let row = Self.table.first { $0.0 == name }!
        #expect(row.1.resolve(in: env(.light)).description == row.2)
        #expect(row.1.resolve(in: env(.dark)).description == row.3)
    }

    @Test("Increased contrast changes blue and accentColor")
    func contrast() {
        #expect(Color.blue.resolve(in: env(.light, .increased)).description == "#1E6EF4FF")
        #expect(Color.blue.resolve(in: env(.dark, .increased)).description == "#5CB8FFFF")
        #expect(Color.accentColor.resolve(in: env(.light, .increased)).description == "#1E6EF4FF")
        #expect(Color.primary.resolve(in: env(.dark, .increased)).description == "#FFFFFFFF")
    }

    @Test("Component colours do not adapt")
    func components() {
        let c = Color(red: 1, green: 0, blue: 0)
        #expect(c.resolve(in: env(.light)).description == "#FF0000FF")
        #expect(c.resolve(in: env(.dark)).description == "#FF0000FF")
        #expect(Color(white: 0.5).resolve(in: env(.light)).description == "#808080FF")
        #expect(Color.red.opacity(0.5).resolve(in: env(.light)).description == "#FF383C80")
        #expect(Color(hue: 0, saturation: 1, brightness: 1).resolve(in: env(.light)).description == "#FF0000FF")
        #expect(Color(hue: 2.0 / 3, saturation: 1, brightness: 1).resolve(in: env(.light)).description == "#0000FFFF")
        #expect(Color(hue: 0.5, saturation: 0.5, brightness: 1).resolve(in: env(.light)).description == "#80FFFFFF")
    }

    @Test("Linear sRGB and Display P3 components")
    func colorSpaces() {
        let mid = Color.Resolved(colorSpace: .sRGBLinear, red: 0.214, green: 0.214, blue: 0.214)
        #expect(abs(mid.red - 0.5) < 0.001)
        #expect(abs(mid.linearRed - 0.214) < 1e-5)
        // Display P3 red lies outside sRGB: extended components.
        let p3 = Color.Resolved(colorSpace: .displayP3, red: 1, green: 0, blue: 0)
        #expect(abs(p3.red - 1.0931) < 0.002)
        #expect(abs(p3.green - (-0.2267)) < 0.002)
        #expect(abs(p3.blue - (-0.1501)) < 0.002)
        #expect(Color(Color.Resolved(red: 0, green: 1, blue: 0)).resolve(in: env(.dark)).description == "#00FF00FF")
    }
}

@Suite("R1 timing curves (T-CURVE)")
struct UnitCurveTests {
    /// 05-animation.md §2, values at t = 0, 0.1, …, 1.
    static let table: [(String, UnitCurve, [Double])] = [
        ("linear", .linear, (0...10).map { Double($0) / 10 }),
        ("easeIn", .easeIn, [0, 0.0170, 0.0623, 0.1296, 0.2149, 0.3154, 0.4291, 0.5548, 0.6916, 0.8394, 1]),
        ("easeOut", .easeOut, [0, 0.1606, 0.3084, 0.4452, 0.5709, 0.6846, 0.7851, 0.8704, 0.9377, 0.9830, 1]),
        ("easeInOut", .easeInOut, [0, 0.0197, 0.0817, 0.1874, 0.3319, 0.5, 0.6681, 0.8126, 0.9183, 0.9803, 1]),
        ("circularEaseIn", .circularEaseIn, [0, 0.0050, 0.0202, 0.0461, 0.0835, 0.1340, 0.2000, 0.2859, 0.4000, 0.5641, 1]),
        ("circularEaseOut", .circularEaseOut, [0, 0.4359, 0.6, 0.7141, 0.8, 0.8660, 0.9165, 0.9539, 0.9798, 0.9950, 1]),
        ("circularEaseInOut", .circularEaseInOut, [0, 0.0101, 0.0417, 0.1, 0.2, 0.5, 0.8, 0.9, 0.9583, 0.9899, 1]),
        ("bezier(0.2,0)-(0,1)", .bezier(startControlPoint: UnitPoint(x: 0.2, y: 0), endControlPoint: UnitPoint(x: 0, y: 1)),
         [0, 0.1562, 0.5, 0.6881, 0.8023, 0.8778, 0.9291, 0.9633, 0.9849, 0.9965, 1]),
    ]

    @Test("Curve values at 11 points", arguments: table.map { $0.0 })
    func values(_ name: String) {
        let row = Self.table.first { $0.0 == name }!
        for (i, expected) in row.2.enumerated() {
            let t = Double(i) / 10
            #expect(abs(row.1.value(at: t) - expected) <= 1e-4, "\(name) at \(t)")
        }
    }

    @Test("Curve velocities at 0, 0.5, 1")
    func velocities() {
        let cases: [(UnitCurve, [Double])] = [
            (.linear, [1, 1, 1]), (.easeIn, [0, 1.0740, 0]), (.easeOut, [1, 1.0740, 0]), (.easeInOut, [0, 1.7241, 0]),
        ]
        for (curve, v) in cases {
            for (t, expected) in zip([0.0, 0.5, 1.0], v) {
                #expect(abs(curve.velocity(at: t) - expected) <= 1e-4, "\(curve) at \(t)")
            }
        }
        #expect(UnitCurve.circularEaseIn.velocity(at: 1).isInfinite)
        #expect(UnitCurve.circularEaseOut.velocity(at: 0).isInfinite)
    }

    @Test("Inverse curves")
    func inverse() {
        for curve in [UnitCurve.easeIn, .easeInOut, .circularEaseIn, .circularEaseInOut] {
            for t in stride(from: 0.05, through: 0.95, by: 0.15) {
                #expect(abs(curve.inverse.value(at: curve.value(at: t)) - t) < 1e-6)
            }
        }
    }
}

@Suite("R1 springs (T-SPRING)")
struct SpringTests {
    @Test("Spring parameters (05 §3 table)")
    func parameters() {
        let cases: [(Spring, Double, Double, Double, Double, Double)] = [
            (Spring(), 0.5, 1.0, 0, 157.9137, 25.1327),
            (.smooth, 0.5, 1.0, 0, 157.9137, 25.1327),
            (.snappy, 0.5, 0.85, 0.15, 157.9137, 21.3628),
            (.bouncy, 0.5, 0.7, 0.3, 157.9137, 17.5929),
            (Spring(duration: 0.5, bounce: 0.3), 0.5, 0.7, 0.3, 157.9137, 17.5929),
            (Spring(response: 0.55, dampingRatio: 0.825), 0.55, 0.825, 0.175, 130.5072, 18.8496),
            (Spring(mass: 1, stiffness: 100, damping: 10), 0.6283, 0.5, 0.5, 100, 10),
            (Spring(duration: 0.5, bounce: -0.3), 0.5, 1.4286, -0.3, 486.6319, 35.9039),
        ]
        for (s, response, ratio, bounce, k, c) in cases {
            #expect(abs(s.response - response) < 1e-4)
            #expect(abs(s.duration - response) < 1e-4)
            #expect(abs(s.dampingRatio - ratio) < 1e-4)
            #expect(abs(s.bounce - bounce) < 1e-4)
            #expect(abs(s.stiffness - k) < 1e-4)
            #expect(abs(s.damping - c) < 1e-4)
            #expect(s.mass == 1)
        }
    }

    @Test("Spring values towards 1 from rest (05 §3)")
    func values() {
        let cases: [(Spring, [Double])] = [
            (.smooth, [0.1313, 0.3577, 0.5620, 0.7154, 0.8210, 0.8900, 0.9336, 0.9605, 0.9767, 0.9864]),
            (.snappy, [0.1382, 0.3881, 0.6177, 0.7864, 0.8945, 0.9564, 0.9880, 1.0016, 1.0059, 1.0060]),
            (.bouncy, [0.1457, 0.4233, 0.6851, 0.8737, 0.9841, 1.0339, 1.0460, 1.0393, 1.0265, 1.0145]),
            (Spring(mass: 1, stiffness: 100, damping: 10),
             [0.1044, 0.3403, 0.6105, 0.8494, 1.0234, 1.1244, 1.1616, 1.1531, 1.1184, 1.0746]),
        ]
        for (s, values) in cases {
            #expect(s.value(target: 1.0, initialVelocity: 0.0, time: 0) == 0)
            for (i, expected) in values.enumerated() {
                let t = Double(i + 1) * 0.05
                #expect(abs(s.value(target: 1.0, initialVelocity: 0.0, time: t) - expected) <= 1e-4, "\(s) at \(t)")
            }
        }
    }

    @Test("Velocity, force and update agree with the motion")
    func dynamics() {
        let s = Spring.bouncy
        let h = 1e-6
        let numeric = (s.value(target: 1.0, time: 0.2 + h) - s.value(target: 1.0, time: 0.2 - h)) / (2 * h)
        #expect(abs(s.velocity(target: 1.0, time: 0.2) - numeric) < 1e-4)
        var v = 0.0, x = 0.0
        for _ in 0..<10 { s.update(value: &x, velocity: &v, target: 1.0, deltaTime: 0.02) }
        #expect(abs(x - s.value(target: 1.0, time: 0.2)) < 1e-9)
        #expect(s.force(target: 1.0, position: 0.0, velocity: 0.0) == s.stiffness)
    }

    @Test("Settling durations of the reference (open rule)")
    func settling() {
        // 05 §3 lists settlingDuration 0.8 (smooth), 0.8768 (snappy), 1.0447
        // (bouncy); the rule behind these numbers is not in the spec yet, so
        // ours (last time 0.1 % away from the target) differs.
        withKnownIssue("settlingDuration rule is an open spec question") {
            #expect(abs(Spring.smooth.settlingDuration - 0.8) < 1e-3)
            #expect(abs(Spring.snappy.settlingDuration - 0.8768) < 1e-3)
            #expect(abs(Spring.bouncy.settlingDuration - 1.0447) < 1e-3)
        }
    }
}
