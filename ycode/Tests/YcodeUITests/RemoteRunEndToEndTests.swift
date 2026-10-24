#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import YcodeUI

/// Opt-in end-to-end run on a real remote Ycode simulator (specs/ide/run.md
/// §Remote Ycode simulator). Skipped unless these are set:
///   YCODE_E2E_REMOTE   ssh destination (user@host; key-based login only)
///   YCODE_E2E_DATA     remote data directory (apps/, devices/<device>)
///   YCODE_E2E_RUNTIME  remote simulator runtime root
///   YCODE_E2E_SIMD     remote ycode-simd (or a wrapper that adds host-side options)
///   YCODE_E2E_APP      local iOS-simulator .app to upload
///   YCODE_E2E_DEVICE   remote device name (default "e2e")
///   YCODE_E2E_MINUTES  how long to wait for the launch (default 30)
///   YCODE_E2E_LEAN_BOOT  1: Lean boot (default: a full boot, as parity runs use)
///   YCODE_E2E_WARM_BOOT  0: always boot cold (default: warm boot, run.md §Warm boot)
/// Nothing here is machine-specific; the values come only from the environment.
@Suite(.serialized, .heavyIntegration) @MainActor struct RemoteRunEndToEndTests {
    @Test func runsAnAppOnARealRemoteSimulator() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let destination = env["YCODE_E2E_REMOTE"], let data = env["YCODE_E2E_DATA"], let runtime = env["YCODE_E2E_RUNTIME"],
              let simd = env["YCODE_E2E_SIMD"], let appPath = env["YCODE_E2E_APP"] else {
            print("skipping: YCODE_E2E_REMOTE and friends are not set")
            return
        }
        _ = NSApplication.shared
        var settings = RemoteSimulatorSettings(destination: destination, dataDirectory: data, runtimeRoot: runtime,
                                               simdPath: simd, deviceName: env["YCODE_E2E_DEVICE"] ?? "e2e")
        settings.leanBoot = env["YCODE_E2E_LEAN_BOOT"] == "1"
        settings.warmBoot = env["YCODE_E2E_WARM_BOOT"] != "0"
        let remote = RemoteSimulator(settings: settings)
        let app = URL(fileURLWithPath: appPath)
        let bundle = try #require(AppBundle(url: app))
        let minutes = Double(env["YCODE_E2E_MINUTES"] ?? "30") ?? 30

        let session = WorkspaceSession(model: try WorkspaceModel(url: try WindowSnapshotTests().samplePackage()))
        let started = Date()
        await session.runOnRemoteSimulator(app: app, remote: remote)
        #expect(await waitUntil(60) { session.simulatorRun?.remotePID != nil })
        // Times seen from the Mac (run start = before the upload): the home
        // screen (the launcher's "home screen at" line) and the launch.
        var homeAt: Double?
        let launched = await waitUntil(minutes * 60) {
            if homeAt == nil, session.console.contains("ycode-sim: home screen at") { homeAt = Date().timeIntervalSince(started) }
            return session.console.contains("launched \(bundle.bundleID)") || session.simulatorRun == nil
        }
        let launchedAt = Date().timeIntervalSince(started)
        print(String(format: "e2e timing: home screen %@ s, app launched %.1f s after Run (warm boot %@)",
                     homeAt.map { String(format: "%.1f", $0) } ?? "-", launchedAt, settings.warmBoot ? "on" : "off"))
        // The full console is printed so a failure can be diagnosed from the test log.
        print("---- remote console ----\n" + String(session.console.suffix(6000)))
        #expect(launched && session.console.contains("launched \(bundle.bundleID)"))
        // Stop (run.md §Remote step 4, §Warm boot item 5): SIGINT to the
        // launcher, which saves the device (warm boot) and reports it; the
        // IDE then closes the connection. The run is still going here.
        #expect(session.simulatorRun != nil)
        guard session.simulatorRun != nil else { return }
        let stoppedAt = Date()
        session.stopSimulatorRun(remote: remote)
        #expect(session.activity == .running(RemoteSimulator.stoppingStatus(app: bundle.executable, saves: settings.warmBoot)))
        // Within the launcher's own stop timeout (120 s), before the IDE's grace time.
        #expect(await waitUntil(remote.stopGrace - 10) { session.simulatorRun == nil })
        print(String(format: "e2e timing: run ended %.1f s after Stop", Date().timeIntervalSince(stoppedAt)))
        print("---- after Stop ----\n" + String(session.console.suffix(2000)))
        if settings.warmBoot {
            #expect(session.consoleText(.debugger).contains("ycode-sim: warm boot: the device was saved; the next run continues from it"))
            #expect(!session.console.contains("the device was not saved"))
        }
        // It ended through the stop, not by a failure or the IDE's fallbacks.
        #expect(session.console.contains("Ycode Simulator stopped") || session.console.contains("Ycode Simulator ended with status"))
        #expect(!session.console.contains("the stop signal did not reach"))
        #expect(!session.console.contains("after Stop; closing the connection"))
        #expect(session.activity == .finished("Finished running \(bundle.executable)"))
    }
}
#endif
