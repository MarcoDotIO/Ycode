import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// R42 (`specs/ide/reference-ui-6.md` §0): the default destination (T3,
/// §2.4.2), the default simulator (T11, §2.4.3) and the run and test
/// activity texts (T5, §3.2–§3.4). Simulators, `simctl`, ssh and the
/// launcher are stand-ins.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct RunTestTextsR42Tests {
    func sim(_ name: String, _ version: String, type: String? = nil) -> Destination {
        Destination(name: name, specifier: "platform=iOS Simulator,id=\(name)-\(version)", platform: "iOS", kind: .simulator,
                    osVersion: version, identifier: "\(name)-\(version)",
                    deviceType: type.map { "com.apple.CoreSimulator.SimDeviceType.\($0)" })
    }

    func remoteRow(_ type: YcodeSimulatorDeviceType, _ version: String?, root: String = "/rr") -> Destination {
        RemoteSimulatorTarget(runtimeRoot: root, runtimeVersion: version, deviceType: type, deviceDirectoryName: "d", isPrimary: false).destination
    }

    func pick(_ sims: [Destination], target: String = "18.0", families: Set<String>? = nil, mac: Bool = false) -> Destination {
        DestinationCatalog.defaultDestination(platform: "iOS", deploymentTarget: target, simulators: sims, supportsMacOS: mac,
                                              deviceFamilies: families, order: DestinationMenuModel.orderedSimulators)
    }

    /// The pass-6b observation: a newer device type on 27.1 (first in the
    /// Simulators order), the standard set on 27.0 and 26.5.
    var observedSet: [Destination] {
        [sim("Phone X", "27.1"), sim("iPhone Duo", "27.1"),
         sim("iPhone 18 Pro", "27.0"), sim("iPhone 18 Pro Max", "27.0"), sim("iPhone Air", "27.0"), sim("iPhone 17e", "27.0"),
         sim("iPhone 17 Pro", "27.0"), sim("iPad Air 11-inch (M4)", "27.0"),
         sim("iPhone 18 Pro", "26.5"), sim("iPhone 17 Pro", "26.5")]
    }

    func project(_ tag: String, edit: (String) -> String) throws -> (dir: URL, proj: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r42-\(tag)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var o = ProjectOptions()
        // The fixtures' simulator runtimes predate V(iOS) (templates.md § Notation).
        o.deploymentTarget = "18.0"
        o.productName = "Tour"
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .none
        o.setStorage(.none)
        let proj = try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
        let pbx = proj.appendingPathComponent("project.pbxproj")
        try edit(try String(contentsOf: pbx, encoding: .utf8)).write(to: pbx, atomically: true, encoding: .utf8)
        return (dir, proj)
    }

    func window(_ url: URL) throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        return WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: url)), loadDestinations: false,
                                         startLanguageService: false, openFirstFile: false,
                                         userStateURL: url.deletingLastPathComponent().appendingPathComponent("state.json"))
    }

    /// Lists simulators the way `setDestinationGroups` does, without the
    /// remote simulator rows another suite's shared settings may add.
    func list(_ wc: WorkspaceWindowController, _ groups: [DestinationGroup]) {
        wc.session.model.destinationGroups = groups
        wc.chooseDefaultDestination()
        wc.rebuildDestinationMenu()
    }

    @Test func projectsPickTheirDefaultInTheWindow() throws {
        let sims = DestinationCatalog.groups(devices: [], simulators: observedSet)
        // A multiplatform app (macOS in its supported platforms): My Mac.
        let multi = try project("multi") { $0.replacingOccurrences(of: "TARGETED_DEVICE_FAMILY = \"1,2\";",
                                                                    with: "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator macosx\";\n\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";") }
        defer { try? FileManager.default.removeItem(at: multi.dir) }
        let wm = try window(multi.proj)
        #expect(wm.defaultDestinationTraits.supportsMacOS)
        #expect(wm.session.destination == .myMac)
        list(wm, sims)
        #expect(wm.session.destination == .myMac)

        // An iOS-only app: the newest Pro iPhone.
        let ios = try project("ios") { $0 }
        defer { try? FileManager.default.removeItem(at: ios.dir) }
        let wi = try window(ios.proj)
        #expect(!wi.defaultDestinationTraits.supportsMacOS && wi.defaultDestinationTraits.deviceFamilies == ["iPhone", "iPad"])
        list(wi, sims)
        #expect(wi.session.destination?.name == "iPhone 18 Pro" && wi.session.destination?.osVersion == "27.0")
        #expect(wi.destinationTitle == "iPhone 18 Pro")

        // An iPad-only app: an iPad.
        let pad = try project("ipad") { $0.replacingOccurrences(of: "TARGETED_DEVICE_FAMILY = \"1,2\"", with: "TARGETED_DEVICE_FAMILY = 2") }
        defer { try? FileManager.default.removeItem(at: pad.dir) }
        let wp = try window(pad.proj)
        #expect(wp.defaultDestinationTraits.deviceFamilies == ["iPad"])
        // ("Phone X" names no family, so it would stay a candidate.)
        list(wp, DestinationCatalog.groups(devices: [], simulators: observedSet.filter { $0.name != "Phone X" }))
        #expect(wp.session.destination?.name == "iPad Air 11-inch (M4)")
    }

    func record(_ session: WorkspaceSession) -> () -> [WorkspaceSession.Activity] {
        final class Box { var all: [WorkspaceSession.Activity] = [] }
        let box = Box()
        session.observe { [weak session] c in
            guard c == .activity, let a = session?.activity, box.all.last != a else { return }
            box.all.append(a)
        }
        return { box.all }
    }

    func writeExecutable(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func app(in root: URL, id: String = "dev.ycode.tour", exe: String = "Tour") throws -> URL {
        let app = root.appendingPathComponent("build/\(exe).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleExecutable": exe], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        try "binary".write(to: app.appendingPathComponent(exe), atomically: true, encoding: .utf8)
        return app
    }

    /// A Mac simulator run without the debugger: "Launching" through boot,
    /// install and launch, then "Running … on <device>", after Stop
    /// "Finished running … on <device>". No boot or install texts.
    @Test func simulatorRunSequence() async throws {
        let root = ycodeDir.appendingPathComponent(".build-ide/r42-sim-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("bin/launch")
        try writeExecutable("""
        #!/bin/sh
        trap 'exit 0' TERM
        echo "dev.ycode.tour: 4242"
        echo "hello from the app"
        while true; do sleep 0.1; done
        """, launcher)
        var simctl = Simctl { _ in (0, "") }
        simctl.launchCommand = ["/bin/sh", launcher.path]
        let session = WorkspaceSession(model: try WorkspaceModel(url: try WindowSnapshotTests().samplePackage()))
        session.destination = sim("iPhone 18 Pro", "27.0")
        let seen = record(session)
        await session.runOnSimulator(app: try app(in: root), udid: "iPhone 18 Pro-27.0", debug: false, simctl: simctl)
        #expect(await waitUntil(20) { session.console.contains("hello from the app") })
        #expect(session.activity == .running("Running Tour on iPhone 18 Pro"))
        session.stopSimulatorRun(simctl: simctl)
        #expect(await waitUntil(20) { session.simulatorRun == nil })
        #expect(seen() == [.running("Launching Tour"), .running("Running Tour on iPhone 18 Pro"),
                           .finished("Finished running Tour on iPhone 18 Pro")])
        #expect(!seen().contains { if case .running(let s) = $0 { s.contains("Booting") || s.contains("Installing") } else { false } })
    }

    /// Ycode's remote simulator: the same sequence with the remote row's
    /// name, no "(1 of 3)" counters, no separate upload or boot text.
    @Test func remoteSimulatorRunSequence() async throws {
        let r = try SimulatorSideR37Tests().makeRemote("r42", launcher: """
        #!/bin/sh
        trap 'echo "ycode-sim: warm boot: the device was saved"; exit 0' INT
        echo "ycode-sim: booting"
        echo "install dev.ycode.remote: ok"
        echo "open: no completion within 60 s"
        echo "launched dev.ycode.remote pid 42"
        echo "hello from the remote app"
        while true; do sleep 0.1; done
        """)
        defer { try? FileManager.default.removeItem(at: r.root) }
        let session = try SimulatorSideR37Tests().session()
        let seen = record(session)
        let device = r.remote.destination.name
        #expect(device.hasSuffix("(Ycode)"))
        await session.runOnRemoteSimulator(app: try SimulatorSideR37Tests().app(in: r.root), remote: r.remote)
        #expect(await waitUntil(20) { session.console.contains("hello from the remote app") && session.simulatorRun?.remotePID != nil })
        #expect(session.activity == .running("Running Remote on \(device)"))
        session.stopSimulatorRun(remote: r.remote)
        #expect(await waitUntil(20) { session.simulatorRun == nil })
        let texts = seen().map { a -> String in
            switch a { case .running(let s), .building(let s), .paused(let s), .finished(let s): s; case .idle: "" }
        }
        #expect(texts == ["Launching Remote", "Running Remote on \(device)", RemoteSimulator.stoppingStatus(app: "Remote", saves: true),
                          "Finished running Remote on \(device)"])
        #expect(!texts.contains { $0.contains(" of 3)") || $0.contains("Booting") || $0.contains("Uploading") })
    }

    /// A test run with a stand-in `swift`: "Test", the build texts,
    /// "Configuring Debugger Actions", "Testing <scheme>", then the result:
    /// a passing selected test "Test Completed", the whole scheme "Test
    /// Succeeded" / "Test Failed".
    @Test func testRunSequence() async throws {
        let dir = ycodeDir.appendingPathComponent(".build-ide/r42-test-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTestPackage(at: dir.appendingPathComponent("Calc"))
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir.appendingPathComponent("Calc")))
        let tool = dir.appendingPathComponent("swift.sh")
        func fake(_ result: String) throws {
            try writeExecutable("""
            #!/bin/sh
            echo "[1/3] Compiling Calc Calc.swift"; sleep 0.05
            echo "[2/3] Compiling CalcTests CalcTests.swift"; sleep 0.05
            echo "[3/3] Linking CalcPackageTests"; sleep 0.05
            echo "Build complete! (0.30s)"; sleep 0.05
            echo "Test Suite 'All tests' started at 2026-10-27 10:00:00.000."; sleep 0.05
            echo "\(result)"
            """, tool)
        }
        session.testRunner.swift = ["/bin/sh", tool.path]
        session.discoverTests()
        await session.testsDiscovered()
        let adds = try #require(session.tests.first { $0.name == "testAdds" })

        try fake("Test Case '-[CalcTests.CalcTests testAdds]' passed (0.001 seconds).")
        var seen = record(session)
        _ = await session.runTests(only: [adds])
        var texts = seen().map { a -> String in
            switch a { case .running(let s), .building(let s), .paused(let s), .finished(let s): s; case .idle: "" }
        }
        #expect(texts.first == "Test")
        #expect(texts.last == "Test Completed")
        let configuring = try #require(texts.firstIndex(of: "Configuring Debugger Actions"))
        let testing = try #require(texts.firstIndex(of: "Testing Calc"))
        let building = try #require(texts.firstIndex { $0.hasPrefix("Building \u{2022} ") })
        #expect(building < configuring && configuring < testing)
        #expect(session.testActivityProgress == nil)

        // Test Again repeats the selected run.
        seen = record(session)
        _ = await session.testAgain()
        #expect(seen().last == .finished("Test Completed"))

        // The whole scheme: Succeeded / Failed.
        seen = record(session)
        _ = await session.runTests()
        #expect(seen().last == .finished("Test Succeeded"))
        try fake("Test Case '-[CalcTests.CalcTests testBroken]' failed (0.001 seconds).")
        seen = record(session)
        _ = await session.runTests()
        texts = seen().map { a -> String in
            switch a { case .running(let s), .building(let s), .paused(let s), .finished(let s): s; case .idle: "" }
        }
        #expect(texts.last == "Test Failed")
    }
}
