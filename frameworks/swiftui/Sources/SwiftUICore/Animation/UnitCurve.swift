import Foundation

/// A function from progress (0…1) to completion (0…1), used to time
/// animations (05-animation.md §2).
///
/// Built-in curves are cubic Béziers from (0, 0) to (1, 1) with the control
/// points of 05 §2 (easeIn (0.42, 0)–(1, 1), easeOut (0, 0)–(0.58, 1),
/// easeInOut (0.42, 0)–(0.58, 1)), plus the circular curves
/// 1 − √(1 − t²), √(1 − (1 − t)²) and their piecewise combination.
public struct UnitCurve: Hashable, Sendable {
    fileprivate indirect enum Storage: Hashable, Sendable {
        case bezier(CGPoint, CGPoint)
        case circularIn
        case circularOut
        case circularInOut
        case inverse(Storage)
    }

    fileprivate let storage: Storage

    fileprivate init(_ storage: Storage) { self.storage = storage }

    /// A cubic Bézier curve from (0, 0) to (1, 1) with the given control
    /// points (x coordinates are clamped to 0…1 so the curve is a function).
    public static func bezier(startControlPoint: UnitPoint, endControlPoint: UnitPoint) -> UnitCurve {
        UnitCurve(.bezier(CGPoint(x: min(max(startControlPoint.x, 0), 1), y: startControlPoint.y),
                          CGPoint(x: min(max(endControlPoint.x, 0), 1), y: endControlPoint.y)))
    }

    public static let linear = UnitCurve(.bezier(.zero, CGPoint(x: 1, y: 1)))
    public static let easeIn = UnitCurve(.bezier(CGPoint(x: 0.42, y: 0), CGPoint(x: 1, y: 1)))
    public static let easeOut = UnitCurve(.bezier(.zero, CGPoint(x: 0.58, y: 1)))
    public static let easeInOut = UnitCurve(.bezier(CGPoint(x: 0.42, y: 0), CGPoint(x: 0.58, y: 1)))
    @available(*, deprecated, renamed: "easeInOut")
    public static let easeInEaseOut = easeInOut
    public static let circularEaseIn = UnitCurve(.circularIn)
    public static let circularEaseOut = UnitCurve(.circularOut)
    public static let circularEaseInOut = UnitCurve(.circularInOut)

    /// The curve's value at `progress` (clamped to 0…1).
    public func value(at progress: Double) -> Double {
        storage.value(min(max(progress, 0), 1))
    }

    /// The curve's slope at `progress` (infinite at the steep ends of the
    /// circular curves).
    public func velocity(at progress: Double) -> Double {
        storage.velocity(min(max(progress, 0), 1))
    }

    /// The inverse function (maps a value back to its progress).
    public var inverse: UnitCurve {
        switch storage {
        case .bezier(let a, let b):
            return UnitCurve(.bezier(CGPoint(x: a.y, y: a.x), CGPoint(x: b.y, y: b.x)))
        case .circularIn: return UnitCurve(.circularOut)
        case .circularOut: return UnitCurve(.circularIn)
        case .inverse(let s): return UnitCurve(s)
        case .circularInOut: return UnitCurve(.inverse(storage))
        }
    }
}

private extension UnitCurve.Storage {
    func value(_ t: Double) -> Double {
        switch self {
        case .bezier(let p1, let p2):
            let b = Bezier(p1, p2)
            return b.y(b.solveX(t))
        case .circularIn: return 1 - (1 - t * t).squareRoot()
        case .circularOut: return (1 - (1 - t) * (1 - t)).squareRoot()
        case .circularInOut:
            return t < 0.5 ? 0.5 * UnitCurve.Storage.circularIn.value(2 * t)
                           : 0.5 + 0.5 * UnitCurve.Storage.circularOut.value(2 * t - 1)
        case .inverse(let s):
            // Bisection on the monotonic base curve.
            var lo = 0.0, hi = 1.0
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                if s.value(mid) < t { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
    }

    func velocity(_ t: Double) -> Double {
        switch self {
        case .bezier(let p1, let p2):
            if p1 == .zero && p2 == CGPoint(x: 1, y: 1) { return 1 }  // linear
            let b = Bezier(p1, p2)
            let s = b.solveX(t)
            let dx = b.dx(s), dy = b.dy(s)
            if abs(dx) < 1e-12 {
                // A control point on an end point makes both derivatives
                // vanish there. Observed (05 §2): such an end reports 1 at
                // the start (easeOut) and 0 at the end (easeIn).
                if abs(dy) < 1e-12 { return t < 0.5 ? 1 : 0 }
                return .infinity
            }
            return dy / dx
        case .circularIn:
            let r = (1 - t * t).squareRoot()
            return r == 0 ? .infinity : t / r
        case .circularOut:
            let r = (1 - (1 - t) * (1 - t)).squareRoot()
            return r == 0 ? .infinity : (1 - t) / r
        case .circularInOut:
            return t < 0.5 ? UnitCurve.Storage.circularIn.velocity(2 * t)
                           : UnitCurve.Storage.circularOut.velocity(2 * t - 1)
        case .inverse(let s):
            let v = s.velocity(value(t))
            return v == 0 ? .infinity : 1 / v
        }
    }
}

/// A cubic Bézier with end points (0, 0) and (1, 1).
private struct Bezier {
    // Polynomial coefficients: f(s) = ((a·s + b)·s + c)·s.
    let ax, bx, cx, ay, by, cy: Double

    init(_ p1: CGPoint, _ p2: CGPoint) {
        cx = 3 * Double(p1.x)
        bx = 3 * Double(p2.x - p1.x) - cx
        ax = 1 - cx - bx
        cy = 3 * Double(p1.y)
        by = 3 * Double(p2.y - p1.y) - cy
        ay = 1 - cy - by
    }

    func x(_ s: Double) -> Double { ((ax * s + bx) * s + cx) * s }
    func y(_ s: Double) -> Double { ((ay * s + by) * s + cy) * s }
    func dx(_ s: Double) -> Double { (3 * ax * s + 2 * bx) * s + cx }
    func dy(_ s: Double) -> Double { (3 * ay * s + 2 * by) * s + cy }

    /// The parameter s with x(s) = t (Newton steps, then bisection).
    func solveX(_ t: Double) -> Double {
        var s = t
        for _ in 0..<8 {
            let err = x(s) - t
            if abs(err) < 1e-12 { return s }
            let d = dx(s)
            if abs(d) < 1e-9 { break }
            s -= err / d
        }
        var lo = 0.0, hi = 1.0
        s = t
        for _ in 0..<64 {
            let v = x(s)
            if abs(v - t) < 1e-12 { break }
            if v < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return s
    }
}
