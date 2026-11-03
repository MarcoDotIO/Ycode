// The re-projection's geometry (specs/simulator/xr-depth.md §5.1).
//
// A source pixel at (u, v) ∈ [0, 1]² (v down) with inverse-depth sample d
// (= near / z) is the homogeneous point (tan x, tan y, −1, d / near) of its
// view: tan x = l + u (r − l), tan y = t − v (t − b) for the view's tangents.
// A point with d = 0 lies at infinity (w = 0) and re-projects by rotation
// only. One 4 × 4 matrix, the destination's projection × its view × the
// source's pose, takes these points to the destination's clip space, so the
// GPU needs nothing per vertex but the depth sample.
//
// Projections are Vulkan's clip space (y down, depth 0…1) with reverse-Z and
// an infinite far plane, as the guest's own (visionos.md §5.6.1): depth =
// near / z, the same inverse depth the samples hold, so a depth buffer of the
// destination is again an image of inverse depths.

import Foundation
import YcodeDisplayStream

/// A 4 × 4 matrix, column-major (m[c * 4 + r]).
public struct XRMatrix4: Equatable, Sendable {
    public var m: [Double]

    public init(_ m: [Double]) { precondition(m.count == 16); self.m = m }

    public static let identity = XRMatrix4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    /// From rows (as one writes a matrix down).
    public init(rows r: [[Double]]) {
        var m = [Double](repeating: 0, count: 16)
        for row in 0..<4 { for c in 0..<4 { m[c * 4 + row] = r[row][c] } }
        self.init(m)
    }

    public subscript(row: Int, column: Int) -> Double {
        get { m[column * 4 + row] }
        set { m[column * 4 + row] = newValue }
    }

    public static func * (a: XRMatrix4, b: XRMatrix4) -> XRMatrix4 {
        var out = [Double](repeating: 0, count: 16)
        for c in 0..<4 {
            for r in 0..<4 {
                var s = 0.0
                for k in 0..<4 { s += a.m[k * 4 + r] * b.m[c * 4 + k] }
                out[c * 4 + r] = s
            }
        }
        return XRMatrix4(out)
    }

    public func apply(_ v: (Double, Double, Double, Double)) -> (x: Double, y: Double, z: Double, w: Double) {
        let p = [v.0, v.1, v.2, v.3]
        var o = [0.0, 0, 0, 0]
        for r in 0..<4 { for k in 0..<4 { o[r] += m[k * 4 + r] * p[k] } }
        return (o[0], o[1], o[2], o[3])
    }

    /// Single precision, column-major, as the GPU takes it.
    public var floats: [Float] { m.map(Float.init) }

    /// The pose's local → stage transform (rotation, then translation).
    public init(pose p: SpatialPose) {
        let r = p.rotation.normalized.rows
        self.init(rows: [[r[0][0], r[0][1], r[0][2], p.position.x],
                         [r[1][0], r[1][1], r[1][2], p.position.y],
                         [r[2][0], r[2][1], r[2][2], p.position.z],
                         [0, 0, 0, 1]])
    }

    /// The stage → local transform of a pose (the view matrix).
    public init(view p: SpatialPose) {
        let r = p.rotation.normalized.rows
        let t = p.position
        // Rᵀ and −Rᵀ t.
        let tx = -(r[0][0] * t.x + r[1][0] * t.y + r[2][0] * t.z)
        let ty = -(r[0][1] * t.x + r[1][1] * t.y + r[2][1] * t.z)
        let tz = -(r[0][2] * t.x + r[1][2] * t.y + r[2][2] * t.z)
        self.init(rows: [[r[0][0], r[1][0], r[2][0], tx],
                         [r[0][1], r[1][1], r[2][1], ty],
                         [r[0][2], r[1][2], r[2][2], tz],
                         [0, 0, 0, 1]])
    }

    /// Vulkan clip space for a view with these tangents (left, down
    /// negative): x right, y down, reverse-Z with an infinite far plane
    /// (depth = near / z).
    public static func projection(_ fov: XRFieldOfView, near: Double) -> XRMatrix4 {
        let t = fov.tangents
        let (l, r, u, d) = (t.left, t.right, t.up, t.down)
        return XRMatrix4(rows: [[2 / (r - l), 0, (r + l) / (r - l), 0],
                                [0, -2 / (u - d), -(u + d) / (u - d), 0],
                                [0, 0, 0, near],
                                [0, 0, -1, 0]])
    }
}

/// One view of the scene: where it was seen from and how.
public struct XRViewGeometry: Equatable, Sendable {
    /// The view's local → stage transform (a pose, or a cube face's basis).
    public var toStage: XRMatrix4
    public var fov: XRFieldOfView
    public var near: Double

    public init(toStage: XRMatrix4, fov: XRFieldOfView, near: Double = 0.1) { (self.toStage, self.fov, self.near) = (toStage, fov, near) }
    public init(pose: SpatialPose, fov: XRFieldOfView, near: Double = 0.1) { self.init(toStage: XRMatrix4(pose: pose), fov: fov, near: near) }

    /// The stage → local transform (the inverse of `toStage`, general).
    public var fromStage: XRMatrix4 { XRReprojection.inverse(toStage) }

    /// The homogeneous view point of a source pixel (u, v ∈ [0, 1], v down)
    /// with inverse-depth sample `q` (xr-depth.md §2).
    public func point(u: Double, v: Double, q: UInt16) -> (Double, Double, Double, Double) {
        let t = fov.tangents
        return (t.left + u * (t.right - t.left), t.up - v * (t.up - t.down), -1, Double(q) / 65535 / near)
    }
}

public enum XRReprojection {
    /// The matrix from a source view's homogeneous view points to a
    /// destination view's clip space (the GPU's one matrix).
    public static func matrix(from source: XRViewGeometry, to destination: XRViewGeometry) -> XRMatrix4 {
        XRMatrix4.projection(destination.fov, near: destination.near) * destination.fromStage * source.toStage
    }

    /// Where a source pixel lands: destination (u, v) and its inverse depth
    /// (relative to the destination's near), or nil behind the destination.
    public static func reproject(u: Double, v: Double, q: UInt16, from source: XRViewGeometry,
                                 to destination: XRViewGeometry) -> (u: Double, v: Double, depth: Double)? {
        let c = matrix(from: source, to: destination).apply(source.point(u: u, v: v, q: q))
        guard c.w > 1e-12 else { return nil }
        return ((c.x / c.w + 1) / 2, (c.y / c.w + 1) / 2, c.z / c.w)
    }

    /// The left and right eyes of a head pose: ± ipd / 2 along the head's x
    /// axis, the head's rotation (xr-depth.md §6).
    public static func eyes(head: SpatialPose, ipd: Double) -> (left: SpatialPose, right: SpatialPose) {
        let off = head.rotation.rotate(SpatialVector(ipd / 2, 0, 0))
        return (SpatialPose(position: head.position - off, rotation: head.rotation),
                SpatialPose(position: head.position + off, rotation: head.rotation))
    }

    /// A general 4 × 4 inverse (Gauss–Jordan; the matrices here are rigid
    /// or a cube face's mirrored basis, all well conditioned).
    public static func inverse(_ a: XRMatrix4) -> XRMatrix4 {
        var m = (0..<4).map { r in (0..<4).map { c in a[r, c] } + (0..<4).map { $0 == r ? 1.0 : 0.0 } }
        for col in 0..<4 {
            var pivot = col
            for r in col..<4 where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            m.swapAt(col, pivot)
            let p = m[col][col]
            guard abs(p) > 1e-15 else { return .identity }
            for k in 0..<8 { m[col][k] /= p }
            for r in 0..<4 where r != col {
                let f = m[r][col]
                if f != 0 { for k in 0..<8 { m[r][k] -= f * m[col][k] } }
            }
        }
        return XRMatrix4(rows: (0..<4).map { r in Array(m[r][4..<8]) })
    }
}

// MARK: - Cube faces (the world cache and the room's environment)

/// The six faces of a cube map in Vulkan's order (+X, −X, +Y, −Y, +Z, −Z),
/// each a 90° × 90° view whose texel rows run top to bottom as the Vulkan
/// specification's cube-map face selection defines them (sc, tc, major axis).
public enum XRCubeFace: Int, CaseIterable, Sendable {
    case posX, negX, posY, negY, posZ, negZ

    /// The face's square field of view.
    public static let fov = XRFieldOfView(tangentLeft: -1, right: 1, up: 1, down: -1)

    /// The images of the face's local x, y, z axes in the cube's frame:
    /// local x → the s axis, local y → −(the t axis), local −z → the major
    /// axis (a mirrored basis: cube maps are left-handed).
    public var basis: (x: SpatialVector, y: SpatialVector, z: SpatialVector) {
        let (major, s, t): (SpatialVector, SpatialVector, SpatialVector)
        switch self {
        case .posX: (major, s, t) = (SpatialVector(1, 0, 0), SpatialVector(0, 0, -1), SpatialVector(0, -1, 0))
        case .negX: (major, s, t) = (SpatialVector(-1, 0, 0), SpatialVector(0, 0, 1), SpatialVector(0, -1, 0))
        case .posY: (major, s, t) = (SpatialVector(0, 1, 0), SpatialVector(1, 0, 0), SpatialVector(0, 0, 1))
        case .negY: (major, s, t) = (SpatialVector(0, -1, 0), SpatialVector(1, 0, 0), SpatialVector(0, 0, -1))
        case .posZ: (major, s, t) = (SpatialVector(0, 0, 1), SpatialVector(1, 0, 0), SpatialVector(0, -1, 0))
        case .negZ: (major, s, t) = (SpatialVector(0, 0, -1), SpatialVector(-1, 0, 0), SpatialVector(0, -1, 0))
        }
        return (s, -t, -major)
    }

    /// The cube frame's axes in the stage, `mirrored`: the guest's environment
    /// cube is held in a left-handed frame, its +Z is the stage's −Z
    /// (xr-depth.md §3.4).
    private static func flip(_ v: SpatialVector, _ mirrored: Bool) -> SpatialVector { mirrored ? SpatialVector(v.x, v.y, -v.z) : v }

    /// The face as a view: local → stage, for a cube at `centre` whose frame
    /// is turned by `orientation` relative to the stage (after the mirror).
    public func geometry(centre: SpatialVector, orientation: SpatialQuaternion = .identity, near: Double = 0.1, mirrored: Bool = false) -> XRViewGeometry {
        let b = basis
        let (x, y, z) = (orientation.rotate(Self.flip(b.x, mirrored)), orientation.rotate(Self.flip(b.y, mirrored)), orientation.rotate(Self.flip(b.z, mirrored)))
        let m = XRMatrix4(rows: [[x.x, y.x, z.x, centre.x], [x.y, y.y, z.y, centre.y], [x.z, y.z, z.z, centre.z], [0, 0, 0, 1]])
        return XRViewGeometry(toStage: m, fov: Self.fov, near: near)
    }

    /// The face's axis (the direction it looks along) in the stage frame.
    public func axis(orientation: SpatialQuaternion = .identity, mirrored: Bool = false) -> SpatialVector { orientation.rotate(-Self.flip(basis.z, mirrored)) }

    /// The face whose major axis is the largest component of `d`, and
    /// (u, v) on it (v down).
    public static func lookup(_ d: SpatialVector) -> (face: XRCubeFace, u: Double, v: Double) {
        let ax = abs(d.x), ay = abs(d.y), az = abs(d.z)
        let (face, sc, tc, ma): (XRCubeFace, Double, Double, Double)
        if ax >= ay && ax >= az {
            (face, sc, tc, ma) = d.x >= 0 ? (.posX, -d.z, -d.y, ax) : (.negX, d.z, -d.y, ax)
        } else if ay >= az {
            (face, sc, tc, ma) = d.y >= 0 ? (.posY, d.x, d.z, ay) : (.negY, d.x, -d.z, ay)
        } else {
            (face, sc, tc, ma) = d.z >= 0 ? (.posZ, d.x, -d.y, az) : (.negZ, -d.x, -d.y, az)
        }
        return (face, (sc / ma + 1) / 2, (tc / ma + 1) / 2)
    }
}

/// Which faces a view can see: the angle between a face's axis and the view's
/// forward is below the face's half-diagonal (54.7°) plus the view's (from
/// its tangents), with a margin.
public func xrVisibleFaces(forward: SpatialVector, fov: XRFieldOfView, orientation: SpatialQuaternion = .identity, mirrored: Bool = false) -> UInt32 {
    let t = fov.tangents
    let half = atan((max(abs(t.left), abs(t.right)) * max(abs(t.left), abs(t.right)) + max(abs(t.up), abs(t.down)) * max(abs(t.up), abs(t.down))).squareRoot())
    let limit = half + atan(2.0.squareRoot()) + 0.05
    var mask: UInt32 = 0
    for f in XRCubeFace.allCases {
        let c = max(-1, min(1, f.axis(orientation: orientation, mirrored: mirrored).dot(forward.normalized)))
        if acos(c) < limit { mask |= 1 << UInt32(f.rawValue) }
    }
    return mask
}
