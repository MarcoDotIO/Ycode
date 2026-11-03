// The display server's headset mode (specs/simulator/xr-viewer.md §4,
// display-stream.md §18): a viewer whose hello asks for `xr` sends the head
// and eye poses (0x8D, latest wins); the server gives the guest one camera
// pose per new picture — the left eye's, then the right eye's (alternate
// stereo), or the head's (mono) — and tags each picture it sends with the
// view and pose it was rendered for (0x0A, before the frame). Damage is kept
// per view, so a still scene costs little in either eye.
//
// The guest's presenter swaps at 60 Hz whether or not the render server
// gave it a new picture, so pictures are counted by content
// (`XRPictureSignature`), not by frame records.

import Foundation
import YcodeDisplayStream
import YcodeHypervisor

#if os(Linux) && arch(arm64)

final class DisplayXRState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduler: XREyeScheduler
    private var lastSignature: UInt64?
    /// The viewer's mirror of each view's image (damage per view), and with
    /// H.264 one encoder per view (each view its own stream of P-frames).
    var mirrors: [XRView: DisplayMirror] = [:]
    var videos: [XRView: VideoFrameEncoder] = [:]
    var videoFailed = false
    /// Foveated streaming (xr-viewer.md §4.5): the inset's share of each
    /// side (0: off), the newest gaze point (never logged), and what the
    /// last inset showed.
    let foveaFraction: Double
    /// The eyes' outward turn (degrees, §4.6); the tags carry it.
    let eyeYaw: Double
    private var foveaPoint: (u: Double, v: Double)?
    var lastInset: (u: Double, v: Double, time: UInt64, frame: UInt64)?
    var insetsSent = 0, insetBytes = 0, insetNs: UInt64 = 0

    func setFovea(u: Double, v: Double) {
        lock.withLock {
            // Eyes on the move: the wearer is looking at things; stay at the guest's full rate.
            if let p = foveaPoint, abs(p.u - u) > 0.02 || abs(p.v - v) > 0.02 { scheduler.noteInteraction(at: monotonicNanoseconds()) }
            foveaPoint = (u, v)
        }
    }

    /// A pinch (selection): stay mono until it is over.
    func noteInteraction() { lock.withLock { scheduler.noteInteraction(at: monotonicNanoseconds()) } }
    var fovea: (u: Double, v: Double)? { lock.withLock { foveaPoint } }
    /// Views whose next frame must be whole (a new mirror, a keyframe request).
    var needsFull: Set<XRView> = [.mono, .left, .right]
    let deliver: (_ viewPose: SpatialPose, _ devicePose: SpatialPose) -> Void
    private(set) var picturesSeen = 0, posesSent = 0, estimatedTags = 0, shownSettled = 0
    /// The newest views with their rotations (vhmdd's device pose).
    private var full: XRViews?

    /// Whether the rendered camera gets the pose's rotation. It does (the HID
    /// bundle's quaternion orientation, visionos.md §5.5.10);
    /// YCODE_XR_GUEST_ROTATION=0 drops it (the eye's position only, tagged
    /// so: a world-locked window ahead; a diagnostic for a guest that does
    /// not turn, xr-viewer.md §4.3).
    static let guestRotation = ProcessInfo.processInfo.environment["YCODE_XR_GUEST_ROTATION"] != "0"

    /// YCODE_XR_LATCH overrides the default latch depth (pictures; Ycode's
    /// measurement, xr-viewer.md §6).
    static let defaultLatch = ProcessInfo.processInfo.environment["YCODE_XR_LATCH"].flatMap(Int.init) ?? 1
    /// YCODE_XR_SETTLE_MS / YCODE_XR_SETTLE_MAX_MS: the least and the most
    /// time a pose has before its picture is taken (alternate stereo, §6).
    static let defaultSettle = ProcessInfo.processInfo.environment["YCODE_XR_SETTLE_MS"].flatMap(Int.init)
    static let defaultSettleMax = ProcessInfo.processInfo.environment["YCODE_XR_SETTLE_MAX_MS"].flatMap(Int.init)
    /// YCODE_XR_RENDER_DELAY_MS: a mono picture shows the pose sent this long before it (§6).
    static let renderDelay = ProcessInfo.processInfo.environment["YCODE_XR_RENDER_DELAY_MS"].flatMap(Int.init)

    init(request: XRClientRequest, deliver: @escaping (_ viewPose: SpatialPose, _ devicePose: SpatialPose) -> Void) {
        let mode = XREyeScheduler.Mode(rawValue: request.stereo) ?? .adaptive
        let settle = (request.settleMs ?? Self.defaultSettle).map { UInt64(min(2000, max(0, $0))) * 1_000_000 }
        scheduler = XREyeScheduler(mode: mode, latch: min(8, max(1, request.latch ?? Self.defaultLatch)), settleTime: settle,
                                   maxSettleTime: Self.defaultSettleMax.map { UInt64(min(4000, max(0, $0))) * 1_000_000 },
                                   renderDelay: Self.renderDelay.map { UInt64(min(2000, max(0, $0))) * 1_000_000 })
        self.deliver = deliver
        foveaFraction = min(0.9, max(0, request.foveaFraction ?? 0))
        eyeYaw = min(20, max(-20, request.eyeYawDegrees ?? 0))
    }

    var mode: XREyeScheduler.Mode { lock.withLock { scheduler.mode } }
    var latch: Int { lock.withLock { scheduler.latch } }
    var settleMilliseconds: UInt64 { lock.withLock { scheduler.effectiveSettle.least / 1_000_000 } }

    /// The rendered camera's pose for an eye or head pose (rotation dropped
    /// unless the guest turns with it).
    static func renderedPose(_ p: SpatialPose) -> SpatialPose {
        guestRotation ? p : SpatialPose(position: p.position, rotation: .identity)
    }

    /// The viewer's newest views (receive thread). The scheduler keeps the
    /// rendered camera's poses (they are the tags); vhmdd gets the full pose.
    func update(_ v0: XRViews) {
        let v = v0.canted(degrees: eyeYaw)
        var r = v
        (r.head, r.left, r.right) = (Self.renderedPose(v.head), Self.renderedPose(v.left), Self.renderedPose(v.right))
        let send = lock.withLock { () -> (XREyeScheduler.Send, SpatialPose)? in
            full = v
            scheduler.update(r, at: monotonicNanoseconds())
            // The first views start the cycle at once.
            if posesSent == 0, let s = scheduler.idle(at: monotonicNanoseconds()) { posesSent += 1; return (s, device(s)) }
            return nil
        }
        if let (s, head) = send { deliver(s.pose, head) }
    }

    /// Between pictures (send loop): a pose to send now, if any.
    func idle() {
        let send = lock.withLock { () -> (XREyeScheduler.Send, SpatialPose)? in
            guard let s = scheduler.idle(at: monotonicNanoseconds()) else { return nil }
            posesSent += 1
            return (s, device(s))
        }
        if let (s, head) = send { deliver(s.pose, head) }
    }

    /// A captured surface. Mono: nil when it shows the same picture as the
    /// last one (a re-presented frame), else its tag (nil: before the first
    /// pose reached a picture) and whether the tag is an estimate; the next
    /// pose goes out. Alternate: the change is noted and nil returned (the
    /// picture is taken by `due`).
    func picture(signature: UInt64) -> (tag: XREyeScheduler.Send?, estimated: Bool)? {
        let r = lock.withLock { () -> (XREyeScheduler.Send?, Bool, (XREyeScheduler.Send, SpatialPose)?)? in
            if signature == lastSignature { return nil }
            lastSignature = signature
            picturesSeen += 1
            let r = scheduler.picture(at: monotonicNanoseconds())
            var send: (XREyeScheduler.Send, SpatialPose)?
            if let s = r.send { posesSent += 1; send = (s, device(s)) }
            guard r.show else { return nil }
            if r.estimated && r.tag != nil { estimatedTags += 1 }
            return (r.tag, r.estimated, send)
        }
        guard let r else { return nil }
        if let (s, head) = r.2 { deliver(s.pose, head) }
        return (r.0, r.1)
    }

    /// Alternate: the eye whose picture has settled (the picture on screen
    /// now shows it) — and the other eye's pose goes out.
    func due() -> (tag: XREyeScheduler.Send?, estimated: Bool)? {
        let r = lock.withLock { () -> (XREyeScheduler.Send, Bool, (XREyeScheduler.Send, SpatialPose)?)? in
            guard let d = scheduler.due(at: monotonicNanoseconds()) else { return nil }
            shownSettled += 1
            if d.estimated { estimatedTags += 1 }
            var send: (XREyeScheduler.Send, SpatialPose)?
            if let s = d.send { posesSent += 1; send = (s, device(s)) }
            return (d.tag, d.estimated, send)
        }
        guard let r else { return nil }
        if let (s, head) = r.2 { deliver(s.pose, head) }
        return (r.0, r.1)
    }

    /// vhmdd's device pose for a send (under the lock): the same eye with its
    /// rotation (visionos.md §5.6.5: the device pose and the rendered camera
    /// move together; ARKit's anchor keeps the head's turn).
    private func device(_ s: XREyeScheduler.Send) -> SpatialPose {
        guard let f = full else { return s.pose }
        return f.eye(s.view)
    }

    /// A keyframe request: every view starts whole again.
    func keyframe() { lock.withLock { needsFull = [.mono, .left, .right] } }

    func takeFull(_ v: XRView) -> Bool {
        lock.withLock { needsFull.remove(v) != nil }
    }

    var summary: String {
        lock.withLock { "\(scheduler.mode.rawValue), render delay \(scheduler.effectiveRenderDelay / 1_000_000) ms, settle \(scheduler.effectiveSettle.least / 1_000_000)–\(scheduler.effectiveSettle.most / 1_000_000) ms, picture interval \(Int(scheduler.pictureInterval / 1e6)) ms, camera rotation \(Self.guestRotation ? "sent" : "not sent"): \(picturesSeen) pictures, \(shownSettled) settled eye pictures, \(posesSent) poses, \(estimatedTags) estimated tags"
            + (foveaFraction > 0 ? String(format: "; foveated %.0f%%: %d insets, %.0f KB each, %.1f ms each", foveaFraction * 100, insetsSent,
                                          insetsSent > 0 ? Double(insetBytes) / 1000 / Double(insetsSent) : 0,
                                          insetsSent > 0 ? Double(insetNs) / 1e6 / Double(insetsSent) : 0) : "") }
    }
}

#endif
