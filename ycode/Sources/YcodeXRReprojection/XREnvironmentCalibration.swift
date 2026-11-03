// The room's environment cube against the pictures (specs/simulator/xr-depth.md
// §5.3). The cube is a panorama of the room taken from one point, the
// guest's probe, somewhere in the room: not at the head. Its frame is known
// (left-handed, `XRCubeFace.geometry(mirrored:)`), its values are linear with
// the pictures' linear light. From final pictures with their depth, which give
// surface points in the stage frame and how bright they are, this finds where
// the probe is, the exposure, and the box the room fills. Drawing the cube on
// that box from that point puts its walls where the pictures have them.

import Foundation
import YcodeDisplayStream

public enum XREnvironmentCalibration {
    /// IEEE half → float.
    @inline(__always)
    public static func half(_ h: UInt16) -> Float {
        let s = UInt32(h >> 15) << 31, e = Int((h >> 10) & 0x1F), m = UInt32(h & 0x3FF)
        if e == 0 {
            if m == 0 { return Float(bitPattern: s) }
            return (s != 0 ? -1 : 1) * Float(m) / 1024 / 16384
        }
        if e == 31 { return Float(bitPattern: s | 0x7F80_0000 | (m << 13)) }
        return Float(bitPattern: s | UInt32(e - 15 + 127) << 23 | (m << 13))
    }

    /// The decoded cube: per face size × size linear RGB.
    public struct Cube: Sendable {
        public let size: Int
        public let rgb: [[Float]]    // 6 faces, 3 floats per texel

        public init(halfFloats data: [UInt8], size: Int) {
            self.size = size
            var faces: [[Float]] = []
            let n = size * size
            for f in 0..<6 {
                var out = [Float](repeating: 0, count: n * 3)
                for i in 0..<n {
                    let o = (f * n + i) * 8
                    for c in 0..<3 { out[i * 3 + c] = XREnvironmentCalibration.half(UInt16(data[o + 2 * c]) | UInt16(data[o + 2 * c + 1]) << 8) }
                }
                faces.append(out)
            }
            rgb = faces
        }

        /// Luminance in a direction of the cube's frame.
        public func luminance(_ d: SpatialVector) -> Float {
            let (face, u, v) = XRCubeFace.lookup(d)
            let x = min(size - 1, max(0, Int(u * Double(size)))), y = min(size - 1, max(0, Int(v * Double(size))))
            let p = rgb[face.rawValue], i = (y * size + x) * 3
            return 0.2126 * p[i] + 0.7152 * p[i + 1] + 0.0722 * p[i + 2]
        }
    }

    /// sRGB-encoded byte → linear.
    @inline(__always)
    public static func linear(_ b: UInt8) -> Float {
        let c = Float(b) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// A surface point seen in a final picture: stage frame, linear luminance.
    public typealias Sample = (point: SpatialVector, luminance: Float)

    public struct Result: Equatable, Sendable {
        /// Where the cube was taken (stage frame).
        public var probe: SpatialVector
        /// The room's extent (stage frame, axis-aligned).
        public var boxMin: SpatialVector, boxMax: SpatialVector
        /// Normalised correlation at the probe (−1…1).
        public var score: Double
        /// Picture / cube (linear), the median of their ratios.
        public var gain: Double
    }

    /// Correlation of the samples' luminance with the cube seen from `probe`
    /// (mirrored: stage direction (x, y, z) is cube direction (x, y, −z)).
    private static func score(cube: Cube, samples: [Sample], probe: SpatialVector) -> Double {
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        for s in samples {
            let d = s.point - probe
            let e = Double(min(1.5, cube.luminance(SpatialVector(d.x, d.y, -d.z))))
            let l = Double(s.luminance)
            sx += l; sy += e; sxx += l * l; syy += e * e; sxy += l * e
        }
        let n = Double(samples.count)
        let v = (sxx - sx * sx / n) * (syy - sy * sy / n)
        return v > 1e-12 ? (sxy - sx * sy / n) / v.squareRoot() : -1
    }

    /// The probe, the exposure and the room's box from samples of several
    /// directions. nil with too few samples or nothing varying.
    public static func calibrate(cube: Cube, samples all: [Sample], searchRadius: Double = 6) -> Result? {
        guard all.count >= 64 else { return nil }
        let stride0 = max(1, all.count / 3000)
        let samples = stride(from: 0, to: all.count, by: stride0).map { all[$0] }
        var best = (score: -2.0, probe: SpatialVector.zero)
        func consider(_ p: SpatialVector) {
            let s = score(cube: cube, samples: samples, probe: p)
            if s > best.score { best = (s, p) }
        }
        var x = -searchRadius
        while x <= searchRadius {
            var z = -searchRadius
            while z <= searchRadius {
                for y in stride(from: -1.0, through: 1.0, by: 0.5) { consider(SpatialVector(x, y, z)) }
                z += 0.5
            }
            x += 0.5
        }
        for step in [0.25, 0.1, 0.05] {
            for _ in 0..<3 {
                let c = best.probe
                for dx in [-step, 0, step] { for dy in [-step, 0, step] { for dz in [-step, 0, step] { consider(c + SpatialVector(dx, dy, dz)) } } }
            }
        }
        guard best.score > -1 else { return nil }
        // The exposure: the median of picture / cube where the cube is not a light.
        var ratios: [Float] = []
        ratios.reserveCapacity(samples.count)
        for s in samples {
            let d = s.point - best.probe
            let e = cube.luminance(SpatialVector(d.x, d.y, -d.z))
            if e > 0.1, e < 1.5, s.luminance < 0.98 { ratios.append(s.luminance / e) }
        }
        ratios.sort()
        let gain = ratios.isEmpty ? 1 : Double(ratios[ratios.count / 2])
        // The box: 1 % and 99 % of the points per axis, the probe inside.
        func bounds(_ f: (SpatialVector) -> Double) -> (Double, Double) {
            let v = all.map { f($0.point) }.sorted()
            return (v[v.count / 100], v[v.count - 1 - v.count / 100])
        }
        let (bx, by, bz) = (bounds(\.x), bounds(\.y), bounds(\.z))
        let p = best.probe
        let lo = SpatialVector(min(bx.0, p.x - 0.5), min(by.0, p.y - 0.5), min(bz.0, p.z - 0.5))
        let hi = SpatialVector(max(bx.1, p.x + 0.5), max(by.1, p.y + 0.5), max(bz.1, p.z + 0.5))
        return Result(probe: p, boxMin: lo, boxMax: hi, score: best.score, gain: gain)
    }

    /// Inverse-depth samples (q = near / z · 65535, `XRDepthImage`'s) that put a
    /// mirrored cube's faces on the box when drawn from the probe: `n` × `n`
    /// per face, six faces; sample j of a row is at u = j / (n − 1).
    public static func boxDepth(probe: SpatialVector, boxMin: SpatialVector, boxMax: SpatialVector, n: Int, near: Double = 0.1) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: 6 * n * n)
        for f in XRCubeFace.allCases {
            let g = f.geometry(centre: .zero, near: near, mirrored: true)
            for j in 0..<n {
                for i in 0..<n {
                    let tx = -1 + 2 * Double(i) / Double(n - 1), ty = 1 - 2 * Double(j) / Double(n - 1)
                    // The local point (tx, ty, −1) · z in the stage is z · dir: z is where the ray meets the box.
                    let r = g.toStage.apply((tx, ty, -1, 0))
                    func hit(_ o: Double, _ d: Double, _ lo: Double, _ hi: Double) -> Double {
                        if d > 1e-9 { return (hi - o) / d }
                        if d < -1e-9 { return (lo - o) / d }
                        return .infinity
                    }
                    let z = min(hit(probe.x, r.x, boxMin.x, boxMax.x), hit(probe.y, r.y, boxMin.y, boxMax.y), hit(probe.z, r.z, boxMin.z, boxMax.z))
                    out[f.rawValue * n * n + j * n + i] = UInt16(max(1, min(65535, (near / max(near, z) * 65535).rounded())))
                }
            }
        }
        return out
    }
}
