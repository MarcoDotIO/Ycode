// The gaze and pinch path of the headset viewer (specs/simulator/xr-viewer.md
// §13): what the eye tracker's samples become before they are the guest's ray,
// and what a pinch does to that ray. Foundation only, so every piece is tested
// with synthetic gaze of a recorded shape (noise, saccades, blinks, head sway).
//
// Privacy (§8): samples pass through and are never logged, recorded or kept
// beyond the short history a fixation needs. Only counts and spreads leave.
//
// The design follows what the eyes do (public eye-movement literature, not any
// device's code):
// - **Fixation.** The eye holds a point of the world; while the head moves the
//   vestibulo-ocular reflex turns the eye against it, so the gaze is steady in
//   the *world* and moves in the *head*. A filter in head space lags that
//   counter-rotation and drags the ray off the target as the head moves.
// - **Saccade.** The eye jumps within 20–60 ms and arrives; there is nothing to
//   smooth, and every millisecond of lag leaves the ray on the last target.
// - **Eyes that travel with the head** (no reflex, a head turn with the eyes
//   carried along): steady in the head. The filter takes whichever frame
//   explains the new sample better.

import Foundation

public struct XRGazeSettings: Sendable, Equatable {
    public enum Filter: String, Sendable, CaseIterable {
        /// Steady on fixations, no lag on saccades, world or head frame by what the eyes do (the default).
        case fixation
        /// The One-Euro filter in head space of runs 5–8 (minimum cutoff 1 Hz, β 0.02): for comparison.
        case oneEuro = "oneeuro"
        /// The tracker's samples as they come.
        case raw
    }

    public var filter = Filter.fixation
    /// `fixation`: the smoothing while the error is small (Hz). 1 Hz lags 160 ms, 3 Hz about 50 ms.
    public var cutoffHz = 3.0
    /// `fixation`: an error larger than this for `snapSamples` samples in a row is a saccade: the ray jumps to the eye.
    public var snapDegrees = 1.0
    public var snapSamples = 2
    /// `fixation`: the ray stays until the filtered gaze has left it by this much (a target's edge does not flicker).
    public var deadbandDegrees = 0.1
    /// A dropout (a blink) up to this long holds the last ray; past it the pointer falls back.
    public var holdSeconds = 0.35
    /// A pinch that begins this soon after a saccade selects what the eyes were on before it.
    public var pinchRewindSeconds = 0.07
    /// A fixation must have lasted this long to be rewound to.
    public var rewindMinimumFixation = 0.1
    /// The ray stays at the pinch's place until the release (the desktop viewers' rule, visionos.md §5.5.8 item 4).
    public var freezeDuringPinch = true
    /// The tracker's constant error, head space, radians, added to every sample (`XRGazeCalibration`).
    public var biasYaw = 0.0, biasPitch = 0.0

    public init() {}
}

public func xrAngleDegrees(_ a: SpatialVector, _ b: SpatialVector) -> Double {
    // atan2 keeps small angles exact, where acos loses them.
    atan2(a.cross(b).length, a.dot(b)) * 180 / .pi
}

/// Yaw and pitch of a direction, radians (positive yaw turns left, as `SpatialQuaternion(yaw:pitch:)`).
func xrYawPitch(_ d: SpatialVector) -> (yaw: Double, pitch: Double) {
    (atan2(-d.x, -d.z), asin(max(-1, min(1, d.normalized.y))))
}

/// The gaze direction over time (`update` per tracked sample; world frame in and out).
public struct XRGazeFilter: Sendable {
    public var settings: XRGazeSettings
    private var state: SpatialVector?, output: SpatialVector?
    private var lastHead: SpatialQuaternion?
    private var lastTime: Double?
    private var over = 0
    // oneeuro
    private var yawFilter = XROneEuro(minCutoff: 1.0, beta: 0.02), pitchFilter = XROneEuro(minCutoff: 1.0, beta: 0.02)
    /// When the ray last jumped, and for how long it had been steady then.
    public private(set) var lastSaccadeAt: Double?
    /// What the ray was on before the last jump.
    public private(set) var previousFixation: (direction: SpatialVector, lasted: Double)?
    private var fixationStart: Double?

    public init(settings: XRGazeSettings = XRGazeSettings()) { self.settings = settings }

    public mutating func reset() {
        state = nil; output = nil; lastHead = nil; lastTime = nil; over = 0
        yawFilter.reset(); pitchFilter.reset()
        fixationStart = nil; previousFixation = nil; lastSaccadeAt = nil
    }

    /// The sample as the filter takes it, with the tracker's constant error corrected.
    public func corrected(_ raw: SpatialVector, head: SpatialQuaternion) -> SpatialVector {
        guard settings.biasYaw != 0 || settings.biasPitch != 0 else { return raw.normalized }
        let local = head.conjugate.rotate(raw).normalized
        let (y, p) = xrYawPitch(local)
        return head.rotate(SpatialQuaternion(yaw: y + settings.biasYaw, pitch: p + settings.biasPitch).rotate(SpatialVector(0, 0, -1)))
    }

    /// The direction to send for this sample (unit, world frame).
    public mutating func update(_ sample: SpatialVector, head: SpatialQuaternion, time: Double) -> SpatialVector {
        let raw = corrected(sample, head: head)
        defer { lastHead = head; lastTime = time }
        switch settings.filter {
        case .raw:
            return raw
        case .oneEuro:
            let local = head.conjugate.rotate(raw)
            let (y, p) = xrYawPitch(local)
            let fy = yawFilter.filter(y * 180 / .pi, at: time) * .pi / 180, fp = pitchFilter.filter(p * 180 / .pi, at: time) * .pi / 180
            return head.rotate(SpatialQuaternion(yaw: fy, pitch: fp).rotate(SpatialVector(0, 0, -1)))
        case .fixation:
            break
        }
        guard var f = state, var o = output, let h = lastHead, let t = lastTime, time > t else {
            state = raw
            output = raw
            fixationStart = fixationStart ?? time
            return raw
        }
        // Which frame the eyes hold: the world (f as it is) or the head (f carried by the head's turn).
        let turn = (head * h.conjugate).normalized
        let carried = turn.rotate(f)
        if xrAngleDegrees(carried, raw) < xrAngleDegrees(f, raw) {
            f = carried
            o = turn.rotate(o).normalized
        }
        let e = xrAngleDegrees(f, raw)
        if e > settings.snapDegrees {
            over += 1
            if over >= settings.snapSamples {
                // A saccade: the ray goes to the eye now. One outlying sample does not move it.
                // In flight a saccade snaps several times; what it left is the fixation that lasted.
                let lasted = time - (fixationStart ?? time)
                if lasted >= settings.rewindMinimumFixation { previousFixation = (o, lasted) }
                lastSaccadeAt = time
                fixationStart = time
                over = 0
                state = raw
                output = raw
                return raw
            }
            state = f
            output = o
            return o
        }
        over = 0
        let dt = min(0.1, time - t)
        let least = 1 / (1 + 1 / (2 * .pi * settings.cutoffHz * dt))
        // Small errors are noise, errors close to a saccade's are the eye drifting: follow those faster.
        let share = e / settings.snapDegrees
        let alpha = max(least, min(1, share * share))
        f = (f + (raw - f) * alpha).normalized
        let lag = xrAngleDegrees(o, f)
        if lag > settings.deadbandDegrees {
            o = (f + (o - f) * (settings.deadbandDegrees / lag)).normalized
        }
        state = f
        output = o
        return o
    }

    /// What the eyes are doing now, for the pinch log (no direction).
    public func fixationAge(at time: Double) -> Double? { fixationStart.map { time - $0 } }
}

/// A finger pinch with a release that does not bounce: on under `on` at once,
/// off only after the distance has stayed over `off` for `releaseSeconds`. It
/// also keeps what a threshold needs to be tuned: how close the fingers came.
public struct XRPinchGate: Sendable, Equatable {
    public var on = 0.020, off = 0.035
    public var releaseSeconds = 0.01
    public private(set) var state = false
    private var overSince: Double?
    private var closest = Double.infinity
    private var dipping = false
    /// Hands closed to within `nearMissMetres` and opened again without a pinch.
    public var nearMissMetres = 0.028
    public private(set) var nearMisses = 0

    public init() {}

    /// Feeds one distance; returns the state.
    public mutating func update(_ d: Double, time: Double) -> Bool {
        if state {
            closest = min(closest, d)
            if d > off {
                let since = overSince ?? time
                overSince = since
                if time - since >= releaseSeconds { state = false; overSince = nil }
            } else {
                overSince = nil
            }
            return state
        }
        if d < on {
            state = true
            overSince = nil
            closest = d
            dipping = false
            return true
        }
        if d < nearMissMetres { dipping = true } else if dipping, d > off { dipping = false; nearMisses += 1 }
        return false
    }

    /// The closest the fingers came during the pinch that just ended (and forgets it).
    public mutating func takeClosest() -> Double? {
        defer { closest = .infinity }
        return closest.isFinite ? closest : nil
    }

    public mutating func reset() { state = false; overSince = nil; dipping = false }
}

/// A pinch began or ended, with what the eyes were doing: times only, never where they looked.
public struct XRPinchEvent: Sendable, Equatable {
    public enum Gaze: Equatable, Sendable {
        case noGaze
        case heldThroughDropout(milliseconds: Int)
        case fixating(milliseconds: Int)
        /// The ray went back to the fixation before a saccade this many ms ago.
        case rewound(milliseconds: Int)
    }
    public var began: Bool
    public var hand: Int
    public var time: Double
    public var gaze: Gaze
    /// A release: how long the pinch lasted, the closest the fingers came (cm).
    public var duration: Double?
    public var closestCentimetres: Double?

    public var description: String {
        var text = "pinch \(began ? "begin" : "end") \(hand == 0 ? "left" : "right")"
        switch gaze {
        case .noGaze: text += ", no gaze"
        case .heldThroughDropout(let ms): text += ", gaze held through a dropout of \(ms) ms"
        case .fixating(let ms): text += ", fixating for \(ms) ms"
        case .rewound(let ms): text += ", rewound past a saccade \(ms) ms ago"
        }
        if let duration { text += String(format: ", lasted %.0f ms", duration * 1000) }
        if let closestCentimetres { text += String(format: ", fingers came to %.1f cm", closestCentimetres) }
        return text
    }
}

// MARK: - The tracker's constant error

/// A few fixed targets, head-locked: the wearer looks at each for a moment. The
/// median of (target − gaze) over the targets is the bias. Eye trackers are
/// calibrated per wearer and keep a constant angular error, and a target of
/// about 1–2.5° is missed by one of that size however steady the ray is.
public struct XRGazeCalibration: Sendable {
    /// The targets' directions in head space, degrees (yaw left positive, pitch up positive).
    public static let targets: [(yaw: Double, pitch: Double)] = [(0, 0), (10, 8), (-10, 8), (10, -8), (-10, -8)]
    /// A sample counts for a target within this much of it; a target needs this long of a steady gaze.
    public var acceptDegrees = 6.0, dwellSeconds = 0.7, targetSeconds = 4.0, spreadDegrees = 0.6
    /// How long the eyes get to move to a new target before samples count.
    public var settleSeconds = 0.25
    public private(set) var index = 0
    public private(set) var finished = false
    private var samples: [(yaw: Double, pitch: Double)] = []
    private var targetStart: Double?
    private var dwellStart: Double?
    private var offsets: [(yaw: Double, pitch: Double)] = []

    public init() {}

    /// The current target (nil: finished).
    public var target: (yaw: Double, pitch: Double)? { finished ? nil : Self.targets[index] }

    /// Feeds the gaze in head space (nil: a dropout).
    public mutating func update(_ local: SpatialVector?, time: Double) {
        guard !finished else { return }
        let start = targetStart ?? time
        targetStart = start
        if time - start >= targetSeconds { advance(); return }
        guard time - start >= settleSeconds, let local else { return }
        let (y, p) = xrYawPitch(local)
        let g = (yaw: y * 180 / .pi, pitch: p * 180 / .pi)
        let t = Self.targets[index]
        guard abs(g.yaw - t.yaw) < acceptDegrees, abs(g.pitch - t.pitch) < acceptDegrees else {
            samples.removeAll(); dwellStart = nil; return
        }
        samples.append(g)
        let dwell = dwellStart ?? time
        dwellStart = dwell
        guard time - dwell >= dwellSeconds else { return }
        let my = Self.median(samples.map(\.yaw)), mp = Self.median(samples.map(\.pitch))
        let spread = (samples.map { ($0.yaw - my) * ($0.yaw - my) + ($0.pitch - mp) * ($0.pitch - mp) }.reduce(0, +) / Double(samples.count)).squareRoot()
        if spread <= spreadDegrees {
            offsets.append((t.yaw - my, t.pitch - mp))
            advance()
        } else {
            samples.removeFirst(samples.count / 2)
            dwellStart = time
        }
    }

    private mutating func advance() {
        samples.removeAll()
        dwellStart = nil
        targetStart = nil
        index += 1
        if index >= Self.targets.count { finished = true }
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    /// The bias (degrees) and how far the targets disagree with it, when
    /// enough targets answered; the viewer logs only the two magnitudes.
    public var result: (yaw: Double, pitch: Double, targets: Int, spread: Double)? {
        guard offsets.count >= 3 else { return nil }
        let y = Self.median(offsets.map(\.yaw)), p = Self.median(offsets.map(\.pitch))
        let spread = (offsets.map { ($0.yaw - y) * ($0.yaw - y) + ($0.pitch - p) * ($0.pitch - p) }.reduce(0, +) / Double(offsets.count)).squareRoot()
        return (y, p, offsets.count, spread)
    }
}

// MARK: - The reticle (`--gaze-dot`)

public enum XRGazeReticle {
    public enum State: Int, Sendable, CaseIterable { case tracking, held, frozen, calibrating }

    /// The quad's pose and size for the ray sent (XR base space), at `distance`
    /// metres along it, facing the eye, covering `degrees` of the wearer's view.
    public static func pose(origin: SpatialVector, direction: SpatialVector, distance: Double, eye: SpatialVector, degrees: Double = 1.4) -> (pose: SpatialPose, size: Double) {
        let at = origin + direction.normalized * distance
        let toEye = eye - at
        let rotation = facingZ(toEye)
        return (SpatialPose(position: at, rotation: rotation), 2 * toEye.length * tan(degrees / 2 * .pi / 180))
    }

    /// The rotation that turns a quad's +Z towards `d`.
    public static func facingZ(_ d: SpatialVector) -> SpatialQuaternion {
        let z = SpatialVector(0, 0, 1)
        let n = d.normalized
        let c = z.dot(n)
        if c > 0.999999 { return .identity }
        if c < -0.999999 { return SpatialQuaternion(axis: SpatialVector(0, 1, 0), radians: .pi) }
        return SpatialQuaternion(axis: z.cross(n).normalized, radians: acos(max(-1, min(1, c))))
    }

    /// A ring with a small dot at its centre (BGRA, unpremultiplied): open, so
    /// what it sits on stays visible.
    public static func image(state: State, size n: Int = 64) -> [UInt8] {
        let (b, g, r): (UInt8, UInt8, UInt8)
        switch state {
        case .tracking: (b, g, r) = (255, 230, 60)      // cyan
        case .held: (b, g, r) = (40, 150, 255)          // orange: the eyes are lost, the last ray is held
        case .frozen: (b, g, r) = (90, 240, 90)         // green: a pinch holds the ray
        case .calibrating: (b, g, r) = (255, 255, 255)  // white: a calibration target
        }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let c = Double(n - 1) / 2
        for y in 0..<n {
            for x in 0..<n {
                let d = ((Double(x) - c) * (Double(x) - c) + (Double(y) - c) * (Double(y) - c)).squareRoot() / c
                // The ring between 0.72 and 0.95, the dot under 0.12; soft edges of about a pixel.
                let edge = 2.0 / Double(n)
                func band(_ lo: Double, _ hi: Double) -> Double { min(1, max(0, min(d - lo, hi - d) / edge + 0.5)) }
                let a = max(band(0.72, 0.95), band(-1, 0.12))
                let o = (y * n + x) * 4
                (px[o], px[o + 1], px[o + 2], px[o + 3]) = (b, g, r, UInt8(255 * a))
            }
        }
        return px
    }

    /// How far along a ray it first meets a depth image (metres), by marching in
    /// inverse depth. `surface(point)` answers the distance of the stored surface
    /// along the camera's axis at a stage point's place, and that point's own distance.
    public static func distance(origin: SpatialVector, direction: SpatialVector, near: Double = 0.3, far: Double = 12, steps: Int = 32,
                                surface: (SpatialVector) -> (surface: Double, point: Double)?) -> Double? {
        let d = direction.normalized
        var previous = near
        for i in 0...steps {
            let inverse = 1 / near + (1 / far - 1 / near) * Double(i) / Double(steps)
            let t = 1 / inverse
            if let s = surface(origin + d * t), s.point >= s.surface {
                // Between the last step and this one: halve it down to a few centimetres.
                var (lo, hi) = (previous, t)
                for _ in 0..<6 {
                    let mid = (lo + hi) / 2
                    if let m = surface(origin + d * mid), m.point >= m.surface { hi = mid } else { lo = mid }
                }
                return (lo + hi) / 2
            }
            previous = t
        }
        return nil
    }
}

// MARK: - Flow control (display-stream.md §4.2)

/// The server's side of `frameWindow`: a new picture is taken only while fewer
/// than `window` frames are unacknowledged, so a slow viewer gets the newest
/// picture when it has room, and no queue forms anywhere between the two. A
/// lost acknowledgement cannot stop the stream: after `timeout` one more goes.
public struct XRFrameWindow: Sendable, Equatable {
    public var window: UInt64
    public var timeoutNanoseconds: UInt64 = 300_000_000
    public private(set) var sent: UInt64 = 0, acknowledged: UInt64 = 0
    private var lastProgress: UInt64 = 0
    /// Scans held back and timeouts taken (the server's log).
    public private(set) var held = 0, timeouts = 0
    private var holding = false

    public init(window: Int?) { self.window = UInt64(max(0, window ?? 0)) }

    public func isOpen(at now: UInt64) -> Bool {
        window == 0 || sent &- acknowledged < window || now &- lastProgress >= timeoutNanoseconds
    }

    /// Whether a new picture may be taken now (counts the times it may not).
    public mutating func open(at now: UInt64) -> Bool {
        if window == 0 || sent &- acknowledged < window { holding = false; return true }
        if now &- lastProgress >= timeoutNanoseconds { timeouts += 1; holding = false; return true }
        if !holding { held += 1; holding = true }
        return false
    }

    public mutating func didSend(sequence: UInt64, at now: UInt64) { sent = sequence; lastProgress = now }

    public mutating func ack(sequence: UInt64, at now: UInt64) {
        guard sequence > acknowledged else { return }
        acknowledged = min(sequence, sent == 0 ? sequence : sent)
        lastProgress = now
    }
}
