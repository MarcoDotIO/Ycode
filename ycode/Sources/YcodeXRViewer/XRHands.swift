// The wearer's own hands in the headset (specs/simulator/xr-viewer.md §5.1):
// drawn from XR_EXT_hand_tracking's joints as camera-facing soft discs —
// one per joint and one between the joints of each finger bone — in a
// neutral, half-transparent white, the thumb and index tips highlighted
// while the hand pinches. They are composited by the runtime as quad layers
// over the simulator's picture at the headset's own rate, so they never wait
// for the guest, and they change nothing that is sent to the guest.
// Ycode's own procedural model: no hand assets.

import Foundation
import YcodeDisplayStream

public struct XRHandSprite: Equatable, Sendable {
    public var pose: SpatialPose
    /// Width and height of the disc, metres.
    public var size: Double
    public var highlight: Bool
    /// The uploaded image it shows (a slot of CYcodeOpenXR.h); -1: by `highlight`, the hands' 3 or 2.
    public var image: Int = -1
}

public enum XRHandModel {
    /// The finger chains of XR_EXT_hand_tracking's joint set (metacarpal → tip).
    static let fingers: [[Int]] = [[2, 3, 4, 5], [6, 7, 8, 9, 10], [11, 12, 13, 14, 15], [16, 17, 18, 19, 20], [21, 22, 23, 24, 25]]
    static let wrist = 1, thumbTip = 5, indexTip = 10
    /// A joint's disc is this many times its radius across (the radius is
    /// the runtime's, about the finger's half thickness).
    static let scale = 2.2
    static let defaultRadius = 0.009

    /// The rotation that turns the quad's +Z towards `direction`.
    static func facing(_ direction: SpatialVector) -> SpatialQuaternion {
        let z = SpatialVector(0, 0, 1)
        let d = direction.normalized
        let c = z.dot(d)
        if c > 0.999999 { return .identity }
        if c < -0.999999 { return SpatialQuaternion(axis: SpatialVector(0, 1, 0), radians: .pi) }
        return SpatialQuaternion(axis: z.cross(d), radians: acos(max(-1, min(1, c))))
    }

    /// The discs of both hands seen from `eye` (all in the XR base space).
    /// `full`: every joint and bone (44 discs a hand); otherwise the wrist,
    /// the knuckles and the finger joints without the bone midpoints (24).
    /// Each disc is a layer the runtime composites, so fewer is cheaper
    /// (WiVRn draws each quad layer over the whole eye image).
    public static func sprites(hands: [XRHandJoints?], pinching: [Bool], eye: SpatialVector, full: Bool = true) -> [XRHandSprite] {
        var out: [XRHandSprite] = []
        for (h, hand) in hands.enumerated() {
            guard let j = hand else { continue }
            let pinch = h < pinching.count && pinching[h]
            func radius(_ i: Int) -> Double {
                guard let r = j.radii, i < r.count, r[i] > 0 else { return defaultRadius }
                return r[i]
            }
            func disc(_ p: SpatialVector, _ r: Double, _ highlight: Bool) {
                out.append(XRHandSprite(pose: SpatialPose(position: p, rotation: facing(eye - p)), size: r * scale, highlight: highlight))
            }
            if j.has(wrist) { disc(j.poses[wrist].position, radius(wrist), false) }
            for chain in fingers {
                for (k, i) in chain.enumerated() where j.has(i) {
                    disc(j.poses[i].position, radius(i), pinch && (i == thumbTip || i == indexTip))
                    if full, k > 0, j.has(chain[k - 1]) {
                        let a = j.poses[chain[k - 1]].position, b = j.poses[i].position
                        disc((a + b) * 0.5, (radius(chain[k - 1]) + radius(i)) / 2, false)
                    }
                }
            }
        }
        return out
    }

    /// One hand as a single layer (§5.1): a square quad at the hand's centre
    /// facing the eye, `n` × `n` pixels, with the hand's discs drawn into it
    /// as seen from the eye. One layer per hand instead of one per disc: the
    /// runtime composites each layer over the whole eye image.
    public static func overlay(hand j: XRHandJoints, pinching: Bool, eye: SpatialVector, n: Int = 256) -> (pose: SpatialPose, size: Double, pixels: [UInt8])? {
        let discs = sprites(hands: [j], pinching: [pinching], eye: eye)
        guard !discs.isEmpty else { return nil }
        let centre = discs.reduce(SpatialVector.zero) { $0 + $1.pose.position } * (1 / Double(discs.count))
        let rotation = facing(eye - centre)
        let inv = rotation.conjugate
        // Each disc projected from the eye onto the quad's plane (z = 0 in quad space).
        let eyeQ = inv.rotate(eye - centre)
        var placed: [(x: Double, y: Double, r: Double, hl: Bool)] = []
        var extent = 0.05
        for d in discs {
            let p = inv.rotate(d.pose.position - centre)
            let t = eyeQ.z / max(1e-6, eyeQ.z - p.z)        // along the ray eye → p to z = 0
            let x = eyeQ.x + (p.x - eyeQ.x) * t, y = eyeQ.y + (p.y - eyeQ.y) * t
            let r = d.size / 2 * t
            placed.append((x, y, r, d.highlight))
            extent = max(extent, abs(x) + r, abs(y) + r)
        }
        let size = extent * 2 * 1.05
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let scale = Double(n) / size
        px.withUnsafeMutableBufferPointer { p in
            for d in placed {
                let cx = (d.x + size / 2) * scale, cy = (size / 2 - d.y) * scale, r = max(1, d.r * scale)
                let (b, g, rr, peak): (UInt8, UInt8, UInt8, Double) = d.hl ? (255, 210, 90, 0.95) : (240, 240, 240, 0.55)
                for y in max(0, Int(cy - r))...min(n - 1, Int(cy + r)) {
                    for x in max(0, Int(cx - r))...min(n - 1, Int(cx + r)) {
                        let dist = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot() / r
                        guard dist < 1 else { continue }
                        let a = UInt8(255 * peak * min(1, (1 - dist) / 0.25))
                        let o = (y * n + x) * 4
                        if a > p[o + 3] || d.hl { (p[o], p[o + 1], p[o + 2], p[o + 3]) = (b, g, rr, max(a, p[o + 3])) }
                    }
                }
            }
        }
        return (SpatialPose(position: centre, rotation: rotation), size, px)
    }

    /// The disc images (BGRA, unpremultiplied alpha): a soft neutral white
    /// and the pinch highlight.
    public static func discImage(size n: Int = 64, highlight: Bool) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let c = Double(n - 1) / 2
        let (b, g, r, peak): (UInt8, UInt8, UInt8, Double) = highlight ? (255, 210, 90, 0.95) : (240, 240, 240, 0.55)
        for y in 0..<n {
            for x in 0..<n {
                let d = ((Double(x) - c) * (Double(x) - c) + (Double(y) - c) * (Double(y) - c)).squareRoot() / c
                let a = d >= 1 ? 0 : peak * min(1, (1 - d) / 0.25)
                let o = (y * n + x) * 4
                (px[o], px[o + 1], px[o + 2], px[o + 3]) = (b, g, r, UInt8(a * 255))
            }
        }
        return px
    }
}
