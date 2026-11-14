#if os(macOS)
import AppKit
import CYcodeTestOffscreen
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Opt-in end-to-end round W6 (`specs/simulator/device-pairing.md` §13) on a
/// real simulator host, driven through the IDE's own controllers: Device
/// Hub creates an iPhone 18 Pro paired with an Apple Watch Series 12 (46mm)
/// (Add Device ▸ iPhone with Paired Watch…), the hub shows the pair, the
/// WatchSamples project's watch scheme runs on the phone-with-watch
/// destination (the iOS app on the phone, the watch app directly on the
/// watch, both launched), WatchConnectivity messages are answered both
/// ways (WCProbe's logs), the watch's compact window turns the crown from a
/// scroll-wheel event, then the hub unpairs and the watch is erased.
/// Skipped unless these are set:
///   YCODE_E2E_PAIR_REMOTE        ssh destination (key-based login only)
///   YCODE_E2E_PAIR_DATA          remote data directory
///   YCODE_E2E_PAIR_IOS_RUNTIME   iOS 27.0 runtime root
///   YCODE_E2E_PAIR_WATCH_RUNTIME watchOS 27.0 runtime root
///   YCODE_E2E_PAIR_SIMD          the remote launcher (ycode-sim)
///   YCODE_E2E_PAIR_SHOTS         directory for the window PNGs (optional)
///   YCODE_E2E_PAIR_MINUTES       how long to wait for both apps (default 60)
///   YCODE_E2E_PAIR_KEEP          1: keep the created devices at the end
/// Nothing here is machine-specific; the values come only from the environment.
@Suite(.serialized, .heavyIntegration) @MainActor struct PairedRunEndToEndTests {
    func log(_ s: String) { print("e2e pair: \(s)"); fflush(stdout) }

    /// `screencapture -l` of one of Ycode's own windows.
    func shot(_ w: NSWindow?, _ name: String, _ dir: String?) {
        guard let w, let dir else { return }
        w.displayIfNeeded()
        let path = (dir as NSString).appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(w.windowNumber)", path]
        YcodeOffscreenOpaqueDuringCapture(w) {
            try? p.run()
            p.waitUntilExit()
        }
        log("screenshot \(path) (\(p.terminationStatus))")
    }

    @Test func createsPairsRunsAndUnpairsFromTheIDE() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let destination = env["YCODE_E2E_PAIR_REMOTE"], let data = env["YCODE_E2E_PAIR_DATA"],
              let iosRoot = env["YCODE_E2E_PAIR_IOS_RUNTIME"], let watchRoot = env["YCODE_E2E_PAIR_WATCH_RUNTIME"],
              let simd = env["YCODE_E2E_PAIR_SIMD"] else {
            print("skipping: YCODE_E2E_PAIR_REMOTE and friends are not set")
            return
        }
        let shots = env["YCODE_E2E_PAIR_SHOTS"]
        let minutes = Double(env["YCODE_E2E_PAIR_MINUTES"] ?? "60") ?? 60
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let t = TestDefaults("pair-e2e")
        let old = Preferences.shared, oldStore = RemotePairsStore.shared.defaults
        Preferences.shared = Preferences(defaults: t.defaults, themesDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ycode-pair-e2e-themes"))
        RemotePairsStore.shared.defaults = t.defaults
        defer {
            Preferences.shared = old
            RemotePairsStore.shared.defaults = oldStore
            t.remove()
        }
        var settings = RemoteSimulatorSettings(destination: destination, dataDirectory: data, runtimeRoot: iosRoot, simdPath: simd, deviceName: "pide")
        settings.otherRuntimeRoots = [watchRoot]
        settings.warmBoot = env["YCODE_E2E_PAIR_WARM_BOOT"] == "1"
        settings.save(t.defaults)
        // The runtimes' versions and platforms, read from the host as the IDE does.
        for (root, primary) in [(iosRoot, true), (watchRoot, false)] {
            let probe = RemoteSimulator(settings: settings, target: RemoteSimulatorTarget(runtimeRoot: root, deviceType: .simdDefault,
                                                                                         deviceDirectoryName: "pide", isPrimary: false))
            let v = try #require(await Task.detached { probe.readRuntimeSystemVersion() }.value, "the runtime \(root) cannot be read")
            RemoteSimulatorSettings.saveRuntimeVersion(v.version, root: root, t.defaults, primary: primary)
            RemoteSimulatorSettings.saveRuntimePlatform(v.platform, root: root, t.defaults)
            log("runtime \(root): \(v.platform) \(v.version)")
        }

        // The workspace and Device Hub.
        let project = ycodeDir.appendingPathComponent("Samples/WatchSamples/WatchSamples.xcodeproj")
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-pair-e2e-\(UUID().uuidString).json")
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: project)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false, userStateURL: state)
        wc.showWindow(nil)
        wc.setDestinationGroups([])
        // Ycode's own rows only (no `simctl` listing: Apple's simulators are not looked at).
        let c = DevicesController(devices: [], simulators: [])
        wc.configureYcodeRemoteDevice(c, defaults: t.defaults)
        let hubWindow = c.makeWindow()
        c.restoreState()
        hubWindow.makeKeyAndOrderFront(nil)
        c.pairing.confirm = { _, _, _ in true }
        defer { c.closeLinks(); c.view.window?.close() }

        // 1. Add Device ▸ iPhone with Paired Watch…
        let started = Date()
        c.pairing.presentForm = { form, done in
            form.phone?.name.stringValue = "iPhone 18 Pro"
            form.phone?.selectModel("iPhone 18 Pro")
            form.watch?.name.stringValue = "Apple Watch Series 12 (46mm)"
            form.watch?.selectModel("Apple Watch Series 12 (46mm)")
            done(true)
        }
        c.presentNewPairedPhone()
        await c.pairing.task?.value
        log("pair: \(c.pairing.status ?? "-") after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        let pair = try #require(c.pairing.pairs.first)
        #expect(pair.active && c.pairing.pairs.count == 1)
        let phoneRow = try #require(c.rows.first { $0.deviceDirectory == pair.phoneDirectory })
        let watchRow = try #require(c.rows.first { $0.deviceDirectory == pair.watchDirectory })
        #expect(phoneRow.name == "iPhone 18 Pro" && watchRow.name == "Apple Watch Series 12 (46mm)")
        c.select(row: try #require(c.rows.firstIndex { $0.identifier == phoneRow.identifier }))
        c.selectInspectorTab(.info)
        #expect(c.canvas.pairedTitle == "Paired with Apple Watch Series 12 (46mm)")
        try await Task.sleep(for: .seconds(1))
        shot(c.view.window, "pair-ide-1-hub-paired.png", shots)

        // 2. The watch scheme on the phone-with-watch destination.
        wc.session.scheme = "WCProbeWatch"
        wc.setDestinationGroups([])
        let row = try #require(wc.destinationMenuModel().rows("Simulators").first { $0.isYcodePairedDestination })
        log("destination: \(row.name)")
        #expect(row.name == "iPhone 18 Pro with Apple Watch Series 12 (46mm)")
        wc.session.destination = row
        wc.rebuildDestinationMenu()
        let runStart = Date()
        wc.runProduct(nil)
        let both = await waitUntil(minutes * 60) {
            wc.session.console.contains("launched dev.ycode.wcprobe ") && wc.session.console.contains("launched dev.ycode.wcprobe.watchkitapp on")
                || wc.session.activity == .finished("Run failed") || wc.session.activity == .finished("Build Failed")
        }
        log(String(format: "both apps launched: %@ after %.1f s", both ? "yes" : "no", Date().timeIntervalSince(runStart)))
        print("---- console ----\n" + String(wc.session.console.suffix(8000)))
        #expect(both && wc.session.console.contains("launched dev.ycode.wcprobe.watchkitapp on"))

        // 3. WatchConnectivity: WCProbe's round trips on both devices.
        let phone = RemoteSimulator(settings: RemoteSimulatorSettings.load(t.defaults), target: RemoteSimulatorSettings.load(t.defaults).target(directory: pair.phoneDirectory))
        let watch = RemoteSimulator(settings: RemoteSimulatorSettings.load(t.defaults), target: RemoteSimulatorSettings.load(t.defaults).target(directory: pair.watchDirectory))
        func rtts(_ r: RemoteSimulator) async -> Int {
            let cmd = "f=$(find \(RemoteSimulator.quote(r.remoteDevicePath + "/data/Containers/Data/Application")) -name wcprobe.log 2>/dev/null | head -1); [ -n \"$f\" ] && grep -c '^.*rtt ' \"$f\" || echo 0"
            let out = await Task.detached { r.runRemote(cmd).1 }.value
            return Int(out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last ?? "0") ?? 0
        }
        var counts = (0, 0), flowed = false
        let end = Date().addingTimeInterval(900)
        while Date() < end, wc.session.simulatorRun != nil {
            counts = (await rtts(phone), await rtts(watch))
            if counts.0 >= 3 && counts.1 >= 3 { flowed = true; break }
            try? await Task.sleep(for: .seconds(10))
        }
        log("WatchConnectivity round trips: phone \(counts.0), watch \(counts.1)")
        #expect(flowed)
        for (r, name) in [(phone, "phone"), (watch, "watch")] {
            let cmd = "f=$(find \(RemoteSimulator.quote(r.remoteDevicePath + "/data/Containers/Data/Application")) -name wcprobe.log 2>/dev/null | head -1); [ -n \"$f\" ] && grep -E 'activation|state |rtt ' \"$f\" | head -12"
            print("---- wcprobe \(name) ----\n" + (await Task.detached { r.runRemote(cmd).1 }.value))
        }

        // 4. The hub during the run: the phone, then the watch in its compact window (crown from the scroll wheel).
        c.select(row: try #require(c.rows.firstIndex { $0.identifier == phoneRow.identifier }))
        _ = await waitUntil(60) { c.canvas.stateDescription == "live" }
        try await Task.sleep(for: .seconds(2))
        shot(c.view.window, "pair-ide-2-hub-phone-running.png", shots)
        c.select(row: try #require(c.rows.firstIndex { $0.identifier == watchRow.identifier }))
        _ = await waitUntil(60) { c.canvas.stateDescription == "live" }
        try await Task.sleep(for: .seconds(2))
        shot(c.view.window, "pair-ide-3-hub-watch-running.png", shots)
        if let compact = c.openInNewWindow(c.selected) {
            _ = await waitUntil(30) { compact.canvas.stateDescription == "live" }
            try await Task.sleep(for: .seconds(2))
            shot(compact.window, "pair-ide-4-watch-compact.png", shots)
            // A scroll-wheel event over the watch's screen turns the crown (watchos.md §12.2).
            let screen = compact.canvas.frameView.screen
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
               let e = NSEvent(cgEvent: cg) {
                for _ in 0..<10 { screen.scrollWheel(with: e); try await Task.sleep(for: .milliseconds(30)) }
            }
            try await Task.sleep(for: .seconds(3))
            shot(compact.window, "pair-ide-5-watch-compact-crown.png", shots)
            let cmd = "f=$(find \(RemoteSimulator.quote(watch.remoteDevicePath + "/data/Containers/Data/Application")) -name wcprobe.log 2>/dev/null | head -1); [ -n \"$f\" ] && grep 'scroll offset' \"$f\" | tail -3"
            log("watch app scroll: \(await Task.detached { watch.runRemote(cmd).1 }.value)")
            compact.window?.close()
        }

        // 5. Stop the run; the watch the run started ends with it.
        wc.stopProduct(nil)
        #expect(await waitUntil(300) { wc.session.simulatorRun == nil })
        #expect(await waitUntil(300) { !RemoteDeviceSessions.shared.isRunning(watch) })
        log("run stopped; watch running: \(RemoteDeviceSessions.shared.isRunning(watch))")

        // 6. Unpair from the hub: the watch is erased.
        c.select(row: try #require(c.rows.firstIndex { $0.identifier == phoneRow.identifier }))
        c.unpair(try #require(c.pairing.pairs.first))
        await c.pairing.task?.value
        log("unpair: \(c.pairing.status ?? "-")")
        #expect(c.pairing.pairs.isEmpty)
        let left = await Task.detached { watch.runRemote("ls -A \(RemoteSimulator.quote(watch.remoteDevicePath))").1 }.value
        log("the watch's directory after the unpair: \(left.split(separator: "\n").joined(separator: ", "))")
        #expect(left.split(separator: "\n").sorted() == ["ycode-device-type", "ycode-udid"])
        try await Task.sleep(for: .seconds(1))
        shot(c.view.window, "pair-ide-6-hub-unpaired.png", shots)

        // 7. The created devices go (their data on the host too).
        if env["YCODE_E2E_PAIR_KEEP"] != "1" {
            for r in [phoneRow, watchRow] {
                c.delete(try #require(c.rows.first { $0.identifier == r.identifier }))
                await c.pairing.task?.value
                log("delete \(r.name): \(c.pairing.status ?? "-")")
            }
        }
        wc.window?.close()
    }
}
#endif
