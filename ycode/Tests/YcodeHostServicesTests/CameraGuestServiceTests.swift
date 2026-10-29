import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel
@testable import YcodeHostServices

/// The guest-facing camera endpoint `dev.ycode.camera` (camera.md "Ycode
/// implementation"), driven by second host tasks acting as guest processes
/// of Ycode's capture layer, with the synthetic camera: the device list,
/// streams, frame flow control, time conversion, one process at a time, a
/// client's end; and the opt-in, the app rule and the privacy rows.
@Suite(.serialized) struct CameraGuestServiceTests {
    typealias P = CameraGuestProtocol

    final class Rig {
        let system = DarwinSystem()
        let surfaces: IOSurfaceHostService
        let service: CameraGuestService

        init(placement: CameraGuestPresentation.Placement = .back, ring: Int = 8) throws {
            surfaces = try IOSurfaceHostService(host: system.hostTask, log: { _ in })
            service = try CameraGuestService(host: system.hostTask, surfaces: surfaces, selection: "synthetic",
                                             presentation: CameraGuestPresentation(placement: placement), log: { _ in })
            service.ringSize = ring
            // A guest clock 1000 s ahead of the host's, at 24 MHz.
            service.setGuestClock { (MachTimebase.hostMonotonicNanoseconds() / 1000 * 24 + 24_000_000_000, 24_000_000) }
            service.start()
        }

        deinit { service.stop() }

        func client(pid: Int32) throws -> Client { try Client(rig: self, pid: pid) }
    }

    final class Client {
        let guest: MachHostTask
        let server: UInt32
        let reply: UInt32
        let frames: UInt32

        init(rig: Rig, pid: Int32) throws {
            let system = rig.system
            guest = system.lock.withLock { MachHostTask(lock: system.lock, system: system.mach, log: { _ in }) }
            guest.pid = pid
            server = try system.hostTask.give(rig.service.servicePort, disposition: MachMsgType.copySend, to: guest.ipc)
            reply = try guest.makePort()
            frames = try guest.makePort(qlimit: 16)
        }

        func call(_ n: Int32, _ words: [UInt32], descriptors: [MachHostDescriptor] = []) throws -> MachHostReceivedMessage {
            try guest.send(MachHostOutgoingMessage(remotePort: server, localPort: reply, localDisposition: MachMsgType.makeSendOnce,
                                                   id: P.base + n, descriptors: descriptors, body: P.body(words)))
            let m = try guest.receive(on: reply, timeout: 10_000_000_000)
            #expect(m.id == P.base + 100 + n)
            return m
        }

        func start(width: Int = 640, height: Int = 480, fps: Double = 30, format: CameraPixelFormat = .biPlanar420Video)
            throws -> [UInt32] {
            let m = try call(P.Request.start, [0, UInt32(width), UInt32(height), UInt32(fps * 1000), format.rawValue, 0],
                             descriptors: [.port(name: frames, disposition: MachMsgType.makeSend)])
            return (0..<6).map { P.word(m.body, $0) }
        }

        func stop(_ stream: UInt32) throws -> UInt32 { P.word(try call(P.Request.stop, [stream]).body, 0) }

        func release(_ stream: UInt32, slot: UInt32, sequence: UInt64) throws {
            try guest.send(MachHostOutgoingMessage(remotePort: server, id: P.base + P.Request.release,
                                                   body: P.body([stream, slot] + P.split(sequence))))
        }

        /// The next message on the frame port (nil on time-out).
        func next(_ seconds: Double = 3) -> MachHostReceivedMessage? {
            try? guest.receive(on: frames, timeout: UInt64(seconds * 1e9))
        }

        func nextFrame(_ seconds: Double = 3) -> Frame? {
            while let m = next(seconds) {
                if m.id == P.base + P.ToClient.frame { return Frame(m.body) }
            }
            return nil
        }
    }

    struct Frame {
        var stream: UInt32, sequence: UInt64, surface: UInt32, slot: UInt32, width: UInt32, height: UInt32, format: UInt32
        var dropped: UInt32, flags: UInt32, pts: UInt64, duration: UInt64
        init(_ b: [UInt8]) {
            let w = { P.word(b, $0) }
            stream = w(0)
            sequence = P.join(w(1), w(2))
            (surface, slot, width, height, format, dropped, flags) = (w(3), w(4), w(6), w(7), w(8), w(9), w(10))
            pts = P.join(w(11), w(12))
            duration = P.join(w(13), w(14))
        }
    }

    func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            usleep(5000)
        }
        return condition()
    }

    // MARK: Devices

    @Test func deviceListShowsOneCamera() throws {
        let rig = try Rig()
        let c = try rig.client(pid: 501)
        let m = try c.call(P.Request.devices, [P.version])
        #expect(m.descriptors.count == 1)
        guard case let .ool(data, _, _)? = m.descriptors.first else { Issue.record("no OOL"); return }
        #expect(P.word(m.body, 0) == UInt32(data.count))
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(data), format: nil) as? [String: Any])
        let devices = try #require(plist["devices"] as? [[String: Any]])
        #expect(devices.count == 1)
        let d = devices[0]
        #expect(d["localizedName"] as? String == "Back Camera")
        #expect(d["deviceType"] as? String == "AVCaptureDeviceTypeBuiltInWideAngleCamera")
        #expect(d["position"] as? Int == 1)
        #expect(d["uniqueID"] as? String == "dev.ycode.camera.back:synthetic")
        #expect(d["modelID"] as? String == "Ycode Synthetic Camera")
        let sizes = (d["formats"] as? [[String: Any]] ?? []).map { "\($0["width"]!)x\($0["height"]!)" }
        #expect(sizes == ["640x480", "1280x720", "1920x1080"])
        let first = try #require((d["formats"] as? [[String: Any]])?.first)
        #expect(first["maxFrameRate"] as? Double == 60 && first["minFrameRate"] as? Double == 15)
    }

    @Test func padPlacementIsExternal() throws {
        let p = CameraGuestPresentation(placement: .external)
        #expect(p.deviceType == "AVCaptureDeviceTypeExternal" && p.position == 0)
        #expect(p.localizedName(hostName: "HD Webcam C615") == "HD Webcam C615")
        #expect(CameraGuestPresentation(placement: .front).position == 2)
    }

    @Test func formatListKeepsPreferredSizes() {
        func size(_ w: Int, _ h: Int, _ fps: [Double]) -> CameraFrameSize {
            CameraFrameSize(width: w, height: h, intervals: fps.map { CameraFrameInterval(fps: $0) })
        }
        // The C615's shape (camera-host.md §2.4): YUYV slow at large sizes, MJPEG 30 everywhere.
        let d = CameraDevice(id: "v4l2:x", kind: .v4l2, name: "Cam", path: "/dev/video0", driver: "uvcvideo", busInfo: "x", formats: [
            CameraFormatDescription(format: .yuyv, name: "YUYV", sizes: [size(640, 480, [30, 5]), size(1280, 720, [10, 5]), size(1920, 1080, [5])]),
            CameraFormatDescription(format: .mjpeg, name: "MJPG", sizes: [size(640, 480, [30, 5]), size(1280, 720, [30, 5]),
                                                                       size(1920, 1080, [30, 5]), size(800, 600, [30])]),
            CameraFormatDescription(format: CameraSourceFormat("H264"), name: "H.264", sizes: [size(3840, 2160, [30])]),
        ])
        let list = CameraGuestFormats.list(for: d)
        #expect(list.map { "\($0.width)x\($0.height)" } == ["640x480", "1280x720", "1920x1080"])
        #expect(list.allSatisfy { $0.maxFPS == 30 && $0.minFPS == 5 })
    }

    // MARK: Streams

    @Test func streamDeliversFramesOnTheGuestClock() throws {
        let rig = try Rig()
        let c = try rig.client(pid: 502)
        let r = try c.start(width: 640, height: 480, fps: 30, format: .bgra)
        #expect(r[0] == P.Status.ok && r[1] != 0)
        #expect(r[2] == 640 && r[3] == 480 && r[5] == CameraPixelFormat.bgra.rawValue)
        var last: Frame?
        for k in 0..<6 {
            guard let f = c.nextFrame() else { Issue.record("no frame \(k)"); return }
            #expect(f.stream == r[1] && f.width == 640 && f.height == 480 && f.format == CameraPixelFormat.bgra.rawValue)
            #expect(f.flags & P.flagSynthetic != 0)
            #expect(rig.surfaces.surface(id: f.surface)?.pixelFormat == CameraPixelFormat.bgra.rawValue)
            // Guest ticks: about 1000 s ahead of host time at 24 MHz; 1/30 s apart.
            let hostNs = MachTimebase.hostMonotonicNanoseconds()
            let nowTicks = hostNs / 1000 * 24 + 24_000_000_000
            #expect(f.pts <= nowTicks && nowTicks - f.pts < 24_000_000)
            #expect((799_999...800_000).contains(f.duration))
            if let last {
                #expect(f.sequence == last.sequence + 1)
                #expect(f.pts > last.pts)
            }
            try c.release(f.stream, slot: f.slot, sequence: f.sequence)
            last = f
        }
        #expect(waitFor(2) { rig.service.heldFrames <= 1 })
        #expect(try c.stop(r[1]) == P.Status.ok)
        #expect(waitFor(2) { !rig.service.isStreaming })
        #expect(try c.stop(r[1]) == P.Status.badRequest)
    }

    @Test func heldFramesStopTheRingUntilReleased() throws {
        let rig = try Rig(ring: 3)
        let c = try rig.client(pid: 503)
        let r = try c.start()
        #expect(r[0] == P.Status.ok)
        var held: [Frame] = []
        for _ in 0..<3 { if let f = c.nextFrame() { held.append(f) } }
        #expect(held.count == 3)
        #expect(Set(held.map(\.surface)).count == 3)
        // Every surface is held: nothing more arrives.
        #expect(c.nextFrame(0.4) == nil)
        #expect(rig.service.heldFrames == 3)
        try c.release(held[0].stream, slot: held[0].slot, sequence: held[0].sequence)
        let f = try #require(c.nextFrame())
        #expect(f.surface == held[0].surface)
        #expect(f.dropped > 0)
        _ = try c.stop(r[1])
    }

    @Test func secondProcessInterruptsTheFirst() throws {
        let rig = try Rig()
        let a = try rig.client(pid: 601), b = try rig.client(pid: 602)
        let ra = try a.start()
        let fa = try #require(a.nextFrame())
        try a.release(fa.stream, slot: fa.slot, sequence: fa.sequence)
        let rb = try b.start(width: 1280, height: 720)
        #expect(rb[0] == P.Status.ok && rb[1] != ra[1] && rb[2] == 1280)
        // A hears that it was interrupted, then nothing.
        var events: [UInt32] = []
        while let m = a.next(0.5) {
            if m.id == P.base + P.ToClient.event { events.append(P.word(m.body, 1)) }
        }
        #expect(events == [P.EventKind.interrupted])
        let fb = try #require(b.nextFrame())
        #expect(fb.stream == rb[1] && fb.width == 1280)
        try b.release(fb.stream, slot: fb.slot, sequence: fb.sequence)
        #expect(rig.service.activeStreamID == rb[1])
        // B stops: A gets the camera back.
        #expect(try b.stop(rb[1]) == P.Status.ok)
        var resumed = false, frame: Frame?
        while let m = a.next(), frame == nil {
            if m.id == P.base + P.ToClient.event, P.word(m.body, 1) == P.EventKind.interruptionEnded { resumed = true }
            if m.id == P.base + P.ToClient.frame { frame = Frame(m.body) }
        }
        #expect(resumed)
        #expect(frame?.stream == ra[1] && frame?.width == 640)
        _ = try a.stop(ra[1])
    }

    @Test func aClientsEndStopsItsStream() throws {
        let rig = try Rig()
        let c = try rig.client(pid: 701)
        let r = try c.start()
        #expect(r[0] == P.Status.ok)
        _ = try #require(c.nextFrame())
        #expect(rig.service.isStreaming)
        // The process ends: its frame port goes.
        try c.guest.destroyPort(c.frames)
        #expect(waitFor(3) { !rig.service.isStreaming && rig.service.activeStreamID == nil })
    }

    @Test func badStartsAreRefused() throws {
        let rig = try Rig()
        let c = try rig.client(pid: 801)
        // Device 1 does not exist; 'yuvs' is not an output format.
        var m = try c.call(P.Request.start, [1, 640, 480, 30000, CameraPixelFormat.biPlanar420Video.rawValue, 0],
                           descriptors: [.port(name: c.frames, disposition: MachMsgType.makeSend)])
        #expect(P.word(m.body, 0) == P.Status.badRequest)
        m = try c.call(P.Request.start, [0, 640, 480, 30000, 0x7975_7673, 0],
                       descriptors: [.port(name: c.frames, disposition: MachMsgType.makeSend)])
        #expect(P.word(m.body, 0) == P.Status.badRequest)
        // No frame port.
        m = try c.call(P.Request.start, [0, 640, 480, 30000, CameraPixelFormat.biPlanar420Video.rawValue, 0])
        #expect(P.word(m.body, 0) == P.Status.badRequest)
        #expect(!rig.service.isStreaming)
    }

    // MARK: Time

    @Test func hostTimesBecomeGuestTicks() {
        let t = CameraGuestTime(hostNanoseconds: 5_000_000_000, guestTicks: 1_000_000, frequency: 24_000_000)
        #expect(t.ticks(atHostNanoseconds: 5_000_000_000) == 1_000_000)
        #expect(t.ticks(atHostNanoseconds: 5_001_000_000) == 1_024_000)
        #expect(t.ticks(atHostNanoseconds: 4_999_000_000) == 976_000)
        // Before the guest's clock began: 0, not a wrap.
        #expect(t.ticks(atHostNanoseconds: 1_000_000_000) == 0)
        #expect(t.ticks(forNanoseconds: 33_333_333) == 799_999)
        // A 1 GHz guest timebase and a long uptime do not overflow.
        let g = CameraGuestTime(hostNanoseconds: 1 << 50, guestTicks: 1 << 52, frequency: 1_000_000_000)
        #expect(g.ticks(atHostNanoseconds: (1 << 50) + 7) == (1 << 52) + 7)
    }

    // MARK: Opt-in

    @Test func optInParsesPersistsAndDefaultsOff() throws {
        #expect(CameraOptIn.mode("on") == .on && CameraOptIn.mode("off") == .off && CameraOptIn.mode("synthetic") == .synthetic)
        #expect(CameraOptIn.mode("/dev/video2") == .device("/dev/video2") && CameraOptIn.mode("v4l2:usb-1") == .device("v4l2:usb-1"))
        #expect(CameraOptIn.mode("bogus") == nil)
        #expect(CameraOptIn(mode: .on).selection == "auto" && CameraOptIn.off.selection == nil)
        let dev = NSTemporaryDirectory() + "camg-optin-\(getpid())"
        try FileManager.default.createDirectory(atPath: dev, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dev) }
        #expect(CameraOptIn.load(dev: dev) == .off)
        try CameraOptIn(mode: .device("/dev/video0"), placement: .front).save(dev: dev)
        #expect(CameraOptIn.load(dev: dev) == CameraOptIn(mode: .device("/dev/video0"), placement: .front))
        try CameraOptIn.off.save(dev: dev)
        #expect(!CameraOptIn.load(dev: dev).isOn)
        #expect(CameraOptIn(mode: .on).placement(isPad: true) == .external && CameraOptIn(mode: .on).placement(isPad: false) == .back)
    }

    @Test func capabilitiesFollowTheSwitch() {
        let base: [String: Any] = ["capabilities": ["still-camera": true, "microphone": true]]
        let off = CameraOptIn.off.applyCapabilities(base, isPad: false)
        #expect((off["capabilities"] as? [String: Any])?.count == 2)
        let caps = CameraOptIn(mode: .on).applyCapabilities(base, isPad: false)["capabilities"] as? [String: Any] ?? [:]
        #expect(caps["rear-facing-camera"] as? Bool == true && caps["video-camera"] as? Bool == true)
        #expect(caps["camera-flash"] as? Bool == false && caps["microphone"] as? Bool == true)
        let front = CameraOptIn(mode: .on, placement: .front).applyCapabilities(base, isPad: false)["capabilities"] as? [String: Any]
        #expect(front?["front-facing-camera"] as? Bool == true && front?["rear-facing-camera"] == nil)
    }

    @Test func onlyAppsGetTheCaptureLayer() {
        #expect(CameraAppInjection.isAppExecutable("/dev/data/Containers/Bundle/Application/ABC/Probe.app/Probe"))
        #expect(CameraAppInjection.isAppExecutable("/rt/Applications/MobileSafari.app/MobileSafari"))
        #expect(CameraAppInjection.isAppExecutable("/dev/data/Containers/Bundle/Application/ABC/Probe.app/PlugIns/W.appex/W"))
        #expect(!CameraAppInjection.isAppExecutable("/rt/System/Library/CoreServices/SpringBoard.app/SpringBoard"))
        #expect(!CameraAppInjection.isAppExecutable("/rt/usr/libexec/tccd"))
        let lib = "/dev/ycode-camera/libYcodeCamera.dylib"
        var env = CameraAppInjection.environment(["HOME=/x", "DYLD_INSERT_LIBRARIES=/a.dylib"], library: lib)
        #expect(env == ["HOME=/x", "DYLD_INSERT_LIBRARIES=/a.dylib:" + lib, "YCODE_CAMERA_SERVICE=dev.ycode.camera"])
        env = CameraAppInjection.environment(env, library: lib)
        #expect(env.filter { $0.hasPrefix("DYLD_INSERT_LIBRARIES=") } == ["DYLD_INSERT_LIBRARIES=/a.dylib:" + lib])
        #expect(env.filter { $0.hasPrefix("YCODE_CAMERA_SERVICE=") }.count == 1)
        #expect(CameraAppInjection.environment(["HOME=/x"], library: lib).contains("DYLD_INSERT_LIBRARIES=" + lib))
    }

    // MARK: Privacy

    @Test func privacyRowsFollowTheActions() throws {
        let dev = NSTemporaryDirectory() + "camg-tcc-\(getpid())"
        try FileManager.default.createDirectory(atPath: dev + "/data/Library/TCC", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dev) }
        #expect(throws: CameraPrivacy.Failure.self) { try CameraPrivacy.apply(.grant, service: "camera", bundleID: "a.b", dev: dev) }
        // A table with the columns of camera.md §6.2 (Ycode's test schema).
        let db = try CameraPrivacy.SQLite(path: CameraPrivacy.databasePath(dev: dev), create: true)
        try db.exec("CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL, "
            + "auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, "
            + "last_modified INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (service, client, client_type))")
        db.close()
        try CameraPrivacy.apply(.grant, service: "camera", bundleID: "dev.ycode.it's", dev: dev)
        #expect(try CameraPrivacy.authValue(service: "camera", bundleID: "dev.ycode.it's", dev: dev) == 2)
        try CameraPrivacy.apply(.revoke, service: "camera", bundleID: "dev.ycode.it's", dev: dev)
        #expect(try CameraPrivacy.authValue(service: "camera", bundleID: "dev.ycode.it's", dev: dev) == 0)
        try CameraPrivacy.apply(.grant, service: "microphone", bundleID: "dev.ycode.it's", dev: dev)
        try CameraPrivacy.apply(.reset, service: "camera", bundleID: "dev.ycode.it's", dev: dev)
        #expect(try CameraPrivacy.authValue(service: "camera", bundleID: "dev.ycode.it's", dev: dev) == nil)
        #expect(try CameraPrivacy.authValue(service: "microphone", bundleID: "dev.ycode.it's", dev: dev) == 2)
        let rows = try CameraPrivacy.SQLite(path: CameraPrivacy.databasePath(dev: dev))
        defer { rows.close() }
        #expect(try rows.query("SELECT service, client_type, auth_reason, auth_version FROM access")
            == [["kTCCServiceMicrophone", "0", "4", "1"]])
        #expect(throws: CameraPrivacy.Failure.self) { try CameraPrivacy.apply(.grant, service: "photos", bundleID: "a.b", dev: dev) }
    }
}
