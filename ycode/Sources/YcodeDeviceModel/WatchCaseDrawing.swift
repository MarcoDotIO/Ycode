// A watch's case as both IDEs draw it (council round 10 rows 250 and 251;
// watchos.md §11.3; device-hub.md §4.3). Ycode's own drawing of the
// structure the council measured at Zoom to Fit, given here in device points
// from the silhouette's outer edge inwards:
//
//   body     a soft light rim whose glow rises from the background over about
//            2.8 to a core 1.6 wide (#5C5C5C, centred about 3.6 in), drops
//            within 0.8 to a flat #1F1F1F band 4.4 wide, which fades to black
//            over 2.8; from there the case is black up to the screen, so the
//            screen's corner is never outlined
//   buttons  the crown, the side button and an Ultra's Action button: the
//            same rim, narrower (its glow over 0.8, its core 0.6), dark
//            inside (#151515); the crown has 9 fine ridges 3 apart across its
//            outer third only
//
// The colours are the same in light and dark (the reference's light case was
// not captured). The macOS frame fills the profile in nested steps; the Linux
// device window shades it between the stops; both read these values.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum WatchCaseDrawing {
    /// One stop of a profile: `inset` device points inside the outline, an
    /// sRGB colour and its opacity. Between stops the colour runs linearly.
    public struct Stop: Equatable, Sendable {
        public var inset: Double
        public var color: UInt32
        public var alpha: Double
        public init(_ inset: Double, _ color: UInt32, _ alpha: Double = 1) {
            self.inset = inset
            self.color = color
            self.alpha = alpha
        }
    }

    /// The rim's core (#5B5B5B–#5E5E5E), the band, the glass.
    public static let rim: UInt32 = 0x5C5C5C
    public static let band: UInt32 = 0x1F1F1F
    public static let black: UInt32 = 0x000000
    /// The inside of the crown and the buttons (#11–#18), and while pressed.
    public static let buttonInside: UInt32 = 0x151515
    public static let pressedInside: UInt32 = 0x4A4A4A

    /// The body, outside in (row 250).
    public static let caseStops: [Stop] = [
        Stop(0, rim, 0), Stop(2.8, rim), Stop(4.4, rim), Stop(5.2, band), Stop(9.6, band), Stop(12.4, black),
    ]
    /// The crown and the buttons, outside in (row 251).
    public static let buttonStops: [Stop] = [Stop(0, rim, 0), Stop(0.8, rim), Stop(1.4, rim), Stop(2.0, buttonInside)]

    /// The crown's ridges (row 251): 9 lines 3 apart, centred on the crown,
    /// from about 5.2 inside its outer edge to its rim.
    public static let ridgeCount = 9
    public static let ridgePitch = 3.0
    public static let ridgeReach = 5.2
    public static let ridgeEnd = 0.8
    public static let ridgeWidth = 0.6
    public static let ridge: UInt32 = 0x3C3C3C

    /// The colour and opacity `inset` device points inside the outline.
    public static func colour(_ stops: [Stop], at inset: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        func rgb(_ c: UInt32) -> (Double, Double, Double) {
            (Double((c >> 16) & 0xFF) / 255, Double((c >> 8) & 0xFF) / 255, Double(c & 0xFF) / 255)
        }
        guard let first = stops.first, let last = stops.last else { return (0, 0, 0, 0) }
        if inset <= first.inset { let c = rgb(first.color); return (c.0, c.1, c.2, first.alpha) }
        if inset >= last.inset { let c = rgb(last.color); return (c.0, c.1, c.2, last.alpha) }
        let i = stops.firstIndex { $0.inset > inset } ?? stops.count - 1
        let a = stops[i - 1], b = stops[i]
        let t = (inset - a.inset) / max(1e-9, b.inset - a.inset)
        let ca = rgb(a.color), cb = rgb(b.color)
        return (ca.0 + (cb.0 - ca.0) * t, ca.1 + (cb.1 - ca.1) * t, ca.2 + (cb.2 - ca.2) * t, a.alpha + (b.alpha - a.alpha) * t)
    }

    /// The outline `inset` inside a rounded rectangle (corners concentric,
    /// never below 0), as points: each corner always `steps` + 1 points, top
    /// left, top right, bottom right, bottom left (y down), so the outlines of
    /// one shape at any two insets pair up point by point.
    public static func outline(_ r: CGRect, radii: CornerRadii, inset: Double, steps: Int = 12) -> [CGPoint] {
        let rect = r.insetBy(dx: inset, dy: inset)
        let lim = max(0, min(Double(rect.width), Double(rect.height)) / 2)
        func rad(_ v: Double) -> Double { min(lim, max(0, v - inset)) }
        let (x0, y0, x1, y1) = (Double(rect.minX), Double(rect.minY), Double(rect.maxX), Double(rect.maxY))
        let corners: [(cx: Double, cy: Double, r: Double, start: Double)] = [
            (x0 + rad(radii.topLeft), y0 + rad(radii.topLeft), rad(radii.topLeft), Double.pi),
            (x1 - rad(radii.topRight), y0 + rad(radii.topRight), rad(radii.topRight), 1.5 * Double.pi),
            (x1 - rad(radii.bottomRight), y1 - rad(radii.bottomRight), rad(radii.bottomRight), 0),
            (x0 + rad(radii.bottomLeft), y1 - rad(radii.bottomLeft), rad(radii.bottomLeft), 0.5 * Double.pi),
        ]
        var out: [CGPoint] = []
        for c in corners {
            for i in 0...steps {
                let a = c.start + Double(i) / Double(steps) * Double.pi / 2
                out.append(CGPoint(x: c.cx + cos(a) * c.r, y: c.cy + sin(a) * c.r))
            }
        }
        return out
    }

    /// The crown's ridges in an upright drawing: horizontal lines across its
    /// outer part (the crown stands out of the body's right edge).
    public static func ridges(crown r: CGRect) -> [FrameSegment] {
        let mid = Double(r.midY), x0 = Double(r.maxX) - ridgeReach, x1 = Double(r.maxX) - ridgeEnd
        return (0..<ridgeCount).map { i in
            let y = mid + (Double(i) - Double(ridgeCount - 1) / 2) * ridgePitch
            return FrameSegment(from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y))
        }
    }

    /// The opacity each nested fill of a profile needs so that, drawn outside
    /// in over one another, the strip between `insets[k]` and `insets[k + 1]`
    /// ends up with the profile's opacity there (a fill covers everything
    /// inside it, so the strips' opacities compound).
    public static func nestedAlphas(_ targets: [Double]) -> [Double] {
        var below = 0.0
        return targets.map { a in
            let a = min(1, max(0, a))
            defer { below = max(below, a) }
            guard below < 1 else { return 1 }
            return a <= below ? 0 : 1 - (1 - a) / (1 - below)
        }
    }
}
