import Foundation
import OVRender

// `Path` (round R5): an outline of lines and Bézier curves. Written from the
// public API names (api-inventory.md) and the usual geometry of the shapes
// (circular arcs approximated by cubic Béziers, 4 per full turn).

#if !canImport(CoreGraphics)
/// CoreGraphics' affine transform, which swift-corelibs-foundation lacks on
/// Linux (an interop name used by SwiftUI's API): x' = a·x + c·y + tx,
/// y' = b·x + d·y + ty.
public struct CGAffineTransform: Equatable, Hashable, Sendable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat
    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        (self.a, self.b, self.c, self.d, self.tx, self.ty) = (a, b, c, d, tx, ty)
    }
    public init() { self.init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }
    public init(translationX x: CGFloat, y: CGFloat) { self.init(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y) }
    public init(scaleX x: CGFloat, y: CGFloat) { self.init(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0) }
    public init(rotationAngle angle: CGFloat) {
        let s = CGFloat(sin(Double(angle))), co = CGFloat(cos(Double(angle)))
        self.init(a: co, b: s, c: -s, d: co, tx: 0, ty: 0)
    }
    public static let identity = CGAffineTransform()
    public var isIdentity: Bool { self == .identity }
    /// `self` followed by `t2`.
    public func concatenating(_ t2: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: a * t2.a + b * t2.c, b: a * t2.b + b * t2.d,
                          c: c * t2.a + d * t2.c, d: c * t2.b + d * t2.d,
                          tx: tx * t2.a + ty * t2.c + t2.tx, ty: tx * t2.b + ty * t2.d + t2.ty)
    }
    public func translatedBy(x: CGFloat, y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: x, y: y).concatenating(self)
    }
    public func scaledBy(x: CGFloat, y: CGFloat) -> CGAffineTransform { CGAffineTransform(scaleX: x, y: y).concatenating(self) }
    public func rotated(by angle: CGFloat) -> CGAffineTransform { CGAffineTransform(rotationAngle: angle).concatenating(self) }
    public func inverted() -> CGAffineTransform {
        let det = a * d - b * c
        guard det != 0 else { return self }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return CGAffineTransform(a: ia, b: ib, c: ic, d: id, tx: -(tx * ia + ty * ic), ty: -(tx * ib + ty * id))
    }
}

extension CGPoint {
    public func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty)
    }
}

extension CGSize {
    public func applying(_ t: CGAffineTransform) -> CGSize {
        CGSize(width: t.a * width + t.c * height, height: t.b * width + t.d * height)
    }
}

extension CGRect {
    public func applying(_ t: CGAffineTransform) -> CGRect {
        if isNull { return self }
        let pts = [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)]
            .map { $0.applying(t) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
#endif

extension CGAffineTransform {
    package var renderTransform: RenderTransform {
        RenderTransform(a: Double(a), b: Double(b), c: Double(c), d: Double(d), tx: Double(tx), ty: Double(ty))
    }
}

/// An outline in two dimensions.
public struct Path: Equatable, Sendable, CustomStringConvertible {
    /// One element of a path.
    public enum Element: Equatable, Sendable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case closeSubpath
    }

    package var elements: [Element] = []

    public init() {}

    public init(_ rect: CGRect) { addRect(rect) }

    public init(roundedRect rect: CGRect, cornerSize: CGSize, style: RoundedCornerStyle = .continuous) {
        addRoundedRect(in: rect, cornerSize: cornerSize, style: style)
    }

    public init(roundedRect rect: CGRect, cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: style)
    }

    public init(roundedRect rect: CGRect, cornerRadii: RectangleCornerRadii, style: RoundedCornerStyle = .continuous) {
        addRoundedRect(in: rect, cornerRadii: cornerRadii, style: style)
    }

    public init(ellipseIn rect: CGRect) { addEllipse(in: rect) }

    public init(_ callback: (inout Path) -> Void) {
        var p = Path()
        callback(&p)
        self = p
    }

    public var isEmpty: Bool { elements.isEmpty }

    public var description: String {
        elements.map { e -> String in
            func f(_ p: CGPoint) -> String { "\(Double(p.x)) \(Double(p.y))" }
            switch e {
            case .move(let p): return f(p) + " m"
            case .line(let p): return f(p) + " l"
            case let .quadCurve(p, c): return f(c) + " " + f(p) + " q"
            case let .curve(p, c1, c2): return f(c1) + " " + f(c2) + " " + f(p) + " c"
            case .closeSubpath: return "h"
            }
        }.joined(separator: " ")
    }

    /// The last point of the path (nil when empty).
    public var currentPoint: CGPoint? {
        var start: CGPoint?, cur: CGPoint?
        for e in elements {
            switch e {
            case .move(let p):
                start = p
                cur = p
            case .line(let p), .quadCurve(let p, _), .curve(let p, _, _): cur = p
            case .closeSubpath: cur = start
            }
        }
        return cur
    }

    /// Bounds of the path's points and control points (the tight bounds of
    /// the curves lie inside).
    public var boundingRect: CGRect {
        var r = CGRect.null
        func add(_ p: CGPoint) { r = r.union(CGRect(origin: p, size: .zero)) }
        for e in elements {
            switch e {
            case .move(let p), .line(let p): add(p)
            case let .quadCurve(p, c):
                add(p)
                add(c)
            case let .curve(p, c1, c2):
                add(p)
                add(c1)
                add(c2)
            case .closeSubpath: break
            }
        }
        return r.isNull ? .zero : r
    }

    public func forEach(_ body: (Element) -> Void) { elements.forEach(body) }

    // MARK: Building

    public mutating func move(to p: CGPoint) { elements.append(.move(to: p)) }

    public mutating func addLine(to p: CGPoint) {
        if currentPoint == nil { move(to: p) } else { elements.append(.line(to: p)) }
    }

    public mutating func addQuadCurve(to p: CGPoint, control: CGPoint) {
        if currentPoint == nil { move(to: control) }
        elements.append(.quadCurve(to: p, control: control))
    }

    public mutating func addCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint) {
        if currentPoint == nil { move(to: control1) }
        elements.append(.curve(to: p, control1: control1, control2: control2))
    }

    public mutating func closeSubpath() {
        if !elements.isEmpty, elements.last != .closeSubpath { elements.append(.closeSubpath) }
    }

    public mutating func addLines(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        move(to: first)
        for p in points.dropFirst() { elements.append(.line(to: p)) }
    }

    public mutating func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        addPath(Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }, transform: transform)
    }

    public mutating func addRects(_ rects: [CGRect], transform: CGAffineTransform = .identity) {
        for r in rects { addRect(r, transform: transform) }
    }

    public mutating func addRoundedRect(in rect: CGRect, cornerSize: CGSize, style: RoundedCornerStyle = .continuous,
                                        transform: CGAffineTransform = .identity) {
        addRoundedRect(in: rect, radii: (cornerSize, cornerSize, cornerSize, cornerSize), style: style, transform: transform)
    }

    public mutating func addRoundedRect(in rect: CGRect, cornerRadii: RectangleCornerRadii, style: RoundedCornerStyle = .continuous,
                                        transform: CGAffineTransform = .identity) {
        func s(_ v: CGFloat) -> CGSize { CGSize(width: v, height: v) }
        addRoundedRect(in: rect, radii: (s(cornerRadii.topLeading), s(cornerRadii.topTrailing),
                                         s(cornerRadii.bottomTrailing), s(cornerRadii.bottomLeading)),
                       style: style, transform: transform)
    }

    /// Corners clockwise from the top left. `.continuous` corners use a
    /// smoother curve that starts further from the corner (Ycode's own
    /// approximation of a curvature-continuous corner: the radius is
    /// stretched by 1.28 along each edge and the handles shortened, so the
    /// curvature ramps up instead of jumping).
    private mutating func addRoundedRect(in rect: CGRect, radii: (CGSize, CGSize, CGSize, CGSize), style: RoundedCornerStyle,
                                         transform: CGAffineTransform) {
        let r = rect.standardized
        guard r.width > 0, r.height > 0 else { return }
        func clamp(_ s: CGSize) -> CGSize {
            CGSize(width: max(0, min(s.width, r.width / 2)), height: max(0, min(s.height, r.height / 2)))
        }
        let (tl, tr, br, bl) = (clamp(radii.0), clamp(radii.1), clamp(radii.2), clamp(radii.3))
        let continuous = style == .continuous
        // Extent along the edges and handle factor of a corner.
        func ext(_ v: CGFloat, _ limit: CGFloat) -> CGFloat { continuous ? min(v * 1.28, limit) : v }
        let k: CGFloat = continuous ? 0.33 : 0.447_715_25 // 1 − 0.5523 for circular arcs
        var p = Path()
        let w2 = r.width / 2, h2 = r.height / 2
        let tlx = ext(tl.width, w2), tly = ext(tl.height, h2)
        let trx = ext(tr.width, w2), try_ = ext(tr.height, h2)
        let brx = ext(br.width, w2), bry = ext(br.height, h2)
        let blx = ext(bl.width, w2), bly = ext(bl.height, h2)
        p.move(to: CGPoint(x: r.minX + tlx, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - trx, y: r.minY))
        if trx > 0 || try_ > 0 {
            p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + try_),
                       control1: CGPoint(x: r.maxX - trx * k, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + try_ * k))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bry))
        if brx > 0 || bry > 0 {
            p.addCurve(to: CGPoint(x: r.maxX - brx, y: r.maxY),
                       control1: CGPoint(x: r.maxX, y: r.maxY - bry * k), control2: CGPoint(x: r.maxX - brx * k, y: r.maxY))
        }
        p.addLine(to: CGPoint(x: r.minX + blx, y: r.maxY))
        if blx > 0 || bly > 0 {
            p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - bly),
                       control1: CGPoint(x: r.minX + blx * k, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - bly * k))
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tly))
        if tlx > 0 || tly > 0 {
            p.addCurve(to: CGPoint(x: r.minX + tlx, y: r.minY),
                       control1: CGPoint(x: r.minX, y: r.minY + tly * k), control2: CGPoint(x: r.minX + tlx * k, y: r.minY))
        }
        p.closeSubpath()
        addPath(p, transform: transform)
    }

    public mutating func addEllipse(in rect: CGRect, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let kx = rx * 0.552_284_75, ky = ry * 0.552_284_75
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: cy))
        p.addCurve(to: CGPoint(x: cx, y: r.maxY), control1: CGPoint(x: r.maxX, y: cy + ky), control2: CGPoint(x: cx + kx, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: cy), control1: CGPoint(x: cx - kx, y: r.maxY), control2: CGPoint(x: r.minX, y: cy + ky))
        p.addCurve(to: CGPoint(x: cx, y: r.minY), control1: CGPoint(x: r.minX, y: cy - ky), control2: CGPoint(x: cx - kx, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: cy), control1: CGPoint(x: cx + kx, y: r.minY), control2: CGPoint(x: r.maxX, y: cy - ky))
        p.closeSubpath()
        addPath(p, transform: transform)
    }

    /// An arc from `startAngle` sweeping `delta` (positive: clockwise on
    /// screen, since y grows downwards).
    public mutating func addRelativeArc(center: CGPoint, radius: CGFloat, startAngle: Angle, delta: Angle,
                                        transform: CGAffineTransform = .identity) {
        var p = Path()
        let a0 = startAngle.radians, sweep = delta.radians
        let segments = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
        let step = sweep / Double(segments)
        let r = Double(radius)
        func pt(_ a: Double) -> CGPoint { CGPoint(x: Double(center.x) + r * cos(a), y: Double(center.y) + r * sin(a)) }
        let start = pt(a0)
        p.move(to: start)
        var a = a0
        for _ in 0..<segments {
            let b = a + step
            let k = 4.0 / 3.0 * tan((b - a) / 4) * r
            let c1 = CGPoint(x: Double(center.x) + r * cos(a) - k * sin(a), y: Double(center.y) + r * sin(a) + k * cos(a))
            let c2 = CGPoint(x: Double(center.x) + r * cos(b) + k * sin(b), y: Double(center.y) + r * sin(b) - k * cos(b))
            p.addCurve(to: pt(b), control1: c1, control2: c2)
            a = b
        }
        if let cur = currentPoint, transform.isIdentity, elements.last != .closeSubpath {
            // Continue the current subpath with a line to the arc's start.
            if cur != start { elements.append(.line(to: start)) }
            elements.append(contentsOf: p.elements.dropFirst())
        } else {
            addPath(p, transform: transform)
        }
    }

    /// An arc of a circle from `startAngle` to `endAngle`; `clockwise` as
    /// in a y-up coordinate system (so `false` draws clockwise on screen).
    public mutating func addArc(center: CGPoint, radius: CGFloat, startAngle: Angle, endAngle: Angle, clockwise: Bool,
                                transform: CGAffineTransform = .identity) {
        var sweep = endAngle.radians - startAngle.radians
        if clockwise {
            while sweep > 0 { sweep -= 2 * .pi }
        } else {
            while sweep < 0 { sweep += 2 * .pi }
        }
        addRelativeArc(center: center, radius: radius, startAngle: startAngle, delta: .radians(sweep), transform: transform)
    }

    /// A tangent arc between the lines current point → `tangent1End` and
    /// `tangent1End` → `tangent2End`.
    public mutating func addArc(tangent1End p1: CGPoint, tangent2End p2: CGPoint, radius: CGFloat,
                                transform: CGAffineTransform = .identity) {
        guard let p0 = currentPoint else {
            move(to: p1)
            return
        }
        let v1 = (x: Double(p0.x - p1.x), y: Double(p0.y - p1.y)), v2 = (x: Double(p2.x - p1.x), y: Double(p2.y - p1.y))
        let l1 = (v1.x * v1.x + v1.y * v1.y).squareRoot(), l2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
        guard l1 > 0, l2 > 0, radius > 0 else {
            addLine(to: p1)
            return
        }
        let u1 = (x: v1.x / l1, y: v1.y / l1), u2 = (x: v2.x / l2, y: v2.y / l2)
        let cosA = max(-1, min(1, u1.x * u2.x + u1.y * u2.y))
        let angle = acos(cosA)
        guard angle > 1e-9, angle < .pi - 1e-9 else {
            addLine(to: p1)
            return
        }
        let r = Double(radius)
        let d = r / tan(angle / 2)
        let t1 = CGPoint(x: Double(p1.x) + u1.x * d, y: Double(p1.y) + u1.y * d)
        let t2 = CGPoint(x: Double(p1.x) + u2.x * d, y: Double(p1.y) + u2.y * d)
        let bis = (x: u1.x + u2.x, y: u1.y + u2.y)
        let bl = (bis.x * bis.x + bis.y * bis.y).squareRoot()
        let h = r / sin(angle / 2)
        let c = CGPoint(x: Double(p1.x) + bis.x / bl * h, y: Double(p1.y) + bis.y / bl * h)
        addLine(to: t1)
        let a0 = atan2(Double(t1.y - c.y), Double(t1.x - c.x)), a1 = atan2(Double(t2.y - c.y), Double(t2.x - c.x))
        var sweep = a1 - a0
        if sweep > .pi { sweep -= 2 * .pi }
        if sweep < -.pi { sweep += 2 * .pi }
        addRelativeArc(center: c, radius: radius, startAngle: .radians(a0), delta: .radians(sweep), transform: transform)
    }

    public mutating func addPath(_ path: Path, transform: CGAffineTransform = .identity) {
        elements.append(contentsOf: transform.isIdentity ? path.elements : path.applying(transform).elements)
    }

    // MARK: Transforming

    public func applying(_ t: CGAffineTransform) -> Path {
        var p = Path()
        p.elements = elements.map { e in
            switch e {
            case .move(let a): return .move(to: a.applying(t))
            case .line(let a): return .line(to: a.applying(t))
            case let .quadCurve(a, c): return .quadCurve(to: a.applying(t), control: c.applying(t))
            case let .curve(a, c1, c2): return .curve(to: a.applying(t), control1: c1.applying(t), control2: c2.applying(t))
            case .closeSubpath: return .closeSubpath
            }
        }
        return p
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> Path { applying(CGAffineTransform(translationX: dx, y: dy)) }

    /// The part of the path between fractions `from` and `to` of its length
    /// (curves measured by flattening).
    public func trimmedPath(from: CGFloat, to: CGFloat) -> Path {
        let a = max(0, min(1, Double(from))), b = max(0, min(1, Double(to)))
        if a <= 0 && b >= 1 { return self }
        guard b > a else { return Path() }
        let segs = flattened()
        let total = segs.reduce(0) { $0 + $1.length }
        guard total > 0 else { return Path() }
        let s0 = a * total, s1 = b * total
        var out = Path(), pos = 0.0, open = false
        for seg in segs {
            let e = pos + seg.length
            defer { pos = e }
            if seg.isMove {
                open = false
                continue
            }
            if e <= s0 || pos >= s1 || seg.length == 0 { continue }
            let t0 = max(0, (s0 - pos) / seg.length), t1 = min(1, (s1 - pos) / seg.length)
            let p0 = seg.point(t0), p1 = seg.point(t1)
            if !open || t0 > 0 { out.move(to: p0); open = true }
            out.elements.append(.line(to: p1))
        }
        return out
    }

    private struct FlatSegment {
        var a: CGPoint, b: CGPoint, isMove: Bool
        var length: Double { isMove ? 0 : Double(hypot(b.x - a.x, b.y - a.y)) }
        func point(_ t: Double) -> CGPoint { CGPoint(x: Double(a.x) + Double(b.x - a.x) * t, y: Double(a.y) + Double(b.y - a.y) * t) }
    }

    private func flattened() -> [FlatSegment] {
        var out: [FlatSegment] = []
        var cur = CGPoint.zero, start = CGPoint.zero
        for e in elements {
            switch e {
            case .move(let p):
                out.append(FlatSegment(a: cur, b: p, isMove: true))
                cur = p
                start = p
            case .line(let p):
                out.append(FlatSegment(a: cur, b: p, isMove: false))
                cur = p
            case let .quadCurve(p, c):
                var prev = cur
                for i in 1...16 {
                    let t = Double(i) / 16, u = 1 - t
                    let q = CGPoint(x: u * u * Double(cur.x) + 2 * u * t * Double(c.x) + t * t * Double(p.x),
                                    y: u * u * Double(cur.y) + 2 * u * t * Double(c.y) + t * t * Double(p.y))
                    out.append(FlatSegment(a: prev, b: q, isMove: false))
                    prev = q
                }
                cur = p
            case let .curve(p, c1, c2):
                var prev = cur
                for i in 1...24 {
                    let t = Double(i) / 24, u = 1 - t
                    let q = CGPoint(x: u * u * u * Double(cur.x) + 3 * u * u * t * Double(c1.x) + 3 * u * t * t * Double(c2.x) + t * t * t * Double(p.x),
                                    y: u * u * u * Double(cur.y) + 3 * u * u * t * Double(c1.y) + 3 * u * t * t * Double(c2.y) + t * t * t * Double(p.y))
                    out.append(FlatSegment(a: prev, b: q, isMove: false))
                    prev = q
                }
                cur = p
            case .closeSubpath:
                out.append(FlatSegment(a: cur, b: start, isMove: false))
                cur = start
            }
        }
        return out
    }

    /// Whether `point` is inside the path (non-zero or even-odd rule),
    /// computed on the flattened outline.
    public func contains(_ point: CGPoint, eoFill: Bool = false) -> Bool {
        var winding = 0
        var subStart = CGPoint.zero, last = CGPoint.zero, inSub = false
        func edge(_ a: CGPoint, _ b: CGPoint) {
            if a.y <= point.y {
                if b.y > point.y, (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y) > 0 { winding += 1 }
            } else if b.y <= point.y, (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y) < 0 {
                winding -= 1
            }
        }
        for s in flattened() {
            if s.isMove {
                if inSub { edge(last, subStart) }
                subStart = s.b
                last = s.b
                inSub = true
            } else {
                edge(s.a, s.b)
                last = s.b
            }
        }
        if inSub { edge(last, subStart) }
        return eoFill ? winding % 2 != 0 : winding != 0
    }

    /// The display-list form of the path.
    package var renderPath: RenderPath {
        RenderPath(elements.map { e in
            switch e {
            case .move(let p): return .move(p)
            case .line(let p): return .line(p)
            case let .quadCurve(p, c): return .quad(p, control: c)
            case let .curve(p, c1, c2): return .cubic(p, control1: c1, control2: c2)
            case .closeSubpath: return .close
            }
        })
    }
}

/// Corner radii of a rectangle.
public struct RectangleCornerRadii: Equatable, Sendable, Animatable {
    public var topLeading: CGFloat
    public var bottomLeading: CGFloat
    public var bottomTrailing: CGFloat
    public var topTrailing: CGFloat
    public init(topLeading: CGFloat = 0, bottomLeading: CGFloat = 0, bottomTrailing: CGFloat = 0, topTrailing: CGFloat = 0) {
        self.topLeading = topLeading
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
        self.topTrailing = topTrailing
    }
    public var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(topLeading, bottomLeading), AnimatablePair(bottomTrailing, topTrailing)) }
        set {
            topLeading = newValue.first.first
            bottomLeading = newValue.first.second
            bottomTrailing = newValue.second.first
            topTrailing = newValue.second.second
        }
    }
}
