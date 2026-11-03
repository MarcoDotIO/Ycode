// The guest's camera when the viewer re-projects (specs/simulator/xr-depth.md
// §5.5). With depth, the viewer corrects small head motion itself every
// headset frame, so the guest need not follow it: `XRCameraHold` keeps its
// camera on one pose until the head has left a band, and the guest then
// renders nothing new unless its content changes. A picture then shows
// exactly the pose it was told. `XRSweep` turns the camera through the whole
// sphere once, so the world cache holds the room everywhere before the wearer
// looks there.

import Foundation

public struct XRCameraHold: Sendable {
    /// The head may leave the held pose by this much before the camera follows.
    public var bandMetres = 0.015, bandRadians = 1.5 * Double.pi / 180
    /// While following, the head counts as at rest within this much…
    public var restMetres = 0.003, restRadians = 0.3 * Double.pi / 180
    /// …for this long.
    public var restSeconds = 0.15
    private var held: SpatialPose?
    private var reference: (pose: SpatialPose, time: Double)?

    public init() {}

    public static func differs(_ a: SpatialPose, _ b: SpatialPose, metres: Double, radians: Double) -> Bool {
        if (a.position - b.position).length > metres { return true }
        let q = (a.rotation.conjugate * b.rotation).normalized
        return 2 * acos(min(1, abs(q.w))) > radians
    }

    /// True while the camera holds a pose (not following the head).
    public var holding: Bool { held != nil }

    /// Forget the pose: the next head pose is held anew.
    public mutating func reset() { held = nil; reference = nil }

    /// The pose to give the guest for this head pose.
    public mutating func apply(_ head: SpatialPose, time: Double) -> SpatialPose {
        if let h = held {
            if !Self.differs(head, h, metres: bandMetres, radians: bandRadians) { return h }
            held = nil
            reference = (head, time)
            return head
        }
        guard let r = reference else {
            held = head
            return head
        }
        if Self.differs(head, r.pose, metres: restMetres, radians: restRadians) {
            reference = (head, time)
        } else if time - r.time >= restSeconds {
            held = head
            reference = nil
        }
        return head
    }
}

public struct XRSweep: Sendable {
    /// The camera's rotations, stage frame, in the order they are visited.
    public let stops: [SpatialQuaternion]
    public private(set) var index = 0
    public var current: SpatialQuaternion? { index < stops.count ? stops[index] : nil }
    public var finished: Bool { index >= stops.count }

    public init(fov: XRFieldOfView) { stops = Self.stops(fov: fov) }

    public mutating func advance() { index += 1 }

    /// Stops that cover the sphere with a camera of this field of view, with
    /// overlap: rows of yaws (spaced by the view's width less a margin, at the
    /// row's narrowest), then straight up and straight down.
    public static func stops(fov: XRFieldOfView, marginDegrees: Double = 12) -> [SpatialQuaternion] {
        let t = fov.tangents
        let halfWide = atan(min(abs(t.left), abs(t.right))) * 180 / .pi
        let halfTall = atan(min(abs(t.up), abs(t.down))) * 180 / .pi
        let rowStep = max(20, 2 * halfTall - marginDegrees)
        var rows = [0.0]
        var p = rowStep
        // A row is needed while the rows so far stop short of the caps (a cap covers from 90° less its short half).
        while p - rowStep + halfTall < 90 - min(halfWide, halfTall) {
            rows += [p, -p]
            p += rowStep
        }
        let n = max(4, Int((360 / (2 * halfWide - marginDegrees)).rounded(.up)))
        var out: [SpatialQuaternion] = []
        for pitch in rows {
            // Forward first, then outwards to either side.
            let yaws = (0..<n).map { i -> Double in
                let k = Double((i + 1) / 2) * 360 / Double(n)
                return i % 2 == 1 ? k : -k
            }
            for yaw in yaws { out.append(SpatialQuaternion(yaw: yaw * .pi / 180, pitch: pitch * .pi / 180)) }
        }
        out.append(SpatialQuaternion(yaw: 0, pitch: 89 * .pi / 180))
        out.append(SpatialQuaternion(yaw: 0, pitch: -89 * .pi / 180))
        // Whatever the corners of those pictures leave out gets a stop of its own.
        let degree = Double.pi / 180
        for j in 0..<36 {
            for i in 0..<72 {
                let az = Double(i) * 5 * degree, el = (Double(j) * 5 - 87.5) * degree
                let d = SpatialVector(cos(el) * sin(az), sin(el), cos(el) * cos(az))
                if !out.contains(where: { sees($0, d, t) }) {
                    out.append(SpatialQuaternion(yaw: atan2(-d.x, -d.z), pitch: el))
                }
            }
        }
        return out
    }

    /// Is a direction well inside a picture taken with this rotation (not in its outer 3 %)?
    public static func sees(_ r: SpatialQuaternion, _ d: SpatialVector, _ t: (left: Double, right: Double, up: Double, down: Double)) -> Bool {
        let l = r.conjugate.rotate(d)
        guard l.z < 0 else { return false }
        let x = l.x / -l.z, y = l.y / -l.z
        return x > t.left * 0.97 && x < t.right * 0.97 && y < t.up * 0.97 && y > t.down * 0.97
    }
}

/// When a picture of one view is **final** (xr-depth.md §5.5): it shows the camera's
/// pose exactly, so it goes on top and into the cache. Times in ns.
public struct XRFinalPictureRule: Sendable {
    /// A picture that arrived this long after the camera came to rest is final at once (the guest's smoothing has converged).
    public var holdNanoseconds: UInt64
    /// …or when no newer one has come for this long (the guest stops rendering once it has converged).
    public var settleNanoseconds: UInt64
    /// Nothing new this long after the camera came to rest: the picture was already right.
    public var nothingNewNanoseconds: UInt64 = 1_500_000_000
    public init(holdNanoseconds: UInt64, settleNanoseconds: UInt64) { (self.holdNanoseconds, self.settleNanoseconds) = (holdNanoseconds, settleNanoseconds) }

    /// - Parameters:
    ///   - finalFor: the camera command that already has a final picture. A newer picture of the same
    ///     command changes only content (a hover, a pinch's feedback): the guest had converged, so it is
    ///     final at once. Waiting for it to go quiet hid every hover behind the cache for up to 800 ms.
    ///   - sweeping: a sweep's jump always changes the picture, so "nothing new" says nothing there.
    public func isFinal(uploadedAt: UInt64, commandedAt: UInt64, now: UInt64, finalFor: UInt64, sweeping: Bool) -> Bool {
        finalFor == commandedAt
            || uploadedAt >= commandedAt + holdNanoseconds
            || (uploadedAt >= commandedAt && now >= uploadedAt + settleNanoseconds + (sweeping ? 200_000_000 : 0))
            || (!sweeping && now >= commandedAt + nothingNewNanoseconds)
    }
}

/// Whether the newest picture goes on top before it is final (xr-viewer.md §13.5).
/// The guest's camera converges over a few hundred ms after it was last told to
/// move: first change about 130–170 ms, within 0.1° at about 230 ms at 60 pictures/s
/// (visionos.md §5.5.12). Past that a hover or a window opening matters more than
/// what is left of the smoothing, and the picture is drawn at the camera's pose.
/// Only the cache waits for a final picture (it keeps what it takes).
public struct XRFreshOnTopRule: Sendable {
    /// 0: only final pictures go on top.
    public var afterNanoseconds: UInt64
    public init(afterNanoseconds: UInt64) { self.afterNanoseconds = afterNanoseconds }
    public func isOnTop(now: UInt64, commandedAt: UInt64, oneView: Bool, sweeping: Bool) -> Bool {
        afterNanoseconds > 0 && oneView && !sweeping && now >= commandedAt + afterNanoseconds
    }
}

/// How fast the guest's camera is being moved (over about 100 ms). While it is slow
/// a picture's tag is close enough that the picture can stay on top: the tag's error is
/// the speed times what is left of the guest's delay, and a head wandering at a few
/// degrees a second would otherwise hide every picture for as long as it wanders
/// (xr-viewer.md §13.5: 90 % of the headset frames, up to 9.5 s at a time).
public struct XRCameraSpeed: Sendable {
    public var windowSeconds = 0.1
    public private(set) var degreesPerSecond = 0.0, metresPerSecond = 0.0
    private var reference: (pose: SpatialPose, time: Double)?

    public init() {}

    public mutating func update(_ pose: SpatialPose, time: Double) {
        guard let r = reference else { reference = (pose, time); return }
        let dt = time - r.time
        guard dt >= windowSeconds else { return }
        let q = (r.pose.rotation.conjugate * pose.rotation).normalized
        degreesPerSecond = 2 * acos(min(1, abs(q.w))) * 180 / .pi / dt
        metresPerSecond = (pose.position - r.pose.position).length / dt
        reference = (pose, time)
    }

    /// Under `limit` degrees per second and the same number of centimetres per second.
    public func isSlow(limitDegrees limit: Double) -> Bool { limit > 0 && degreesPerSecond <= limit && metresPerSecond <= limit / 100 }
}
