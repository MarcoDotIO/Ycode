// Ycode's own glyphs for the device windows' second capsule and the zoom
// toolbar's Zoom to Fit (device-hub.md §13.1, §14.1; council rows 131, 132, 156), as shapes shared by
// the macOS canvas (drawn with AppKit paths) and the Linux device window
// (drawn with its own primitives), so both draw the same thing. No Apple
// artwork: the shapes follow the spec's descriptions in words.
//
// Coordinates are points around the glyph's centre, y downwards; angles are
// radians in that space (0 to the right, π/2 down).
//
//   Rotate       a rounded square with a curved arrow over its top-left
//                corner pointing right and one under its bottom-right corner
//                pointing left: 19 × 21.5
//   Closed       a narrow upright phone with a small dot near its top-right
//                corner: 10.5 × 13.5
//   Half open    an open book seen from above, its top and bottom edges
//                dipping at the spine: 16 × 13.5
//   Flat         a wide rounded rectangle with a short bar near its bottom
//                edge (a tablet laid flat): 17 × 13.5
//   Zoom to Fit  a magnifier whose lens holds four small arrowheads pointing
//                outward to its diagonal corners (council round 6 row 156,
//                device-hub.md §14.1): 16 × 15, the toolbar's magnifier size

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

    // MARK: Rotate (row 132)

    /// The arrows' circle around the square's centre.
    public static let rotateArcRadius = 8.8
    /// Each arrow sweeps this arc; it ends in an arrowhead.
    public static let rotateTopArc = (from: 1.03 * Double.pi, to: 1.38 * Double.pi)
    public static let rotateBottomArc = (from: 0.03 * Double.pi, to: 0.38 * Double.pi)

    public static var rotate: Glyph {
        let side = 11.0
        let square = Shape.roundedRect(x: -side / 2, y: -side / 2, width: side, height: side, radius: 1.6)
        let r = rotateArcRadius
        var strokes = [square]
        var solids: [Shape] = []
        for a in [rotateTopArc, rotateBottomArc] {
            strokes.append(.arc(centre: Point(0, 0), radius: r, from: a.from, to: a.to))
            solids.append(.polygon(arrowhead(radius: r, angle: a.to)))
        }
        return Glyph(size: (19, 21.5), lineWidth: 1.3, fills: [], strokes: strokes, solids: solids)
    }

    /// A filled arrowhead at the end of an arc (pointing along it, clockwise).
    static func arrowhead(radius r: Double, angle a: Double) -> [Point] {
        let end = Point(r * cos(a), r * sin(a))
        // The direction of travel (clockwise in a y-down space) and the normal.
        let t = (x: -sin(a), y: cos(a)), n = (x: cos(a), y: sin(a))
        let length = 3.2, half = 2.2
        return [Point(end.x + t.x * length, end.y + t.y * length),
                Point(end.x + n.x * half - t.x * 0.4, end.y + n.y * half - t.y * 0.4),
                Point(end.x - n.x * half - t.x * 0.4, end.y - n.y * half - t.y * 0.4)]
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
            // Outer edges at ±8, the spine dipping 2 points at the top and bottom.
            let w = 8.0 - 0.6, top = -6.75 + 0.6, bottom = 6.75 - 0.6, dip = 2.0
            let outline: [Point] = [Point(-w, top), Point(0, top + dip), Point(w, top), Point(w, bottom - dip), Point(0, bottom), Point(-w, bottom - dip)]
            // Filled as two convex halves (back ends that fill fans).
            let left: [Point] = [Point(-w, top), Point(0, top + dip), Point(0, bottom), Point(-w, bottom - dip)]
            let right: [Point] = [Point(0, top + dip), Point(w, top), Point(w, bottom - dip), Point(0, bottom)]
            return Glyph(size: (16, 13.5), lineWidth: 1.2, fills: [.polygon(left), .polygon(right)],
                         strokes: [.polygon(outline), .polyline([Point(0, top + dip), Point(0, bottom)])], solids: [])
        case .flat:
            let body = Shape.roundedRect(x: -8.5 + 0.6, y: -6.75 + 0.6, width: 17 - 1.2, height: 13.5 - 1.2, radius: 2)
            return Glyph(size: (17, 13.5), lineWidth: 1.2, fills: [body], strokes: [body],
                         solids: [.roundedRect(x: -2.5, y: 3.3, width: 5, height: 1.2, radius: 0.6)])
        }
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
