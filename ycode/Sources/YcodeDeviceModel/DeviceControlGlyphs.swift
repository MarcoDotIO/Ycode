// Ycode's own glyphs for the device windows' capsules and toolbar
// (device-hub.md §13.1, §14.1, §15.5, §15.6; council rows 131, 132, 156,
// 174, 175), as shapes shared by the macOS canvas (drawn with AppKit paths)
// and the Linux device window (drawn with its own primitives), so both draw
// the same thing. No Apple artwork: the shapes follow the spec's
// descriptions in words.
//
// Coordinates are points around the glyph's centre, y downwards; angles are
// radians in that space (0 to the right, π/2 down).
//
//   Home         a 3 × 3 grid of small rounded squares (§15.6)
//   Rotate       a rounded square with a small hooked arrow at two opposite
//                corners, the top right and the bottom left (§15.6)
//   Closed       a narrow upright phone with a small dot near its top-right
//                corner: 10.5 × 13.5
//   Half open    a flat sheet whose top and bottom edges curve slightly (an
//                unfolded panel, §15.6): 16 × 13.5
//   Flat         a wide rounded rectangle with a short bar near its bottom
//                edge (a tablet laid flat): 17 × 13.5
//   Zoom to Fit  a magnifier whose lens holds four small arrowheads pointing
//                outward to its diagonal corners (council round 6 row 156,
//                device-hub.md §14.1): 16 × 15, the toolbar's magnifier size
//   Layout       an outline rounded rectangle with a bar across its top and
//                a narrow panel along its right side (§15.5, the resize-mode
//                toggle): 16 × 13
//   Compact      two arrows on the rising diagonal, each pointing inward to
//                the centre (§15.5, the compact-window button): 15 × 15
//   Crown        the Digital Crown seen from the side, a short upright
//                cylinder with ridges, and an arrow at its right pointing
//                left into it, a press (council rows 234, 252): 17 × 15
//   Side Button  the case's right edge in profile, a tall narrow curve like a
//                bracket, and an arrow pointing left into its middle: 17 × 15

import Foundation

public enum DeviceControlGlyphs {
    public struct Point: Equatable, Sendable {
        public var x: Double, y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public enum Shape: Equatable, Sendable {
        /// A rounded rectangle (`x`, `y` its top-left corner).
        case roundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double)
        /// An arc of a circle from `from` to `to` (increasing: clockwise on screen).
        case arc(centre: Point, radius: Double, from: Double, to: Double)
        /// A closed polygon.
        case polygon([Point])
        /// An open polyline.
        case polyline([Point])
        /// A filled circle.
        case disc(centre: Point, radius: Double)
    }

    /// A glyph: shapes filled with its fill colour (a posture's grey or
    /// accent fill), shapes stroked with the line colour, shapes filled with
    /// the line colour (arrowheads, dots, bars).
    public struct Glyph: Equatable, Sendable {
        public var size: (width: Double, height: Double)
        public var lineWidth: Double
        public var fills: [Shape]
        public var strokes: [Shape]
        public var solids: [Shape]

        public static func == (a: Glyph, b: Glyph) -> Bool {
            a.size == b.size && a.lineWidth == b.lineWidth && a.fills == b.fills && a.strokes == b.strokes && a.solids == b.solids
        }
    }

    public enum Posture: Sendable, CaseIterable { case closed, halfOpen, flat }

    // MARK: Home (row 175)

    /// Home: a 3 × 3 grid of small rounded squares (§15.6), about 12.5
    /// across (§13.1's Home box).
    public static let homeCell = 3.3, homePitch = 4.6

    public static var home: Glyph {
        var solids: [Shape] = []
        for i in -1...1 {
            for j in -1...1 {
                let x = Double(i) * homePitch - homeCell / 2, y = Double(j) * homePitch - homeCell / 2
                solids.append(.roundedRect(x: x, y: y, width: homeCell, height: homeCell, radius: 0.9))
            }
        }
        return Glyph(size: (12.5, 12.5), lineWidth: 1, fills: [], strokes: [], solids: solids)
    }

    // MARK: Rotate (rows 132, 175)

    /// The square's half side and each hook's radius around its corner.
    public static let rotateHalfSide = 5.0
    public static let rotateHookRadius = 3.1
    /// Each hook's arc around its corner: the top-right one from above the
    /// top edge, over the corner, to beside the right edge pointing down; the
    /// bottom-left one the same turned half a turn.
    public static let rotateTopRightArc = (from: 1.08 * Double.pi, to: 1.88 * Double.pi)
    public static let rotateBottomLeftArc = (from: 0.08 * Double.pi, to: 0.88 * Double.pi)

    /// Rotate: a rounded square with a small hooked arrow at its top-right
    /// and bottom-left corners (§15.6), both turning clockwise: about 20 ×
    /// 17.5.
    public static var rotate: Glyph {
        let h = rotateHalfSide, r = rotateHookRadius
        let square = Shape.roundedRect(x: -h, y: -h, width: 2 * h, height: 2 * h, radius: 1.6)
        var strokes = [square]
        var solids: [Shape] = []
        for (corner, a) in [(Point(h, -h), rotateTopRightArc), (Point(-h, h), rotateBottomLeftArc)] {
            strokes.append(.arc(centre: corner, radius: r, from: a.from, to: a.to))
            solids.append(.polygon(arrowhead(centre: corner, radius: r, angle: a.to, length: 2.8, half: 1.8)))
        }
        return Glyph(size: (20, 17.5), lineWidth: 1.3, fills: [], strokes: strokes, solids: solids)
    }

    /// A filled arrowhead at the end of an arc (pointing along it, clockwise).
    static func arrowhead(centre c: Point = Point(0, 0), radius r: Double, angle a: Double, length: Double = 3.2,
                          half: Double = 2.2) -> [Point] {
        let end = Point(c.x + r * cos(a), c.y + r * sin(a))
        // The direction of travel (clockwise in a y-down space) and the normal.
        let t = (x: -sin(a), y: cos(a)), n = (x: cos(a), y: sin(a))
        return [Point(end.x + t.x * length, end.y + t.y * length),
                Point(end.x + n.x * half - t.x * 0.4, end.y + n.y * half - t.y * 0.4),
                Point(end.x - n.x * half - t.x * 0.4, end.y - n.y * half - t.y * 0.4)]
    }

    // MARK: Toolbar: layout and compact window (row 174)

    /// The resize-mode toggle's glyph (§15.5): an outline rounded rectangle
    /// with a bar across its top and a narrow panel along its right side.
    public static var layout: Glyph {
        let w = 16.0 - 1.3, h = 13.0 - 1.3, x = -w / 2, y = -h / 2
        let bar = y + 3.4, panel = x + w - 4.6
        return Glyph(size: (16, 13), lineWidth: 1.3, fills: [],
                     strokes: [.roundedRect(x: x, y: y, width: w, height: h, radius: 2.6),
                               .polyline([Point(x, bar), Point(x + w, bar)]),
                               .polyline([Point(panel, bar), Point(panel, y + h)])],
                     solids: [])
    }

    /// The compact-window button's glyph (§15.5): two arrows on the rising
    /// diagonal (bottom left to top right), each pointing inward to the centre.
    public static var compactWindow: Glyph {
        let outer = 6.4, tip = 1.1, head = 3.4
        var strokes: [Shape] = []
        for s in [1.0, -1.0] {
            // From the top-right (s = 1) or bottom-left corner to near the centre.
            let from = Point(s * outer, -s * outer), to = Point(s * tip, -s * tip)
            strokes.append(.polyline([from, to]))
            strokes.append(.polyline([Point(to.x, to.y - s * head), to, Point(to.x + s * head, to.y)]))
        }
        return Glyph(size: (15, 15), lineWidth: 1.4, fills: [], strokes: strokes, solids: [])
    }

    // MARK: Zoom to Fit (council round 6 row 156)

    /// The lens: its centre (from the glyph's centre) and radius (to the
    /// stroke's middle), in the 16 × 15 box the toolbar's other magnifiers
    /// take.
    public static let zoomLensCentre = Point(-1.5, -1.75)
    public static let zoomLensRadius = 4.4
    /// The four arrowheads' tips and bases, from the lens's centre.
    public static let zoomArrowTip = 3.0, zoomArrowBase = 1.15, zoomArrowHalfWidth = 1.05
    /// The handle's end along the diagonal from the lens's centre.
    public static let zoomHandleEnd = 11.0

    /// Zoom to Fit: a magnifier whose lens holds four small arrowheads
    /// pointing outward to its four diagonal corners (§14.1), with a handle
    /// to the bottom right. Ycode's own drawing.
    public static var zoomToFit: Glyph {
        let c = zoomLensCentre, r = zoomLensRadius
        var solids: [Shape] = []
        for k in 0..<4 {
            let a = Double.pi / 4 + Double(k) * Double.pi / 2
            let d = (x: cos(a), y: sin(a)), n = (x: -sin(a), y: cos(a))
            let tip = Point(c.x + d.x * zoomArrowTip, c.y + d.y * zoomArrowTip)
            let base = (x: c.x + d.x * zoomArrowBase, y: c.y + d.y * zoomArrowBase)
            solids.append(.polygon([tip, Point(base.x + n.x * zoomArrowHalfWidth, base.y + n.y * zoomArrowHalfWidth),
                                    Point(base.x - n.x * zoomArrowHalfWidth, base.y - n.y * zoomArrowHalfWidth)]))
        }
        // The handle: a bar 2 wide from the lens's rim to the bottom right.
        let a = Double.pi / 4, d = (x: cos(a), y: sin(a)), n = (x: -sin(a), y: cos(a)), half = 1.0
        let from = (x: c.x + d.x * (r + 0.4), y: c.y + d.y * (r + 0.4)), to = (x: c.x + d.x * zoomHandleEnd, y: c.y + d.y * zoomHandleEnd)
        solids.append(.polygon([Point(from.x + n.x * half, from.y + n.y * half), Point(to.x + n.x * half, to.y + n.y * half),
                                Point(to.x - n.x * half, to.y - n.y * half), Point(from.x - n.x * half, from.y - n.y * half)]))
        return Glyph(size: (16, 15), lineWidth: 1.3, fills: [], strokes: [.arc(centre: c, radius: r, from: 0, to: 2 * Double.pi)],
                     solids: solids)
    }

    // MARK: Postures (row 131)

    public static func posture(_ p: Posture) -> Glyph {
        switch p {
        case .closed:
            let body = Shape.roundedRect(x: -5.25 + 0.6, y: -6.75 + 0.6, width: 10.5 - 1.2, height: 13.5 - 1.2, radius: 2)
            return Glyph(size: (10.5, 13.5), lineWidth: 1.2, fills: [body], strokes: [body],
                         solids: [.disc(centre: Point(2.1, -3.9), radius: 0.85)])
        case .halfOpen:
            // A flat sheet whose top and bottom edges sag slightly toward the
            // middle (§15.6): outer edges at ±8, the sag 1.6 at the middle.
            let w = 8.0 - 0.6, sag = 1.6, top = -6.75 + 0.6 + sag / 2, bottom = 6.75 - 0.6 - sag / 2, n = 8
            func edge(_ base: Double, _ x: Double) -> Double { base + sag * (1 - (x / w) * (x / w)) - sag / 2 }
            let xs = (0...n).map { -w + 2 * w * Double($0) / Double(n) }
            let outline = xs.map { Point($0, edge(top, $0)) } + xs.reversed().map { Point($0, edge(bottom, $0)) }
            // Filled as convex strips (back ends that fill fans).
            let strips: [Shape] = zip(xs, xs.dropFirst()).map { a, b in
                .polygon([Point(a, edge(top, a)), Point(b, edge(top, b)), Point(b, edge(bottom, b)), Point(a, edge(bottom, a))])
            }
            return Glyph(size: (16, 13.5), lineWidth: 1.2, fills: strips, strokes: [.polygon(outline)], solids: [])
        case .flat:
            let body = Shape.roundedRect(x: -8.5 + 0.6, y: -6.75 + 0.6, width: 17 - 1.2, height: 13.5 - 1.2, radius: 2)
            return Glyph(size: (17, 13.5), lineWidth: 1.2, fills: [body], strokes: [body],
                         solids: [.roundedRect(x: -2.5, y: 3.3, width: 5, height: 1.2, radius: 0.6)])
        }
    }

    // MARK: A watch's hardware controls (council rows 234, 252)

    /// Both glyphs' box (row 252: about 17 × 15) and line.
    public static let watchGlyphSize = (width: 17.0, height: 15.0)
    public static let watchGlyphLine = 1.3
    /// The Digital Crown seen from the side: a short upright cylinder (its
    /// outline's top-left corner, size and corner) with two ridges inside it.
    public static let crownCylinder = (x: -7.85, y: -6.85, width: 6.6, height: 13.7, radius: 1.6)
    public static let crownRidgeXs = [-5.65, -3.45]
    public static let crownRidgeHalfLength = 5.0, crownRidgeWidth = 0.9
    /// The case's right edge in profile, a bracket: an arc of a circle about
    /// a centre left of the glyph, from above to below its right-most point.
    public static let caseEdgeCentre = Point(-10.91, 0), caseEdgeRadius = 7.5, caseEdgeHalfAngle = 1.15
    /// The press: an arrow pointing left (its tip, the head's base and half
    /// height, the shaft's right end), level with the middle of the part.
    public static let crownArrow = (tip: 0.6, base: 4.0, half: 2.6, end: 7.85)
    public static let sideArrow = (tip: -1.5, base: 1.9, half: 2.6, end: 7.85)

    static func pressArrow(_ a: (tip: Double, base: Double, half: Double, end: Double)) -> (shaft: Shape, head: Shape) {
        (.polyline([Point(a.base - 0.4, 0), Point(a.end, 0)]),
         .polygon([Point(a.tip, 0), Point(a.base, -a.half), Point(a.base, a.half)]))
    }

    /// Digital Crown: the crown as a short cylinder seen from the side, its
    /// ridges upright, and an arrow at its right pointing left into it.
    public static var digitalCrown: Glyph {
        let c = crownCylinder, arrow = pressArrow(crownArrow), h = crownRidgeHalfLength, w = crownRidgeWidth
        let ridges: [Shape] = crownRidgeXs.map { .roundedRect(x: $0 - w / 2, y: -h, width: w, height: 2 * h, radius: w / 2) }
        return Glyph(size: watchGlyphSize, lineWidth: watchGlyphLine, fills: [],
                     strokes: [.roundedRect(x: c.x, y: c.y, width: c.width, height: c.height, radius: c.radius), arrow.shaft],
                     solids: ridges + [arrow.head])
    }

    /// Side Button: the case's right edge in profile, a tall narrow curve
    /// like a bracket, and an arrow pointing left into its middle.
    public static var sideButton: Glyph {
        let arrow = pressArrow(sideArrow)
        return Glyph(size: watchGlyphSize, lineWidth: watchGlyphLine, fills: [],
                     strokes: [.arc(centre: caseEdgeCentre, radius: caseEdgeRadius, from: -caseEdgeHalfAngle, to: caseEdgeHalfAngle), arrow.shaft],
                     solids: [arrow.head])
    }

    // MARK: Colours (§11.1, §12.1, §13.1)

    /// A posture glyph's line and fill (sRGB hex): the current posture in
    /// the accent colour over its fill (#2D4B6D in dark, #BFDDFE in light),
    /// the others in the glyph colour over grey (#6C6C6D dark, #BEBEBE light).
    public static func postureColours(current: Bool, dark: Bool) -> (line: UInt32, fill: UInt32) {
        if current { return (0x007AFF, dark ? 0x2D4B6D : 0xBFDDFE) }
        return (dark ? 0xFFFFFF : 0x000000, dark ? 0x6C6C6D : 0xBEBEBE)
    }

    /// The point list of a rounded rectangle (corners as quarter circles of
    /// `steps` segments), for back ends without a path type.
    public static func outline(x: Double, y: Double, width: Double, height: Double, radius: Double, steps: Int = 6) -> [Point] {
        let r = min(radius, width / 2, height / 2)
        var out: [Point] = []
        let corners: [(Double, Double, Double)] = [(x + width - r, y + r, -Double.pi / 2), (x + width - r, y + height - r, 0),
                                                   (x + r, y + height - r, Double.pi / 2), (x + r, y + r, Double.pi)]
        for (cx, cy, start) in corners {
            for i in 0...steps {
                let a = start + Double(i) / Double(steps) * Double.pi / 2
                out.append(Point(cx + r * cos(a), cy + r * sin(a)))
            }
        }
        return out
    }

    /// The point list of an arc.
    public static func arcPoints(centre c: Point, radius r: Double, from: Double, to: Double, steps: Int = 14) -> [Point] {
        (0...steps).map { i in
            let a = from + (to - from) * Double(i) / Double(steps)
            return Point(c.x + r * cos(a), c.y + r * sin(a))
        }
    }

    /// The glyph's ink box (around its centre) from its shapes, for tests.
    public static func inkBox(_ g: Glyph) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var pts: [Point] = []
        for s in g.fills + g.strokes + g.solids {
            switch s {
            case .roundedRect(let x, let y, let w, let h, _): pts += [Point(x, y), Point(x + w, y + h)]
            case .arc(let c, let r, let f, let t): pts += arcPoints(centre: c, radius: r, from: f, to: t)
            case .polygon(let p), .polyline(let p): pts += p
            case .disc(let c, let r): pts += [Point(c.x - r, c.y - r), Point(c.x + r, c.y + r)]
            }
        }
        let half = g.lineWidth / 2
        return (pts.map(\.x).min()! - half, pts.map(\.y).min()! - half, pts.map(\.x).max()! + half, pts.map(\.y).max()! + half)
    }
}
