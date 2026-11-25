import AppKit
import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeDeviceUI
@testable import YcodeIDECore
@testable import YcodeUI

/// The macOS hub against a real Ycode simulator host (opt-in; offscreen):
/// with `YCODE_B5_LIVE_SSH=<user@host>`, `YCODE_B5_LIVE_DATA=<data dir>`,
/// `YCODE_B5_LIVE_RUNTIME=<runtime root>`, `YCODE_B5_LIVE_LAUNCHER=<ycode-sim>`
/// and `YCODE_B5_LIVE_DEVICE=<device directory>`, the hub opened without a
/// workspace lists the host's simulator, Start boots it, the canvas shows its
/// live screen, Home and Screenshot act on it, and Shut Down stops it.
/// `YCODE_B5_SHOTS=<dir>` keeps pictures of the window.
@MainActor
@Suite(.serialized) struct DeviceHubLiveMacTests {
    nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static var enabled: Bool { env["YCODE_B5_LIVE_SSH"] != nil }

    /// Runs the main run loop for a moment (a synchronous helper: the run
    /// loop may not be run directly from an async context).
    static func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func wait(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > end { return false }
            Self.spin(0.2)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    @Test(.enabled(if: DeviceHubLiveMacTests.enabled)) func startAYcodeSimulatorFromTheHubAndSeeItsScreen() async throws {
        let t = TestDefaults("hub-live-mac")
        defer { t.remove() }
        var s = RemoteSimulatorSettings(destination: Self.env["YCODE_B5_LIVE_SSH"] ?? "", dataDirectory: Self.env["YCODE_B5_LIVE_DATA"] ?? "",
                                        runtimeRoot: Self.env["YCODE_B5_LIVE_RUNTIME"] ?? "", simdPath: Self.env["YCODE_B5_LIVE_LAUNCHER"] ?? "",
                                        deviceName: Self.env["YCODE_B5_LIVE_DEVICE"] ?? "ycode-device")
        s.warmBoot = true
        s.save(t.defaults)
        _ = NSApplication.shared
        let hub = DevicesController(devices: [], simulators: [])
        hub.defaults = t.defaults
        hub.configureStandalone(defaults: t.defaults, simctl: nil)
        let w = hub.makeWindow()
        w.isExcludedFromWindowsMenu = true
        w.setFrameAutosaveName("")
        hub.splitView.autosaveName = nil
        w.setContentSize(NSSize(width: 1100, height: 800))
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        w.orderBack(nil)
        defer {
            if let r = hub.selected, r.state == "Booted" { _ = hub.shutDown(r) }
            w.close()
        }
        w.contentView?.layoutSubtreeIfNeeded()
        let i = try #require(hub.rows.firstIndex { $0.isYcodeRemote && $0.deviceDirectory == s.deviceName })
        hub.select(row: i)
        let row = try #require(hub.selected)
        print("B5LIVE row \(row.name) \(row.state) \(row.model)")
        #expect(hub.canvas.stateDescription == "stopped" && hub.canvas.statusActionButton.title == "Start")
        Self.shot(w, "mac-live-1-stopped.png")
        // Start, as the status view's button does.
        let t0 = Date()
        if let a = hub.canvas.statusActionButton.action { NSApp.sendAction(a, to: hub.canvas.statusActionButton.target, from: hub.canvas.statusActionButton) }
        await hub.lifecycleTask?.value
        #expect(hub.selected?.state == "Booted")
        Self.shot(w, "mac-live-2-starting.png")
        let live = await wait(900) { hub.canvas.stateDescription == "live" && hub.canvas.session?.isLive == true }
        print(String(format: "B5LIVE live=%@ after %.1f s, canvas %@", live ? "yes" : "no", Date().timeIntervalSince(t0), hub.canvas.stateDescription))
        #expect(live)
        guard live else { return }
        // The stream is live from the boot logo on: wait for the home screen.
        // The canvas's own picture (its screen view), not only the session's.
        let home = await wait(300) { hub.canvas.frameView.screen.image.map(Self.isLit) == true }
        print(String(format: "B5LIVE home screen=%@ after %.1f s", home ? "yes" : "no", Date().timeIntervalSince(t0)))
        #expect(home)
        _ = await wait(3) { false }
        Self.shot(w, "mac-live-3-live.png")
        Self.canvasShot(hub, "mac-live-3-canvas.png")
        hub.canvas.perform(.home)
        _ = await wait(3) { false }
        Self.shot(w, "mac-live-4-home.png")
        Self.canvasShot(hub, "mac-live-4-canvas.png")
        hub.canvas.perform(.rotateLeft)
        _ = await wait(4) { false }
        Self.shot(w, "mac-live-5-rotate.png")
        Self.canvasShot(hub, "mac-live-5-canvas.png")
        print("B5LIVE rotate: banner \(hub.canvas.bannerText ?? "none"), canRotate \(hub.canvas.canPerform(.rotateLeft))")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-b5-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("YCODE_DEVICE_CAPTURE_DIR", dir.path, 1)
        defer { unsetenv("YCODE_DEVICE_CAPTURE_DIR"); try? FileManager.default.removeItem(at: dir) }
        hub.canvas.perform(.screenshot)
        let saved = await wait(20) { hub.canvas.bannerText == "Screenshot Saved" }
        print("B5LIVE screenshot banner \(hub.canvas.bannerText ?? "none")")
        #expect(saved)
        print("B5LIVE screenshot files \((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])")
        // Shut Down from More Actions' item.
        let running = try #require(hub.selected)
        let shut = try #require(hub.lifecycleItems(for: running).first { $0.title == "Shut Down" })
        _ = shut.target?.perform(shut.action, with: shut)
        await hub.lifecycleTask?.value
        #expect(hub.selected?.state == "Shutdown")
        _ = await wait(2) { false }
        Self.shot(w, "mac-live-6-shut-down.png")
    }

    /// With `YCODE_B5_LIVE_YCRUN_DEVICE=<device directory>` naming a device
    /// `ycrun simctl boot` started on the same host: the hub lists it as
    /// running, shows its live screen, and Shut Down stops it (ycrun's SIGTERM).
    nonisolated static var ycrunEnabled: Bool { enabled && env["YCODE_B5_LIVE_YCRUN_DEVICE"] != nil }

    @Test(.enabled(if: DeviceHubLiveMacTests.ycrunEnabled)) func aDeviceYcrunBootedIsLiveInTheHubAndShutsDownFromIt() async throws {
        let t = TestDefaults("hub-live-mac-ycrun")
        defer { t.remove() }
        let dir = Self.env["YCODE_B5_LIVE_YCRUN_DEVICE"] ?? ""
        var s = RemoteSimulatorSettings(destination: Self.env["YCODE_B5_LIVE_SSH"] ?? "", dataDirectory: Self.env["YCODE_B5_LIVE_DATA"] ?? "",
                                        runtimeRoot: Self.env["YCODE_B5_LIVE_RUNTIME"] ?? "", simdPath: Self.env["YCODE_B5_LIVE_LAUNCHER"] ?? "",
                                        deviceName: dir)
        s.warmBoot = true
        s.save(t.defaults)
        _ = NSApplication.shared
        let hub = DevicesController(devices: [], simulators: [])
        hub.defaults = t.defaults
        hub.configureStandalone(defaults: t.defaults, simctl: nil)
        let w = hub.makeWindow()
        w.isExcludedFromWindowsMenu = true
        w.setFrameAutosaveName("")
        hub.splitView.autosaveName = nil
        w.setContentSize(NSSize(width: 1100, height: 800))
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        w.orderBack(nil)
        defer { w.close() }
        w.contentView?.layoutSubtreeIfNeeded()
        let t0 = Date()
        await hub.pollYcrun(force: true)?.value
        print("B5LIVE ycrun booted \(hub.ycrunBooted)")
        #expect(hub.ycrunBooted.contains(dir))
        hub.applyRemoteRows()
        let i = try #require(hub.rows.firstIndex { $0.isYcodeRemote && $0.deviceDirectory == dir })
        hub.select(row: i)
        #expect(hub.selected?.state == "Booted")
        let live = await wait(300) { hub.canvas.stateDescription == "live" && hub.canvas.session?.isLive == true }
        print(String(format: "B5LIVE ycrun device live=%@ after %.1f s", live ? "yes" : "no", Date().timeIntervalSince(t0)))
        #expect(live)
        _ = await wait(5) { false }
        Self.shot(w, "mac-live-ycrun-1-live.png")
        Self.canvasShot(hub, "mac-live-ycrun-1-canvas.png")
        let running = try #require(hub.selected)
        let t1 = Date()
        await hub.shutDown(running)?.value
        print(String(format: "B5LIVE ycrun device shut down from the hub in %.1f s", Date().timeIntervalSince(t1)))
        #expect(hub.selected?.state == "Shutdown")
        await hub.pollYcrun(force: true)?.value
        #expect(!hub.ycrunBooted.contains(dir))
        _ = await wait(2) { false }
        Self.shot(w, "mac-live-ycrun-2-shut-down.png")
    }

    /// A lit screen (the home screen), not the boot logo on black: fewer
    /// than 90 % of a 32 × 32 sample darker than 24 (the viewer's `wait-home`).
    static func isLit(_ image: CGImage) -> Bool {
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var dark = 0
        for i in 0..<(n * n) where max(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) < 24 { dark += 1 }
        return Double(dark) < 0.9 * Double(n * n)
    }

    /// The picture the canvas's screen view holds, as a PNG (a window kept
    /// off every display may be captured with the picture it first showed).
    static func canvasShot(_ hub: DevicesController, _ name: String) {
        guard let dir = env["YCODE_B5_SHOTS"], let image = hub.canvas.frameView.screen.image,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    static func shot(_ w: NSWindow, _ name: String) {
        guard let dir = env["YCODE_B5_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
