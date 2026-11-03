// XR-QUALITY: depth edges at rest and in motion, the GPU's YUV conversion and
// mipmapped sampling, and the gaze → guest mapping with re-projection
// (specs/simulator/xr-viewer.md §12, display-stream.md §14).

import CYcodeVideo
import Foundation
import Testing
import YcodeDisplayStream
@testable import YcodeXRReprojection

@Suite struct XRDepthEdgeTests {
    /// At its own viewpoint a picture shows exactly as sent, depth edges included
    /// (they used to take one flat colour: a band of depth texels around every window).
    @Test func atItsOwnViewpointEveryPixelIsThePicture() {
        // Colour at 4 × the depth's resolution, as on the stream.
        let s = SyntheticScene(width: 640, height: 360)
        let (c, _) = s.render()
        let low = SyntheticScene(width: 160, height: 90)
        let (_, d) = low.render()
        let v = XRViewGeometry(pose: .identity, fov: s.fov)
        for mode in [XRFillMode.background, .discard] {
            let r = XRReferenceWarp.warp(colour: c, colourWidth: s.width, colourHeight: s.height, depth: d, source: v, destination: v,
                                         width: s.width, height: s.height, settings: XRWarpSettings(gridStep: 1, mode: mode))
            var wrong = 0
            for y in 4..<(s.height - 4) { for x in 4..<(s.width - 4) {
                let p = r.pixel(x, y), i = (y * s.width + x) * 4
                if p.a == 0 || abs(Int(p.b) - Int(c[i])) > 2 || abs(Int(p.g) - Int(c[i + 1])) > 2 || abs(Int(p.r) - Int(c[i + 2])) > 2 { wrong += 1 }
            } }
            #expect(wrong == 0, "\(mode): \(wrong) pixels differ from the picture")
            #expect(r.stretched == 0)
        }
    }

    /// A small move keeps the edge triangles over the cache; a large one drops them.
    @Test func overTheCacheAnEdgeIsDroppedOnlyOnceStretched() {
        let s = SyntheticScene(width: 320, height: 180)
        let (c, d) = s.render()
        let src = XRViewGeometry(pose: .identity, fov: s.fov)
        func covered(_ x: Double) -> Int {
            XRReferenceWarp.warp(colour: c, colourWidth: s.width, colourHeight: s.height, depth: d, source: src,
                                 destination: XRViewGeometry(pose: SpatialPose(position: SpatialVector(x, 0, 0)), fov: s.fov),
                                 width: s.width, height: s.height, settings: XRWarpSettings(gridStep: 1, mode: .discard)).covered
        }
        let rest = covered(0), tiny = covered(0.0005), large = covered(0.1)
        #expect(tiny >= rest - s.width)      // only the picture's border moved off
        #expect(large < rest)
    }

    /// In a large disocclusion the fill is the background's colour, not the near surface's.
    @Test func aStretchedEdgeClosesInOnTheBackground() {
        let s = SyntheticScene(width: 320, height: 180)
        let (c, d) = s.render()
        let src = XRViewGeometry(pose: .identity, fov: s.fov)
        let r = XRReferenceWarp.warp(colour: c, colourWidth: s.width, colourHeight: s.height, depth: d, source: src,
                                     destination: XRViewGeometry(pose: SpatialPose(position: SpatialVector(0.2, 0, 0)), fov: s.fov),
                                     width: s.width, height: s.height, settings: XRWarpSettings(gridStep: 1, mode: .background))
        // Beside the box (red, 1 m) at mid height, once it has moved left by 0.1 of the width against the wall.
        var red = 0, grey = 0
        let row = s.height / 2
        let edge = Int((0.625 - 0.2 / 1.0 / 2) * Double(s.width)), wall = Int((0.625 - 0.2 / 4.0 / 2) * Double(s.width))
        for x in (edge + 3)..<(wall - 1) {
            let p = r.pixel(x, row)
            if p.r > 150 && p.g < 80 { red += 1 } else if p.a == 255 { grey += 1 }
        }
        #expect(grey > 3 * red, "red \(red), wall \(grey)")
    }
}

/// A small disc floating before a wall (xr-depth.md §5.6): the shape of a home
/// icon, whose depth used to fill a tube from it to the wall in the world cache.
struct FloatingDiscScene {
    var width = 480, height = 480
    var fov = XRFieldOfView(left: -.pi / 4, right: .pi / 4, up: .pi / 4, down: -.pi / 4)
    let wall = 4.0, disc = 1.0, radius = 0.12
    /// Bands of the wall (BGRA): dark above y = 0, below it light and mid grey in turn every 16 cm.
    func wallColour(x: Double, y: Double) -> (UInt8, UInt8, UInt8) {
        if y > 0 { return (40, 40, 40) }
        return Int(floor(y / 0.16)) & 1 == 0 ? (230, 230, 230) : (130, 130, 130)
    }
    /// The scene from an eye at (`eyeX`, 0, 0). `window`: the disc's samples carry the windows layer's mark.
    func render(eyeX: Double = 0, window: Bool = false) -> (colour: [UInt8], depth: XRDepthImage) {
        let t = fov.tangents
        var c = [UInt8](repeating: 255, count: width * height * 4), q = [UInt16](repeating: 0, count: width * height)
        for py in 0..<height {
            for px in 0..<width {
                let tx = t.left + (Double(px) + 0.5) / Double(width) * (t.right - t.left)
                let ty = t.up - (Double(py) + 0.5) / Double(height) * (t.up - t.down)
                let i = py * width + px
                let dx = eyeX + tx * disc, dy = ty * disc
                if dx * dx + dy * dy < radius * radius {
                    (c[i * 4], c[i * 4 + 1], c[i * 4 + 2]) = (220, 80, 30)    // blue
                    q[i] = XRDepthSample.sample(distance: Float(disc), near: 0.1) & 0xFFFE | (window ? 1 : 0)
                } else {
                    (c[i * 4], c[i * 4 + 1], c[i * 4 + 2]) = wallColour(x: eyeX + tx * wall, y: ty * wall)
                    q[i] = XRDepthSample.sample(distance: Float(wall), near: 0.1) & 0xFFFE
                }
            }
        }
        return (c, XRDepthImage(width: width, height: height, samples: q, near: 0.1, fov: fov))
    }
}

@Suite(.serialized) struct XRPictureGPUTests {
    static let gpu: XRReprojector? = try? XRReprojector(vulkan: nil)

    /// A smooth picture as planes, from BT.709 limited-range values.
    static func planes(width w: Int, height h: Int, yuv444: Bool) -> (y: [UInt8], u: [UInt8], v: [UInt8]) {
        var y = [UInt8](repeating: 0, count: w * h)
        let cw = yuv444 ? w : w / 2, ch = yuv444 ? h : h / 2
        var u = [UInt8](repeating: 0, count: cw * ch), v = u
        for r in 0..<h { for x in 0..<w { y[r * w + x] = UInt8(16 + (x * 219 / w + r * 40 / h) % 220) } }
        for r in 0..<ch { for x in 0..<cw {
            u[r * cw + x] = UInt8(64 + x * 128 / cw)
            v[r * cw + x] = UInt8(192 - r * 128 / ch)
        } }
        return (y, u, v)
    }

    @Test func yuv444ConversionMatchesTheReference() throws {
        guard let gpu = Self.gpu else { print("XRPictureGPUTests: no Vulkan device; skipped"); return }
        let (w, h) = (256, 128)
        let (y, u, v) = Self.planes(width: w, height: h, yuv444: true)
        var reference = [UInt8](repeating: 0, count: w * h * 4)
        yvid_yuv444_to_bgrx(y, u, v, Int32(w), Int32(w), Int32(h), &reference, w * 4)
        let view = XRViewGeometry(pose: .identity, fov: .guest(width: w, height: h))
        try y.withUnsafeBufferPointer { py in try u.withUnsafeBufferPointer { pu in try v.withUnsafeBufferPointer { pv in
            try gpu.setPictureYUV(yuv444: true, y: py.baseAddress!, u: pu.baseAddress!, v: pv.baseAddress!, pitch: w, width: w, height: h, view: view)
        } } }
        let out = try gpu.readPicture(width: w, height: h)
        var worst = 0
        for i in 0..<(w * h) { for k in 0..<3 { worst = max(worst, abs(Int(out[i * 4 + k]) - Int(reference[i * 4 + k]))) } }
        #expect(worst <= 2, "the GPU differs from the reference by up to \(worst) levels")
    }

    @Test func nv12ConversionMatchesTheReference() throws {
        guard let gpu = Self.gpu else { return }
        let (w, h) = (256, 128)
        let (y, u, v) = Self.planes(width: w, height: h, yuv444: false)
        var uv = [UInt8](repeating: 0, count: w * h / 2)
        for i in 0..<u.count { uv[i * 2] = u[i]; uv[i * 2 + 1] = v[i] }
        var reference = [UInt8](repeating: 0, count: w * h * 4)
        yvid_nv12_to_bgrx(y, uv, Int32(w), Int32(w), Int32(h), &reference, w * 4)
        let view = XRViewGeometry(pose: .identity, fov: .guest(width: w, height: h))
        try y.withUnsafeBufferPointer { py in try uv.withUnsafeBufferPointer { puv in
            try gpu.setPictureYUV(yuv444: false, y: py.baseAddress!, u: puv.baseAddress!, v: nil, pitch: w, width: w, height: h, view: view)
        } }
        let out = try gpu.readPicture(width: w, height: h)
        // The GPU interpolates chroma (the reference repeats it): a smooth ramp stays within a few levels.
        var worst = 0
        for i in 0..<(w * h) { for k in 0..<3 { worst = max(worst, abs(Int(out[i * 4 + k]) - Int(reference[i * 4 + k]))) } }
        #expect(worst <= 6, "the GPU differs from the reference by up to \(worst) levels")
    }

    /// A one-pixel checker minified 8 × must come out flat, not aliased.
    @Test func aMinifiedPictureDoesNotAlias() throws {
        guard let gpu = Self.gpu else { return }
        let (w, h) = (1024, 1024)
        var bgra = [UInt8](repeating: 255, count: w * h * 4)
        for r in 0..<h { for x in 0..<w where (r + x) & 1 == 0 { for k in 0..<3 { bgra[(r * w + x) * 4 + k] = 0 } } }
        let fov = XRFieldOfView.guest(width: w, height: h)
        let view = XRViewGeometry(pose: .identity, fov: fov)
        try bgra.withUnsafeBytes { try gpu.setPicture(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4, view: view) }
        let q = [UInt16](repeating: UInt16(65535.0 * 0.1 / 2.0), count: 64 * 64)
        try gpu.setDepth(XRDepthImage(width: 64, height: 64, samples: q, near: 0.1, fov: fov))
        try gpu.enableCache(faceSize: 0, centre: .zero)
        gpu.settings = XRWarpSettings(gridStep: 1, mode: .background)
        try gpu.render(eye: .identity, fov: fov, target: .init(width: 128, height: 128))
        let out = try gpu.readOffscreen(width: 128, height: 128)
        var lo = 255, hi = 0
        for r in 16..<112 { for x in 16..<112 { let g = Int(out[(r * 128 + x) * 4 + 1]); lo = min(lo, g); hi = max(hi, g) } }
        // The average of black and white in linear light is about 188 in sRGB.
        #expect(hi - lo <= 6, "minified checker spans \(lo)…\(hi)")
        #expect(lo > 170 && hi < 205, "minified checker spans \(lo)…\(hi)")
    }

    /// Cache texels next to empty ones keep their own colour when filtered, not darkened by the empties' zeros.
    @Test func filteredCacheEdgesAreNotDarkened() throws {
        guard let gpu = Self.gpu else { return }
        let (w, h) = (256, 256)
        let bgra = [UInt8](repeating: 200, count: w * h * 4)
        let fov = XRFieldOfView(tangentLeft: -0.35, right: 0.35, up: 0.35, down: -0.35)
        let q = [UInt16](repeating: UInt16(65535.0 * 0.1 / 2.0), count: 64 * 64)
        let view = XRViewGeometry(pose: .identity, fov: fov)
        try bgra.withUnsafeBytes { try gpu.setPicture(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4, view: view) }
        try gpu.setDepth(XRDepthImage(width: 64, height: 64, samples: q, near: 0.1, fov: fov))
        try gpu.enableCache(faceSize: 512, centre: .zero)
        try gpu.clearCache()
        gpu.settings = XRWarpSettings(gridStep: 1, mode: .background)
        try gpu.updateCache()
        // Only the cache, minified: its filled square's rim must not go dark.
        try gpu.render(eye: .identity, fov: .guest(width: 256, height: 256), target: .init(width: 256, height: 256), picture: false)
        let out = try gpu.readOffscreen(width: 256, height: 256)
        var darkRim = 0, lit = 0
        for i in 0..<(256 * 256) {
            let g = Int(out[i * 4 + 1])
            if g > 150 { lit += 1 } else if g > 8 { darkRim += 1 }
        }
        #expect(lit > 1000)
        #expect(darkRim == 0, "\(darkRim) darkened texels against \(lit) lit")
        try gpu.enableCache(faceSize: 0, centre: .zero)
    }
}

/// What the wearer looks at must be what the guest's ray hits (xr-viewer.md §5.2):
/// a target at a known place, a guest picture taken from a held camera, the head
/// elsewhere. The guest's hit test works in the stage frame; what the wearer sees
/// comes through the re-projection.
@Suite struct XRSelectionTests {
    /// The guest's window: a plane at z = −1.2 m in the stage frame.
    static let planeZ = -1.2
    static let fov = XRFieldOfView.guest(width: 1080, height: 1920)

    /// The stage point a ray hits on the plane.
    static func hit(origin: SpatialVector, direction: SpatialVector) -> SpatialVector {
        let t = (planeZ - origin.z) / direction.z
        return SpatialVector(origin.x + direction.x * t, origin.y + direction.y * t, planeZ)
    }

    /// A stage point's pixel (u, v) in a guest picture taken from `camera`.
    static func pixel(_ p: SpatialVector, camera: SpatialPose, fov: XRFieldOfView = XRSelectionTests.fov) -> (u: Double, v: Double) {
        let l = camera.rotation.conjugate.rotate(p - camera.position)
        let t = fov.tangents
        let tx = l.x / -l.z, ty = l.y / -l.z
        return ((tx - t.left) / (t.right - t.left), (t.up - ty) / (t.up - t.down))
    }

    /// The pose looking from `eye` at `target` (with no roll).
    static func look(from eye: SpatialVector, at target: SpatialVector) -> SpatialPose {
        let d = target - eye
        let yaw = atan2(-d.x, -d.z), pitch = asin(d.y / d.length)
        return SpatialPose(position: eye, rotation: SpatialQuaternion(yaw: yaw, pitch: pitch))
    }

    /// The guest pixel the wearer's gaze selects, through the input mapping.
    static func selected(target: SpatialVector, head: SpatialPose, anchorHead: SpatialPose, camera: SpatialPose) -> (u: Double, v: Double) {
        var mapper = XRInputMapper(pointer: .eyes, stereo: false)
        mapper.filterGaze = false
        mapper.anchor(at: anchorHead)
        let anchor = mapper.anchor!
        let eye = head.position
        let gaze = look(from: eye, at: anchor.fromStage(SpatialPose(position: target)).position)
        let out = mapper.map(XRTrackingSample(time: 0, head: head, gaze: gaze))
        let p = hit(origin: out.selection.rayOrigin, direction: out.selection.rayDirection)
        return pixel(p, camera: camera)
    }

    /// The picture's pixel the wearer sees along the gaze, through the reference warp:
    /// each guest pixel is coloured by its own (u, v).
    static func seen(target: SpatialVector, eye: SpatialPose, camera: SpatialPose, fov: XRFieldOfView = XRSelectionTests.fov) -> (u: Double, v: Double)? {
        let (w, h) = (512, 512)
        var colour = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            colour[(y * w + x) * 4 + 2] = UInt8(x * 255 / (w - 1))
            colour[(y * w + x) * 4 + 1] = UInt8(y * 255 / (h - 1))
        } }
        // The depth of the plane as the camera sees it.
        let t = fov.tangents
        let (dw, dh) = (128, 128)
        var q = [UInt16](repeating: 0, count: dw * dh)
        for y in 0..<dh { for x in 0..<dw {
            let tx = t.left + (Double(x) + 0.5) / Double(dw) * (t.right - t.left), ty = t.up - (Double(y) + 0.5) / Double(dh) * (t.up - t.down)
            let dir = camera.rotation.rotate(SpatialVector(tx, ty, -1))
            let s = (planeZ - camera.position.z) / dir.z       // the view distance along −Z is s
            q[y * dw + x] = s > 0 ? UInt16(min(65535, 65535 * 0.1 / s)) : 0
        } }
        let depth = XRDepthImage(width: dw, height: dh, samples: q, near: 0.1, fov: fov)
        // The eye's own narrow view along the gaze: the middle pixel is the gaze.
        let g = look(from: eye.position, at: target)
        let narrow = XRFieldOfView(tangentLeft: -0.2, right: 0.2, up: 0.2, down: -0.2)
        let r = XRReferenceWarp.warp(colour: colour, colourWidth: w, colourHeight: h, depth: depth, source: XRViewGeometry(pose: camera, fov: fov),
                                     destination: XRViewGeometry(pose: g, fov: narrow), width: 129, height: 129, settings: XRWarpSettings(gridStep: 1))
        let p = r.pixel(64, 64)
        guard p.a == 255 else { return nil }
        return (Double(p.r) / 255, Double(p.g) / 255)
    }

    static let target = SpatialVector(0.15, 0.1, planeZ)

    func expectSame(_ a: (u: Double, v: Double), _ b: (u: Double, v: Double), _ what: String, tolerance: Double = 0.012) {
        #expect(abs(a.u - b.u) < tolerance && abs(a.v - b.v) < tolerance, "\(what): \(a) against \(b)")
    }

    /// Still, moving within the hold, or having moved on from a stale picture: the
    /// ray hits the target's guest pixel, and the re-projected picture shows it along the gaze.
    @Test(arguments: [
        ("still", SpatialPose.identity),
        ("1 cm and 1° inside the hold", SpatialPose(position: SpatialVector(0.01, -0.005, 0), rotation: SpatialQuaternion(yaw: 0.0175, pitch: 0))),
        ("10 cm and 15° ahead of a stale picture", SpatialPose(position: SpatialVector(0.1, 0.02, -0.03), rotation: SpatialQuaternion(yaw: -0.26, pitch: 0.1))),
    ])
    func theGazeHitsTheSameGuestPixelTheWearerSees(name: String, head: SpatialPose) throws {
        let camera = SpatialPose.identity
        let expected = Self.pixel(Self.target, camera: camera)
        let hit = Self.selected(target: Self.target, head: head, anchorHead: .identity, camera: camera)
        expectSame(hit, expected, "\(name): the guest's hit")
        let seen = try #require(Self.seen(target: Self.target, eye: head, camera: camera))
        expectSame(seen, expected, "\(name): what the wearer sees")
    }

    /// Without re-projection a picture is shown at its own pose: the wearer who
    /// looks at the target along the camera's own ray selects the same pixel.
    @Test func withoutReprojectionTheSamePixelIsSelected() {
        let camera = SpatialPose(position: SpatialVector(0.02, 0, 0), rotation: SpatialQuaternion(yaw: 0.05, pitch: -0.02))
        let hit = Self.selected(target: Self.target, head: camera, anchorHead: .identity, camera: camera)
        expectSame(hit, Self.pixel(Self.target, camera: camera), "no re-projection")
    }

    /// A stage anchored away from the base origin changes nothing: gaze, camera and picture share the stage frame.
    @Test func aTurnedAnchorKeepsTheMapping() {
        let anchorHead = SpatialPose(position: SpatialVector(0.4, 1.6, -0.2), rotation: SpatialQuaternion(yaw: 0.8, pitch: 0))
        var mapper = XRInputMapper(pointer: .eyes, stereo: false)
        mapper.anchor(at: anchorHead)
        let anchor = mapper.anchor!
        let headStage = SpatialPose(position: SpatialVector(0.03, 0.01, 0), rotation: SpatialQuaternion(yaw: 0.1, pitch: 0))
        let head = anchor.fromStage(headStage)
        let hit = Self.selected(target: Self.target, head: head, anchorHead: anchorHead, camera: .identity)
        expectSame(hit, Self.pixel(Self.target, camera: .identity), "turned anchor")
    }

    /// The gaze is the wearer's, whichever eye: a gaze from either eye's place hits the target.
    @Test(arguments: [-0.032, 0.032])
    func eitherEyesOriginHitsTheTarget(offset: Double) {
        let head = SpatialPose.identity
        var mapper = XRInputMapper(pointer: .eyes, stereo: false)
        mapper.filterGaze = false
        mapper.anchor(at: head)
        let gaze = Self.look(from: SpatialVector(offset, 0, 0), at: Self.target)
        let out = mapper.map(XRTrackingSample(time: 0, head: head, gaze: gaze))
        let p = Self.hit(origin: out.selection.rayOrigin, direction: out.selection.rayDirection)
        #expect((p - Self.target).length < 0.002)
    }
}

@Suite struct XRFinalPictureTests {
    static let rule = XRFinalPictureRule(holdNanoseconds: 800_000_000, settleNanoseconds: 300_000_000)
    static let ms: UInt64 = 1_000_000

    /// The camera came to rest at 1000 ms and a picture of it is already final: a hover
    /// picture 100 ms later shows at once, not 800 ms after the head rested.
    @Test func aHoverAfterAFinalPictureIsFinalAtOnce() {
        let t = 1_100 * Self.ms
        #expect(Self.rule.isFinal(uploadedAt: t, commandedAt: 1_000 * Self.ms, now: t, finalFor: 1_000 * Self.ms, sweeping: false))
    }

    @Test func aPictureRightAfterAMoveIsNotFinal() {
        let t = 1_100 * Self.ms
        #expect(!Self.rule.isFinal(uploadedAt: t, commandedAt: 1_000 * Self.ms, now: t, finalFor: 500 * Self.ms, sweeping: false))
        // …until it has been quiet, or arrived after the hold.
        #expect(Self.rule.isFinal(uploadedAt: t, commandedAt: 1_000 * Self.ms, now: t + 300 * Self.ms, finalFor: 500 * Self.ms, sweeping: false))
        let late = 1_800 * Self.ms
        #expect(Self.rule.isFinal(uploadedAt: late, commandedAt: 1_000 * Self.ms, now: late, finalFor: 500 * Self.ms, sweeping: false))
    }

    /// A slow guest during a sweep: the last stop's picture never counts for this stop.
    @Test func aSweepStopNeverTakesTheLastStopsPicture() {
        let old = 900 * Self.ms, commanded = 1_000 * Self.ms
        #expect(!Self.rule.isFinal(uploadedAt: old, commandedAt: commanded, now: commanded + 2_400 * Self.ms, finalFor: 500 * Self.ms, sweeping: true))
        #expect(Self.rule.isFinal(uploadedAt: old, commandedAt: commanded, now: commanded + 1_600 * Self.ms, finalFor: 500 * Self.ms, sweeping: false))
    }
}
