// The gaze path with synthetic gaze of a recorded shape (no real eye data):
// fixations with the tracker's noise (0.30° RMS from frame to frame, as run 8
// measured it), saccades of the main sequence at 1.6–1.9 per second (run 8),
// blinks, a head that sways with the vestibulo-ocular reflex holding the eye
// on its target. Specs: xr-viewer.md §13.

import Foundation
import Testing
@testable import YcodeDisplayStream

/// A small deterministic generator (SplitMix64).
struct GazeRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u = max(1e-12, uniform()), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

func direction(yaw: Double, pitch: Double) -> SpatialVector {
    SpatialQuaternion(yaw: yaw * .pi / 180, pitch: pitch * .pi / 180).rotate(SpatialVector(0, 0, -1))
}

/// A wearer: one target (yaw, pitch in the world, degrees) at a time, the eye
/// arriving by a saccade of the main sequence (about 21 ms + 2.2 ms per degree).
struct SyntheticWearer {
    static let dt = 1.0 / 90
    var random: GazeRandom
    /// Per axis: 0.15° gives 0.30° RMS from frame to frame in two dimensions.
    var noise = 0.15
    /// The head's sway about yaw (degrees, Hz); the reflex keeps the eye on the target in the world.
    var swayDegrees = 0.0, swayHz = 0.3
    /// The tracker's constant error in head space (degrees).
    var biasYaw = 0.0, biasPitch = 0.0
    private(set) var eye = (yaw: 0.0, pitch: 0.0)
    private var from = (yaw: 0.0, pitch: 0.0), to = (yaw: 0.0, pitch: 0.0)
    private var saccadeStart = -1.0, saccadeLength = 0.0

    init(seed: UInt64) { random = GazeRandom(seed: seed) }

    mutating func look(at target: (yaw: Double, pitch: Double), time: Double) {
        from = eye
        to = target
        let amplitude = hypot(to.yaw - from.yaw, to.pitch - from.pitch)
        saccadeStart = time
        saccadeLength = 0.021 + 0.0022 * amplitude
    }

    func head(at time: Double) -> SpatialPose {
        SpatialPose(position: SpatialVector(0, 1.6, 0), rotation: SpatialQuaternion(yaw: swayDegrees * sin(2 * .pi * swayHz * time) * .pi / 180, pitch: 0))
    }

    /// The tracker's sample at `time` (the true eye, then bias and noise).
    mutating func sample(at time: Double) -> XRTrackingSample {
        if saccadeStart >= 0 {
            let u = min(1, (time - saccadeStart) / saccadeLength)
            let s = u * u * (3 - 2 * u)
            eye = (from.yaw + (to.yaw - from.yaw) * s, from.pitch + (to.pitch - from.pitch) * s)
            if u >= 1 { saccadeStart = -1 }
        }
        let h = head(at: time)
        var local = h.rotation.conjugate.rotate(direction(yaw: eye.yaw, pitch: eye.pitch))
        let (y, p) = xrYawPitch(local)
        local = direction(yaw: y * 180 / .pi + biasYaw + noise * random.gaussian(), pitch: p * 180 / .pi + biasPitch + noise * random.gaussian())
        let (wy, wp) = xrYawPitch(h.rotation.rotate(local))
        return XRTrackingSample(time: time, head: h, gaze: SpatialPose(position: h.position, rotation: SpatialQuaternion(yaw: wy, pitch: wp).normalized))
    }

    /// The true direction of the eye now, world frame.
    var trueDirection: SpatialVector { direction(yaw: eye.yaw, pitch: eye.pitch) }
}

/// A session of `seconds`: saccades among places on the windows at a rate like run 8's.
func wanderingSession(seconds: Double, settings: XRGazeSettings, sway: Double = 0, seed: UInt64 = 7) -> (stats: XRGazeStats, errors: (fixating: Double, after100ms: Double)) {
    var wearer = SyntheticWearer(seed: seed)
    wearer.swayDegrees = sway
    var mapper = XRInputMapper()
    mapper.gazeSettings = settings
    var next = 0.3, sumA = 0.0, nA = 0, sumB = 0.0, nB = 0, last = 0.0
    var t = 0.0
    while t < seconds {
        if t >= next {
            let a = 3 + 12 * wearer.random.uniform(), angle = 2 * .pi * wearer.random.uniform()
            wearer.look(at: (wearer.eye.yaw * 0.3 + a * cos(angle), wearer.eye.pitch * 0.3 + a * sin(angle) * 0.6), time: t)
            last = t
            next = t + 0.25 + 0.55 * wearer.random.uniform()
        }
        let out = mapper.map(wearer.sample(at: t))
        let e = xrAngleDegrees(out.selection.rayDirection, mapper.anchor!.toStage(direction: wearer.trueDirection))
        if t - last >= 0.1 { sumA += e * e; nA += 1 }
        if t - last >= 0.1, t - last < 0.3 { sumB += e * e; nB += 1 }
        t += SyntheticWearer.dt
    }
    return (mapper.gazeStats, ((sumA / Double(max(1, nA))).squareRoot(), (sumB / Double(max(1, nB))).squareRoot()))
}

@Suite struct XRGazeLagTests {
    static var legacy: XRGazeSettings {
        var s = XRGazeSettings()
        s.filter = .oneEuro
        s.pinchRewindSeconds = 0
        s.freezeDuringPinch = false
        return s
    }

    /// Run 8's "filter removed 1.5–1.9°" comes out of the old filter on synthetic gaze of the same
    /// noise and saccade rate. It is the first 100 ms after each saccade (3.8° RMS), not a lasting offset.
    @Test func theOldFilterRemovesWhatRun8MeasuredInTheFirstMoments() {
        let (stats, errors) = wanderingSession(seconds: 120, settings: Self.legacy)
        #expect(abs(stats.rawJitterDegrees - 0.32) < 0.05)
        #expect(stats.filteredResidualDegrees > 1.1 && stats.filteredResidualDegrees < 1.9)
        #expect(stats.lagDegrees(0) > 3)
        #expect(errors.after100ms < 0.8)
    }

    @Test func theFixationFilterKeepsTheRayOnTheEye() {
        let (stats, errors) = wanderingSession(seconds: 120, settings: XRGazeSettings())
        #expect(stats.filteredResidualDegrees < 0.45)
        #expect(stats.lagDegrees(0) < 0.5)
        #expect(errors.fixating < 0.15)
        #expect(errors.after100ms < 0.15)
    }

    /// On one fixation the ray is steadier than the samples: under a third of the tracker's step.
    @Test func aFixationIsSteady() {
        var wearer = SyntheticWearer(seed: 13)
        var mapper = XRInputMapper()
        var t = 0.0
        while t < 20 { _ = mapper.map(wearer.sample(at: t)); t += SyntheticWearer.dt }
        #expect(mapper.gazeStats.rawJitterDegrees > 0.28)
        #expect(mapper.gazeStats.rayJitterDegrees < 0.08)
        #expect(mapper.gazeStats.saccades == 0)
    }

    /// The old filter crosses what lies between: each 3° cell it passes could be a hover the guest draws.
    @Test func theRayDoesNotTravelAcrossWhatLiesBetween() {
        let (old, _) = wanderingSession(seconds: 120, settings: Self.legacy)
        let (new, _) = wanderingSession(seconds: 120, settings: XRGazeSettings())
        #expect(new.cellChanges * 3 < old.cellChanges * 2)
    }

    /// A 10° saccade: how long until the ray is within 1° of the eye.
    func settle(_ settings: XRGazeSettings) -> Double {
        var wearer = SyntheticWearer(seed: 3)
        wearer.noise = 0
        var mapper = XRInputMapper()
        mapper.gazeSettings = settings
        var t = 0.0
        while t < 1 { _ = mapper.map(wearer.sample(at: t)); t += SyntheticWearer.dt }
        wearer.look(at: (10, 0), time: t)
        let start = t
        var within: Double?
        while t < 3 {
            let out = mapper.map(wearer.sample(at: t))
            let e = xrAngleDegrees(out.selection.rayDirection, mapper.anchor!.toStage(direction: direction(yaw: 10, pitch: 0)))
            if e < 1 { if within == nil { within = t - start } } else { within = nil }
            t += SyntheticWearer.dt
        }
        return within ?? 99
    }

    @Test func aSaccadeLandsWithinAFrameOrTwoOfTheEye() {
        let old = settle(Self.legacy), new = settle(XRGazeSettings())
        // The saccade itself takes 43 ms; the old filter arrives about 80 ms after it.
        #expect(old > 0.1)
        #expect(new < 0.043 + 3 * SyntheticWearer.dt)
    }

    /// The head moves, the eye holds its target: the reflex turns the eye in the
    /// head, and a filter in head space lags it, dragging the ray off in the world.
    @Test func aSwayingHeadDoesNotDragTheRay() {
        func error(_ settings: XRGazeSettings) -> Double {
            var wearer = SyntheticWearer(seed: 11)
            wearer.swayDegrees = 6       // ±6° at 0.3 Hz: up to 11°/s
            var mapper = XRInputMapper()
            mapper.gazeSettings = settings
            var sum = 0.0, n = 0
            var t = 0.0
            while t < 30 {
                let out = mapper.map(wearer.sample(at: t))
                let e = xrAngleDegrees(out.selection.rayDirection, mapper.anchor!.toStage(direction: wearer.trueDirection))
                if t > 1 { sum += e * e; n += 1 }
                t += SyntheticWearer.dt
            }
            return (sum / Double(n)).squareRoot()
        }
        #expect(error(Self.legacy) > 0.5)
        #expect(error(XRGazeSettings()) < 0.2)
    }

    /// The eyes carried with the head (a head turn, eyes still in the head): no lag either.
    @Test func eyesThatTravelWithTheHeadAreNotLeftBehind() {
        var mapper = XRInputMapper()
        var random = GazeRandom(seed: 5)
        var worst = 0.0
        var t = 0.0
        while t < 4 {
            let yaw = 40 * sin(2 * .pi * 0.25 * t)      // up to 63°/s
            let head = SpatialPose(position: SpatialVector(0, 1.6, 0), rotation: SpatialQuaternion(yaw: yaw * .pi / 180, pitch: 0))
            let local = direction(yaw: 3 + 0.15 * random.gaussian(), pitch: 0.15 * random.gaussian())
            let (y, p) = xrYawPitch(head.rotation.rotate(local))
            let out = mapper.map(XRTrackingSample(time: t, head: head, gaze: SpatialPose(position: head.position, rotation: SpatialQuaternion(yaw: y, pitch: p))))
            let truth = mapper.anchor!.toStage(direction: head.rotation.rotate(direction(yaw: 3, pitch: 0)))
            if t > 0.5 { worst = max(worst, xrAngleDegrees(out.selection.rayDirection, truth)) }
            t += SyntheticWearer.dt
        }
        #expect(worst < 0.7)
    }

    /// One outlying sample is not a saccade.
    @Test func oneOutlierDoesNotMoveTheRay() {
        var f = XRGazeFilter()
        let head = SpatialQuaternion.identity
        var t = 0.0
        for _ in 0..<30 { _ = f.update(direction(yaw: 0, pitch: 0), head: head, time: t); t += SyntheticWearer.dt }
        let out = f.update(direction(yaw: 15, pitch: 0), head: head, time: t)
        #expect(xrAngleDegrees(out, direction(yaw: 0, pitch: 0)) < 0.01)
        t += SyntheticWearer.dt
        let back = f.update(direction(yaw: 0, pitch: 0), head: head, time: t)
        #expect(xrAngleDegrees(back, direction(yaw: 0, pitch: 0)) < 0.01)
        #expect(f.lastSaccadeAt == nil)
    }

    /// At a target's edge the ray does not flicker across it.
    @Test func theRayDoesNotChatterAtATargetsEdge() {
        func crossings(_ settings: XRGazeSettings) -> Int {
            var wearer = SyntheticWearer(seed: 9)
            var mapper = XRInputMapper()
            mapper.gazeSettings = settings
            wearer.look(at: (0.5, 0), time: 0)
            var inside: Bool?, n = 0
            var t = 0.0
            while t < 30 {
                let out = mapper.map(wearer.sample(at: t))
                let (y, _) = xrYawPitch(out.selection.rayDirection)
                // The edge exactly where the eye looks, on the true side of the anchor's frame.
                let now = y * 180 / .pi > 0.5
                if let i = inside, i != now { n += 1 }
                inside = now
                t += SyntheticWearer.dt
            }
            return n
        }
        var raw = XRGazeSettings()
        raw.filter = .raw
        let (r, f) = (crossings(raw), crossings(XRGazeSettings()))
        #expect(r > 800)        // about one sample in two
        #expect(f * 10 < r)
    }
}

/// Targets on a window: a grid of squares; which one does a pinch select?
struct TargetGrid {
    /// The side of a target, degrees (60 pt at 2 m is about 1.3°, at 1 m 2.5°).
    var side: Double
    var spacing: Double
    func hit(_ d: SpatialVector) -> (Int, Int)? {
        let (y, p) = xrYawPitch(d)
        let (a, b) = (y * 180 / .pi / spacing, p * 180 / .pi / spacing)
        let (i, j) = (a.rounded(), b.rounded())
        guard abs(a - i) * spacing <= side / 2, abs(b - j) * spacing <= side / 2 else { return nil }
        return (Int(i), Int(j))
    }
}

func hand(gap: Double, at p: SpatialVector = SpatialVector(0.1, 1.3, -0.4)) -> XRHandJoints {
    var poses = [SpatialPose](repeating: SpatialPose(position: p), count: 26)
    poses[XRHandJoints.indexTip] = SpatialPose(position: p)
    poses[XRHandJoints.thumbTip] = SpatialPose(position: p + SpatialVector(gap, 0, 0))
    return XRHandJoints(poses: poses)
}

@Suite struct XRGazeSelectionTests {
    /// Trials: look at a target, pinch `delay` after the saccade began. The share that selects it.
    func selectionRate(_ settings: XRGazeSettings, side: Double, spacing: Double, delay: Double, sway: Double = 0, biasYaw: Double = 0, biasPitch: Double = 0, seed: UInt64 = 21) -> Double {
        let grid = TargetGrid(side: side, spacing: spacing)
        var wearer = SyntheticWearer(seed: seed)
        wearer.swayDegrees = sway
        wearer.biasYaw = biasYaw
        wearer.biasPitch = biasPitch
        var mapper = XRInputMapper()
        mapper.gazeSettings = settings
        var t = 0.0
        var good = 0, trials = 0
        func step(_ gap: Double) -> XRInputOutput {
            var s = wearer.sample(at: t)
            s.hands = [nil, hand(gap: gap)]
            let out = mapper.map(s)
            t += SyntheticWearer.dt
            return out
        }
        for _ in 0..<40 { _ = step(0.08) }
        for _ in 0..<200 {
            let i = Int((wearer.random.uniform() * 9).rounded()) - 4, j = Int((wearer.random.uniform() * 5).rounded()) - 2
            let target = (Double(i) * spacing, Double(j) * spacing)
            wearer.look(at: target, time: t)
            let begin = t
            while t - begin < delay { _ = step(0.08) }
            let out = step(0.01)        // the pinch
            trials += 1
            if let h = grid.hit(out.selection.rayDirection), h == (i, j) { good += 1 }
            for _ in 0..<9 { _ = step(0.01) }
            for _ in 0..<9 { _ = step(0.08) }
        }
        return Double(good) / Double(trials)
    }

    /// Small targets at a quick look: where the old filter's trip across costs a selection.
    @Test func aQuickLookSelectsTheTarget() {
        let old = selectionRate(XRGazeLagTests.legacy, side: 1.3, spacing: 2, delay: 0.15)
        let new = selectionRate(XRGazeSettings(), side: 1.3, spacing: 2, delay: 0.15)
        #expect(new > 0.97)
        #expect(new > old + 0.05)
    }

    /// With steady eyes and an unmoving tracker error both filters select 1.3° targets once the
    /// eyes have rested for 200 ms: the filter alone does not explain "hard to grab" (xr-viewer.md §13.3).
    @Test func aRestedLookSelectsWithEitherFilter() {
        #expect(selectionRate(XRGazeLagTests.legacy, side: 1.3, spacing: 2, delay: 0.25) > 0.97)
        #expect(selectionRate(XRGazeSettings(), side: 1.3, spacing: 2, delay: 0.25) > 0.97)
    }

    @Test func aSwayingHeadDoesNotCostTheTarget() {
        #expect(selectionRate(XRGazeSettings(), side: 1.3, spacing: 2, delay: 0.3, sway: 6) > 0.97)
    }

    /// The ray stays where the pinch began, however the eyes and the hand move.
    @Test func aPinchHoldsTheRayUntilTheRelease() {
        var wearer = SyntheticWearer(seed: 2)
        var mapper = XRInputMapper()
        var t = 0.0
        func step(_ gap: Double) -> XRInputOutput {
            var s = wearer.sample(at: t)
            s.hands = [nil, hand(gap: gap)]
            t += SyntheticWearer.dt
            return mapper.map(s)
        }
        for _ in 0..<60 { _ = step(0.08) }
        let begun = step(0.01)
        #expect(mapper.rayFrozen)
        wearer.look(at: (12, 3), time: t)
        var last = begun
        for _ in 0..<30 { last = step(0.01); #expect(last.selection.rayDirection == begun.selection.rayDirection) }
        // The release's own message still carries the pinch's place.
        _ = step(0.08)
        let released = step(0.08)
        #expect(mapper.rayFrozen)
        #expect(released.selection.right?.pinching == false)
        #expect(released.selection.rayDirection == begun.selection.rayDirection)
        // Then the ray is the eyes' again.
        let after = step(0.08)
        #expect(!mapper.rayFrozen)
        #expect(xrAngleDegrees(after.selection.rayDirection, mapper.anchor!.toStage(direction: direction(yaw: 12, pitch: 3))) < 1)
    }

    /// The eyes leave as the fingers close: the pinch takes what they were on.
    @Test func aPinchJustAfterASaccadeSelectsWhatTheEyesLeft() {
        func selected(rewind: Double) -> SpatialVector {
            var settings = XRGazeSettings()
            settings.pinchRewindSeconds = rewind
            var wearer = SyntheticWearer(seed: 4)
            wearer.noise = 0.05
            var mapper = XRInputMapper()
            mapper.gazeSettings = settings
            var t = 0.0
            func step(_ gap: Double) -> XRInputOutput {
                var s = wearer.sample(at: t)
                s.hands = [nil, hand(gap: gap)]
                t += SyntheticWearer.dt
                return mapper.map(s)
            }
            for _ in 0..<60 { _ = step(0.08) }
            wearer.look(at: (8, 0), time: t)    // the eyes move on (39 ms)
            for _ in 0..<5 { _ = step(0.08) }
            return step(0.01).selection.rayDirection
        }
        #expect(xrAngleDegrees(selected(rewind: 0.07), direction(yaw: 0, pitch: 0)) < 0.2)
        #expect(xrAngleDegrees(selected(rewind: 0), direction(yaw: 8, pitch: 0)) < 1)
    }

    /// A blink holds the last ray; it does not jump to the head's forward.
    @Test func aDropoutHoldsTheRay() {
        var wearer = SyntheticWearer(seed: 6)
        wearer.noise = 0
        var mapper = XRInputMapper()
        wearer.look(at: (10, 5), time: 0)
        var t = 0.0
        while t < 1 { _ = mapper.map(wearer.sample(at: t)); t += SyntheticWearer.dt }
        let target = direction(yaw: 10, pitch: 5)
        for _ in 0..<18 {       // 200 ms
            var s = wearer.sample(at: t)
            s.gaze = nil
            let out = mapper.map(s)
            #expect(xrAngleDegrees(out.selection.rayDirection, target) < 0.2)
            #expect(mapper.gazeHeld)
            t += SyntheticWearer.dt
        }
        // Long gone: the fallback (the head).
        for _ in 0..<40 {
            var s = wearer.sample(at: t)
            s.gaze = nil
            _ = mapper.map(s)
            t += SyntheticWearer.dt
        }
        #expect(!mapper.gazeHeld)
        var s = wearer.sample(at: t)
        s.gaze = nil
        do { let v = xrAngleDegrees(mapper.map(s).selection.rayDirection, SpatialVector(0, 0, -1)) < 0.1; #expect(v) }
        #expect(mapper.gazeStats.heldFrames >= 18)
    }

    /// A constant error of the tracker: what a calibration takes away.
    @Test func aCalibrationFindsTheTrackersBias() {
        var wearer = SyntheticWearer(seed: 8)
        wearer.biasYaw = 1.5
        wearer.biasPitch = -1
        var calibration = XRGazeCalibration()
        var t = 0.0
        wearer.look(at: (0, 0), time: 0)
        var at = -1
        while !calibration.finished && t < 40 {
            if calibration.index != at, let g = calibration.target {
                at = calibration.index
                wearer.look(at: (g.yaw, g.pitch), time: t)
            }
            let s = wearer.sample(at: t)
            calibration.update(s.gaze.map { s.head.rotation.conjugate.rotate($0.forward) }, time: t)
            t += SyntheticWearer.dt
        }
        let r = try! #require(calibration.result)
        #expect(r.targets == 5)
        #expect(abs(r.yaw + 1.5) < 0.15 && abs(r.pitch - 1) < 0.15)
        #expect(r.spread < 0.2)
        // With it, a 2° target at a look.
        var settings = XRGazeSettings()
        let plain = XRGazeSelectionTests().selectionRate(settings, side: 2, spacing: 3, delay: 0.4, biasYaw: 1.5, biasPitch: -1)
        settings.biasYaw = r.yaw * .pi / 180
        settings.biasPitch = r.pitch * .pi / 180
        let corrected = XRGazeSelectionTests().selectionRate(settings, side: 2, spacing: 3, delay: 0.4, biasYaw: 1.5, biasPitch: -1)
        #expect(plain < 0.2)
        #expect(corrected > 0.9)
    }

    /// A target the wearer does not look at, a gaze that wanders off: skipped, no bias.
    @Test func aCalibrationWithoutAFixationGivesNothing() {
        var calibration = XRGazeCalibration()
        var t = 0.0
        while !calibration.finished && t < 40 {
            calibration.update(direction(yaw: 25, pitch: 0), time: t)
            t += SyntheticWearer.dt
        }
        #expect(calibration.result == nil)
    }
}

@Suite struct XRPinchTests {
    func sample(_ t: Double, gap: Double?, at p: SpatialVector = SpatialVector(0.1, 1.3, -0.4)) -> XRTrackingSample {
        XRTrackingSample(time: t, head: SpatialPose(position: SpatialVector(0, 1.6, 0)), hands: [nil, gap.map { hand(gap: $0, at: p) }])
    }

    /// Fingers hiding each other: the tracker loses the hand for a few frames in mid-pinch.
    @Test func aLostHandDoesNotReleaseThePinch() {
        var m = XRInputMapper()
        var t = 0.0
        var states: [Bool] = []
        let script: [Double?] = [0.08, 0.01, 0.01, nil, nil, nil, nil, 0.01, 0.01, 0.08, 0.08, 0.08]
        for gap in script {
            states.append(m.map(sample(t, gap: gap)).selection.right!.pinching)
            t += 0.011
        }
        #expect(states == [false, true, true, true, true, true, true, true, true, true, true, false] || states == [false, true, true, true, true, true, true, true, true, true, false, false])
        #expect(m.pinchCount == 1)
        #expect(m.handHeldFrames == 4)
    }

    @Test func aHandLostForLongGoesToRest() {
        var m = XRInputMapper()
        var t = 0.0
        _ = m.map(sample(t, gap: 0.01))
        var out = m.map(sample(t + 0.011, gap: 0.01))
        #expect(out.selection.right!.pinching)
        for _ in 0..<30 { t += 0.011; out = m.map(sample(t + 0.011, gap: nil)) }
        #expect(!out.selection.right!.pinching)
        #expect(close(out.selection.right!.position, SpatialInteraction.rightRest, tolerance: 0.001))
    }

    /// Closing and opening the fingers moves their midpoint: a tap must not become a drag.
    @Test func fingersClosingAreNotADrag() {
        var m = XRInputMapper()
        var t = 0.0
        _ = m.map(sample(t, gap: 0.05))
        t += 0.011
        let begin = m.map(sample(t, gap: 0.019)).selection.right!
        #expect(begin.pinching)
        var last = begin
        for gap in [0.012, 0.008, 0.005, 0.008, 0.012, 0.02, 0.03] {
            t += 0.011
            last = m.map(sample(t, gap: gap)).selection.right!
            #expect(last.position == begin.position)
        }
        #expect(last.pinching)
        // A real move goes through, without a jump at the edge of the dead zone.
        t += 0.011
        let far = m.map(sample(t, gap: 0.01, at: SpatialVector(0.1 + 0.05, 1.3, -0.4))).selection.right!
        #expect(abs((far.position - begin.position).length - 0.05) < 0.02)
        #expect((far.position - begin.position).length < 0.05)
    }

    @Test func aBounceAtTheThresholdIsOnePinch() {
        var gate = XRPinchGate()
        let script: [(Double, Bool)] = [(0.015, true), (0.04, true), (0.02, true), (0.04, true), (0.04, false)]
        for (i, step) in script.enumerated() {
            let v = gate.update(step.0, time: Double(i) * 0.011)
            #expect(v == step.1)
        }
    }

    @Test func anAttemptThatStopsShortIsCounted() {
        var gate = XRPinchGate()
        for (i, d) in [0.06, 0.04, 0.025, 0.022, 0.03, 0.04, 0.06].enumerated() { let v = gate.update(d, time: Double(i) * 0.011); #expect(!v) }
        #expect(gate.nearMisses == 1)
    }

    /// The log's words carry times and states, never a direction.
    @Test func thePinchLogHasNoDirection() {
        var m = XRInputMapper()
        var wearer = SyntheticWearer(seed: 1)
        var t = 0.0
        for gap in [0.08, 0.08, 0.01, 0.01, 0.08, 0.08, 0.08, 0.08] {
            var s = wearer.sample(at: t)
            s.hands = [nil, hand(gap: gap)]
            _ = m.map(s)
            t += 0.011
        }
        let events = m.takePinchEvents()
        #expect(events.count == 2)
        #expect(events[0].began && events[0].description.contains("fixating"))
        #expect(!events[1].began && events[1].description.contains("lasted"))
        do { let v = m.takePinchEvents().isEmpty; #expect(v) }
    }

    func close(_ a: SpatialVector, _ restRelative: SpatialVector, tolerance: Double) -> Bool {
        (a - restRelative).length < tolerance
    }
}

@Suite struct XRFrameWindowTests {
    @Test func theWindowHoldsTheNewestPictureBack() {
        var w = XRFrameWindow(window: 3)
        do { let v = w.open(at: 0); #expect(v) }
        w.didSend(sequence: 1, at: 0)
        w.didSend(sequence: 2, at: 1)
        do { let v = w.open(at: 2); #expect(v) }
        w.didSend(sequence: 3, at: 2)
        do { let v = !w.open(at: 3); #expect(v) }
        do { let v = !w.open(at: 4); #expect(v) }
        #expect(w.held == 1)
        w.ack(sequence: 1, at: 5)
        do { let v = w.open(at: 6); #expect(v) }
    }

    @Test func noWindowNeverHolds() {
        var w = XRFrameWindow(window: nil)
        for i in 1...100 as ClosedRange<UInt64> { let v = w.open(at: i); #expect(v); w.didSend(sequence: i, at: i) }
    }

    /// A frame lost on UDP is covered by the next ack; a lost ack, by the timeout.
    @Test func lostAcksDoNotStopTheStream() {
        var w = XRFrameWindow(window: 2)
        w.didSend(sequence: 1, at: 0)
        w.didSend(sequence: 2, at: 0)
        do { let v = !w.open(at: 100_000_000); #expect(v) }
        do { let v = w.open(at: 300_000_000); #expect(v) }
        #expect(w.timeouts == 1)
        w.didSend(sequence: 3, at: 300_000_000)
        do { let v = !w.open(at: 400_000_000); #expect(v) }
        w.ack(sequence: 3, at: 400_000_000)
        #expect(w.acknowledged == 3)
        do { let v = w.open(at: 400_000_001); #expect(v) }
    }

    @Test func theAckRoundTrips() throws {
        var p = DisplayMessageParser()
        p.append(DisplayMessage.frameAck(sequence: 123_456_789_012).encoded())
        guard case .frameAck(let s)? = try p.next() else { Issue.record("no ack"); return }
        #expect(s == 123_456_789_012)
    }
}

@Suite struct XRGapTests {
    func pose(_ yaw: Double) -> SpatialPose { SpatialPose(position: .zero, rotation: SpatialQuaternion(yaw: yaw * .pi / 180, pitch: 0)) }
    let ms: UInt64 = 1_000_000

    /// Pictures at `first` and at `second`, frames between, the last picture's stages as given.
    func gap(presents: UInt64, cameraMoves: Bool = false, saccade: Bool = false, frameEvery: UInt64 = 11,
             received: UInt64 = 495, capture: UInt64 = 480, waited: UInt64 = 0, work: UInt64 = 0) -> XRGapRecorder.Gap? {
        var r = XRGapRecorder()
        r.frame(at: 0, tracked: true, head: pose(0))
        r.picture(.init(sequence: 1, guestFrame: 100, captureStart: 1, sendEnd: 2, received: 3, decoded: 4, uploaded: 5 * ms))
        var t: UInt64 = 5
        while t < 500 {
            t += frameEvery
            r.frame(at: t * ms, tracked: true, head: pose(0), waited: waited * ms, work: work * ms, cameraMoved: cameraMoves && t < 60, saccade: saccade && t < 60)
        }
        return r.picture(.init(sequence: 2, guestFrame: 100 + presents, captureStart: capture * ms, sendEnd: (capture + 1) * ms,
                               received: received * ms, decoded: (received + 2) * ms, uploaded: 500 * ms))
    }

    @Test func aShortStretchIsNoGap() {
        var r = XRGapRecorder()
        r.picture(.init(sequence: 1, guestFrame: 1, uploaded: 1))
        do { let v = r.picture(.init(sequence: 2, guestFrame: 2, uploaded: 200 * ms)) == nil; #expect(v) }
    }

    @Test func causes() {
        #expect(gap(presents: 30)?.cause == .idle)
        #expect(gap(presents: 30, saccade: true)?.cause == .idleGaze)
        #expect(gap(presents: 30, cameraMoves: true)?.cause == .guestNoPicture)
        // Asked only at the very end: a rest, and a quick answer.
        do {
            var r = XRGapRecorder()
            r.picture(.init(sequence: 1, guestFrame: 100, uploaded: 5 * ms))
            r.frame(at: 400 * ms, tracked: true, head: pose(0), cameraMoved: true)
            let g = r.picture(.init(sequence: 2, guestFrame: 130, uploaded: 500 * ms))
            #expect(g?.cause == .idle)
            #expect(g?.unanswered == 100)
            #expect(r.answers == [100])
        }
        #expect(gap(presents: 0, cameraMoves: true)?.cause == .guestStalled)
        // The picture was captured early and took the way here: the stream.
        #expect(gap(presents: 30, received: 480, capture: 100)?.cause == .stream)
        // Here long before it was uploaded.
        #expect(gap(presents: 30, received: 100, capture: 90)?.cause == .viewer)
        // The headset loop stopped for 300 ms, waiting for the runtime.
        #expect(gap(presents: 30, frameEvery: 300, waited: 280)?.cause == .runtime)
        #expect(gap(presents: 30, frameEvery: 300, waited: 5, work: 280)?.cause == .viewerLoop)
    }

    @Test func notTrackedIsNoGap() {
        var r = XRGapRecorder()
        r.picture(.init(sequence: 1, guestFrame: 1, uploaded: 1))
        r.frame(at: 100 * ms, tracked: false, head: nil)
        do { let v = r.picture(.init(sequence: 2, guestFrame: 50, uploaded: 900 * ms)) == nil; #expect(v) }
    }

    @Test func theSummaryNamesWhatHappened() {
        var r = XRGapRecorder()
        r.picture(.init(sequence: 1, guestFrame: 1, uploaded: 1))
        r.frame(at: 10 * ms, tracked: true, head: pose(0), cameraMoved: true, pictureHidden: true)
        r.frame(at: 20 * ms, tracked: true, head: pose(5), pictureHidden: true)
        let g = r.picture(.init(sequence: 2, guestFrame: 50, uploaded: 900 * ms))
        #expect(g?.cause == .guestNoPicture)
        #expect(abs(g!.headDegrees - 5) < 0.01)
        #expect(g!.hiddenMilliseconds == 10)
        #expect(r.summary.contains("guest-no-picture 1 "))
        #expect(r.summary.contains("under the cache"))
    }

    @Test func staleTrackingIsAStretchOfOldSamples() {
        var t = XRStaleTracking()
        for (age, at) in [(Int64(60_000_000), UInt64(0)), (300_000_000, 100 * ms), (400_000_000, 200 * ms)] {
            let ended = t.note(age: age, at: at)
            #expect(!ended)
        }
        let ended = t.note(age: 60_000_000, at: 900 * ms)
        #expect(ended && t.stretches == 1 && t.longest == 800)
        #expect(t.lastDescription.contains("800 ms"))
    }

    @Test func theServersLogSaysWhy() {
        var l = XRServerGapLog()
        do { let v = l.frameSent(at: 0, record: 10, load: { "1" }) == nil; #expect(v) }
        l.poseDelivered(at: 1 * ms)
        l.scanned(changed: false)
        let line = l.frameSent(at: 400 * ms, record: 34, load: { "2.5" })
        #expect(line?.contains("asked, and the guest's picture did not change") == true)
        #expect(line?.contains("load 2.5") == true)
        do { let v = l.frameSent(at: 500 * ms, record: 40, load: { "1" }) == nil; #expect(v) }
        do { let v = l.frameSent(at: 900 * ms, record: 40, load: { "1" })?.contains("presenter stopped") == true; #expect(v) }
        #expect(l.gaps == 2)
    }

    @Test func hoverBurstsInANewPlaceAreTargetChanges() {
        var h = XRHoverCounter()
        h.damage(x: 0.2, y: 0.2, width: 0.05, height: 0.05, at: 0)
        h.damage(x: 0.2, y: 0.2, width: 0.05, height: 0.05, at: 16 * ms)
        #expect(h.bursts == 1 && h.targetChanges == 0)
        h.damage(x: 0.4, y: 0.2, width: 0.05, height: 0.05, at: 300 * ms)
        #expect(h.bursts == 2 && h.targetChanges == 1)
        // The same place again: a new burst, not a new target. The whole picture: not a hover.
        h.damage(x: 0.4, y: 0.2, width: 0.05, height: 0.05, at: 600 * ms)
        h.damage(x: 0, y: 0, width: 1, height: 1, at: 900 * ms)
        #expect(h.bursts == 3 && h.targetChanges == 1)
    }
}

@Suite struct XRCameraBandTests {
    @Test func aPictureGoesOnTopOnceTheCameraHasRested() {
        let rule = XRFreshOnTopRule(afterNanoseconds: 350_000_000)
        #expect(!rule.isOnTop(now: 200_000_000, commandedAt: 0, oneView: true, sweeping: false))
        #expect(rule.isOnTop(now: 350_000_000, commandedAt: 0, oneView: true, sweeping: false))
        // Not in a sweep (a stop's picture must be final), not with eye pictures, not when turned off.
        #expect(!rule.isOnTop(now: 999_000_000, commandedAt: 0, oneView: true, sweeping: true))
        #expect(!rule.isOnTop(now: 999_000_000, commandedAt: 0, oneView: false, sweeping: false))
        #expect(!XRFreshOnTopRule(afterNanoseconds: 0).isOnTop(now: 999_000_000, commandedAt: 0, oneView: true, sweeping: false))
    }

    @Test func aSlowCameraIsSlow() {
        func speed(degreesPerSecond: Double, metresPerSecond: Double = 0) -> XRCameraSpeed {
            var c = XRCameraSpeed()
            var t = 0.0
            while t < 1 {
                c.update(SpatialPose(position: SpatialVector(metresPerSecond * t, 0, 0), rotation: SpatialQuaternion(yaw: degreesPerSecond * t * .pi / 180, pitch: 0)), time: t)
                t += 1.0 / 90
            }
            return c
        }
        #expect(abs(speed(degreesPerSecond: 5).degreesPerSecond - 5) < 0.1)
        #expect(speed(degreesPerSecond: 5).isSlow(limitDegrees: 8))
        #expect(!speed(degreesPerSecond: 30).isSlow(limitDegrees: 8))
        #expect(!speed(degreesPerSecond: 0, metresPerSecond: 0.2).isSlow(limitDegrees: 8))
        #expect(!speed(degreesPerSecond: 1).isSlow(limitDegrees: 0))
    }

    /// A head that sways by 2° and 1.5 cm: the camera stays with the wider band, and followed with run 8's.
    @Test func aSwayInsideTheBandMovesNoCamera() {
        func moves(degrees: Double, metres: Double) -> Int {
            var hold = XRCameraHold()
            hold.bandRadians = degrees * .pi / 180
            hold.bandMetres = metres
            var last: SpatialPose?, n = 0
            var t = 0.0
            while t < 20 {
                let head = SpatialPose(position: SpatialVector(0.015 * sin(2 * .pi * 0.3 * t), 0, 0), rotation: SpatialQuaternion(yaw: 2 * sin(2 * .pi * 0.2 * t) * .pi / 180, pitch: 0))
                let p = hold.apply(head, time: t)
                if let l = last, XRCameraHold.differs(l, p, metres: 0.0005, radians: 0.0009) { n += 1 }
                last = p
                t += 1.0 / 90
            }
            return n
        }
        #expect(moves(degrees: 3, metres: 0.02) == 0)
        #expect(moves(degrees: 1.5, metres: 0.015) > 0)
    }
}

@Suite struct XRReticleTests {
    @Test func theDotSitsOnTheRayAndFacesTheEye() {
        let eye = SpatialVector(0, 1.6, 0)
        let d = direction(yaw: 20, pitch: -10)
        let q = XRGazeReticle.pose(origin: eye, direction: d, distance: 2, eye: eye, degrees: 1.4)
        #expect((q.pose.position - (eye + d * 2)).length < 1e-9)
        // The quad's +Z towards the eye, 1.4° across at 2 m.
        let z = q.pose.rotation.rotate(SpatialVector(0, 0, 1))
        #expect(xrAngleDegrees(z, (eye - q.pose.position).normalized) < 1e-6)
        #expect(abs(q.size - 2 * 2 * tan(0.7 * .pi / 180)) < 1e-9)
    }

    @Test func theSentRayIsWhatTheDotShows() {
        // Through the mapper and back: the dot's place is the ray of the selection in the base space, a turned anchor included.
        var m = XRInputMapper()
        let head = SpatialPose(position: SpatialVector(1, 1.6, 2), rotation: SpatialQuaternion(yaw: 0.7, pitch: 0))
        let g = direction(yaw: 45, pitch: 5)
        let (y, p) = xrYawPitch(g)
        let out = m.map(XRTrackingSample(time: 0, head: head, gaze: SpatialPose(position: head.position, rotation: SpatialQuaternion(yaw: y, pitch: p))))
        let a = m.anchor!
        #expect(xrAngleDegrees(a.fromStage(direction: out.selection.rayDirection), g) < 1e-6)
        #expect((a.fromStage(point: out.selection.rayOrigin) - head.position).length < 1e-9)
    }

    @Test func eachStateHasItsColourAndTheRingIsOpen() {
        var colours = Set<[UInt8]>()
        for state in XRGazeReticle.State.allCases {
            let n = 64
            let px = XRGazeReticle.image(state: state, size: n)
            #expect(px.count == n * n * 4)
            func at(_ x: Int, _ y: Int) -> [UInt8] { Array(px[(y * n + x) * 4..<(y * n + x) * 4 + 4]) }
            #expect(at(n / 2, n / 2)[3] > 200)          // the dot
            #expect(at(n / 2 + 14, n / 2)[3] == 0)      // open between the dot and the ring
            #expect(at(n / 2 + 26, n / 2)[3] > 200)     // the ring
            #expect(at(0, 0)[3] == 0)
            colours.insert(Array(at(n / 2, n / 2)[0..<3]))
        }
        #expect(colours.count == XRGazeReticle.State.allCases.count)
    }

    @Test func theDotLandsOnTheSurface() {
        // A wall 2 m ahead of the camera, everywhere.
        let found = XRGazeReticle.distance(origin: .zero, direction: SpatialVector(0, 0, -1)) { p in (2, -p.z) }
        #expect(abs(found! - 2) < 0.02)
        #expect(XRGazeReticle.distance(origin: .zero, direction: SpatialVector(0, 0, -1)) { _ in nil } == nil)
    }
}
