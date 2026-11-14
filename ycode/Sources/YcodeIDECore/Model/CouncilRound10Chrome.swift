import Foundation

// Council round 10, group A (`specs/ide/fidelity-council.md` rows 236–247):
// the shared models both IDEs draw from, so the macOS IDE (`YcodeUI`) and
// the Linux IDE (`ycode-ide`) look and behave one to one.

// MARK: Row 236: the determinate build ring

/// The title area's build ring fills to the build's n/m (row 236): its arc
/// starts at 12 o'clock and runs clockwise to the fraction the subtitle
/// counts ("Building • 36/55"); before the first count a short arc of 15°.
/// Each new fraction is reached by easing over 0.25 s and the arc never
/// moves backwards. Times are in seconds on any monotonic clock.
public struct BuildRingProgress: Equatable, Sendable {
    /// The arc before the first count: 15° from the top.
    public static let startFraction = 15.0 / 360
    /// How long the arc takes to reach a new fraction.
    public static let easeDuration = 0.25

    public private(set) var from: Double
    public private(set) var target: Double
    public private(set) var start: Double

    public init(at time: Double = 0) {
        from = Self.startFraction
        target = Self.startFraction
        start = time
    }

    /// The fraction an activity text counts: n/m of "Building • n/m"
    /// (`WorkspaceSession.BuildActivityText.progress`); nil without a count.
    public static func fraction(activity: String) -> Double? {
        guard let bullet = activity.lastIndex(of: "\u{2022}") else { return nil }
        let rest = activity[activity.index(after: bullet)...].trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let n = Int(parts[0]),
              let m = Int(parts[1].prefix { $0.isNumber }), m > 0 else { return nil }
        return min(1, max(0, Double(n) / Double(m)))
    }

    /// The arc's fraction at `time`: eased out from where it was to the target.
    public func value(at time: Double) -> Double {
        let u = min(1, max(0, (time - start) / Self.easeDuration))
        let eased = 1 - pow(1 - u, 3)
        return from + (target - from) * eased
    }

    /// Whether the arc has reached its target at `time`.
    public func isSettled(at time: Double) -> Bool { time - start >= Self.easeDuration || from == target }

    /// Takes a new activity text: a larger count eases to its fraction from
    /// where the arc is now; a smaller one (or none) leaves the arc alone.
    /// Returns whether the target moved.
    @discardableResult
    public mutating func update(activity: String, at time: Double) -> Bool {
        guard let f = Self.fraction(activity: activity), f > target else { return false }
        from = value(at: time)
        target = f
        start = time
        return true
    }
}

// MARK: Row 241: the Welcome window's place

/// Where the Welcome window opens (row 241; `editor-area.md` F.11): on the
/// screen, not on the workspace window: centred horizontally on the
/// visible frame of the screen it opens on, its top 28 % of the free
/// height below the visible frame's top (the reference's 28 : 72 split
/// above and below), never above the visible frame. Coordinates are y up
/// (AppKit's screen space).
public enum WelcomePlacement {
    /// The share of the free height above the window.
    public static let topShare = 0.28

    /// The window's origin (its bottom left) for its size in a visible frame.
    public static func origin(width: Double, height: Double,
                              visible: (x: Double, y: Double, width: Double, height: Double)) -> (x: Double, y: Double) {
        let x = visible.x + (visible.width - width) / 2
        let free = max(0, visible.height - height)
        let top = visible.y + visible.height - topShare * free
        let y = max(visible.y, min(top - height, visible.y + visible.height - height))
        return (x.rounded(), y.rounded())
    }
}

// MARK: Row 247: the jump bar's leading items

/// The jump bar's leading items with a file open (row 247; `source-editor.md`
/// §Jump bar, `editor-area.md` F.10, H.4, I.5), from the bar's leading edge:
/// the Related Items grid 13 × 13 at 13 (four 6 × 6 squares, 1-point
/// strokes on whole pixels), a 1 × 12 divider at 35, the path's first ink
/// at 49. The grid is Ycode's own drawing.
public enum JumpBarLeading {
    public static let gridX = 13.0
    public static let gridSide = 13.0
    /// One square's ink, and the gap between two.
    public static let gridCell = 6.0
    public static let dividerX = 35.0
    public static let dividerWidth = 1.0
    public static let dividerHeight = 12.0
    /// The path's first ink (the project's mark).
    public static let pathX = 49.0

    /// The grid's ink (#939393–#A0A0A0 / #7F7F7F–#8B8B8B measured).
    public static func gridColor(dark: Bool) -> UInt32 { dark ? 0x858585 : 0x9A9A9A }
    /// The divider (#E6E6E6 / #3C3C3C).
    public static func dividerColor(dark: Bool) -> UInt32 { dark ? 0x3C3C3C : 0xE6E6E6 }

    /// The grid: four squares of `gridCell`, 1-point strokes whose centres
    /// lie half a point inside each square, so at 1x each side is one
    /// whole pixel column or row; corners rounded 1.
    public static let grid: GlyphDrawing = {
        let r = 1.0, c = 0.5523 * r
        func square(_ x0: Double, _ y0: Double) -> GlyphPath {
            let a = x0 + 0.5, b = y0 + 0.5, e = x0 + gridCell - 0.5, f = y0 + gridCell - 0.5
            return GlyphPath([
                .move(a + r, b), .line(e - r, b), .curve(e - r + c, b, e, b + r - c, e, b + r),
                .line(e, f - r), .curve(e, f - r + c, e - r + c, f, e - r, f),
                .line(a + r, f), .curve(a + r - c, f, a, f - r + c, a, f - r),
                .line(a, b + r), .curve(a, b + r - c, a + r - c, b, a + r, b), .close,
            ], fills: false, strokeWidth: 1)
        }
        let far = gridSide - gridCell
        return GlyphDrawing(width: gridSide, height: gridSide, paths: [square(0, 0), square(far, 0), square(0, far), square(far, far)])
    }()
}

// MARK: Row 245: the navigator's dark background

public extension WorkspaceChrome {
    /// The navigator's background in dark (row 245): #28282A, flat (the
    /// reference's mean over a flat area in rounds 9 and 10); light keeps
    /// the sidebar material. A sheet's dimming follows from it.
    static let navigatorDarkBackground: UInt32 = 0x28282A
}

// MARK: Rows 243, 244, 246: glyphs on the pixel grid

public extension FileGlyphs {
    /// Ycode's picture glyph (row 243) in the reference's 14 × 12 box: a
    /// rounded frame of a 1-point stroke whose sides fall on whole pixel
    /// columns and rows at 1x (the stroke's centre half a point inside the
    /// box), a small round sun in the upper left third and a filled hill
    /// landscape over the bottom third, its peak right of the centre.
    static let picture: GlyphDrawing = {
        let w = 14.0, h = 12.0, r = 1.5, c = 0.5523 * r
        let a = 0.5, b = 0.5, e = w - 0.5, f = h - 0.5
        let frame = GlyphPath([
            .move(a + r, b), .line(e - r, b), .curve(e - r + c, b, e, b + r - c, e, b + r),
            .line(e, f - r), .curve(e, f - r + c, e - r + c, f, e - r, f),
            .line(a + r, f), .curve(a + r - c, f, a, f - r + c, a, f - r),
            .line(a, b + r), .curve(a, b + r - c, a + r - c, b, a + r, b), .close,
        ], fills: false, strokeWidth: 1)
        let sr = 1.1, sc = 0.5523 * sr, sx = 4.2, sy = 4.0
        let sun = GlyphPath([
            .move(sx + sr, sy), .curve(sx + sr, sy + sc, sx + sc, sy + sr, sx, sy + sr),
            .curve(sx - sc, sy + sr, sx - sr, sy + sc, sx - sr, sy), .curve(sx - sr, sy - sc, sx - sc, sy - sr, sx, sy - sr),
            .curve(sx + sc, sy - sr, sx + sr, sy - sc, sx + sr, sy), .close,
        ])
        let hills = GlyphPath([
            // From the frame's inner edge (y 11), so its bottom is a pixel edge.
            .move(1.0, f - 0.5), .line(1.0, 10.0),
            .curve(2.0, 9.3, 3.4, 8.7, 4.6, 8.9),
            .curve(5.9, 9.1, 7.2, 6.6, 8.6, 6.6),
            .curve(10.0, 6.6, 11.6, 8.6, 13.0, 9.8),
            .line(13.0, f - 0.5), .close,
        ])
        return GlyphDrawing(width: w, height: h, paths: [frame, sun, hills])
    }()

    /// The jump bar's Markdown book (row 246) in a 13 × 10.5 box: 1-point
    /// strokes with the outer sides on the box's first and last pixel
    /// columns and the spine on its middle column at 1x; each page's top
    /// a slight arch (high mid-page, a point lower at the outer corner and
    /// at the spine), its bottom likewise.
    static let jumpBarBook: GlyphDrawing = {
        let w = 13.0, h = 10.5, spine = 6.5, outer = 0.5
        let topCorner = 1.5, topControl = 1.5 - 4.0 / 3.0, bottomCorner = 9.5, bottomControl = 9.5 - 4.0 / 3.0
        func page(_ m: (Double) -> Double) -> GlyphPath {
            let o = m(outer), s = m(spine), k1 = m(outer + (spine - outer) / 3), k2 = m(outer + 2 * (spine - outer) / 3)
            return GlyphPath([
                .move(s, topCorner),
                .curve(k2, topControl, k1, topControl, o, topCorner),
                .line(o, bottomCorner),
                .curve(k1, bottomControl, k2, bottomControl, s, bottomCorner),
                .close,
            ], fills: false, strokeWidth: 1)
        }
        return GlyphDrawing(width: w, height: h, paths: [page { $0 }, page { w - $0 }])
    }()

    /// The jump bar's JSON glyph (row 246) in a 14 × 10 box: braces of
    /// 1-point strokes on whole columns at the box's edges, and the quote as
    /// two filled marks about 3 × 4 (a round dot with a tail rising to the
    /// upper right), at x 4–7 and 8–11, y 3–7.
    static let jumpBarJSON: GlyphDrawing = {
        let w = 14.0, h = 10.0
        func brace(_ m: (Double) -> Double) -> GlyphPath {
            let top = 0.5, bottom = h - 0.5, mid = h / 2, stem = m(1.5), tip = m(0.5), arm = m(3.0)
            return GlyphPath([
                .move(arm, top),
                .curve(m(2.2), top, stem, top + 0.3, stem, top + 1.3),
                .line(stem, mid - 1.3),
                .curve(stem, mid - 0.5, m(1.1), mid, tip, mid),
                .curve(m(1.1), mid, stem, mid + 0.5, stem, mid + 1.3),
                .line(stem, bottom - 1.3),
                .curve(stem, bottom - 0.3, m(2.2), bottom, arm, bottom),
            ], fills: false, strokeWidth: 1)
        }
        func mark(_ x: Double) -> [GlyphPath] {
            let y = 3.0, r = 1.45, cx = x + 1.5, cy = y + 4 - r, c = 0.5523 * r
            let dot = GlyphPath([
                .move(cx + r, cy), .curve(cx + r, cy + c, cx + c, cy + r, cx, cy + r),
                .curve(cx - c, cy + r, cx - r, cy + c, cx - r, cy), .curve(cx - r, cy - c, cx - c, cy - r, cx, cy - r),
                .curve(cx + c, cy - r, cx + r, cy - c, cx + r, cy), .close,
            ])
            let tail = GlyphPath([
                .move(cx - r, cy),
                .curve(cx - r, y + 0.9, x + 1.2, y, x + 3.0, y),
                .line(x + 3.0, y + 0.85),
                .curve(x + 2.1, y + 0.95, cx - 0.1, y + 1.4, cx, cy - r + 0.1),
                .close,
            ])
            return [dot, tail]
        }
        return GlyphDrawing(width: w, height: h, paths: [brace { $0 }, brace { w - $0 }] + mark(4) + mark(8))
    }()

    /// The jump bar's JSON red (row 246): the system red #FF383C / #FF4245,
    /// not the navigator's.
    static let jumpBarJSONTint = GlyphColor(0xFF383C, 0xFF4245)

    /// A glyph as the jump bar draws it: its own drawings for Markdown and
    /// JSON (row 246), else the navigator's fitted to the jump bar's box.
    static func jumpBarDrawing(_ icon: NavigatorRowIcon) -> GlyphDrawing? {
        switch icon {
        case .markdown: jumpBarBook
        case .json: jumpBarJSON
        default: drawing(icon, in: jumpBarBox(icon))
        }
    }

    /// A drawing moved by less than half a pixel and its strokes set to
    /// whole pixels so that, drawn with its box at `origin` (points, in a
    /// space whose pixels are `scale` per point and whose origin is on a
    /// pixel corner), its straight horizontal and vertical runs fall on
    /// whole pixels: a stroke of an odd number of pixels centred on a
    /// pixel's centre, an even one on a pixel edge, a fill's edge on a
    /// pixel edge (rows 243, 244, 246). Strokes become
    /// `max(1, ⌊w × scale + 0.25⌋)` pixels: 1.5 points stays 3 pixels at 2x
    /// and becomes one pixel at 1x, as the reference's straight runs.
    static func pixelAligned(_ d: GlyphDrawing, origin: (x: Double, y: Double), scale: Double) -> GlyphDrawing {
        guard scale > 0 else { return d }
        var out = d
        out.paths = d.paths.map { p in
            var q = p
            if q.strokeWidth > 0 { q.strokeWidth = max(1, (q.strokeWidth * scale + 0.25).rounded(.down)) / scale }
            return q
        }
        // Straight runs: (axis coordinate, length, the ideal fraction of a pixel).
        var xs: [(Double, Double, Double)] = [], ys: [(Double, Double, Double)] = []
        for p in out.paths {
            let strokePixels = Int((p.strokeWidth * scale).rounded())
            let ideal = p.strokeWidth > 0 ? (strokePixels % 2 == 1 ? 0.5 : 0) : 0
            let weight = p.strokeWidth > 0 ? 1.0 : 0.5
            var cur = (0.0, 0.0), first = (0.0, 0.0)
            func run(_ a: (Double, Double), _ b: (Double, Double)) {
                if abs(a.0 - b.0) < 0.01, abs(a.1 - b.1) > 0.3 { xs.append((a.0, abs(a.1 - b.1) * weight, ideal)) }
                if abs(a.1 - b.1) < 0.01, abs(a.0 - b.0) > 0.3 { ys.append((a.1, abs(a.0 - b.0) * weight, ideal)) }
            }
            for e in p.elements {
                switch e {
                case let .move(x, y): cur = (x, y); first = cur
                case let .line(x, y): run(cur, (x, y)); cur = (x, y)
                case let .curve(_, _, _, _, x, y): cur = (x, y)
                case .close: run(cur, first); cur = first
                }
            }
        }
        func bestShift(_ runs: [(Double, Double, Double)], _ o: Double) -> Double {
            guard !runs.isEmpty else { return 0 }
            func frac(_ v: Double) -> Double {
                let f = v.truncatingRemainder(dividingBy: 1)
                return f < 0 ? f + 1 : f
            }
            // The candidates: no shift, and each run's own exact alignment.
            var candidates = [0.0]
            for (v, _, ideal) in runs {
                var d = frac(ideal - (o + v) * scale)
                if d >= 0.5 { d -= 1 }
                candidates.append(d / scale)
            }
            var best = (cost: Double.infinity, shift: 0.0)
            for s in candidates {
                var cost = 0.0
                for (v, len, ideal) in runs {
                    let f = frac((o + v + s) * scale - ideal)
                    cost += len * min(f, 1 - f)
                }
                if cost < best.cost - 1e-9 || (abs(cost - best.cost) <= 1e-9 && abs(s) < abs(best.shift)) { best = (cost, s) }
            }
            return best.shift
        }
        let dx = bestShift(xs, origin.x), dy = bestShift(ys, origin.y)
        if dx != 0 || dy != 0 {
            out.paths = out.paths.map { p in
                let w = p.strokeWidth
                var q = p.transformed(scale: 1, dx: dx, dy: dy)
                q.strokeWidth = w
                return q
            }
        }
        // Then each stroked straight run that still straddles pixels is
        // snapped to its nearest whole-pixel place (an outline whose runs
        // lie at many phases, Python's): its vertices move, and the curves
        // leaving them move their nearer control point with them.
        out.paths = out.paths.map { snapRuns($0, origin: origin, scale: scale) }
        return out
    }

    /// Moves a stroked path's horizontal and vertical runs onto whole
    /// pixels (`pixelAligned`).
    private static func snapRuns(_ p: GlyphPath, origin: (x: Double, y: Double), scale: Double) -> GlyphPath {
        guard p.strokeWidth > 0 else { return p }
        let px = Int((p.strokeWidth * scale).rounded()), ideal = px % 2 == 1 ? 0.5 : 0
        func snap(_ v: Double, _ o: Double) -> Double {
            let d = (o + v) * scale - ideal
            return ((d.rounded() + ideal) / scale) - o
        }
        // The coordinates that carry a straight run.
        var xs: [Double] = [], ys: [Double] = []
        var cur = (0.0, 0.0), first = (0.0, 0.0)
        func run(_ a: (Double, Double), _ b: (Double, Double)) {
            if abs(a.0 - b.0) < 0.001, abs(a.1 - b.1) > 0.3 { xs.append(a.0) }
            if abs(a.1 - b.1) < 0.001, abs(a.0 - b.0) > 0.3 { ys.append(a.1) }
        }
        for e in p.elements {
            switch e {
            case let .move(x, y): cur = (x, y); first = cur
            case let .line(x, y): run(cur, (x, y)); cur = (x, y)
            case let .curve(_, _, _, _, x, y): cur = (x, y)
            case .close: run(cur, first); cur = first
            }
        }
        guard !xs.isEmpty || !ys.isEmpty else { return p }
        func mapX(_ x: Double) -> Double { xs.contains { abs($0 - x) < 0.001 } ? snap(x, origin.x) : x }
        func mapY(_ y: Double) -> Double { ys.contains { abs($0 - y) < 0.001 } ? snap(y, origin.y) : y }
        var q = p
        var last = (0.0, 0.0), lastMoved = (0.0, 0.0)
        q.elements = p.elements.map { e in
            switch e {
            case let .move(x, y):
                let n = (mapX(x), mapY(y))
                last = (x, y); lastMoved = n
                return .move(n.0, n.1)
            case let .line(x, y):
                let n = (mapX(x), mapY(y))
                last = (x, y); lastMoved = n
                return .line(n.0, n.1)
            case let .curve(a, b, c, d, x, y):
                let n = (mapX(x), mapY(y))
                let start = (lastMoved.0 - last.0, lastMoved.1 - last.1), end = (n.0 - x, n.1 - y)
                last = (x, y); lastMoved = n
                return .curve(a + start.0, b + start.1, c + end.0, d + end.1, n.0, n.1)
            case .close: return .close
            }
        }
        return q
    }
}
