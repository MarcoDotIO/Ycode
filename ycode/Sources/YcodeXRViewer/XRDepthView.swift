// The headset viewer's depth path (specs/simulator/xr-depth.md §5–§7): the
// stream's depth (0x0C) and environment (0x0D) feed YcodeXRReprojection,
// which draws each eye every headset frame into the session's rendered
// swapchains (CYcodeOpenXR's hooks a, b, d): the environment at infinity,
// the world cache, then the newest picture re-projected from the pose it
// was rendered for to the eye's current pose. Both eyes come from one view
// (`--stereo synth`), or from each eye's newest picture (alternate).

import CYcodeCodec
import CYcodeOpenXR
import Foundation
import YcodeDisplayStream
import YcodeRemoteViewer
import YcodeXRReprojection

final class XRDepthView: @unchecked Sendable {
    let reprojector: XRReprojector
    /// nil: offscreen (replay without a headset; the reprojector's own device).
    let session: XRSession?
    /// Offscreen: the eye size, and where to write a PNG of the right eye now and then.
    var offscreenSize = (1350, 1485)
    var shotDirectory: String?
    private var lastShot: UInt64 = 0
    private(set) var shots = 0
    let log: (String) -> Void
    private let lock = NSLock()
    /// Decoded depths by frame sequence (the newest few).
    private var depths: [UInt64: (XRDepthImage, XRFrameDepth.Flags, UInt64)] = [:]
    private var pendingEnvironment: (XREnvironment, [UInt8])?
    private var shownSequence: UInt64 = 0
    private var waitingSince: UInt64 = 0
    private var insetSerial = -1
    private var cacheCentre: SpatialVector?
    let options: XRViewerOptions
    // Measurements (xr-depth.md §7).
    private(set) var uploads = 0, withDepth = 0, withoutDepth = 0, rendered = 0, depthBytes = 0, depthMessages = 0, otherFrame = 0
    private var gpu: [Double] = [], cacheGpu: [Double] = [], loop: [Double] = []
    private var translationError: [Double] = [], angleError: [Double] = [], pictureAge: [Double] = [], disocclusion: [Double] = []
    private var lastDisocclusion: UInt64 = 0
    private let started = viewerNanoseconds()
    private var source: (pose: SpatialPose, fov: XRFieldOfView, sentAt: UInt64)?
    private var reference: (colour: [UInt8], w: Int, h: Int, depth: XRDepthImage, view: XRViewGeometry)?
    private var newestDepth: XRDepthImage?
    /// The environment as received (for the calibration) and its calibration.
    private var environmentCube: (XREnvironment, XREnvironmentCalibration.Cube)?
    private var lastEnvironmentSerial: UInt32 = 0
    private var environmentChanged = false
    private var calibrating = false
    private var calibration: XREnvironmentCalibration.Result?
    /// Surface points of final pictures, for the calibration.
    private var calibrationSamples: [XREnvironmentCalibration.Sample] = []
    private(set) var cacheTaken = 0
    /// The shown picture's pose was settled (else the cache goes over it).
    private var pictureSettled = true
    private var currentCached = false, currentHasDepth = false
    private var uploadedAt: UInt64 = 0
    /// This frame's predicted display time, ms ahead of now.
    private var aheadMilliseconds = 0.0
    private(set) var framesUnder = 0

    /// The camera the guest was told: one view for both eyes (mono, synth).
    /// The head's pose in the stage frame → the pose to send: held while the
    /// head stays in a band, or the sweep's stop. Remembers it for `settleCurrent`.
    func camera(_ head: SpatialPose, anchor: XRStageAnchor, recentred: Bool) -> SpatialPose {
        let now = viewerNanoseconds()
        hold.bandRadians = options.holdBandDegrees * .pi / 180
        hold.bandMetres = options.holdBandCentimetres / 100
        if recentred {
            hold.reset()
            sweepAt = now + 1_500_000_000      // the guest's own recentre first (a held crown)
            sweep = nil
        }
        var pose = hold.apply(head, time: Double(now) / 1e9)
        if options.sweep, options.cacheFaceSize > 0, !sweptOnce, source != nil {
            sweptOnce = true
            sweepAt = now + 300_000_000
        }
        if let at = sweepAt, now >= at, source != nil {
            sweepAt = nil
            sweep = XRSweep(fov: source!.fov)
            sweepPosition = head.position
            sweepStart = now
            stopStart = now
            log("ycode-xr-viewer: sweep: \(sweep!.stops.count) stops")
        }
        if var s = sweep {
            // The next stop once this one's picture is in the cache, or after its time. Out of time with a
            // picture of this stop's pose: that picture goes in, nearly right beats the cube's blur.
            if finalAtStop || now &- stopStart > UInt64(options.sweepStopMs) * 1_000_000 {
                if !finalAtStop {
                    if uploadedAt >= stopStart + 300_000_000 { forceFinal = true; return anchor.toStage(commanded ?? anchor.fromStage(pose)) }
                    sweepMissed += 1
                }
                s.advance()
                finalAtStop = false
                stopStart = now
            }
            if let r = s.current {
                pose = SpatialPose(position: sweepPosition, rotation: r)
                sweep = s
            } else {
                forceFinal = false
                log(String(format: "ycode-xr-viewer: sweep done in %.1f s (%d of %d stops without a final picture)",
                           Double(now &- sweepStart) / 1e9, sweepMissed, s.stops.count))
                sweep = nil
                sweepMissed = 0
                startCalibration()
                hold.reset()
                pose = hold.apply(head, time: Double(now) / 1e9)
            }
        }
        let base = anchor.fromStage(pose)
        cameraSpeed.update(base, time: Double(now) / 1e9)
        if commanded == nil || XRCameraHold.differs(commanded!, base, metres: 0.0001, radians: 0.0002) {
            commanded = base
            commandedAt = now
        }
        return pose
    }

    /// The newest picture is under the cache now (its pose is not trusted yet).
    private(set) var pictureHidden = false
    /// It is on top before it is final: the camera has rested long enough for the guest to have nearly converged (§13.5).
    private var onTop = false, retagged = false
    private var cameraSpeed = XRCameraSpeed()
    /// A sweep is running or still to come.
    var sweeping: Bool { sweep != nil || sweepAt != nil || (options.sweep && options.cacheFaceSize > 0 && !sweptOnce) }

    /// How far along a ray (base space) the guest's newest depth has a surface: where a gaze dot belongs.
    func surfaceDistance(origin: SpatialVector, direction: SpatialVector) -> Double? {
        guard let src = source, let d = lock.withLock({ newestDepth }) else { return nil }
        let inverse = src.pose.rotation.conjugate
        let t = d.fov.tangents
        return XRGazeReticle.distance(origin: origin, direction: direction) { p in
            let l = inverse.rotate(p - src.pose.position)
            guard l.z < -1e-3 else { return nil }
            let u = (l.x / -l.z - t.left) / (t.right - t.left), v = (t.up - l.y / -l.z) / (t.up - t.down)
            guard u >= 0, u < 1, v >= 0, v < 1 else { return nil }
            let q = d.samples[Int(v * Double(d.height)) * d.width + Int(u * Double(d.width))]
            guard q > 0 else { return nil }
            return (Double(XRDepthSample.distance(q, near: d.near)), -l.z)
        }
    }

    /// The shown picture is **final** when it shows the camera's pose exactly
    /// (xr-depth.md §5.3): it arrived `holdMs` or more after the camera came to
    /// rest (the guest's smoothing has converged), or the camera is at rest and
    /// no newer picture has come for `settleWindowMs` (the guest stops rendering
    /// once it has converged). The tag of a turn's last picture often names a
    /// pose of the turn; a final picture is re-tagged with the camera's pose and
    /// goes on top and into the cache. Until then the cache is drawn over it.
    /// A mistaken final picture (a stall of the guest) is overwritten by the next.
    private func settleCurrent(_ viewer: XRViewer, anchor: XRStageAnchor) {
        let now = viewerNanoseconds()
        // Not final yet, but the camera has rested for this long: on top, at the camera's pose. Only the
        // cache waits for a final picture; a hover or a window opening is seen now (xr-viewer.md §13.5).
        if !pictureSettled, let camera = commanded, let src = source, uploadedAt > 0 {
            let oneView = shownView == .mono && !options.stereo
            if XRFreshOnTopRule(afterNanoseconds: UInt64(options.freshTopMs) * 1_000_000).isOnTop(now: now, commandedAt: commandedAt, oneView: oneView, sweeping: sweep != nil) {
                onTop = true
                if !retagged {
                    retagged = true
                    reprojector.retag(XRViewGeometry(pose: camera, fov: src.fov, near: reprojector.source?.near ?? 0.1))
                }
            } else {
                // Still moving: on top while slowly, at its tag's pose.
                onTop = oneView && sweep == nil && cameraSpeed.isSlow(limitDegrees: options.freshTopSpeed)
            }
        } else if !pictureSettled {
            onTop = false
        }
        if !pictureSettled, let src = source, uploadedAt > 0 {
            let camera = options.stereo ? nil : commanded
            let settled: Bool
            if shownView != .mono {
                settled = true       // the server shows an eye only once settled, and its tag names it.
            } else if camera != nil {
                settled = forceFinal || XRFinalPictureRule(holdNanoseconds: UInt64(options.holdMs) * 1_000_000, settleNanoseconds: UInt64(options.settleWindowMs) * 1_000_000)
                    .isFinal(uploadedAt: uploadedAt, commandedAt: commandedAt, now: now, finalFor: finalFor, sweeping: sweep != nil)
            } else {
                settled = false
            }
            if settled {
                pictureSettled = true
                forceFinal = false
                if camera != nil { finalFor = commandedAt }
                if shownView == .mono, let camera {
                    let q = (src.pose.rotation.conjugate * camera.rotation).normalized
                    let error = (2 * acos(min(1, abs(q.w))) * 180 / .pi, (src.pose.position - camera.position).length * 1000)
                    lock.withLock { tagErrors.append(error) }
                    source = (camera, src.fov, src.sentAt)
                    reprojector.retag(XRViewGeometry(pose: camera, fov: src.fov, near: reprojector.source?.near ?? 0.1))
                }
                finalAtStop = sweep != nil
                if sweep != nil, let camera { collectSamples(viewer, anchor: anchor, pose: camera, fov: src.fov) }
                dumpFinal(viewer, anchor: anchor, pose: camera ?? src.pose, fov: src.fov)
            }
        }
        // Into the cache at most every 250 ms (a playing animation brings a picture a frame).
        if pictureSettled, !currentCached, currentHasDepth, reprojector.cacheFaceSize > 0, now &- lastCacheAt > 250_000_000 {
            lockQueue { if (try? reprojector.updateCache()) != nil { cacheTaken += 1 } }
            currentCached = true
            lastCacheAt = now
        }
    }
    /// For final pictures: how far their tag was from the pose they show (degrees, mm).
    private var tagErrors: [(Double, Double)] = []
    private var hold = XRCameraHold()
    private var commanded: SpatialPose?
    private var commandedAt: UInt64 = 0
    /// The camera command that has a final picture (0: none yet).
    private var finalFor: UInt64 = 0
    /// A sweep stop ran out of time: its newest picture counts as final.
    private var forceFinal = false
    private var lastCacheAt: UInt64 = 0
    /// The sweep (--sweep): when it starts, and its progress.
    private var sweepAt: UInt64?
    private var sweep: XRSweep?
    private var sweepPosition = SpatialVector.zero
    private var sweepStart: UInt64 = 0, stopStart: UInt64 = 0
    private var finalAtStop = false
    private var sweptOnce = false
    private var sweepMissed = 0

    /// `--reproject-shots`: each final picture beside its raw depth and pose
    /// in the stage frame, for checks of the depth's scale (xr-depth.md §5.5).
    private func dumpFinal(_ viewer: XRViewer, anchor: XRStageAnchor, pose: SpatialPose, fov: XRFieldOfView) {
        guard let dir = options.reprojectShots, let (d, _, _) = lock.withLock({ depths[shownSequence] }), let canvas = viewer.client.canvas(for: shownView),
              dumpedFor != commandedAt, viewerNanoseconds() >= commandedAt + 1_000_000_000 else { return }
        dumpedFor = commandedAt
        finalDumps += 1
        let name = "\(dir)/final-\(String(format: "%03d", finalDumps))"
        let rgba = canvas.withPixels { base, bytesPerRow, _ in PNGWriter.rgba(fromBGRX: base, width: canvas.width, height: canvas.height, bytesPerRow: bytesPerRow) }
        if let png = PNGWriter.encode(rgba: rgba, width: canvas.width, height: canvas.height, level: 1) {
            FileManager.default.createFile(atPath: name + ".png", contents: Data(png))
        }
        FileManager.default.createFile(atPath: name + ".u16", contents: d.samples.withUnsafeBytes { Data($0) })
        let s = anchor.toStage(pose), t = fov.tangents
        let meta = String(format: "{\"w\":%d,\"h\":%d,\"near\":%f,\"tan\":[%f,%f,%f,%f],\"p\":[%f,%f,%f],\"q\":[%f,%f,%f,%f]}\n",
                          d.width, d.height, Double(d.near), t.left, t.right, t.up, t.down, s.position.x, s.position.y, s.position.z,
                          s.rotation.x, s.rotation.y, s.rotation.z, s.rotation.w)
        FileManager.default.createFile(atPath: name + ".json", contents: Data(meta.utf8))
    }
    private var finalDumps = 0
    private var dumpedFor: UInt64 = 0
    private var shownView = XRView.mono

    init(session: XRSession?, options: XRViewerOptions, log: @escaping (String) -> Void) throws {
        if let session {
            var h = yxr_vulkan_handles()
            guard yxr_vulkan(session.handle, &h) == 0 else { throw XRReprojectionError("the session has no Vulkan objects") }
            reprojector = try XRReprojector(vulkan: .init(getInstanceProcAddr: h.get_instance_proc_addr, instance: h.instance,
                                                           physicalDevice: h.physical_device, device: h.device, queueFamily: h.queue_family,
                                                           queue: h.queue, anisotropy: h.anisotropy != 0))
        } else {
            reprojector = try XRReprojector(vulkan: nil)
        }
        reprojector.settings = XRWarpSettings(gridStep: options.depthGridStep, edgeRatio: 1.08, mode: .background)
        // The exposure measured on the room (xr-depth.md §8), until a sweep's calibration.
        reprojector.environmentGain = options.environmentGain ?? 0.62
        self.session = session
        self.options = options
        self.log = log
    }

    // MARK: Stream (connection thread)

    func depthArrived(_ d: XRFrameDepth) {
        guard var image = try? XRDepthImage(d) else { return }
        // An older server's low bit is only depth: it marks nothing (xr-depth.md §3.1).
        if !d.flags.contains(.windowsMarked) { image.samples = image.samples.map { $0 == 0 ? 0 : max(2, $0 & 0xFFFE) } }
        lock.withLock {
            depths[d.frameSequence] = (image, d.flags, viewerNanoseconds())
            newestDepth = image
            if depths.count > 8, let oldest = depths.keys.min() { depths[oldest] = nil }
            depthBytes += d.data.count + 60
            depthMessages += 1
            if d.flags.contains(.otherFrame) { otherFrame += 1 }
        }
    }

    func environmentArrived(_ e: XREnvironment) {
        let raw = 6 * Int(e.faceSize) * Int(e.faceSize) * e.bytesPerTexel
        var faces = e.data
        if e.compressed {
            var out = [UInt8](repeating: 0, count: raw)
            var size = raw
            let rc = e.data.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { ycodec_zlib_uncompress(src.baseAddress, src.count, $0.baseAddress, &size) } }
            guard rc == 0, size == raw else { log("ycode-xr-viewer: environment \(e.serial): cannot inflate"); return }
            faces = out
        }
        guard faces.count == raw else { return }
        let cube = e.format == .rgba16Float ? XREnvironmentCalibration.Cube(halfFloats: faces, size: Int(e.faceSize)) : nil
        lock.withLock {
            if lastEnvironmentSerial != 0, lastEnvironmentSerial != e.serial { environmentChanged = true }
            lastEnvironmentSerial = e.serial
            pendingEnvironment = (e, faces)
            if let cube { environmentCube = (e, cube) }
        }
        if let dir = options.reprojectShots {
            FileManager.default.createFile(atPath: "\(dir)/env-\(e.serial)-\(e.faceSize).rgba16f", contents: Data(faces))
        }
        log("ycode-xr-viewer: environment \(e.serial): \(e.faceSize)² per face, level \(e.level)")
    }

    // MARK: Headset loop

    /// Uploads the newest picture (with its depth, its inset) when there is
    /// one, then draws both eyes. Returns the poses and fields of view the
    /// projection layer must carry, or nil when nothing could be drawn.
    func frame(_ viewer: XRViewer, _ frame: XRFrameState, anchor: XRStageAnchor) -> (poses: [SpatialPose], fovs: [XRFieldOfView])? {
        guard let s = frame.sample, frame.fov.count == 2 else { return nil }
        let ahead = frame.displayTime > 0 && session != nil ? Double(max(0, frame.displayTime - session!.xrNow)) / 1e6 : 0
        return draw(viewer, eyes: [s.leftEye, s.rightEye], fovs: frame.fov, anchor: anchor, ahead: ahead)
    }

    /// The same without a headset (replay): offscreen eyes of `offscreenSize`.
    func offscreen(_ viewer: XRViewer, _ s: XRTrackingSample, fovs: [XRFieldOfView], anchor: XRStageAnchor) {
        _ = draw(viewer, eyes: [s.leftEye, s.rightEye], fovs: fovs, anchor: anchor, ahead: 0)
    }

    private func draw(_ viewer: XRViewer, eyes: [SpatialPose], fovs: [XRFieldOfView], anchor: XRStageAnchor, ahead: Double)
        -> (poses: [SpatialPose], fovs: [XRFieldOfView])? {
        let loopStart = viewerNanoseconds()
        aheadMilliseconds = ahead
        let yaw = SpatialQuaternion(axis: SpatialVector(0, 1, 0), radians: anchor.yaw)
        if cacheCentre == nil || cacheCentre! != anchor.origin {
            // The cache is kept in the base space about the anchor (the stage's origin).
            if reprojector.cacheFaceSize != options.cacheFaceSize {
                try? reprojector.enableCache(faceSize: options.cacheFaceSize, centre: anchor.origin)
            } else {
                lockQueue { try? reprojector.clearCache(centre: anchor.origin) }
            }
            cacheCentre = anchor.origin
            cacheTaken = 0
            // The stage moved: the probe's place is found again by the next sweep.
            lockQueue { try? reprojector.setEnvironmentShape(centre: nil, depth: [], n: 0) }
            if let (e, _) = lock.withLock({ environmentCube }) { reprojector.setEnvironmentOrientation((yaw * environmentTurn(e)).normalized) }
            lock.withLock { calibrationSamples = [] }
        }
        if lock.withLock({ defer { environmentChanged = false }; return environmentChanged }) {
            // A new room: what the cache holds is gone, and the sweep fills it again.
            lockQueue {
                try? reprojector.clearCache()
                try? reprojector.setEnvironmentShape(centre: nil, depth: [], n: 0)
            }
            cacheTaken = 0
            lock.withLock { calibrationSamples = [] }
            if options.sweep { sweep = nil; sweepAt = loopStart + 500_000_000 }
        }
        if let (e, faces) = lock.withLock({ () -> (XREnvironment, [UInt8])? in defer { pendingEnvironment = nil }; return pendingEnvironment }) {
            lockQueue {
                try? reprojector.setEnvironment(faces: faces, halfFloat: e.format == .rgba16Float, size: Int(e.faceSize),
                                                orientation: (yaw * environmentTurn(e)).normalized, mirrored: !e.orientationKnown)
            }
        }
        // A calibration that finished: the cube on the room's box, from its probe, at its exposure.
        if let c = lock.withLock({ () -> XREnvironmentCalibration.Result? in defer { calibration = nil }; return calibration }) {
            if options.environmentGain == nil { reprojector.environmentGain = min(2, max(0.2, c.gain)) }
            if c.score > 0.45, options.environmentYaw == nil {
                let n = 33
                let depth = XREnvironmentCalibration.boxDepth(probe: c.probe, boxMin: c.boxMin, boxMax: c.boxMax, n: n)
                lockQueue { try? reprojector.setEnvironmentShape(centre: anchor.fromStage(SpatialPose(position: c.probe)).position, depth: depth, n: n) }
            }
        }
        uploadNewest(viewer, anchor: anchor)
        settleCurrent(viewer, anchor: anchor)
        pictureHidden = !pictureSettled && cacheTaken > 0 && !onTop
        // Both eyes at their current poses (the views of this frame's predicted display time).
        var ok = true
        for eye in 0..<2 {
            var image: UInt64 = 0, w = Int32(offscreenSize.0), h = Int32(offscreenSize.1), format: Int64 = 0
            if let session { guard yxr_acquire_render(session.handle, Int32(eye), &image, &w, &h, &format) == 0 else { ok = false; break } }
            lockQueue {
                do {
                    // During a sweep only final pictures show: the others name their place only roughly.
                    try reprojector.render(eye: eyes[eye], fov: fovs[eye], target: .init(image: image, format: format, width: Int(w), height: Int(h)),
                                           picture: sweep == nil || pictureSettled, freshUnder: pictureHidden)
                } catch {
                    ok = false
                    log("ycode-xr-viewer: reprojection: \(error)")
                }
            }
            if let session { _ = yxr_release_render(session.handle, Int32(eye)) }
            if let g = reprojector.gpuMilliseconds { lock.withLock { gpu.append(g) } }
            if session == nil, let dir = shotDirectory, viewerNanoseconds() &- lastShot > 2_000_000_000, eye == 1 {
                lastShot = viewerNanoseconds()
                if let bgra = try? reprojector.readOffscreen(width: Int(w), height: Int(h)) {
                    let rgba = bgra.withUnsafeBytes { PNGWriter.rgba(fromBGRX: $0.baseAddress!, width: Int(w), height: Int(h), bytesPerRow: Int(w) * 4) }
                    if let png = PNGWriter.encode(rgba: rgba, width: Int(w), height: Int(h), level: 3) {
                        shots += 1
                        FileManager.default.createFile(atPath: "\(dir)/eye-\(String(format: "%03d", shots)).png", contents: Data(png))
                    }
                    // Once, the picture as decoded, for comparing the encodings (RGBA rows and a PNG).
                    if shots == 3, let canvas = viewer.client.canvas(for: shownView) {
                        let rgba = canvas.rgba()
                        FileManager.default.createFile(atPath: "\(dir)/picture.rgba", contents: rgba.withUnsafeBytes { Data($0) })
                        if let png = PNGWriter.encode(rgba: rgba, width: canvas.width, height: canvas.height, level: 1) {
                            FileManager.default.createFile(atPath: "\(dir)/picture.png", contents: Data(png))
                        }
                    }
                    // The newest depth beside it: grey = 255 at 0.5 m, falling as 0.5 / distance (black: nothing).
                    if let d = lock.withLock({ newestDepth }) {
                        var rgba = [UInt8](repeating: 255, count: d.width * d.height * 4)
                        var lo = Float.infinity, hi: Float = 0
                        for (i, q) in d.samples.enumerated() {
                            let z = XRDepthSample.distance(q, near: d.near)
                            if z.isFinite { lo = min(lo, z); hi = max(hi, z) }
                            let g = z.isFinite ? UInt8(max(0, min(255, 255 * 0.5 / z))) : 0
                            (rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]) = (g, g, g)
                        }
                        if let png = PNGWriter.encode(rgba: rgba, width: d.width, height: d.height, level: 3) {
                            FileManager.default.createFile(atPath: "\(dir)/depth-\(String(format: "%03d", shots)).png", contents: Data(png))
                        }
                        log(String(format: "ycode-xr-viewer: shot %d: depth %dx%d, %.2f … %.2f m", shots, d.width, d.height, lo, hi))
                    }
                }
            }
        }
        guard ok else { return nil }
        rendered += 1
        if let src = source {
            // What the re-projection makes up for: the picture's viewpoint against the eye's.
            let base = SpatialPose(position: (eyes[0].position + eyes[1].position) * 0.5, rotation: eyes[0].rotation)
            let q = (src.pose.rotation.conjugate * base.rotation).normalized
            lock.withLock {
                translationError.append((base.position - src.pose.position).length * 1000)
                angleError.append(2 * acos(min(1, abs(q.w))) * 180 / .pi)
                if translationError.count > 200_000 { translationError.removeFirst(100_000); angleError.removeFirst(100_000) }
                if pictureAge.count > 200_000 { pictureAge.removeFirst(100_000) }
            }
        }
        // The disoccluded area, from the CPU reference at a small size, twice a second.
        if viewerNanoseconds() &- lastDisocclusion > 500_000_000, let r = reference, let src = source {
            lastDisocclusion = viewerNanoseconds()
            // The right eye against the picture's own view: what stereo synthesis uncovers.
            let dst = XRViewGeometry(pose: eyes[1], fov: fovs[1])
            _ = src
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let out = XRReferenceWarp.warp(colour: r.colour, colourWidth: r.w, colourHeight: r.h, depth: r.depth, source: r.view,
                                               destination: dst, width: 192, height: 212, settings: XRWarpSettings(gridStep: 1))
                self?.lock.withLock { self?.disocclusion.append(out.stretchedFraction) }
            }
        }
        lock.withLock {
            loop.append(Double(viewerNanoseconds() - loopStart) / 1e6)
            if gpu.count > 200_000 { gpu.removeFirst(100_000) }
            if loop.count > 200_000 { loop.removeFirst(100_000) }
        }
        return (eyes, fovs)
    }

    /// The cube's frame → the stage: the server's, or `--env-yaw` after the mirror.
    private func environmentTurn(_ e: XREnvironment) -> SpatialQuaternion {
        if e.orientationKnown { return e.orientation }
        if let y = options.environmentYaw { return SpatialQuaternion(axis: SpatialVector(0, 1, 0), radians: y * .pi / 180) }
        return .identity
    }

    /// Keeps surface points of a final picture (stage frame) for the calibration.
    private func collectSamples(_ viewer: XRViewer, anchor: XRStageAnchor, pose: SpatialPose, fov: XRFieldOfView) {
        guard !options.stereo, lock.withLock({ calibrationSamples.count < 40_000 && environmentCube != nil }),
              let (d, _, _) = lock.withLock({ depths[shownSequence] }), let canvas = viewer.client.canvas(for: shownView) else { return }
        let stage = anchor.toStage(pose), t = fov.tangents
        var out: [XREnvironmentCalibration.Sample] = []
        let columns = 48, rows = max(16, columns * canvas.height / max(1, canvas.width))
        // Point samples, whatever the canvas holds: no whole picture is converted on the headset's loop.
        var points: [(x: Int, y: Int)] = [], places: [(u: Double, v: Double, q: UInt16)] = []
        for j in 0..<rows {
            for i in 0..<columns {
                let u = (Double(i) + 0.5) / Double(columns), v = (Double(j) + 0.5) / Double(rows)
                let q = d.samples[min(d.height - 1, Int(v * Double(d.height))) * d.width + min(d.width - 1, Int(u * Double(d.width)))]
                guard q > 0 else { continue }
                points.append((Int(u * Double(canvas.width)), Int(v * Double(canvas.height))))
                places.append((u, v, q))
            }
        }
        for (place, c) in zip(places, canvas.samplesBGR(points)) {
            let b = XREnvironmentCalibration.linear(c.0), g = XREnvironmentCalibration.linear(c.1), r = XREnvironmentCalibration.linear(c.2)
            let z = Double(XRDepthSample.distance(place.q, near: d.near))
            let local = SpatialVector((t.left + place.u * (t.right - t.left)) * z, (t.up - place.v * (t.up - t.down)) * z, -z)
            out.append((stage.position + stage.rotation.rotate(local), 0.2126 * r + 0.7152 * g + 0.0722 * b))
        }
        lock.withLock { calibrationSamples += out }
    }

    /// After a sweep: where the cube was taken, its exposure and the room's box.
    private func startCalibration() {
        guard options.environment, options.environmentYaw == nil,
              let (cube, samples) = lock.withLock({ () -> (XREnvironmentCalibration.Cube, [XREnvironmentCalibration.Sample])? in
                  guard !calibrating, let c = environmentCube else { return nil }
                  calibrating = true
                  return (c.1, calibrationSamples)
              }) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let started = viewerNanoseconds()
            let r = XREnvironmentCalibration.calibrate(cube: cube, samples: samples)
            guard let self else { return }
            self.lock.withLock {
                self.calibrating = false
                self.calibration = r
            }
            if let r {
                self.log(String(format: "ycode-xr-viewer: environment: taken at (%.2f, %.2f, %.2f) m, correlation %.2f, exposure %.2f, room x %.2f…%.2f y %.2f…%.2f z %.2f…%.2f m (%d points, %.0f ms)",
                                r.probe.x, r.probe.y, r.probe.z, r.score, r.gain, r.boxMin.x, r.boxMax.x, r.boxMin.y, r.boxMax.y, r.boxMin.z, r.boxMax.z,
                                samples.count, Double(viewerNanoseconds() - started) / 1e6))
            }
        }
    }

    private func lockQueue(_ body: () -> Void) {
        guard let session else { body(); return }
        yxr_queue_lock(session.handle)
        body()
        yxr_queue_unlock(session.handle)
    }

    /// The newest picture of any view, once its depth is here (or 40 ms
    /// after it arrived without one: an older server, or a lost message).
    private func uploadNewest(_ viewer: XRViewer, anchor: XRStageAnchor) {
        let views: [XRView] = [.mono, .left, .right]
        guard let (v, entry) = views.compactMap({ v in viewer.board.get(v).map { (v, $0) } }).max(by: { $0.1.sequence < $1.1.sequence }) else { return }
        if entry.sequence == shownSequence {
            // The gaze moved and the picture did not: a new inset of the same picture.
            if let inset = viewer.inset(v), inset.serial != insetSerial, inset.inset.frameSequence == entry.sequence {
                insetSerial = inset.serial
                let i = inset.inset
                lockQueue {
                    try? inset.pixels.withUnsafeBytes {
                        try reprojector.setInset(bgra: $0.baseAddress, width: i.width, height: i.height, bytesPerRow: i.width * 4,
                                                 rect: (i.x, i.y, i.width, i.height), fullWidth: i.fullWidth, fullHeight: i.fullHeight)
                    }
                }
            }
            return
        }
        guard let canvas = viewer.client.canvas(for: v) else { return }
        // A picture whose frame view was lost (media over UDP) names no pose: skip it, the next will.
        if entry.tag == nil, viewer.xrServer, source != nil { shownSequence = entry.sequence; return }
        let depth = lock.withLock { depths[entry.sequence] }
        if depth == nil {
            if waitingSince == 0 { waitingSince = viewerNanoseconds() }
            if viewerNanoseconds() &- waitingSince < 40_000_000 { return }
        }
        waitingSince = 0
        shownSequence = entry.sequence
        shownView = v
        let (gw, gh) = viewer.guestSize
        let pose = entry.tag.map { anchor.fromStage($0.pose) } ?? .identity
        let fov = entry.tag?.fov ?? .guest(width: gw, height: gh)
        let view = XRViewGeometry(pose: pose, fov: fov, near: Double(depth?.0.near ?? 0.1))
        var failure: Error?
        lockQueue {
            do {
                let video = canvas.withVideoPlanes { p, _ -> Error? in
                    do { try reprojector.setPictureYUV(yuv444: p.format == .yuv444, y: p.y, u: p.u, v: p.v, pitch: p.pitch, width: canvas.width, height: canvas.height, view: view); return nil }
                    catch { return error }
                }
                if let video {
                    failure = video
                } else {
                    failure = canvas.withPixels { base, bytesPerRow, _ in
                        do { try reprojector.setPicture(bgra: base, width: canvas.width, height: canvas.height, bytesPerRow: bytesPerRow, view: view); return nil }
                        catch { return error }
                    }
                }
                if let (d, _, _) = depth { try reprojector.setDepth(d) } else if reprojector.hasDepth { try reprojector.clearDepth() }
                if let inset = viewer.inset(v), inset.serial != insetSerial, inset.inset.frameSequence == entry.sequence {
                    insetSerial = inset.serial
                    let i = inset.inset
                    try inset.pixels.withUnsafeBytes {
                        try reprojector.setInset(bgra: $0.baseAddress, width: i.width, height: i.height, bytesPerRow: i.width * 4,
                                                 rect: (i.x, i.y, i.width, i.height), fullWidth: i.fullWidth, fullHeight: i.fullHeight)
                    }
                } else if viewer.inset(v)?.inset.frameSequence != entry.sequence {
                    try reprojector.setInset(bgra: nil, width: 0, height: 0, bytesPerRow: 0, rect: (0, 0, 0, 0), fullWidth: 0, fullHeight: 0)
                }
                // The cache takes a picture once it is final (§5.3): see `settleCurrent`.
                pictureSettled = false
                onTop = false
                retagged = false
                currentCached = false
                currentHasDepth = depth != nil
                if options.cacheAll, depth != nil, reprojector.cacheFaceSize > 0 {
                    try reprojector.updateCache()
                    currentCached = true
                    cacheTaken += 1
                }
            } catch { failure = error }
        }
        if let failure { log("ycode-xr-viewer: reprojection upload: \(failure)"); return }
        uploads += 1
        if depth != nil { withDepth += 1 } else { withoutDepth += 1 }
        source = (pose, fov, entry.tag.flatMap { viewer.poseSent($0.poseSequence) } ?? 0)
        uploadedAt = viewerNanoseconds()
        if let sentAt = source?.sentAt, sentAt > 0 { lock.withLock { pictureAge.append(Double(uploadedAt &- sentAt) / 1e6) } }
        // The stages of this picture (xr-viewer.md §6): the summary's "ours" and --measure.
        var sample = XRLatencySample(received: entry.receivedAt, decoded: entry.decodedAt, uploaded: uploadedAt,
                                     display: uploadedAt + UInt64(aheadMilliseconds * 1e6))
        sample.poseSent = source?.sentAt ?? 0
        if let t = viewer.client.takeTiming(sequence: entry.sequence) {
            let clock = viewer.client.clock
            func map(_ ns: UInt64) -> UInt64 { ns == 0 ? 0 : clock.clientTime(server: ns) ?? 0 }
            (sample.recordSeen, sample.captureStart, sample.encodeEnd, sample.sendEnd) = (map(t.recordSeen), map(t.captureStart), map(t.encodeEnd), map(t.sendEnd))
        }
        viewer.addLatency(sample)
        viewer.pictureShown(entry, sample)
        // For the disocclusion measurement only the depth matters: the colour is one grey texel.
        if let (d, _, _) = depth, uploads % 30 == 1 { reference = ([128, 128, 128, 255], 1, 1, d, view) }
    }

    var summary: String {
        func pct(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * p))] }
        let seconds = max(0.001, Double(viewerNanoseconds() - started) / 1e9)
        return lock.withLock {
            String(format: "reprojection: %d headset frames, %d pictures (%d with depth, %d without), GPU per eye p50 %.2f / p99 %.2f ms, loop p50 %.2f ms; "
                   + "viewpoint the re-projection corrects p50 %.0f mm / %.1f°, p90 %.0f mm / %.1f°; picture pose age when first shown p50 %.0f ms; "
                   + "disoccluded p50 %.2f %% / p90 %.2f %%; depth %.2f Mbit/s (%d messages, %d not paired); cache took %d pictures; final pictures' tag error p50 %.1f° / %.0f mm",
                   rendered, uploads, withDepth, withoutDepth, pct(gpu, 0.5), pct(gpu, 0.99), pct(loop, 0.5),
                   pct(translationError, 0.5), pct(angleError, 0.5), pct(translationError, 0.9), pct(angleError, 0.9), pct(pictureAge, 0.5),
                   100 * pct(disocclusion, 0.5), 100 * pct(disocclusion, 0.9), Double(depthBytes) * 8 / 1e6 / seconds, depthMessages, otherFrame, cacheTaken,
                   pct(tagErrors.map(\.0), 0.5), pct(tagErrors.map(\.1), 0.5))
        }
    }
}
