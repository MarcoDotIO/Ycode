import AppKit
import Foundation
import Testing
import YcodeDeviceModel
import YcodeDeviceUI
import YcodeDisplayStream
@testable import YcodeIDECore
@testable import YcodeUI

/// XR-HUB (`device-hub.md` §I.12): Device Hub's headset for a Vision Pro —
/// the onboarding's steps and Re-check against a stand-in viewer host, and
/// View in Headset → Back to Desktop against a stand-in launcher whose
/// "viewer" is a second connection to a stand-in display server that hands
/// the display over as `ycode-simd` does (one viewer at a time; the old
/// one gets the takeover notice). The device keeps running throughout. With
/// `YCODE_XR_HUB_SHOTS=<dir>` the onboarding's steps and the canvas are
/// written there as PNGs (drawn offscreen).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct HeadsetHubTests {
    /// The display server's handover, with a hello for a Vision Pro and one picture per connection.
    final class TakeoverServer: @unchecked Sendable {
        let path: String
        let listener: DisplayListener
        private let lock = NSLock()
        private var current: DisplayConnection?
        private(set) var accepted = 0
        private(set) var takeovers = 0
        /// Poses each connection sent, by its number (1 first).
        private var poses: [Int: [SpatialPose]] = [:]
        func poses(connection: Int) -> [SpatialPose] { lock.withLock { poses[connection] ?? [] } }

        init() throws {
            path = NSTemporaryDirectory() + "ycode-xrhub-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
            listener = try DisplayListener(address: .unix(path))
            let t = Thread { [self] in
                while let c = listener.accept() {
                    let old = lock.withLock { () -> DisplayConnection? in accepted += 1; defer { current = c }; return current }
                    if let old {
                        try? old.send(.notice(DisplayNotice.takenOver))
                        old.close()
                        lock.withLock { takeovers += 1 }
                    }
                    serve(c, number: lock.withLock { accepted })
                }
            }
            t.start()
        }

        var connections: (accepted: Int, takeovers: Int) { lock.withLock { (accepted, takeovers) } }

        func serve(_ c: DisplayConnection, number: Int) {
            Thread { [self] in
                var parser = DisplayMessageParser()
                while let b = c.receive() {
                    parser.append(b)
                    while let m = try? parser.next() {
                        if case .input(.pose(_, let p)) = m { lock.withLock { poses[number, default: []].append(p) } }
                    }
                }
            }.start()
            var h = DisplayServerHello(deviceName: "Apple Vision Pro", model: "RealityDevice14,1", pixelWidth: 3840, pixelHeight: 2160, scale: 2,
                                       encodings: ["zlib"], touch: true, keyboard: true, buttons: ["home"], rotation: false)
            h.deviceType = "vision-pro"
            h.osVersion = "visionOS 27.0"
            h.spatial = true
            h.xr = true
            try? c.send(.hello(h))
            try? c.send(.status(DisplayStatus(phase: "live", uptimeMilliseconds: 60_000, guestFrames: 1000)))
            // One 8 × 8 picture as zlib tiles: header, raw deflate, a trailer the viewer does not check.
            let px = Data([UInt8](repeating: 0x80, count: 8 * 8 * 4))
            let deflated = (try? (px as NSData).compressed(using: .zlib) as Data) ?? Data()
            let tile = DisplayTile(x: 0, y: 0, width: 8, height: 8, data: [0x78, 0x9C] + [UInt8](deflated) + [0, 0, 0, 0])
            try? c.send(.frame(DisplayFrame(sequence: 1, guestFrame: 1, serverNanoseconds: 0, inputSequence: 0, width: 8, height: 8,
                                            encoding: .zlibBGRA, isFull: true, tiles: [tile])))
        }

        func close() { listener.close(); unlink(path) }
    }

    /// The headset viewer: a second client of the server; streaming once it has the hello.
    final class StandInLauncher: HeadsetViewerLauncher, @unchecked Sendable {
        let path: String
        private let lock = NSLock()
        private var connection: DisplayConnection?
        private var hasHello = false
        private(set) var starts = 0, stops = 0
        init(path: String) { self.path = path }
        func start() async throws {
            let c = try DisplayConnection.connect(to: .unix(path))
            lock.withLock { connection = c; hasHello = false; starts += 1 }
            try c.send(.clientHello(DisplayClientHello(client: "stand-in headset")))
            Thread { [self] in
                var parser = DisplayMessageParser()
                while let b = c.receive() {
                    parser.append(b)
                    while let m = try? parser.next() { if case .hello = m { lock.withLock { hasHello = true } } }
                }
            }.start()
        }
        func state() async -> HeadsetViewerState {
            lock.withLock { HeadsetViewerState(phase: connection == nil ? .absent : hasHello ? .streaming : .waitingForHeadset) }
        }
        func stop() async {
            let c = lock.withLock { () -> DisplayConnection? in stops += 1; defer { connection = nil }; return connection }
            c?.close()
        }
    }

    struct Runner: HeadsetCommandRunner {
        var missingLoader = false
        func run(_ command: String) async -> HeadsetCommandResult {
            let ok = { (s: String) in HeadsetCommandResult(status: 0, output: s) }
            let answers: [(String, HeadsetCommandResult)] = [
                ("uname", ok("Linux")), ("vulkaninfo", ok("deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\ndeviceName = NVIDIA GeForce RTX 4060 Ti\n")),
                ("libopenxr_loader", missingLoader ? HeadsetCommandResult(status: 1) : ok("libopenxr_loader.so.1")),
                ("active_runtime.json", ok("{\"runtime\":{\"name\":\"WiVRn\"}}")), ("test -f", ok("")),
                ("wivrn-server --version", ok("WiVRn version 26.9")), ("pgrep", ok("1")), ("--help", ok("usage: ycode-xr-viewer --state-file")),
                ("command -v adb", ok("/usr/bin/adb")), ("ssh -o BatchMode=yes", ok("")), ("lsusb", ok("ID 2833:5018")),
                ("adb devices", ok("List of devices attached\nSERIAL device usb:1 model:Quest_Pro\n")),
                ("pm list packages", ok("package:org.meumeu.wivrn.github\n")), ("versionName", ok("versionName=26.9")),
                ("TRACKING.*granted", ok("com.oculus.permission.HAND_TRACKING: granted=true\ncom.oculus.permission.EYE_TRACKING: granted=true\n")),
                ("HeadsetConnected", ok("b true")), ("HandTracking", ok("b true")), ("EyeGaze", ok("b true")), ("SystemName", ok("s \"Meta Quest Pro\"")),
            ]
            return answers.first { command.contains($0.0) }?.1 ?? HeadsetCommandResult(status: 1)
        }
    }

    static let row = DeviceRow(name: "Apple Vision Pro (Ycode)", identifier: "tester@sim-host:/data/devices/vp", platform: "visionOS", osVersion: "27.0",
                               state: "Booted", model: "Apple Vision Pro, Ycode Simulator (Linux)", isAvailable: true, isYcodeRemote: true,
                               deviceTypeID: "vision-pro", deviceDirectory: "vp")

    /// Waits on the main actor's own time (README "Tests in a full run").
    func until(_ what: String, _ seconds: Double = 20, _ cond: () -> Bool) async {
        let ok = await waitUntil(seconds, cond)
        #expect(ok, "\(what)")
    }

    /// Writes the window as the window server draws it (glass needs that; a view's
    /// own cached drawing has none), placed off the screens and behind everything,
    /// so nothing on the owner's desktop changes. Falls back to the cached drawing.
    func shot(_ window: NSWindow, _ name: String) async {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_XR_HUB_SHOTS"], !dir.isEmpty else { return }
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let path = URL(fileURLWithPath: dir).appendingPathComponent("xr-hub-\(name).png").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 || !FileManager.default.fileExists(atPath: path), let v = window.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func makeHub(_ server: TakeoverServer, runner: Runner = Runner()) -> (DevicesController, NSWindow, StandInLauncher) {
        let t = TestDefaults("xr-hub")
        let hub = DevicesController(devices: [], simulators: [Self.row])
        hub.defaults = t.defaults
        var s = HeadsetSettings()
        s.viewerHost = "tester@workstation"
        hub.headsetSettings = s
        let launcher = StandInLauncher(path: server.path)
        hub.headset.makeRunner = { _ in runner }
        hub.headset.makeLauncher = { _, _ in launcher }
        hub.headset.route = { _ in .sshSocket(destination: "tester@sim-host", socket: "/data/display/vp.sock") }
        hub.makeDisplayLink = { r in RemoteDisplayLink(address: .unix(server.path), spec: .visionPro, name: r.name, os: "visionOS 27.0") }
        let w = hub.makeWindow()
        w.setContentSize(NSSize(width: 1100, height: 760))
        hub.select(row: 0)
        return (hub, w, launcher)
    }

    @Test func onboardingStepsAndRecheck() async throws {
        let server = try TakeoverServer()
        defer { server.close() }
        let (hub, w, _) = makeHub(server, runner: Runner(missingLoader: true))
        defer { hub.closeLinks(); w.close() }
        let setup = hub.presentHeadsetSetup()
        defer { setup.close() }
        await hub.checkHeadset().value
        #expect(hub.headset.report?.status == .notSetUp)
        #expect(hub.headsetStatus(for: Self.row) == .notSetUp)
        // The window opens on the first step with a problem.
        setup.show(hub.headset.report!.firstProblemStep)
        #expect(setup.step == .workstation)
        #expect(setup.shownChecks.first { $0.id == .openXRLoader }?.fix == .command("sudo apt install libopenxr-loader1"))
        await shot(setup.window!, "2-workstation-missing")
        // The user installs the loader and clicks Re-check.
        hub.headset.makeRunner = { _ in Runner() }
        await setup.recheck().value
        #expect(hub.headset.report?.status == .ready && hub.headsetStatus(for: Self.row) == .ready)
        for s in HeadsetSetupStep.allCases {
            setup.show(s)
            #expect(setup.shownChecks.allSatisfy { $0.state == .ok }, "\(s)")
            await shot(setup.window!, "\(s.rawValue + 1)-\(s.title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
        if #available(macOS 26, *) {
            // The control layer's glass: the panel, and Next tinted (the inactive window's captures draw it flat).
            #expect(setup.window?.contentView?.descendant(id: "headset-steps-panel") is NSGlassEffectView)
            #expect(setup.primaryButton.bezelStyle == .glass && setup.primaryButton.tintProminence == .primary)
        }
        setup.back()
        #expect(setup.step == .tracking)
        setup.next()
        #expect(setup.step == .connect)
        // The Settings tab's box shows the capsule.
        hub.selectInspectorTab(.settings)
        let status = w.contentView?.descendant(id: "headset-status") as? NSTextField
        #expect(status?.stringValue == "Ready")
    }

    @Test func viewInHeadsetThenBackToDesktop() async throws {
        let server = try TakeoverServer()
        defer { server.close() }
        let (hub, w, launcher) = makeHub(server)
        defer { hub.closeLinks(); w.close() }
        await until("the canvas is live") { hub.canvas.stateDescription == "live" }
        #expect(server.connections.accepted == 1)
        #expect(hub.headsetCommandTitle(for: Self.row) == "View in Headset" && hub.canvas.canPerform(.viewInHeadset))
        await shot(w, "canvas-desktop")
        // ⌃⌘H / the toolbar: View in Headset.
        hub.canvas.perform(.viewInHeadset)
        await until("in the headset") { hub.headsetSwitch(for: Self.row)?.state == .inHeadset }
        await until("the canvas waits") { hub.canvas.stateDescription == "in headset" }
        #expect(server.connections == (2, 1) && launcher.starts == 1)
        #expect(hub.headsetStatus(for: Self.row) == .inHeadset && hub.headsetCommandTitle(for: Self.row) == "Back to Desktop")
        #expect(hub.canvas.takenOverCapsule != nil && hub.canvas.bannerText == nil)
        let session = hub.links[Self.row.identifier]!.session
        #expect(session.isHeldForHeadset && !session.isLive)
        // The desktop does not reconnect while the headset has the device.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(server.connections.accepted == 2)
        await shot(w, "canvas-in-headset")
        // Back to Desktop: the canvas takes the display back and the viewer is stopped.
        hub.toggleHeadset()
        await until("back on the desktop") { hub.headsetSwitch(for: Self.row)?.state == .desktop }
        await until("the canvas is live again") { hub.canvas.stateDescription == "live" && session.isLive }
        #expect(server.connections.accepted == 3 && launcher.stops == 1)
        // The desktop's own camera again (§I.12.3): sent on the connection that took the display back.
        await until("the desktop's camera is sent") { !server.poses(connection: 3).isEmpty }
        #expect(server.poses(connection: 3).last == hub.canvas.frameView.screen.spatial.camera.pose)
        #expect(!session.isHeldForHeadset && hub.canvas.takenOverCapsule == nil)
        #expect(hub.headset.switches[Self.row.identifier]?.lastSwitch?.done != nil)
        // Both ways again: the device never restarted (one server throughout).
        hub.toggleHeadset()
        await until("in the headset again") { hub.headsetSwitch(for: Self.row)?.state == .inHeadset }
        hub.canvas.perform(.viewInHeadset)
        await until("back again") { hub.headsetSwitch(for: Self.row)?.state == .desktop && hub.canvas.stateDescription == "live" }
        #expect(server.connections.accepted == 5 && launcher.starts == 2 && launcher.stops == 2)
    }

    @Test func anotherViewerIsNotFought() async throws {
        let server = try TakeoverServer()
        defer { server.close() }
        let (hub, w, _) = makeHub(server)
        defer { hub.closeLinks(); w.close() }
        await until("live") { hub.canvas.stateDescription == "live" }
        // Someone else's viewer connects: the canvas says so and waits; Take Back reconnects.
        let other = try DisplayConnection.connect(to: .unix(server.path))
        defer { other.close() }
        await until("taken over") { hub.canvas.stateDescription == "taken over" }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(server.connections.accepted == 2)
        hub.links[Self.row.identifier]!.session.takeBack()
        await until("live again") { hub.canvas.stateDescription == "live" }
        #expect(server.connections.accepted == 3)
    }

    /// Against a real device, opt-in: `YCODE_XR_HUB_LIVE="<viewer host>|<simulator host>|<display socket there>|<viewer path>|<script>|<rounds>"`.
    /// The hub's real path (Mac → ssh viewer host → ssh simulator host) with `--replay`
    /// in place of a headset; a tall device's real stream on the real canvas. The switch's
    /// Connect step is not used, so nothing starts on a headset. Prints the timings.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YCODE_XR_HUB_LIVE"] != nil), .timeLimit(.minutes(10)))
    func realDeviceThroughTheRealPath() async throws {
        let f = ProcessInfo.processInfo.environment["YCODE_XR_HUB_LIVE"]!.split(separator: "|").map(String.init)
        let (viewerHost, simHost, socket, viewer, script, rounds) = (f[0], f[1], f[2], f[3], f[4], Int(f[5]) ?? 5)
        let local = NSTemporaryDirectory() + "ycode-xrhub-live-\(getpid()).sock"
        unlink(local)
        let forward = Process()
        forward.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        forward.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-L", "\(local):\(socket)", simHost]
        try forward.run()
        defer { forward.terminate(); forward.waitUntilExit(); unlink(local) }
        await until("the forward") { FileManager.default.fileExists(atPath: local) }

        let t = TestDefaults("xr-hub-live")
        let hub = DevicesController(devices: [], simulators: [Self.row])
        hub.defaults = t.defaults
        var s = HeadsetSettings()
        s.viewerHost = viewerHost
        s.viewerPath = viewer
        s.viewerOptions = "--replay \(script) --foveate"
        hub.headsetSettings = s
        let route = HeadsetRoute.sshSocket(destination: simHost, socket: socket)
        hub.headset.route = { _ in route }
        hub.makeDisplayLink = { r in RemoteDisplayLink(address: .unix(local), spec: .visionPro, name: r.name, os: "visionOS 27.0") }
        let w = hub.makeWindow()
        w.setContentSize(NSSize(width: 1100, height: 760))
        hub.select(row: 0)
        defer { hub.closeLinks(); w.close() }
        await until("the canvas is live", 60) { hub.canvas.stateDescription == "live" }
        let session = hub.links[Self.row.identifier]!.session
        // The real tall stream: the hello's display, the crop, the pointer's space.
        #expect(session.isTallVision && session.hello?.pixelWidth == 2160 && session.hello?.pixelHeight == 3840)
        #expect(session.image?.width == 2160 && session.image?.height == 1215)
        #expect(hub.canvas.frameView.screen.pointSize == CGSize(width: 1920, height: 1080))
        print("XRHUB picture \(session.image?.width ?? 0)x\(session.image?.height ?? 0) from \(session.hello?.pixelWidth ?? 0)x\(session.hello?.pixelHeight ?? 0)")
        await shot(w, "live-desktop")

        // The real checklist of the real workstation (read-only commands).
        await hub.checkHeadset().value
        for c in hub.headset.report?.checks ?? [] { print("XRHUB check \(c.id.rawValue): \(c.state.rawValue): \(c.reason)") }
        let setup = hub.presentHeadsetSetup()
        setup.show(.workstation)
        await shot(setup.window!, "live-setup-workstation")
        setup.show(.connect)
        await shot(setup.window!, "live-setup-connect")
        setup.close()

        let runner = try #require(hub.headset.makeRunner(hub.headsetHost))
        let c = hub.switchController(for: Self.row, route: route, runner: runner)
        c.pollInterval = 0.1
        var frames = 0
        session.onFrame = { _ in frames += 1 }
        for i in 1...rounds {
            let t0 = Date()
            let enter = Task { await c.viewInHeadset() }
            await until("taken over", 30) { session.isTakenOver }
            let takeover = Date().timeIntervalSince(t0)
            await until("in the headset", 30) { c.state == .inHeadset }
            await enter.value
            let inHeadset = Date().timeIntervalSince(t0)
            if i == 1 { await shot(w, "live-in-headset") }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            frames = 0
            let t1 = Date()
            let back = Task { await c.backToDesktop() }
            await until("a new picture", 30) { frames > 0 }
            let picture = Date().timeIntervalSince(t1)
            await back.value
            let stopped = Date().timeIntervalSince(t1)
            await until("at rest", 30) { c.state == .desktop }
            print(String(format: "XRHUB round %d: enter takeover %.2f s, in headset %.2f s; back first picture %.2f s, viewer stopped %.2f s", i, takeover, inHeadset, picture, stopped))
            #expect(session.isLive)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        await shot(w, "live-back-on-desktop")
    }
}

extension NSView {
    func descendant(id: String) -> NSView? {
        if identifier?.rawValue == id { return self }
        for s in subviews { if let v = s.descendant(id: id) { return v } }
        return nil
    }
}
