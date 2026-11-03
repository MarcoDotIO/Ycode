#if os(macOS)
import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Product ▸ Test (⌘U) on app-hosted tests (specs/ide/testing.md, "Ycode
/// implementation"): the HostMac sample's XCTest and Swift Testing bundles
/// run inside HostMac.app through ycodebuild, and the Test navigator, the
/// gutter and the issues show their results. Needs the swift-build helper
/// (`YCODE_SWB`) and the test agent (`swift build --product YcodeTestAgent`);
/// skipped without them.
@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(10))) struct HostedTestRunTests {
    static func tools() -> (ycodebuild: String, helper: String, agent: String)? {
        let fm = FileManager.default
        let ycodebuild = ycodeDir.appendingPathComponent(".build/debug/ycodebuild").path
        let agent = ycodeDir.appendingPathComponent(".build/debug/libYcodeTestAgent.dylib").path
        guard fm.isExecutableFile(atPath: ycodebuild), fm.fileExists(atPath: agent) else { return nil }
        let env = ProcessInfo.processInfo.environment
        let helper = env["YCODE_SWB"] ?? ycodeDir.appendingPathComponent("Tools/ycode-swb/.build/debug/ycode-swb").path
        guard fm.isExecutableFile(atPath: helper) else { return nil }
        return (ycodebuild, helper, agent)
    }

    /// A copy of a sample project (tests must not write into the repository).
    static func copySample(_ name: String) throws -> URL {
        let dir = ycodeDir.appendingPathComponent(".build-ide/hosted-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: ycodeDir.appendingPathComponent("Samples/TestHostSamples/" + name), to: to)
        return to.appendingPathComponent(name + ".xcodeproj")
    }

    /// Removes the DerivedData folder a run made for a copied sample (its
    /// result bundle line names it), so runs leave no build output behind.
    static func removeDerivedData(_ session: WorkspaceSession, sample: String) {
        for line in session.buildLog {
            guard let r = line.range(of: "/Logs/Test/") else { continue }
            let folder = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let name = URL(fileURLWithPath: folder).lastPathComponent
            guard folder.contains("/DerivedData/"), name.hasPrefix(sample + "-") else { continue }
            try? FileManager.default.removeItem(atPath: folder)
        }
    }

    @Test func hostedMacTestsPassAndFailAsWritten() async throws {
        guard let tools = Self.tools() else {
            print("skipping: ycodebuild, the test agent or the swift-build helper is not built")
            return
        }
        _ = NSApplication.shared
        let project = try Self.copySample("HostMac")
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent().deletingLastPathComponent()) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: project))
        defer { Self.removeDerivedData(session, sample: "HostMac") }
        session.scheme = "HostMac"
        session.testRunner.xcodebuild = [tools.ycodebuild]
        session.testRunner.environment = ["YCODE_SWB": tools.helper, "YCODE_TEST_AGENT": tools.agent]
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        await session.testsDiscovered()
        let ids = Set(session.tests.map(\.identifier))
        #expect(ids.isSuperset(of: ["HostMacXCTests/testAddsInTheApp", "HostMacXCTests/testFailsOnPurpose", "HostMacSwiftTests/failsOnPurpose"]))

        let outcomes = await session.runTests()
        func status(_ id: String) -> TestOutcome.Status? { session.tests.first { $0.identifier == id }.flatMap { session.testResults[$0] } }
        #expect(status("HostMacXCTests/testAddsInTheApp") == .passed)
        #expect(status("HostMacXCTests/testRunsAfterLaunch") == .passed)
        #expect(status("HostMacXCTests/testPlanEnvironment") == .passed)
        #expect(status("HostMacXCTests/testFailsOnPurpose") == .failed)
        #expect(status("HostMacSwiftTests/addsInTheApp") == .passed)
        #expect(status("HostMacSwiftTests/runsAfterLaunch") == .passed)
        #expect(status("HostMacSwiftTests/failsOnPurpose") == .failed)
        #expect(outcomes.contains { $0.name == "testSkipped" && $0.status == .skipped })
        // The failures are issues at their lines.
        #expect(session.issues.contains { $0.location?.line == 24 && $0.location?.file.hasSuffix("HostMacXCTests.swift") == true })
        #expect(session.reports.first?.succeeded == false)

        // One test's diamond runs only that test, inside the app.
        let file = project.deletingLastPathComponent().appendingPathComponent("HostMacXCTests/HostMacXCTests.swift").path
        wc.open(path: file, line: nil)
        let one = session.tests.filter { $0.identifier == "HostMacXCTests/testAddsInTheApp" }
        let single = await session.runTests(only: one)
        #expect(single.map(\.name) == ["testAddsInTheApp"] && single.first?.status == .passed)
        #expect(session.reports.first?.succeeded == true)
    }

    /// ⌘U with the Ycode simulator chosen: the HostPhone sample's hosted
    /// tests run in the app on the remote simulator and their results reach
    /// the Test navigator. Opt-in, with the remote run test's variables
    /// (`YCODE_E2E_REMOTE`, `YCODE_E2E_DATA`, `YCODE_E2E_RUNTIME`,
    /// `YCODE_E2E_SIMD`, `YCODE_E2E_DEVICE`) and the simulator build of the
    /// agent (`OUT=.build/debug SimGuestAgents/build-test-agent.sh`).
    @Test func hostedPhoneTestsRunOnTheYcodeSimulator() async throws {
        let env = ProcessInfo.processInfo.environment
        let simAgent = ycodeDir.appendingPathComponent(".build/debug/iphonesimulator/libYcodeTestAgent.dylib").path
        guard let tools = Self.tools(), FileManager.default.fileExists(atPath: simAgent),
              let destination = env["YCODE_E2E_REMOTE"], let data = env["YCODE_E2E_DATA"], let runtime = env["YCODE_E2E_RUNTIME"],
              let simd = env["YCODE_E2E_SIMD"] else {
            print("skipping: YCODE_E2E_REMOTE and friends, or the simulator test agent, are not set up")
            return
        }
        _ = NSApplication.shared
        let project = try Self.copySample("HostPhone")
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent().deletingLastPathComponent()) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: project))
        defer { Self.removeDerivedData(session, sample: "HostPhone") }
        session.scheme = "HostPhone"
        session.testRunner.xcodebuild = [tools.ycodebuild]
        session.testRunner.environment = ["YCODE_SWB": tools.helper, "YCODE_TEST_AGENT_IPHONESIMULATOR": simAgent]
        var settings = RemoteSimulatorSettings(destination: destination, dataDirectory: data, runtimeRoot: runtime, simdPath: simd,
                                               deviceName: env["YCODE_E2E_DEVICE"] ?? "e2e")
        settings.warmBoot = env["YCODE_E2E_WARM_BOOT"] != "0"
        session.remoteSimulatorForTests = { _ in RemoteSimulator(settings: settings, target: nil) }
        session.destination = RemoteSimulator.destination
        await session.testsDiscovered()
        let outcomes = await session.runTests()
        print("---- test log ----\n" + session.buildLog.suffix(60).joined(separator: "\n"))
        func status(_ id: String) -> TestOutcome.Status? { session.tests.first { $0.identifier == id }.flatMap { session.testResults[$0] } }
        #expect(status("HostPhoneTests/testAppTitle") == .passed)
        #expect(status("HostPhoneTests/testRunsInTheApp") == .passed)
        #expect(status("HostPhoneTests/testFailsOnPurpose") == .failed)
        #expect(status("HostPhoneSwiftTests/title") == .passed)
        #expect(status("HostPhoneSwiftTests/failsOnPurpose") == .failed)
        #expect(outcomes.count == 5)
    }
}
#endif
