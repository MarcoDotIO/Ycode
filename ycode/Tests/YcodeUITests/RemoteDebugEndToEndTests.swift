#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Opt-in end-to-end debugging of an app on a real remote Ycode simulator
/// (specs/simulator/debug-stub.md §8.2, specs/ide/debug.md §Remote): Run
/// with a breakpoint set, the stop in the session (debug bar state, frames,
/// variables), a step over, continue, Stop. Skipped unless the
/// `RemoteRunEndToEndTests` variables are set, plus
///   YCODE_E2E_DEBUG_FILE  the source file of the breakpoint (absolute, as the app's debug info names it)
///   YCODE_E2E_DEBUG_LINE  its line
///   YCODE_E2E_SIMD_ARGS   extra host-side ycode-simd options (optional)
@Suite(.serialized, .heavyIntegration) @MainActor struct RemoteDebugEndToEndTests {
    @Test func stopsAtABreakpointOnARealRemoteSimulator() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let destination = env["YCODE_E2E_REMOTE"], let data = env["YCODE_E2E_DATA"], let runtime = env["YCODE_E2E_RUNTIME"],
              let simd = env["YCODE_E2E_SIMD"], let appPath = env["YCODE_E2E_APP"], let file = env["YCODE_E2E_DEBUG_FILE"],
              let line = env["YCODE_E2E_DEBUG_LINE"].flatMap(Int.init) else {
            print("skipping: YCODE_E2E_REMOTE, YCODE_E2E_DEBUG_FILE and friends are not set")
            return
        }
        _ = NSApplication.shared
        var settings = RemoteSimulatorSettings(destination: destination, dataDirectory: data, runtimeRoot: runtime,
                                               simdPath: simd, deviceName: env["YCODE_E2E_DEVICE"] ?? "e2e")
        if let lean = env["YCODE_E2E_LEAN_BOOT"] { settings.leanBoot = lean == "1" }
        settings.warmBoot = env["YCODE_E2E_WARM_BOOT"] != "0"
        // Extra host-side options (e.g. --debug-server-log).
        if let extra = env["YCODE_E2E_SIMD_ARGS"] { settings.additionalArguments = extra }
        let remote = RemoteSimulator(settings: settings)
        let app = URL(fileURLWithPath: appPath)
        let bundle = try #require(AppBundle(url: app))
        let minutes = Double(env["YCODE_E2E_MINUTES"] ?? "30") ?? 30

        let session = WorkspaceSession(model: try WorkspaceModel(url: try WindowSnapshotTests().samplePackage()))
        session.breakpoints.click(file: file, line: line)
        await session.runOnRemoteSimulator(app: app, remote: remote)
        let launched = await waitUntil(minutes * 60) { session.console.contains("launched \(bundle.bundleID)") || session.simulatorRun == nil }
        #expect(launched && session.simulatorRun != nil)
        // The debugger attaches and the breakpoint stops the app.
        // (The attach's own stop is continued by the session at once.)
        let stopped = await waitUntil(300) { session.stoppedThread != nil && session.frames.first?.line == line }
        print("---- remote console ----\n" + String(session.console.suffix(4000)))
        #expect(stopped)
        guard stopped else {
            session.stopSimulatorRun(remote: remote)
            _ = await waitUntil(remote.stopGrace) { session.simulatorRun == nil }
            return
        }
        // The variables and the paused activity follow the frames.
        #expect(await waitUntil(60) { !session.isLoadingVariables && !session.variables.isEmpty })
        #expect(await waitUntil(30) { if case .paused = session.activity { true } else { false } })
        print("e2e debug: activity \(session.activity); frames: " + session.frames.prefix(4).map { "\($0.name) \($0.file ?? "-"):\($0.line)" }.joined(separator: " | "))
        print("e2e debug: variables: " + session.variables.map { "\($0.name)=\($0.value)" }.joined(separator: ", "))
        #expect(session.frames.first?.line == line)
        #expect(session.frames.first?.file?.hasSuffix((file as NSString).lastPathComponent) == true)
        #expect(!session.variables.isEmpty)
        // Swift values are formatted (an Int as its digits), and a Swift
        // expression evaluates in the frame (debug-stub.md §10.2).
        if let round = session.variables.first(where: { $0.name == "round" }) { #expect(Int(round.value) != nil) }
        let product = await session.evaluateInConsole("expression round * 2")
        print("e2e debug: expression round * 2 -> \(product ?? "nil")")
        #expect(product.map { !$0.contains("error") && $0.contains("Int") } == true)
        // Step over: the next line of the same function.
        let before = session.frames.first?.line
        await session.step("over")
        #expect(await waitUntil(60) { session.stoppedThread != nil && session.frames.first?.line != before && !session.isLoadingVariables })
        // `n` has its value now.
        print("e2e debug: variables after step: " + session.variables.map { "\($0.name)=\($0.value)" }.joined(separator: ", "))
        #expect(session.variables.contains { $0.name == "n" })
        print("e2e debug: after step over: " + (session.frames.first.map { "\($0.name):\($0.line)" } ?? "-"))
        // Continue: the breakpoint stops it again on the next round.
        await session.continueOrPause()
        #expect(await waitUntil(60) { session.stoppedThread != nil && session.frames.first?.line == line })
        // Stop: the debugger detaches, the launcher saves the device.
        session.stopSimulatorRun(remote: remote)
        #expect(await waitUntil(remote.stopGrace) { session.simulatorRun == nil })
        print("---- after Stop ----\n" + String(session.console.suffix(2000)))
    }
}
#endif
