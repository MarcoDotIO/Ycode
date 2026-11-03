// What the wearer sees of the gaze path (specs/simulator/xr-viewer.md §13.4): the
// reticle `--gaze-dot` draws at the point the viewer sends to the guest, and the
// targets of `--gaze-calibrate`. Each is one quad layer over the picture, drawn
// by the runtime, never sent to the guest and never in a recording.

import Foundation
import YcodeDisplayStream

final class XRGazeOverlay {
    static let reticleSlot = 12, targetSlot = 13
    /// Where the dot goes when the ray meets nothing known (metres).
    static let defaultDistance = 1.5
    let showDot: Bool
    private var uploaded: XRGazeReticle.State?
    private var targetUploaded = false
    private var distance = XRGazeOverlay.defaultDistance
    private(set) var calibration: XRGazeCalibration?
    private var calibrationDue: Double?
    private let log: (String) -> Void

    init(showDot: Bool, calibrate: Bool, log: @escaping (String) -> Void) {
        self.showDot = showDot
        self.log = log
        if calibrate { calibration = XRGazeCalibration() }
    }

    /// The sprites for this frame (between begin and end). `surface` answers how far along the ray the guest's picture is.
    func sprites(session: XRSession, mapper: inout XRInputMapper, sample s: XRTrackingSample, out: XRInputOutput, anchor: XRStageAnchor, waiting: Bool,
                 surface: (SpatialVector, SpatialVector) -> Double?) -> [XRHandSprite] {
        var list: [XRHandSprite] = []
        // A calibration: after the sweep, once the eyes are tracked.
        if var c = calibration, !c.finished, !waiting, s.gaze != nil || calibrationDue != nil {
            let due = calibrationDue ?? s.time + 1
            calibrationDue = due
            if s.time >= due {
                if !targetUploaded {
                    let image = XRGazeReticle.image(state: .calibrating, size: 64)
                    targetUploaded = (try? image.withUnsafeBytes { try session.upload(eye: Self.targetSlot, pixels: $0.baseAddress!, width: 64, height: 64, bytesPerRow: 256) }) != nil
                }
                c.update(mapper.headSpaceGaze(s), time: s.time)
                if c.finished {
                    if let r = c.result {
                        var g = mapper.gazeSettings
                        g.biasYaw = r.yaw * .pi / 180
                        g.biasPitch = r.pitch * .pi / 180
                        mapper.gazeSettings = g
                        // Magnitudes only (§8).
                        log(String(format: "ycode-xr-viewer: gaze calibration: %d of %d targets, the tracker's constant error %.1f°, the targets disagree by %.1f° RMS",
                                   r.targets, XRGazeCalibration.targets.count, (r.yaw * r.yaw + r.pitch * r.pitch).squareRoot(), r.spread))
                    } else {
                        log("ycode-xr-viewer: gaze calibration: too few targets answered, no correction")
                    }
                } else if let t = c.target, targetUploaded {
                    let d = s.head.rotation.rotate(SpatialQuaternion(yaw: t.yaw * .pi / 180, pitch: t.pitch * .pi / 180).rotate(SpatialVector(0, 0, -1)))
                    let q = XRGazeReticle.pose(origin: s.head.position, direction: d, distance: 1.5, eye: s.head.position, degrees: 1.6)
                    list.append(XRHandSprite(pose: q.pose, size: q.size, highlight: false, image: Self.targetSlot))
                }
            }
            calibration = c
        }
        guard showDot else { return list }
        let state: XRGazeReticle.State = mapper.rayFrozen ? .frozen : mapper.gazeHeld ? .held : .tracking
        if uploaded != state {
            let image = XRGazeReticle.image(state: state, size: 64)
            if (try? image.withUnsafeBytes { try session.upload(eye: Self.reticleSlot, pixels: $0.baseAddress!, width: 64, height: 64, bytesPerRow: 256) }) != nil { uploaded = state }
        }
        guard uploaded != nil else { return list }
        // The ray the guest got, in the base space, at the surface it meets: both eyes then see the dot on what it selects.
        let origin = anchor.fromStage(point: out.selection.rayOrigin), direction = anchor.fromStage(direction: out.selection.rayDirection)
        let target = surface(origin, direction) ?? Self.defaultDistance
        distance += (target - distance) * 0.25
        let q = XRGazeReticle.pose(origin: origin, direction: direction, distance: distance, eye: s.head.position)
        list.append(XRHandSprite(pose: q.pose, size: q.size, highlight: false, image: Self.reticleSlot))
        return list
    }
}
