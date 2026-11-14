import Foundation

/// The toolbar's coding assistant button (New Conversation;
/// `fidelity-council.md` round 9, row 214, the owner's rule 5): Ycode's
/// own drawing of an outlined speech bubble with a plus, 18 × 18 points
/// with its tail at the lower left (round 10, row 239), in a 36-point
/// glass circle: the outline painted with one **angular** gradient
/// centred on the bubble and running clockwise from the top through the
/// measured stops, the plus with its own linear gradient. The light capsule
/// darkens from #FBFBFB to #F2F2F2 under the pointer; the dark one does
/// not change. Shared by the AppKit toolbar (`AssistantToolbarButton`)
/// and the Linux IDE's (`GlassCircleButton`), so both draw the same path
/// and colours.
public enum AssistantButtonGlyph {
    // MARK: Size

    /// The glass circle's diameter.
    public static let diameter = 36.0
    /// The glyph's box, stroke and tail included (round 10, row 239: ink
    /// 18 × 18 with the tail at 1x).
    public static let width = 18.0
    public static let height = 18.0
    /// The bubble's outline: one pixel at 1x, so each straight side is one
    /// whole pixel column or row at full colour; 1.4 points at 2x and more,
    /// as round 9 measured it (`bubbleStroke(scale:)`).
    public static let bubbleStroke = 1.0
    public static func bubbleStroke(scale: Double) -> Double { scale >= 1.5 ? 1.4 : bubbleStroke }
    /// The plus's arms (round 10, row 239): 8 points across, 7 down, 1.5
    /// thick, centred in the bubble's body, filled with its own linear
    /// gradient (`plusTop` to `plusBottom`), not the outline's.
    public static let plusStroke = 1.5
    public static let plusSpan = 8.0
    public static let plusHeight = 7.0

    // MARK: Path (y down, in the glyph's box)

    /// One drawing step of a path, in the glyph's box (y down).
    public enum Element: Equatable, Sendable {
        case move(Double, Double)
        case line(Double, Double)
        case quad(Double, Double, cx: Double, cy: Double)
        case curve(Double, Double, c1x: Double, c1y: Double, c2x: Double, c2y: Double)
        case close
    }

    /// The bubble's body: its stroke's centre half a point inside the box at
    /// the left, top and right (whole pixels at 1x), its bottom at 14 (the
    /// bottom splits over two rows, as the reference's); the corners'
    /// radius 2.
    static let inset = 0.5
    static let bodyBottom = 14.0
    static let corner = 2.0
    /// The tail's point: 4 in from the body's left edge and 3 below its
    /// bottom.
    static let tip = (x: 4.5, y: 17.0)

    /// The bubble's outline (stroked, not filled), clockwise from the top
    /// left corner's end: the top edge, the right corners, the bottom edge
    /// to the tail, the tail's point, back up to the bottom left corner and
    /// the left edge.
    public static var bubble: [Element] {
        let l = inset, t = inset, r = width - inset, b = bodyBottom, c = corner
        let k = 0.5523 * c   // a quarter circle's control length
        return [
            .move(l + c, t),
            .line(r - c, t),
            .curve(r, t + c, c1x: r - c + k, c1y: t, c2x: r, c2y: t + c - k),
            .line(r, b - c),
            .curve(r - c, b, c1x: r, c1y: b - c + k, c2x: r - c + k, c2y: b),
            .line(8.2, b),
            .quad(tip.x, tip.y, cx: 6.0, cy: b + 1.3),
            .quad(l + c, b, cx: 3.9, cy: b + 1.2),
            .curve(l, b - c, c1x: l + c - k, c1y: b, c2x: l, c2y: b - c + k),
            .line(l, t + c),
            .curve(l + c, t, c1x: l, c1y: t + c - k, c2x: l + c - k, c2y: t),
            .close,
        ]
    }

    /// The outline gradient's centre: the bubble body's centre.
    public static let center = (x: width / 2, y: (inset + bodyBottom) / 2)
    /// The plus's centre (x 9, y 7 in the box: at 1x on the pixel edges
    /// in the body's middle, as the reference's x 584, y 23.5–24).
    public static let plusCenter = (x: width / 2, y: 7.0)

    /// The plus: two strokes through its centre, round caps; the ink spans
    /// `plusSpan` across and `plusHeight` down.
    public static var plus: [Element] {
        let h = (plusSpan - plusStroke) / 2, v = (plusHeight - plusStroke) / 2, (x, y) = plusCenter
        return [.move(x - h, y), .line(x + h, y), .move(x, y - v), .line(x, y + v)]
    }

    /// The plus's own linear gradient, top to bottom of its ink (round 9's
    /// #F46E5A → #BF8EA8; median about #E3828D / #DF7C80), in both
    /// appearances.
    public static let plusTop: UInt32 = 0xF46E5A
    public static let plusBottom: UInt32 = 0xBF8EA8
    /// The plus's ink from top to bottom (y in the box).
    public static var plusInkY: (top: Double, bottom: Double) { (plusCenter.y - plusHeight / 2, plusCenter.y + plusHeight / 2) }

    /// The plus's colour at `y` in the box, as (r, g, b) in 0…1.
    public static func plusColor(atY y: Double) -> (r: Double, g: Double, b: Double) {
        let (t, b) = plusInkY
        let f = min(1, max(0, (y - t) / (b - t)))
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double(v >> s & 0xFF) / 255 }
        func mix(_ s: UInt32) -> Double { ch(plusTop, s) + (ch(plusBottom, s) - ch(plusTop, s)) * f }
        return (mix(16), mix(8), mix(0))
    }

    // MARK: Gradient

    /// The measured stops, clockwise from the top (degrees), 0xRRGGBB.
    public struct Stop: Equatable, Sendable {
        public var degrees: Double
        public var light: UInt32
        public var dark: UInt32
    }

    public static let stops: [Stop] = [
        Stop(degrees: 0, light: 0xFD6848, dark: 0xFD6043),
        Stop(degrees: 45, light: 0xFC5168, dark: 0xFB4A53),
        Stop(degrees: 90, light: 0xF27CCA, dark: 0xF070BB),
        Stop(degrees: 135, light: 0xBE99EF, dark: 0xBE96EE),
        Stop(degrees: 180, light: 0x80AADC, dark: 0x78A5D7),
        Stop(degrees: 225, light: 0x6FB1D6, dark: 0x6AAED1),
        Stop(degrees: 270, light: 0xE5956F, dark: 0xDF8F5E),
        Stop(degrees: 315, light: 0xFD8039, dark: 0xF97533),
        Stop(degrees: 360, light: 0xFD6848, dark: 0xFD6043),
    ]

    /// The gradient's colour at `degrees` clockwise from the top, as
    /// (r, g, b) in 0…1: linear between the neighbouring stops.
    public static func color(atDegrees degrees: Double, dark: Bool) -> (r: Double, g: Double, b: Double) {
        var a = degrees.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        let i = max(0, min(stops.count - 2, Int(a / 45)))
        let s0 = stops[i], s1 = stops[i + 1]
        let f = (a - s0.degrees) / (s1.degrees - s0.degrees)
        func ch(_ v: UInt32, _ shift: UInt32) -> Double { Double(v >> shift & 0xFF) / 255 }
        let c0 = dark ? s0.dark : s0.light, c1 = dark ? s1.dark : s1.light
        func mix(_ shift: UInt32) -> Double { ch(c0, shift) + (ch(c1, shift) - ch(c0, shift)) * f }
        return (mix(16), mix(8), mix(0))
    }

    /// The angle (degrees, clockwise from the top) of a point in the
    /// glyph's box (y down) as the gradient sees it.
    public static func degrees(atX x: Double, y: Double) -> Double {
        let a = atan2(x - center.x, center.y - y) * 180 / .pi
        return a < 0 ? a + 360 : a
    }

    // MARK: Capsule

    /// The capsule's fill at rest and under the pointer, 0xRRGGBB: light
    /// #FBFBFB to #F2F2F2; dark #454545 either way.
    public static func capsule(dark: Bool, hovered: Bool) -> UInt32 {
        dark ? 0x454545 : (hovered ? 0xF2F2F2 : 0xFBFBFB)
    }

    /// The hover drawn over a capsule the toolkit fills itself: black at
    /// this opacity takes #FBFBFB to #F2F2F2 (none in dark).
    public static func hoverOverlayOpacity(dark: Bool) -> Double {
        dark ? 0 : 1 - Double(0xF2) / Double(0xFB)
    }

    /// Pressed (not captured in the reference; Ycode's own, as a system
    /// glass button): black at this opacity over the capsule, a little
    /// darker than the hover.
    public static func pressedOverlayOpacity(dark: Bool) -> Double { dark ? 0.12 : 0.08 }
}
