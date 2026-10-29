import AppKit
import Foundation
import Testing
import YcodeBuild
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

    // MARK: T11 — default simulator

    @Test func newestProIPhoneOnTheNewestRuntimeThatHasOne() {
        // §2.4.3 acceptance: "iPhone 18 Pro" on 27.0, not the 27.1 rows that come first.
        let d = pick(observedSet)
        #expect(d.name == "iPhone 18 Pro" && d.osVersion == "27.0")
        #expect(DestinationMenuModel.submenuTitle(d) == "iPhone 18 Pro 27.0")
        // Without any Pro iPhone: the first row of the Simulators section.
        // (Within a runtime iPhones come first, so that is "iPhone Duo" on
        // 27.1; "Phone X" names no family.)
        let noPro = observedSet.filter { DestinationCatalog.proIPhoneGeneration(of: $0) == nil }
        #expect(pick(noPro) == DestinationMenuModel.orderedSimulators(noPro).first)
        #expect(pick(noPro).name == "iPhone Duo" && pick(noPro).osVersion == "27.1")
        // The deployment target leaves out runtimes below it.
        #expect(pick(observedSet, target: "27.1").name == "iPhone Duo")
        #expect(pick(observedSet + [sim("iPhone 17 Pro", "27.1")], target: "27.1").name == "iPhone 17 Pro")
        // No candidate: the generic simulator.
        #expect(pick([], target: "18.0").name == "Any iOS Simulator Device")
    }

    @Test func proGenerationsComeFromTheDeviceType() {
        #expect(DestinationCatalog.proIPhoneGeneration(of: sim("iPhone 18 Pro", "27.0")) == 18)
        for name in ["iPhone 18 Pro Max", "iPhone Air", "iPhone 17e", "iPhone 18", "Phone X", "iPad Pro 13-inch (M5)"] {
            #expect(DestinationCatalog.proIPhoneGeneration(of: sim(name, "27.0")) == nil, "\(name)")
        }
        // A renamed simulator keeps its type; a type that is not a Pro
        // iPhone wins nothing by its name.
        #expect(DestinationCatalog.proIPhoneGeneration(of: sim("Work phone", "27.0", type: "iPhone-18-Pro")) == 18)
        #expect(DestinationCatalog.proIPhoneGeneration(of: sim("iPhone 19 Pro", "27.0", type: "iPhone-Air")) == nil)
        let renamed = [sim("iPhone 17 Pro", "27.0", type: "iPhone-17-Pro"), sim("Work phone", "26.5", type: "iPhone-18-Pro")]
        #expect(pick(renamed).name == "Work phone")
        #expect(DestinationCatalog.deviceFamily(of: sim("Work phone", "26.5", type: "iPhone-18-Pro")) == "iPhone")
        #expect(DestinationCatalog.deviceFamily(of: sim("Tablet", "26.5", type: "iPad-Pro-13-inch-M5")) == "iPad")
        #expect(DestinationCatalog.deviceFamily(of: sim("Phone X", "27.1")) == nil)
        // simctl's listing carries the type.
        let json = Data("""
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
          {"udid": "U1", "name": "Mine", "isAvailable": true, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"}]}}
        """.utf8)
        let listed = DestinationCatalog.simulators(fromSimctlJSON: json)
        #expect(listed.first?.deviceType == "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro")
        #expect(pick(listed + [sim("iPhone 17 Pro", "27.0")]).name == "Mine")
    }

    @Test func deviceFamiliesTheProductSupports() {
        #expect(DestinationCatalog.deviceFamilies(targetedDeviceFamily: "1,2") == ["iPhone", "iPad"])
        #expect(DestinationCatalog.deviceFamilies(targetedDeviceFamily: "2") == ["iPad"])
        #expect(DestinationCatalog.deviceFamilies(targetedDeviceFamily: nil) == nil)
        #expect(DestinationCatalog.deviceFamilies(targetedDeviceFamily: "7") == nil)
        // An iPad-only app: no Pro iPhone, the first iPad.
        let named = observedSet.filter { $0.name != "Phone X" }
        #expect(pick(named, families: ["iPad"]).name == "iPad Air 11-inch (M4)")
        // Unknown families stay candidates.
        #expect(pick([sim("Phone X", "27.1"), sim("iPad Air", "27.0")], families: ["iPad"]).name == "Phone X")
    }

    /// Ycode's simulator rows (one per runtime root and device type) are
    /// rows of the Simulators section and rank there: by runtime, then by
    /// family and name, so a local simulator of the same type and runtime
    /// comes first; a newer runtime of the Pro type wins wherever it is.
    @Test func ycodeSimulatorRowsRankWithLocalSimulators() {
        let ycode18 = remoteRow(.iPhone18Pro, "27.0"), duo = remoteRow(.iPhoneDuo, "27.1", root: "/rr2"), ipad = remoteRow(.iPadA16, "27.0")
        #expect(ycode18.name == "iPhone 18 Pro (Ycode)" && DestinationCatalog.proIPhoneGeneration(of: ycode18) == 18)
        #expect(DestinationCatalog.proIPhoneGeneration(of: duo) == nil && DestinationCatalog.deviceFamily(of: ipad) == "iPad")
        // Same type and runtime: the local simulator.
        #expect(pick([ycode18, duo, ipad, sim("iPhone 18 Pro", "27.0")]).identifier == "iPhone 18 Pro-27.0")
        // Only an older runtime locally: Ycode's 27.0 row.
        let d = pick([ycode18, duo, ipad, sim("iPhone 18 Pro", "26.5"), sim("iPhone 17 Pro", "26.5")])
        #expect(d.isYcodeRemoteSimulator && d.name == "iPhone 18 Pro (Ycode)")
        // Ycode's rows alone, no Pro type: the first row (iPhone Duo on 27.1).
        #expect(pick([duo, ipad]).name == "iPhone Duo (Ycode)")
        // A row whose runtime version is not read yet sorts as the newest.
        let unread = remoteRow(.iPhone18Pro, nil)
        #expect(pick([unread, sim("iPhone 18 Pro", "26.5"), sim("iPhone 17", "27.0")]).isYcodeRemoteSimulator)
        #expect(pick([unread, sim("iPhone 18 Pro", "27.0")]).identifier == "iPhone 18 Pro-27.0")
    }

    // MARK: T3 — macOS-capable products default to My Mac

    @Test func multiplatformAppDefaultsToMyMac() {
        #expect(pick(observedSet, mac: true) == .myMac)
        #expect(DestinationCatalog.defaultDestination(platform: "macOS", deploymentTarget: nil, simulators: observedSet) == .myMac)
        #expect(DestinationCatalog.defaultDestination(platform: nil, deploymentTarget: nil, simulators: observedSet) == .myMac)
    }

    func project(_ tag: String, edit: (String) -> String) throws -> (dir: URL, proj: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r42-\(tag)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var o = ProjectOptions()
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
        let multi = try project("multi") { $0.replacingOccurrences(of: "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\"",
                                                                    with: "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator macosx\"") }
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

    // MARK: T5 — run texts

    @Test func runTextsHaveNoCounters() {
        #expect(WorkspaceSession.RunActivityText.launching("Tour") == "Launching Tour")
        #expect(WorkspaceSession.RunActivityText.configuringDebugger == "Configuring Debugger Actions")
        #expect(WorkspaceSession.RunActivityText.running("Tour", on: "iPhone 18 Pro") == "Running Tour on iPhone 18 Pro")
        #expect(WorkspaceSession.RunActivityText.finished("Tour", on: "iPhone 18 Pro") == "Finished running Tour on iPhone 18 Pro")
        #expect(DebugPresentation.runningTitle("Tour") == "Running Tour" && DebugPresentation.finishedTitle("Tour") == "Finished running Tour")
        for p: RemoteSimulator.Phase in [.booting, .launching(retries: 0), .launching(retries: 2)] {
            #expect(RemoteSimulator.status(p, app: "Tour", device: "iPhone Duo (Ycode)") == "Launching Tour")
        }
        #expect(RemoteSimulator.status(.running, app: "Tour", device: "iPhone Duo (Ycode)") == "Running Tour on iPhone Duo (Ycode)")
        // Accepted actions show their names (§3.2).
        #expect(WorkspaceSession.BuildActivityText.accepted(.test) == "Test" && WorkspaceSession.BuildActivityText.accepted(.analyze) == "Analyze")
        #expect(WorkspaceSession.BuildPresentation(action: .analyze, subject: "Tour").running == "Analyze")
        #expect(WorkspaceSession.BuildActivityText.isBuild("Analyze"))
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

    // MARK: T5 — test texts

    @Test func testProgressMovesForwardThroughTheTestTexts() {
        let p = TestActivityProgress(subject: "Calc")
        #expect(p.text == "Test")
        let lines = ["Building for debugging...", "[1/3] Compiling Calc Calc.swift", "[2/3] Compiling CalcTests CalcTests.swift",
                     "[3/3] Linking CalcPackageTests", "Build complete! (0.52s)", "Test Suite 'All tests' started at 2026-10-27",
                     "Test Case '-[CalcTests.CalcTests testAdds]' started.", "[9/9] not a build step any more"]
        let texts = lines.compactMap { p.feed($0) }
        #expect(texts == ["Building \u{2022} 0/3", "Building \u{2022} 1/3", "Building \u{2022} 2/3", "Configuring Debugger Actions", "Testing Calc"])
        #expect(p.phase == .testing)
        // xcodebuild: step headers, "Testing started", XCTest lines; swift-testing's run start.
        let x = TestActivityProgress(subject: "App")
        let xt = ["CompileSwift normal arm64 /p/A.swift", "Ld /p/App normal", "** TEST BUILD SUCCEEDED **", "Testing started",
                  "Test Suite 'All tests' started"].compactMap { x.feed($0) }
        #expect(xt == ["Building \u{2022} 0/1", "Building \u{2022} 1/2", "Configuring Debugger Actions", "Testing App"])
        let s = TestActivityProgress(subject: "Pkg")
        #expect(["\u{25C7} Test run started."].compactMap { s.feed($0) } == ["Testing Pkg"])
    }

    @Test func testFinishedTexts() {
        #expect(WorkspaceSession.testFinishedText(selected: true, passed: true) == "Test Completed")
        #expect(WorkspaceSession.testFinishedText(selected: true, passed: false) == "Test Completed")
        #expect(WorkspaceSession.testFinishedText(selected: false, passed: true) == "Test Succeeded")
        #expect(WorkspaceSession.testFinishedText(selected: false, passed: false) == "Test Failed")
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
