import CYcodeCamera
import Foundation
import Testing
import YcodeDarwinKernel
@testable import YcodeHostServices
import YcodeXPC

/// The synthetic camera, negotiation, the surface ring, and the camera
/// service end to end (camera-host.md §3, §5–§7). The opt-in hardware test
/// (`YCODE_CAMERA_HW_TESTS=1` with a V4L2 camera attached) streams from the
/// real device.
@Suite(.serialized) struct CameraServiceTests {
    func surfaces() throws -> IOSurfaceHostService { try IOSurfaceHostService(host: DarwinSystem().hostTask, log: { _ in }) }

    final class Box<T>: @unchecked Sendable {
        let lock = NSLock()
        var items: [T] = []
        func add(_ v: T) { lock.withLock { items.append(v) } }
        var all: [T] { lock.withLock { items } }
    }

    func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            usleep(5000)
        }
        return condition()
    }

    // MARK: Synthetic camera

    @Test func syntheticFramesCountAndMove() throws {
        let cam = SyntheticCamera(width: 320, height: 240, interval: CameraFrameInterval(numerator: 1, denominator: 30), paced: false,
                                  firstFrame: 41, startTime: 1_000_000_000)
        #expect(cam.format.source == .yuyv && cam.format.colorimetry == .video601)
        var boxes: [Int] = []
        for k in 0..<3 {
            guard let f = try cam.next(timeoutMilliseconds: 0) else { Issue.record("no frame"); return }
            #expect(f.deviceSequence == UInt32(41 + k) && f.synthetic)
            // Presentation times: start + n x interval.
            #expect(f.timestamp == 1_000_000_000 + Int64(41 + k) * 33_333_333)
            let luma = { (x: Int, y: Int) in f.bytes[y * f.bytesPerLine + 2 * x] }
            #expect(SyntheticCamera.readCounter(width: 320, height: 240, luma: luma) == UInt32(41 + k))
            let box = SyntheticCamera.box(frame: UInt32(41 + k), width: 320, height: 240)
            #expect(luma(box.x + box.side / 2, box.y + box.side / 2) == 235)
            boxes.append(box.x)
            cam.recycle(f)
        }
        #expect(boxes[0] != boxes[1] && boxes[1] != boxes[2])
        // Bars: the second bar is 75 % yellow.
        guard let f = try cam.next(timeoutMilliseconds: 0) else { return }
        let yellow = SyntheticCamera.ycbcr(r: 191, g: 191, b: 0)
        let x = 320 / 8 + 21, y = 150  // below the box, inside the bars
        #expect(f.bytes[y * f.bytesPerLine + 2 * x] == yellow.y && f.bytes[y * f.bytesPerLine + 2 * (x & ~1) + 1] == yellow.cb)
        #expect(yellow.y == 161 && yellow.cb == 44 && yellow.cr == 142)
        cam.close()
        #expect(throws: CameraError.self) { _ = try cam.next(timeoutMilliseconds: 0) }
    }

    @Test func syntheticPacing() throws {
        let cam = SyntheticCamera(width: 64, height: 48, interval: CameraFrameInterval(numerator: 1, denominator: 50))
        let t0 = ycam_monotonic_ns()
        for _ in 0..<6 { _ = try cam.next(timeoutMilliseconds: 500) }
        let took = ycam_monotonic_ns() - t0
        #expect(took >= 90_000_000, "6 frames at 50 fps took \(took) ns")
    }

    // MARK: Negotiation

    /// A UVC webcam's table: YUYV up to 640x480 at 30 fps, 1280x720 at 10,
    /// 1920x1080 at 5; MJPEG everywhere at 30.
    var webcam: [CameraFormatDescription] {
        func sizes(_ list: [(Int, Int, [UInt32])]) -> [CameraFrameSize] {
            list.map { CameraFrameSize(width: $0.0, height: $0.1, intervals: $0.2.map { CameraFrameInterval(numerator: 1, denominator: $0) }) }
        }
        return [
            CameraFormatDescription(format: .yuyv, name: "YUYV", sizes: sizes([(640, 480, [30, 15, 5]), (320, 240, [30, 15]),
                                                                               (1024, 576, [15, 10]), (960, 720, [15, 10]),
                                                                               (1280, 720, [10, 5]), (1920, 1080, [5])])),
            CameraFormatDescription(format: CameraSourceFormat("H264"), name: "H.264", sizes: sizes([(1280, 720, [30])])),
            CameraFormatDescription(format: .mjpeg, name: "MJPEG", sizes: sizes([(640, 480, [30, 15]), (320, 240, [30]),
                                                                                 (1024, 576, [30]), (960, 720, [30]),
                                                                                 (1280, 720, [30, 15]), (1920, 1080, [30, 24])])),
        ]
    }

    @Test func negotiation() {
        func pick(_ w: Int, _ h: Int, _ fps: Double, only: CameraSourceFormat? = nil) -> String {
            guard let c = CameraNegotiation.choose(webcam, width: w, height: h, framesPerSecond: fps, only: only) else { return "none" }
            return "\(c.format) \(c.width)x\(c.height) \(c.interval)"
        }
        #expect(pick(1280, 720, 30) == "MJPG 1280x720 30 fps")
        #expect(pick(640, 480, 30) == "YUYV 640x480 30 fps")
        #expect(pick(640, 480, 15) == "YUYV 640x480 15 fps")  // the slowest interval that reaches the request
        #expect(pick(1280, 720, 10) == "YUYV 1280x720 10 fps")
        #expect(pick(1000, 700, 30) == "MJPG 1280x720 30 fps")  // the smallest size that covers the request
        #expect(pick(4000, 3000, 30) == "MJPG 1920x1080 30 fps")  // the largest
        #expect(pick(1920, 1080, 24) == "MJPG 1920x1080 24 fps")
        #expect(pick(1280, 720, 30, only: .yuyv) == "YUYV 1280x720 10 fps")
        #expect(pick(1280, 720, 30, only: CameraSourceFormat("H264")) == "none")
        #expect(CameraNegotiation.choose([], width: 640, height: 480, framesPerSecond: 30) == nil)
    }

    @Test func deviceSelection() throws {
        let cam = CameraDevice(id: "v4l2:usb-1", kind: .v4l2, name: "Cam", path: "/dev/video4", driver: "uvcvideo", busInfo: "usb-1",
                               formats: webcam)
        #expect(try CameraHostService.resolve("auto", devices: [SyntheticCamera.device, cam]).id == "v4l2:usb-1")
        #expect(try CameraHostService.resolve("auto", devices: [SyntheticCamera.device]).id == "synthetic")
        #expect(try CameraHostService.resolve("synthetic", devices: [cam]).id == "synthetic")
        #expect(try CameraHostService.resolve("/dev/video4", devices: [cam]).id == "v4l2:usb-1")
        #expect(try CameraHostService.resolve("v4l2:usb-1", devices: [cam]).path == "/dev/video4")
        #expect(throws: CameraError.self) { try CameraHostService.resolve("none", devices: [cam]) }
        #expect(throws: CameraError.self) { try CameraHostService.resolve("/dev/video9", devices: [cam]) }
    }

    // MARK: Surfaces and the ring

    @Test func hostSurfacesAnswerLikeGuestSurfaces() throws {
        let s = try surfaces()
        let layout = CameraSurfaceLayout.make(.biPlanar420Video, width: 640, height: 480)
        guard let made = s.makeHostSurface(width: 640, height: 480, pixelFormat: layout.format.rawValue, bytesPerElement: layout.bytesPerElement,
                                           bytesPerRow: layout.bytesPerRow, allocationSize: layout.allocationSize, planes: layout.planes,
                                           name: "cam 0", attachments: layout.attachments(.video601)) else {
            Issue.record("no surface")
            return
        }
        #expect(made.surface.width == 640 && made.surface.pixelFormat == 0x3432_3076 && made.surface.planes.count == 2)
        #expect(made.surface.planes[1].offset == layout.planes[1].offset)
        // A guest connection looks it up by ID.
        let conn: UInt32 = 0x2201
        s.addTestConnection(conn)
        let r = XPCDict(s.perform(["Method": .uint64(2), "LookupID": .uint64(UInt64(made.surface.id))], connection: conn).0
            .map { XPCDict.Entry(key: $0.0, value: $0.1) })
        guard case let .data(state)? = r["SurfaceState"] else { Issue.record("no state"); return }
        func u32(_ d: [UInt8], _ i: Int) -> UInt32 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self) } }
        #expect(u32(state, 1) == made.surface.id && u32(state, 3) == 640 && u32(state, 4) == 480 && u32(state, 7) == 0x3432_3076)
        #expect(u32(state, 9) == 2)  // plane count
        let p = XPCDict(s.perform(["Method": .uint64(6), "SurfaceID": .uint64(UInt64(made.surface.id)), "PlaneIndex": .uint64(1)],
                                  connection: conn).0.map { XPCDict.Entry(key: $0.0, value: $0.1) })
        guard case let .data(plane)? = p["PlaneState"] else { Issue.record("no plane state"); return }
        #expect(u32(plane, 1) == 320 && u32(plane, 2) == 240 && u32(plane, 3) == UInt32(layout.planes[1].offset) && u32(plane, 4) == 640)
        let a = XPCDict(s.perform(["Method": .uint64(21), "SurfaceID": .uint64(UInt64(made.surface.id))], connection: conn).0
            .map { XPCDict.Entry(key: $0.0, value: $0.1) })
        #expect(a["YCbCrMatrixIndex"]?.uint64Value == 6 && a["TransferFunctionIndex"]?.uint64Value == 1)
        // The host's writes raise the seed.
        #expect(s.hostDidWrite(id: made.surface.id) == 1 && s.hostDidWrite(id: made.surface.id) == 2)
        // Released by the host, it lives on while the guest references it.
        s.releaseHostSurface(port: made.port)
        #expect(s.surface(id: made.surface.id) != nil)
        _ = s.perform(["Method": .uint64(3), "SurfaceID": .uint64(UInt64(made.surface.id))], connection: conn)
        #expect(s.surface(id: made.surface.id) == nil)
    }

    @Test func ringSkipsBusySurfaces() throws {
        let s = try surfaces()
        let ring = try CameraSurfaceRing(surfaces: s, layout: CameraSurfaceLayout.make(.bgra, width: 64, height: 32), count: 3,
                                         name: "ring", colorimetry: .video601)
        let ids = ring.surfaceIDs
        #expect(ids.count == 3 && Set(ids).count == 3)
        // Round robin.
        var order: [Int] = []
        for _ in 0..<4 {
            guard let i = ring.acquire() else { Issue.record("no slot"); return }
            _ = ring.commit(i, hold: false)
            order.append(i)
        }
        #expect(order == [0, 1, 2, 0])
        // A held slot and a slot a guest uses (Method 15) are skipped.
        let held = ring.acquire()!
        _ = ring.commit(held, hold: true)
        #expect(held == 1)
        let conn: UInt32 = 0x3301
        s.addTestConnection(conn)
        _ = s.perform(["Method": .uint64(15), "SurfaceID": .uint64(UInt64(ids[2]))], connection: conn)
        #expect(s.guestUsage(id: ids[2])?.useCount == 1)
        let next = ring.acquire()
        #expect(next == 0)
        ring.cancel(next!)
        // Everything busy: no slot (the frame would be dropped).
        let a = ring.acquire()!
        #expect(a == 0)
        #expect(ring.acquire() == nil)
        ring.cancel(a)
        ring.release(held)
        _ = s.perform(["Method": .uint64(16), "SurfaceID": .uint64(UInt64(ids[2]))], connection: conn)
        #expect(ring.acquire() == 2)  // after the last written slot (1)
        ring.invalidate()
        #expect(s.surfaceSummary.isEmpty)
    }

    // MARK: The service

    @Test func syntheticStreamEndToEnd() throws {
        let s = try surfaces()
        let service = CameraHostService(surfaces: s)
        let frames = Box<(CameraFrame, UInt32?)>()
        let events = Box<CameraEvent>()
        let config = CameraConfiguration(width: 320, height: 240, framesPerSecond: 60, output: .biPlanar420Video, ringSize: 3)
        let format = try service.start(selection: "synthetic", configuration: config, onFrame: { f in
            // Read the counter strip back from the surface's luma plane.
            let info = s.surface(id: f.surfaceID)!
            let layout = CameraSurfaceLayout.make(f.format, width: f.width, height: f.height)
            let y = info.memory.host.assumingMemoryBound(to: UInt8.self)
            let n = SyntheticCamera.readCounter(width: f.width, height: f.height) { y[$1 * layout.planes[0].bytesPerRow + $0] }
            frames.add((f, n))
        }, onEvent: { events.add($0) })
        #expect(format.width == 320 && format.height == 240 && format.source == .yuyv && format.output == .biPlanar420Video)
        #expect(throws: CameraError.self) { try service.start(selection: "synthetic", onFrame: { _ in }) }
        #expect(waitFor(5) { frames.all.count >= 12 })
        service.stop()
        let got = frames.all
        #expect(got.count >= 12)
        for (i, (f, counter)) in got.enumerated() {
            #expect(f.sequence == UInt64(i) && f.synthetic && f.droppedBefore == 0)
            #expect(counter == f.deviceSequence, "frame \(i): counter \(String(describing: counter)) vs \(f.deviceSequence)")
            #expect(f.duration == 16_666_666)
            if i > 0 { #expect(f.presentationTime - got[i - 1].0.presentationTime == 16_666_666) }
            #expect(f.slot == i % 3)
        }
        #expect(events.all.first == .started(format) && events.all.last == .stopped)
        #expect(s.surfaceSummary.isEmpty, "surfaces left: \(s.surfaceSummary)")
        #expect(service.delivered >= 12 && service.dropped == 0)
    }

    /// A capture that reports the device gone after a few frames.
    final class VanishingCapture: CameraCapture, @unchecked Sendable {
        let inner = SyntheticCamera(width: 160, height: 120, interval: CameraFrameInterval(numerator: 1, denominator: 100), paced: true)
        let device = CameraDevice(id: "v4l2:test-vanishing", kind: .v4l2, name: "Vanishing", path: "/nonexistent/video0", driver: "test",
                                  busInfo: "test-vanishing", formats: [])
        var format: CameraStreamFormat { inner.format }
        var left = 3
        func next(timeoutMilliseconds: Int) throws -> CameraRawFrame? {
            if left == 0 { throw CameraError(.gone, "unplugged") }
            left -= 1
            guard var f = try inner.next(timeoutMilliseconds: timeoutMilliseconds) else { return nil }
            f.synthetic = false
            return f
        }
        func recycle(_ frame: CameraRawFrame) {}
        func close() { inner.close() }
    }

    @Test func unpluggedDeviceFallsBackToSynthetic() throws {
        let s = try surfaces()
        let service = CameraHostService(surfaces: s)
        let frames = Box<CameraFrame>()
        let events = Box<CameraEvent>()
        let capture = VanishingCapture()
        var config = CameraConfiguration(width: 160, height: 120, framesPerSecond: 100, ringSize: 2)
        config.syntheticWhileAbsent = true
        _ = try service.start(capture: capture, device: capture.device, configuration: config, auto: false,
                              onFrame: { frames.add($0) }, onEvent: { events.add($0) })
        #expect(waitFor(5) { frames.all.count >= 8 })
        service.stop()
        let got = frames.all
        #expect(got.prefix(3).allSatisfy { !$0.synthetic } && got.dropFirst(3).allSatisfy { $0.synthetic })
        #expect(events.all.contains(.disconnected(deviceID: "v4l2:test-vanishing", fallback: true)))
        #expect(got.map(\.sequence) == Array(0..<UInt64(got.count)))
        #expect(s.surfaceSummary.isEmpty)
    }

    @Test func heldFramesAreNotOverwritten() throws {
        let s = try surfaces()
        let service = CameraHostService(surfaces: s)
        let frames = Box<CameraFrame>()
        let config = CameraConfiguration(width: 64, height: 48, framesPerSecond: 200, output: .bgra, ringSize: 2,
                                         holdFramesUntilReleased: true)
        _ = try service.start(selection: "synthetic", configuration: config, onFrame: { frames.add($0) })
        // Nothing is released: two frames fill the ring, the rest are dropped.
        #expect(waitFor(3) { service.dropped >= 5 })
        #expect(frames.all.count == 2)
        service.release(frames.all[0])
        #expect(waitFor(3) { frames.all.count == 3 })
        let third = frames.all[2]
        #expect(third.slot == frames.all[0].slot && third.droppedBefore > 0)
        service.stop()
    }

    // MARK: Hardware (opt-in)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YCODE_CAMERA_HW_TESTS"] == "1"))
    func webcamStreams() throws {
        let devices = V4L2.devices().devices
        guard let device = devices.first else {
            Issue.record("YCODE_CAMERA_HW_TESTS=1 but no V4L2 capture device")
            return
        }
        #expect(!device.formats.isEmpty)
        for (config, label) in [(CameraConfiguration(width: 640, height: 480, framesPerSecond: 30, output: .bgra), "640x480"),
                                (CameraConfiguration(width: 1280, height: 720, framesPerSecond: 30), "1280x720")] {
            let s = try surfaces()
            let service = CameraHostService(surfaces: s)
            let frames = Box<CameraFrame>()
            let format = try service.start(selection: device.id, configuration: config, onFrame: { frames.add($0) })
            let arrived = waitFor(10) { frames.all.count >= 15 }
            service.stop()
            #expect(arrived, "\(label): \(frames.all.count) frames")
            let got = frames.all
            #expect(got.allSatisfy { !$0.synthetic && $0.width == format.width && $0.height == format.height })
            for i in got.indices.dropFirst() {
                #expect(got[i].presentationTime > got[i - 1].presentationTime)
                #expect(got[i].deviceSequence > got[i - 1].deviceSequence)
            }
            #expect(s.surfaceSummary.isEmpty)
        }
    }
}
