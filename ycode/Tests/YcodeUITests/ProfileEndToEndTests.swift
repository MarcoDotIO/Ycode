#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProfiler
@testable import YcodeUI

/// Opt-in end-to-end check of Product ▸ Profile (specs/ide/profiler.md §5,
/// §10): the IDE builds GaugeDemo with the Profile configuration, runs it on
/// a remote Ycode simulator under Gauge, stops it after a while, copies the
/// trace back, symbolicates it with the build's dSYM and shows it in the
/// profiler window. Set YCODE_E2E_PROFILE=1 and:
///   YCODE_E2E_REMOTE    ssh destination (user@host; key-based login only)
///   YCODE_E2E_DATA      remote data directory (apps/, devices/, profiles/)
///   YCODE_E2E_RUNTIME   remote simulator runtime root (its version picks the device types)
///   YCODE_E2E_SIMD      remote launcher (ycode-sim) or ycode-simd
///   YCODE_E2E_DEVICE    device name (default "gauge"; the iPhone 18 Pro row's directory is <name>-iphone-18-pro-<version>)
///   YCODE_E2E_TYPE      device type id (default iphone-18-pro)
///   YCODE_E2E_SECONDS   how long the app runs after its launch (default 15)
///   YCODE_E2E_MINUTES   how long to wait for the launch (default 30)
///   YCODE_E2E_WARM_BOOT 0: boot cold (default: warm boot)
///   YCODE_E2E_PNG       where to write a PNG of the profiler window
///   YCODE_E2E_ENGINE    build engine (xcodebuild or swift-build; default xcodebuild)
///   YCODE_E2E_CONSOLE   a file that mirrors the run's console while the test waits
/// Nothing here is machine-specific; the values come only from the environment.
@Suite(.serialized, .heavyIntegration) @MainActor struct ProfileEndToEndTests {
    /// Progress goes to stderr (unbuffered) so a long run can be followed.
    func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    @Test func profilesGaugeDemoOnARemoteSimulator() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["YCODE_E2E_PROFILE"] == "1", let destination = env["YCODE_E2E_REMOTE"], let data = env["YCODE_E2E_DATA"],
              let runtime = env["YCODE_E2E_RUNTIME"], let simd = env["YCODE_E2E_SIMD"] else {
            log("skipping: YCODE_E2E_PROFILE and friends are not set")
            return
        }
        _ = NSApplication.shared
        let scratch = TestDefaults("e2e-profile")
        defer { scratch.remove() }
        let defaults = scratch.defaults
        var settings = RemoteSimulatorSettings(destination: destination, dataDirectory: data, runtimeRoot: runtime,
                                               simdPath: simd, deviceName: env["YCODE_E2E_DEVICE"] ?? "gauge")
        settings.warmBoot = env["YCODE_E2E_WARM_BOOT"] != "0"
        settings.save(defaults)
        let saved = Preferences.shared
        Preferences.shared = Preferences(defaults: defaults)
        defer { Preferences.shared = saved }

        let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = ycodeDir.appendingPathComponent("Tools/gauge-samples/GaugeDemo/GaugeDemo.xcodeproj")
        let session = WorkspaceSession(model: try WorkspaceModel(url: project))
        session.engine = (BuildSystemPreference(rawValue: env["YCODE_E2E_ENGINE"] ?? "xcodebuild") ?? .xcodebuild).makeEngine()
        let type = env["YCODE_E2E_TYPE"] ?? "iphone-18-pro"
        let target = try #require(RemoteSimulatorSettings.load(defaults).targets.first { $0.deviceType.id == type })
        log("e2e profile: destination \(target.destination.name) \(target.runtimeVersion ?? "?"), device directory \(target.deviceDirectoryName)")
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        session.destination = target.destination
        session.scheme = "GaugeDemo"
        #expect(session.destination?.isYcodeRemoteSimulator == true)
        let started = Date()
        let gauge = try #require(wc.profileScheme(building: true))
        let minutes = Double(env["YCODE_E2E_MINUTES"] ?? "30") ?? 30
        log("e2e profile: Profile started (build, upload, launch)")
        // YCODE_E2E_CONSOLE: a file that mirrors the console while waiting
        // (the test runner's output is shown only at the end).
        let mirror = env["YCODE_E2E_CONSOLE"].map { URL(fileURLWithPath: $0) }
        var mirrored = 0
        func mirrorConsole() {
            guard let mirror, session.console.count != mirrored else { return }
            mirrored = session.console.count
            try? Data(("phase \(gauge.model.phase)\n" + session.console).utf8).write(to: mirror)
        }
        let launched = await waitUntil(minutes * 60) {
            mirrorConsole()
            if case .failed = gauge.model.phase { return true }
            return session.console.contains("launched dev.ycode.GaugeDemo")
        }
        log(String(format: "e2e profile: launched after %.0f s", Date().timeIntervalSince(started)))
        #expect(launched && session.console.contains("launched dev.ycode.GaugeDemo"))
        let seconds = Double(env["YCODE_E2E_SECONDS"] ?? "15") ?? 15
        _ = await waitUntil(seconds) { session.simulatorRun == nil }
        // Stop from the profiler window (the run's Stop).
        gauge.recordButton.performClick(nil)
        let loaded = await waitUntil(300) {
            mirrorConsole()
            if case .recording = gauge.model.phase { return false }
            return true
        }
        mirrorConsole()
        log("---- remote console ----\n" + String(session.console.suffix(5000)))
        #expect(loaded && gauge.model.phase == .loaded)
        let trace = try #require(gauge.model.trace)
        log(GaugeReport.summary(trace, top: 12))
        // The deliberate work is the hot path, by name (dSYM symbols), with lines.
        let top = CallTree.topFunctions(trace: trace).prefix(5).map(\.name)
        #expect(top.contains("sieve_primes") || top.contains("multiply_matrices"))
        let crunch = trace.signposts.filter { $0.name == "Crunch" }
        #expect(!crunch.isEmpty)
        #expect(trace.signposts.contains { $0.name == "Sieve" } && trace.signposts.contains { $0.name == "Matrix" })
        // Select the hot function and show its source.
        if let node = gauge.model.tree?.root.find("sieve_primes") {
            gauge.model.selectedPath = node.path
            #expect(gauge.model.annotation?.file?.hasSuffix("Work.c") == true)
        }
        if let png = env["YCODE_E2E_PNG"] {
            gauge.window?.setContentSize(NSSize(width: 1440, height: 900))
            gauge.model.content = .callTree
            #expect(gauge.writeSnapshot(to: URL(fileURLWithPath: png)))
            log("e2e profile: window snapshot \(png)")
        }
        gauge.close()
    }

}
#endif
