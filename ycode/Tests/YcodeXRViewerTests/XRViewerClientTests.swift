// The headset viewer without a headset (specs/simulator/xr-viewer.md §7,
// §9): the stream client's per-view canvases, the options, and a recorded
// tracking script driving the viewer against an in-memory server.

import CYcodeCodec
import CYcodeOpenXR
import CYcodeVideo
import Foundation
import Testing
import YcodeDisplayStream
@testable import YcodeRemoteViewer
@testable import YcodeXRViewer

/// A transport whose incoming bytes are given and whose outgoing bytes are kept.
final class MemoryTransport: DisplayTransport, @unchecked Sendable {
    private let cond = NSCondition()
    private var incoming: [[UInt8]] = []
    private var closed = false
    private(set) var sent: [UInt8] = []

    func push(_ m: DisplayMessage) { cond.withLock { incoming.append(m.encoded()); cond.broadcast() } }
    func send(_ bytes: [UInt8]) throws { cond.withLock { sent += bytes } }
    func receive(max: Int) -> [UInt8]? {
        cond.withLock {
            while incoming.isEmpty && !closed { cond.wait() }
            return incoming.isEmpty ? nil : incoming.removeFirst()
        }
    }
    func close() { cond.withLock { closed = true; cond.broadcast() } }

    /// Every message the client sent so far.
    func sentMessages() throws -> [DisplayMessage] {
        var p = DisplayMessageParser()
        p.append(cond.withLock { sent })
        var out: [DisplayMessage] = []
        while let m = try p.next() { out.append(m) }
        return out
    }
}

private func wait(_ what: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while !what() { if Date() > deadline { return false }; Thread.sleep(forTimeInterval: 0.01) }
    return true
}

private func zlibFrame(sequence: UInt64, value: UInt8, width: Int = 8, height: Int = 4) -> DisplayFrame? {
    let px = [UInt8](repeating: value, count: width * height * 4)
    var cap = ycodec_zlib_bound(px.count)
    var z = [UInt8](repeating: 0, count: cap)
    guard ycodec_zlib_compress(px, px.count, 6, &z, &cap) == 0 else { return nil }
    return DisplayFrame(sequence: sequence, guestFrame: sequence, serverNanoseconds: 0, inputSequence: 0, width: width, height: height,
                        encoding: .zlibBGRA, isFull: true, tiles: [DisplayTile(x: 0, y: 0, width: width, height: height, data: Array(z.prefix(cap)))])
}

private func visionHello() -> DisplayServerHello {
    var h = DisplayServerHello(deviceName: "Vision", model: "RealityDevice", pixelWidth: 3840, pixelHeight: 2160, scale: 2,
                               encodings: ["zlib"], touch: true, keyboard: true, buttons: ["home"], rotation: false)
    h.spatial = true
    h.xr = true
    return h
}

@Suite struct XRStreamClientTests {
    @Test func taggedFramesLandInTheirViewsCanvas() throws {
        guard ycodec_zlib_available() != 0 else { return }
        let t = MemoryTransport()
        let client = DisplayStreamClient(settings: XRViewerOptions().hello) { t }
        client.reconnects = false
        let frames = FrameLog()
        client.onEvent = { if case .frame(let f) = $0 { frames.add(f) } }
        client.start()
        defer { client.stop(); t.close() }
        t.push(.hello(visionHello()))
        let fov = XRFieldOfView.guest(width: 8, height: 4)
        t.push(.frameView(XRFrameView(frameSequence: 1, view: .left, latch: 2, poseSequence: 3, pose: .identity, fov: fov, guestFrame: 1)))
        t.push(.frame(try #require(zlibFrame(sequence: 1, value: 0x20))))
        t.push(.frameView(XRFrameView(frameSequence: 2, view: .right, latch: 2, poseSequence: 4, pose: .identity, fov: fov, guestFrame: 2)))
        t.push(.frame(try #require(zlibFrame(sequence: 2, value: 0x80))))
        // An untagged frame (and a tag for another frame) go to the mono canvas.
        t.push(.frameView(XRFrameView(frameSequence: 99, view: .left, latch: 2, poseSequence: 5, pose: .identity, fov: fov, guestFrame: 3)))
        t.push(.frame(try #require(zlibFrame(sequence: 3, value: 0xF0))))
        #expect(wait { frames.count == 3 })
        let got = frames.all
        #expect(got.map { $0.view?.view } == [.left, .right, nil])
        #expect(got[0].view?.poseSequence == 3)
        func first(_ v: XRView) -> UInt8? { client.canvas(for: v)?.withPixels { b, _, _ in b.load(as: UInt8.self) } }
        #expect(first(.left) == 0x20 && first(.right) == 0x80 && first(.mono) == 0xF0)
    }
}

final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [ReceivedFrame] = []
    func add(_ f: ReceivedFrame) { lock.withLock { frames.append(f) } }
    var count: Int { lock.withLock { frames.count } }
    var all: [ReceivedFrame] { lock.withLock { frames } }
}

@Suite struct XRFlowAndPlainPathTests {
    /// The client acknowledges what it decoded, when it asked for a window and the server honours one.
    @Test func framesAreAcknowledged() throws {
        for (window, serverAcks, expected) in [(3, true, true), (0, true, false), (3, false, false)] {
            var o = XRViewerOptions()
            o.frameWindow = window
            let transport = MemoryTransport()
            var hello = visionHello()
            hello.frameAcks = serverAcks ? true : nil
            let client = DisplayStreamClient(settings: o.hello(problem: { _ in nil })) { transport }
            client.reconnects = false
            let got = XRFlag()
            client.onEvent = { if case .frame = $0 { got.set() } }
            client.start()
            transport.push(.hello(hello))
            transport.push(.frame(try #require(zlibFrame(sequence: 7, value: 1))))
            #expect(wait { got.isSet })
            // The ack goes out right after the frame event.
            Thread.sleep(forTimeInterval: 0.05)
            let acks = try transport.sentMessages().compactMap { m -> UInt64? in if case .frameAck(let s) = m { return s } else { return nil } }
            #expect(acks == (expected ? [7] : []))
            client.stop()
        }
    }

    @Test func theHelloAsksForTheWindow() {
        #expect(XRViewerOptions().hello(problem: { _ in nil }).frameWindow == 3)
        var o = XRViewerOptions()
        o.frameWindow = 0
        #expect(o.hello(problem: { _ in nil }).frameWindow == nil)
    }

    /// The plain path uploads each view's newest picture once, and only a new one.
    @Test func thePlainPathTakesTheNewestPictureOnce() throws {
        final class CountingSink: XRPictureSink {
            var uploads: [(Int, Int, Int)] = []
            func upload(eye: Int, pixels: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) throws { uploads.append((eye, width, height)) }
            func uploadNV12(eye: Int, y: UnsafePointer<UInt8>, uv: UnsafePointer<UInt8>, pitch: Int, width: Int, height: Int) throws { Issue.record("no video here") }
            func uploadYUV444(eye: Int, y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>, pitch: Int, width: Int, height: Int) throws { Issue.record("no video here") }
        }
        var o = XRViewerOptions()
        o.connect = "unix:/nowhere"
        o.reproject = false
        let transport = MemoryTransport()
        let viewer = XRViewer(options: o, connect: { transport }, log: { _ in })
        viewer.client.reconnects = false
        viewer.client.start()
        transport.push(.hello(visionHello()))
        let path = XRPlainPath(), sink = CountingSink()
        func view(_ sequence: UInt64) -> XRFrameView {
            XRFrameView(frameSequence: sequence, view: .mono, latch: 1, poseSequence: 1, pose: .identity, fov: .guest(width: 8, height: 4), guestFrame: sequence)
        }
        transport.push(.frameView(view(1)))
        transport.push(.frame(try #require(zlibFrame(sequence: 1, value: 10))))
        #expect(wait { viewer.board.get(.mono)?.sequence == 1 })
        path.update(viewer, into: sink, anchor: XRStageAnchor(), head: nil, ahead: 0, log: { _ in })
        path.update(viewer, into: sink, anchor: XRStageAnchor(), head: nil, ahead: 0, log: { _ in })
        #expect(sink.uploads.count == 1 && sink.uploads[0].0 == XRLayerPlan.monoSlot)
        transport.push(.frameView(view(2)))
        transport.push(.frame(try #require(zlibFrame(sequence: 2, value: 20))))
        #expect(wait { viewer.board.get(.mono)?.sequence == 2 })
        path.update(viewer, into: sink, anchor: XRStageAnchor(), head: nil, ahead: 0, log: { _ in })
        #expect(sink.uploads.count == 2)
        #expect(path.plan.layout()?.first?.shown.sequence == 2)
        viewer.client.stop()
    }

    /// The conversion that replaced the one-thread BGRX copy gives the same pixels, every format.
    @Test func theThreadedConversionMatchesTheReference() {
        let (w, h) = (97, 61)
        var y = [UInt8](repeating: 0, count: w * h), u = y, v = y
        for j in 0..<h { for i in 0..<w {
            y[j * w + i] = UInt8(16 + (i * 7 + j * 3) % 220); u[j * w + i] = UInt8((i * 5 + j) % 256); v[j * w + i] = UInt8((i + j * 9) % 256)
        } }
        var fast = [UInt8](repeating: 0, count: w * h * 4), reference = fast
        yxr_convert_yuv444(y, u, v, Int32(w), Int32(w), Int32(h), &fast, 1)
        yvid_yuv444_to_bgrx(y, u, v, Int32(w), Int32(w), Int32(h), &reference, w * 4)
        #expect(fast == reference)
        // Red first, for a swapchain that is not BGRA.
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        yxr_convert_yuv444(y, u, v, Int32(w), Int32(w), Int32(h), &rgba, 0)
        #expect(rgba[0] == fast[2] && rgba[2] == fast[0])
        // NV12.
        var uv = [UInt8](repeating: 128, count: w * (h / 2 + 1))
        for i in 0..<uv.count { uv[i] = UInt8((i * 3) % 256) }
        var n1 = [UInt8](repeating: 0, count: w * h * 4), n2 = n1
        yxr_convert_nv12(y, uv, Int32(w), Int32(w), Int32(h), &n1, 1)
        yvid_nv12_to_bgrx(y, uv, Int32(w), Int32(w), Int32(h), &n2, w * 4)
        #expect(n1 == n2)
    }
}

@Suite struct XRViewerOptionTests {
    @Test func parsesTheGazeOptions() {
        guard case .run(let o) = XRViewerOptions.parse(["--link", "d", "--gaze-dot", "--gaze-calibrate", "--gaze-filter", "oneeuro", "--gaze-cutoff", "5", "--gaze-snap", "1.5", "--gaze-deadband", "0.2",
                                                        "--gaze-hold", "200", "--gaze-time", "now", "--pinch-rewind", "0", "--pinch-freeze", "off", "--pinch-on", "2.5", "--pinch-off", "4", "--pinch-slop", "8",
                                                        "--hand-hold", "100", "--poke", "off", "--hold-band", "5,3", "--fresh-top", "0", "--frame-window", "0", "--upload", "bgrx"]) else {
            Issue.record("did not parse")
            return
        }
        #expect(o.gazeDot && o.gazeCalibrate && o.gaze.filter == .oneEuro && o.gaze.cutoffHz == 5 && o.gaze.snapDegrees == 1.5 && o.gaze.deadbandDegrees == 0.2)
        #expect(o.gaze.holdSeconds == 0.2 && o.gazeAtPresent && o.gaze.pinchRewindSeconds == 0 && !o.gaze.freezeDuringPinch)
        #expect(o.pinchOnCentimetres == 2.5 && o.pinchOffCentimetres == 4 && o.pinchSlopMillimetres == 8 && o.handHoldMs == 100 && !o.poke)
        #expect(o.holdBandDegrees == 5 && o.holdBandCentimetres == 3 && o.freshTopMs == 0 && o.frameWindow == 0 && o.uploadViaBGRX)
        // Into the mapper.
        let m = XRInputMapper(options: o)
        #expect(m.gazeSettings.filter == .oneEuro && m.pinchOn == 0.025 && m.pinchOff == 0.04 && m.pinchSlop == 0.008 && !m.poke)
    }

    @Test func theGazeDotIsOffByDefault() {
        guard case .run(let o) = XRViewerOptions.parse(["--link", "d"]) else { Issue.record("did not parse"); return }
        #expect(!o.gazeDot && !o.gazeCalibrate && o.gaze.filter == .fixation)
    }

    @Test func parsesTheOptions() {
        guard case .run(let o) = XRViewerOptions.parse(["--link", "vision", "--host", "thor", "--stereo", "mono", "--latch", "3",
                                                        "--pointer", "controller", "--palm", "--encoding", "zlib"]) else {
            Issue.record("did not parse"); return
        }
        #expect(o.linkDevice == "vision" && o.linkHost == "thor" && !o.stereo && o.latch == 3 && o.pointer == .controller && o.palmOrientation)
        // Depth and the environment are asked for unless --reproject off (xr-depth.md §7).
        var expected = XRClientRequest(stereo: "mono", latch: 3, depthDownscale: 4)
        expected.environment = true
        #expect(o.hello.xr == expected)
        guard case .run(let off) = XRViewerOptions.parse(["--link", "vision", "--reproject", "off"]) else { Issue.record("did not parse"); return }
        #expect(off.hello.xr?.depthDownscale == nil && off.hello.xr?.environment == nil)
        // Without re-projection the default is adaptive stereo; with it (the default), both eyes from one view, a sweep.
        #expect(off.stereoMode == "adaptive" && off.stereo && off.hello.xr?.stereo == "adaptive")
        guard case .run(let d) = XRViewerOptions.parse(["--link", "vision"]) else { Issue.record("did not parse"); return }
        #expect(d.synthStereo && !d.stereo && d.hello.xr?.stereo == "mono" && d.sweep && d.cacheFaceSize == 2048 && d.depthGridStep == 1)
        guard case .run(let a) = XRViewerOptions.parse(["--link", "vision", "--stereo", "adaptive", "--sweep", "off"]) else { Issue.record("did not parse"); return }
        #expect(a.stereo && a.hello.xr?.stereo == "adaptive" && a.hello.xr?.depthDownscale == 4 && !a.sweep)
        guard case .run(let synth) = XRViewerOptions.parse(["--link", "vision", "--stereo", "synth", "--depth", "2", "--cache", "0", "--environment", "off"]) else {
            Issue.record("did not parse"); return
        }
        #expect(synth.synthStereo && !synth.stereo && synth.hello.xr?.stereo == "mono" && synth.hello.xr?.depthDownscale == 2)
        #expect(synth.cacheFaceSize == 0 && synth.hello.xr?.environment == false)
        #expect(o.hello.encoding == "zlib" && o.hello.timing == true)
        guard case .exit(64, _) = XRViewerOptions.parse(["--stereo", "wobble"]) else { Issue.record("accepted a bad mode"); return }
        guard case .exit(64, _) = XRViewerOptions.parse([]) else { Issue.record("ran without a device"); return }
        guard case .run(let p) = XRViewerOptions.parse(["--probe"]), p.probe else { Issue.record("--probe needs no device"); return }
    }

    @Test func openXRIsReportedWhenMissing() {
        #if !os(Linux)
        let (ok, why) = XRSession.available()
        #expect(!ok && why.contains("Linux"))
        #endif
    }
}

@Suite struct XRReplayTests {
    /// A recorded script (head turning, the right hand pinching, the A
    /// button held for a recentre-length press) drives the viewer against a
    /// server that has the headset mode: views, selections with the pinch,
    /// and the crown's button with its timing go out.
    @Test func scriptDrivesViewsSelectionsAndCrown() throws {
        let t = MemoryTransport()
        var o = XRViewerOptions()
        o.connect = "unused"
        let viewer = XRViewer(options: o, connect: { t }, log: { _ in })
        viewer.client.reconnects = false
        viewer.client.start()
        defer { viewer.client.stop(); t.close() }
        t.push(.hello(visionHello()))
        #expect(wait { viewer.spatial && viewer.xrServer })
        var mapper = XRInputMapper()
        var poses = [SpatialPose](repeating: SpatialPose(position: SpatialVector(0.15, 1.3, -0.4)), count: 26)
        func sample(_ i: Int) -> XRTrackingSample {
            let t = Double(i) * 0.011
            let head = SpatialPose(position: SpatialVector(0, 1.6, 0), rotation: SpatialQuaternion(yaw: Double(i) * 0.01, pitch: 0))
            // Pinch from frame 10 to 20.
            poses[XRHandJoints.thumbTip] = SpatialPose(position: SpatialVector(0.15 + ((10..<20).contains(i) ? 0.01 : 0.06), 1.3, -0.4))
            let a = (30..<40).contains(i)
            return XRTrackingSample(time: t, head: head, hands: [nil, XRHandJoints(poses: poses)],
                                    controllers: [XRController(lowerButton: a), nil])
        }
        for i in 0..<50 {
            viewer.send(mapper.map(sample(i)))
            Thread.sleep(forTimeInterval: 0.002)
        }
        let sent = try t.sentMessages()
        var views = 0, pinchOn = false, pinchOff = false, buttons: [Bool] = []
        for m in sent {
            switch m {
            case .input(.views(_, let v)):
                views += 1
                #expect(v.stereo)
            case .input(.selection(_, let s)):
                if s.right?.pinching == true { pinchOn = true } else if pinchOn { pinchOff = true }
            case .input(.button(_, .home, let down)): buttons.append(down)
            default: break
            }
        }
        #expect(views == 50)
        #expect(pinchOn && pinchOff)
        #expect(buttons == [true, false])
    }

    @Test func olderServerGetsPosesInsteadOfViews() throws {
        let t = MemoryTransport()
        var o = XRViewerOptions()
        o.connect = "unused"
        let viewer = XRViewer(options: o, connect: { t }, log: { _ in })
        viewer.client.reconnects = false
        viewer.client.start()
        defer { viewer.client.stop(); t.close() }
        var h = visionHello()
        h.xr = nil
        t.push(.hello(h))
        #expect(wait { viewer.spatial })
        var mapper = XRInputMapper()
        viewer.send(mapper.map(XRTrackingSample(time: 0, head: SpatialPose(position: SpatialVector(0, 1.6, 0)))))
        let sent = try t.sentMessages()
        #expect(sent.contains { if case .input(.pose) = $0 { true } else { false } })
        #expect(!sent.contains { if case .input(.views) = $0 { true } else { false } })
    }
}
