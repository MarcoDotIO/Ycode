// OVRender: the display list, the rasteriser and the compositors of
// OpenViews (09-open-design.md §2, §3.5, §3.6; 10-plan.md round R5). This
// module knows nothing about views: SwiftUICore lowers its view graph to a
// `DisplayList`, and a `Compositor` turns display lists into pixels on a
// `RenderSurface` that the platform host (OVPlatform, round R7) or a test
// provides.
//
// Geometry is in points unless a name says pixels; `RenderFrame.scale`
// converts. The origin is the top left corner, y grows downwards.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A 2-D affine transform: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
public struct RenderTransform: Hashable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = RenderTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ x: Double, _ y: Double) -> RenderTransform {
        RenderTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    public static func scale(_ sx: Double, _ sy: Double) -> RenderTransform {
        RenderTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    /// Rotation by `radians`, clockwise on screen (y grows downwards).
    public static func rotation(_ radians: Double) -> RenderTransform {
        let co = cos(radians), si = sin(radians)
        return RenderTransform(a: co, b: si, c: -si, d: co, tx: 0, ty: 0)
    }

    public var isIdentity: Bool { self == .identity }

    /// `self` applied after `inner`: a point goes through `inner` first.
    public func concatenating(_ inner: RenderTransform) -> RenderTransform {
        RenderTransform(a: a * inner.a + c * inner.b,
                        b: b * inner.a + d * inner.b,
                        c: a * inner.c + c * inner.d,
                        d: b * inner.c + d * inner.d,
                        tx: a * inner.tx + c * inner.ty + tx,
                        ty: b * inner.tx + d * inner.ty + ty)
    }

    public func apply(_ p: CGPoint) -> CGPoint {
        CGPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }

    public var inverted: RenderTransform? {
        let det = a * d - b * c
        guard det != 0, det.isFinite else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return RenderTransform(a: ia, b: ib, c: ic, d: id,
                               tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }

    /// The axis-aligned bounding box of `rect` after the transform.
    public func boundingBox(of rect: CGRect) -> CGRect {
        if rect.isNull { return rect }
        let pts = [apply(CGPoint(x: rect.minX, y: rect.minY)), apply(CGPoint(x: rect.maxX, y: rect.minY)),
                   apply(CGPoint(x: rect.minX, y: rect.maxY)), apply(CGPoint(x: rect.maxX, y: rect.maxY))]
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }
}

/// A size in device pixels.
public struct PixelSize: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// A rectangle in device pixels (top-left origin).
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public func union(_ o: PixelRect) -> PixelRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let x0 = min(x, o.x), y0 = min(y, o.y)
        return PixelRect(x: x0, y: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
    }

    public func intersection(_ o: PixelRect) -> PixelRect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        if x1 <= x0 || y1 <= y0 { return PixelRect(x: 0, y: 0, width: 0, height: 0) }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The smallest pixel rectangle covering `rect` (points) at `scale`.
    public static func covering(_ rect: CGRect, scale: Double) -> PixelRect {
        if rect.isNull || rect.isEmpty { return PixelRect(x: 0, y: 0, width: 0, height: 0) }
        let x0 = Int((rect.minX * scale).rounded(.down)), y0 = Int((rect.minY * scale).rounded(.down))
        let x1 = Int((rect.maxX * scale).rounded(.up)), y1 = Int((rect.maxY * scale).rounded(.up))
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
