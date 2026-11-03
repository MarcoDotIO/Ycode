import Foundation
import Testing
@testable import YcodeXcodebuild

/// Hosted tests (`TEST_HOST`), the test-host protocol, test plans and the
/// result-bundle reader. See `specs/ide/testing.md` and
/// `specs/xcodebuild/test-actions.md`, "Ycode implementation".
@Suite struct TestHostProtocolTests {
    func report(_ fields: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) // swiftlint:disable:this force_try
        return TestHostProtocol.prefix + String(decoding: data, as: UTF8.self)
    }

    @Test func linesSplitIntoTextAndReports() {
        let plain = TestHostProtocol.split("Test Case '-[M.C t]' started.")
        #expect(plain.text == "Test Case '-[M.C t]' started." && plain.event == nil)
        let r = TestHostProtocol.split(report(["kind": "runFinished", "session": "s", "v": 1]))
        #expect(r.text == nil && r.event?.kind == "runFinished" && r.event?.string("session") == "s")
        // The app's partial line before a report stays the app's.
        let mixed = TestHostProtocol.split("app says " + report(["kind": "agentLoaded"]))
        #expect(mixed.text == "app says " && mixed.event?.kind == "agentLoaded")
        // A broken report is ordinary text.
        #expect(TestHostProtocol.split(TestHostProtocol.prefix + "{nope").event == nil)
    }

    @Test func planJSON() throws {
        var plan = TestHostProtocol.Plan(session: "S1", bundles: [.init(path: "T.xctest", module: "T", only: ["C/test()"], skip: ["D"])],
                                         repetition: .init(mode: .retryOnFailure, count: 3))
        plan.launchTimeout = 12
        let o = try #require(try JSONSerialization.jsonObject(with: Data(plan.json.utf8)) as? [String: Any])
        #expect(o["session"] as? String == "S1" && o["launchTimeout"] as? Double == 12)
        let b = try #require((o["bundles"] as? [[String: Any]])?.first)
        #expect(b["path"] as? String == "T.xctest" && b["module"] as? String == "T")
        #expect(b["only"] as? [String] == ["C/test()"] && b["skip"] as? [String] == ["D"])
        #expect((o["repetition"] as? [String: Any])?["mode"] as? String == "retryOnFailure")
        // No repetition: no key.
        #expect(!TestHostProtocol.Plan(bundles: []).json.contains("repetition"))
    }

    @Test func agentLocation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("iphonesimulator"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.path + "/libYcodeTestAgent.dylib", contents: Data())
        FileManager.default.createFile(atPath: dir.path + "/iphonesimulator/libYcodeTestAgent.dylib", contents: Data())
        #expect(TestHostProtocol.agent(sdk: "macosx", environment: [:], executableDirectory: dir.path) == dir.path + "/libYcodeTestAgent.dylib")
        #expect(TestHostProtocol.agent(sdk: "iphonesimulator", environment: [:], executableDirectory: dir.path)
                == dir.path + "/iphonesimulator/libYcodeTestAgent.dylib")
        let other = dir.path + "/libYcodeTestAgent.dylib"
        #expect(TestHostProtocol.agent(sdk: "iphonesimulator", environment: ["YCODE_TEST_AGENT_IPHONESIMULATOR": other], executableDirectory: nil) == other)
        #expect(TestHostProtocol.agent(sdk: "xrsimulator", environment: [:], executableDirectory: dir.path) == nil)
    }
}

@Suite struct HostRunCollectorTests {
    func target(_ name: String, app: String = "/p/Debug/App.app") -> TestTarget {
        var t = TestTarget(blueprintName: name, projectName: "App", projectRelativePath: "App.xcodeproj", blueprintIdentifier: "",
                           moduleName: name, bundleIdentifier: "", bundlePath: app + "/PlugIns/\(name).xctest", executablePath: "",
                           productsDirectory: "/p/Debug", testHost: app + "/App")
        t.platform = "iphonesimulator"
        return t
    }

    func report(_ fields: [String: Any]) -> String {
        var f = fields
        f["session"] = f["session"] ?? "S"
        let data = try! JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) // swiftlint:disable:this force_try
        return TestHostProtocol.prefix + String(decoding: data, as: UTF8.self)
    }

    /// A transcript of one host running two bundles, as the agent and the
    /// libraries print it.
    var transcript: [String] {
        [
            "app: launching",
            report(["kind": "agentLoaded", "pid": 7]),
            report(["kind": "runStarted", "bundles": 2]),
            report(["kind": "bundleStarted", "path": "UnitTests.xctest", "module": "UnitTests"]),
            report(["kind": "bundleLoaded", "path": "/x/App.app/PlugIns/UnitTests.xctest"]),
            "Test Suite 'All tests' started at 2026-10-30 10:00:00.000.",
            "Test Case '-[UnitTests.UnitTests testA]' started.",
            report(["kind": "testStarted", "framework": "XCTest", "suite": "UnitTests", "name": "testA"]),
            "Test Case '-[UnitTests.UnitTests testA]' passed (0.001 seconds).",
            "/src/U.swift:9: error: -[UnitTests.UnitTests testB] : XCTAssertTrue failed",
            "Test Case '-[UnitTests.UnitTests testB]' failed (0.002 seconds).",
            report(["kind": "bundleFinished", "path": "UnitTests.xctest"]),
            report(["kind": "bundleStarted", "path": "SwiftTests.xctest", "module": "SwiftTests"]),
            report(["kind": "swiftTest", "id": "SwiftTests.Model/adds()/M.swift:3:6", "name": "adds()", "isSuite": false,
                    "file": "/src/M.swift", "line": 3]),
            report(["kind": "swiftTest", "id": "SwiftTests.Model", "name": "Model", "isSuite": true]),
            "◇ Test adds() started.",
            "✘ Test adds() recorded an issue at M.swift:4:9: Expectation failed: 1 == 2",
            "✘ Test adds() failed after 0.001 seconds with 1 issue.",
            report(["kind": "bundleFinished", "path": "SwiftTests.xctest"]),
            report(["kind": "runFinished", "status": "failed", "exitCode": 1]),
        ]
    }

    @Test func routesLinesToBundlesAndHidesReports() {
        var echoed: [String] = []
        let lock = NSLock()
        let c = HostRunCollector(session: "S", targets: [target("UnitTests"), target("SwiftTests")]) { l in lock.withLock { echoed.append(l) } }
        for l in transcript { c.feed(l) }
        #expect(c.isAgentLoaded && c.isFinished && c.errors.isEmpty)
        #expect(!echoed.contains { $0.contains(TestHostProtocol.prefix) })
        #expect(echoed.first == "app: launching")
        let unit = c.parts[0].parser.results
        #expect(unit.map(\.name) == ["testA", "testB"] && unit.map(\.status) == [.passed, .failed])
        #expect(unit[1].issues.first?.file == "/src/U.swift")
        // The suite comes from the agent's swiftTest report (hosted bundles cannot be listed beforehand).
        let swift = c.parts[1].parser.results
        #expect(swift.count == 1 && swift[0].suite == "Model" && swift[0].status == .failed)
        #expect(swift[0].issues.first?.file == "/src/M.swift")
        #expect(c.hostOutput.contains("app: launching"))
    }

    @Test func otherSessionsAndCrashes() {
        let c = HostRunCollector(session: "S", targets: [target("UnitTests")]) { _ in }
        // A stale report from an earlier run (another session) is ignored.
        c.feed(report(["kind": "runFinished", "session": "OLD"]))
        #expect(!c.isFinished)
        c.feed(report(["kind": "agentLoaded"]))
        c.feed(report(["kind": "bundleStarted", "path": "UnitTests.xctest"]))
        c.feed(report(["kind": "testStarted", "framework": "XCTest", "suite": "UnitTests", "name": "testCrash"]))
        var outcome = TestActions.Outcome()
        TestActions.collect(c, status: .exited(139), hostName: "App", into: &outcome)
        #expect(outcome.errors == ["App exited with status 139 before its tests finished (while running UnitTests/testCrash)."])
        var none = TestActions.Outcome()
        TestActions.collect(HostRunCollector(session: "S", targets: []) { _ in }, status: .noAgent, hostName: "App", into: &none)
        #expect(none.errors.first?.contains("did not load Ycode's test agent") == true)
    }

    @Test func agentErrorsAreReported() {
        let c = HostRunCollector(session: "S", targets: [target("UnitTests")]) { _ in }
        c.feed(report(["kind": "error", "message": "There is no test bundle at /x."]))
        c.feed(report(["kind": "runFinished", "exitCode": 70]))
        var outcome = TestActions.Outcome()
        TestActions.collect(c, status: .exited(70), hostName: "App", into: &outcome)
        #expect(outcome.errors == ["There is no test bundle at /x."])
        #expect(!outcome.succeeded)
    }

    @Test func hostAppAndBundlePaths() throws {
        let t = target("UnitTests")
        let host = try #require(TestActions.hostApp(t))
        #expect(host.app == "/p/Debug/App.app" && host.executable == "/p/Debug/App.app/App")
        #expect(TestActions.agentBundlePath(t, app: host.app) == "UnitTests.xctest")
        var mac = t
        mac.testHost = "/p/Debug/Mac.app/Contents/MacOS/Mac"
        mac.bundlePath = "/p/Debug/Mac.app/Contents/PlugIns/UnitTests.xctest"
        #expect(TestActions.hostApp(mac)?.app == "/p/Debug/Mac.app")
        #expect(TestActions.agentBundlePath(mac, app: "/p/Debug/Mac.app") == "UnitTests.xctest")
        var outside = t
        outside.bundlePath = "/elsewhere/UnitTests.xctest"
        #expect(TestActions.agentBundlePath(outside, app: host.app) == "/elsewhere/UnitTests.xctest")
        var none = t
        none.testHost = "/usr/bin/tool"
        #expect(TestActions.hostApp(none) == nil)
    }

    @Test func languageArguments() {
        var t = target("UnitTests")
        t.language = "fr"
        t.region = "CA"
        #expect(TestActions.languageArguments(t) == ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_CA"])
        t.testHost = nil
        #expect(TestActions.languageArguments(t).isEmpty)
    }
}

@Suite struct TestPlanOptionsTests {
    let plan = """
    {
      "configurations" : [
        { "id" : "A", "name" : "English", "options" : { "language" : "en", "region" : "GB" } },
        { "id" : "B", "name" : "Repeated", "options" : { "testRepetitionMode" : "untilFailure", "maximumTestRepetitions" : 5,
          "environmentVariableEntries" : [ { "key" : "MODE", "value" : "repeat" } ] } }
      ],
      "defaultOptions" : {
        "commandLineArgumentEntries" : [ { "argument" : "-flag", "enabled" : true }, { "argument" : "-off", "enabled" : false } ],
        "environmentVariableEntries" : [ { "key" : "MODE", "value" : "default" }, { "key" : "OFF", "value" : "x", "enabled" : false } ],
        "testRepetitionMode" : "retryOnFailure",
        "codeCoverage" : { "targets" : [] },
        "testTimeoutsEnabled" : true
      },
      "testTargets" : [
        { "parallelizable" : true, "skippedTests" : [ "C/testB()" ],
          "target" : { "containerPath" : "container:App.xcodeproj", "identifier" : "ABC", "name" : "AppTests" } },
        { "enabled" : false, "selectedTests" : [ "S/f()" ],
          "target" : { "containerPath" : "container:App.xcodeproj", "identifier" : "DEF", "name" : "OtherTests" } }
      ],
      "version" : 1
    }
    """

    @Test func entriesOptionsAndConfigurations() throws {
        let f = try #require(TestPlanFile(data: Data(plan.utf8), name: "Plan"))
        #expect(f.entries.map(\.targetName) == ["AppTests", "OtherTests"])
        #expect(f.entries[0].identifier == "ABC" && f.entries[0].parallelizable == true && f.entries[0].skipped == ["C/testB()"])
        #expect(f.entries[1].enabled == false && f.entries[1].selected == ["S/f()"])
        #expect(f.defaultOptions.enabledArguments == ["-flag"])
        #expect(f.defaultOptions.enabledEnvironment == ["MODE": "default"])
        #expect(f.defaultOptions.codeCoverage == true && f.defaultOptions.testTimeoutsEnabled == true)
        #expect(f.defaultOptions.repetition == .init(mode: .retryOnFailure, count: 3))
        let english = f.options(for: f.configurations[0])
        #expect(english.language == "en" && english.region == "GB" && english.enabledEnvironment == ["MODE": "default"])
        let repeated = f.options(for: f.configurations[1])
        #expect(repeated.repetition == .init(mode: .untilFailure, count: 5) && repeated.enabledEnvironment == ["MODE": "repeat"])
        #expect(repeated.enabledArguments == ["-flag"])
        #expect(f.configurations(only: [], skip: []).map(\.name) == ["English", "Repeated"])
        #expect(f.configurations(only: ["Repeated"], skip: []).map(\.name) == ["Repeated"])
        #expect(f.configurations(only: [], skip: ["English"]).map(\.name) == ["Repeated"])
        // A plan without configurations has one.
        let bare = try #require(TestPlanFile(data: Data(#"{"testTargets":[]}"#.utf8), name: "Bare"))
        #expect(bare.configurations(only: [], skip: []).map(\.name) == ["Configuration 1"])
    }

    @Test func referenceNames() {
        #expect(TestPlanFile.name(ofReference: "container:Plan.xctestplan") == "Plan")
        #expect(TestPlanFile.name(ofReference: "container:Dir/Smoke.xctestplan") == "Smoke")
        #expect(TestPlanFile.name(ofReference: "Other.xctestplan") == "Other")
    }

    @Test func expansionPerConfiguration() throws {
        let f = try #require(TestPlanFile(data: Data(plan.utf8), name: "Plan"))
        let t = TestTarget(blueprintName: "AppTests", projectName: "App", projectRelativePath: "", blueprintIdentifier: "", moduleName: "AppTests",
                           bundleIdentifier: "", bundlePath: "/b", executablePath: "", productsDirectory: "/p", testHost: nil)
        let inv = try #require(try? ArgumentParser.parse(["test"]))
        let out = TestActions.expand([t], plan: f, inv)
        #expect(out.map { $0.configuration } == ["English", "Repeated"])
        #expect(out[0].language == "en" && out[0].arguments == ["-flag"] && out[0].environment["MODE"] == "default")
        #expect(out[1].repetition?.mode == TestPlanFile.Repetition.Mode.untilFailure && out[1].environment["MODE"] == "repeat")
        let only = TestActions.expand([t], plan: f, try #require(try? ArgumentParser.parse(["-only-test-configuration", "English", "test"])))
        #expect(only.count == 1 && only[0].configuration == "English")
        // One configuration: not named in the results.
        let single = try #require(TestPlanFile(data: Data(#"{"configurations":[{"id":"1","name":"C","options":{}}],"testTargets":[]}"#.utf8), name: "P"))
        #expect(TestActions.expand([t], plan: single, inv).map { $0.configuration } == [String?.none])
    }

    @Test func commandLineRepetitions() throws {
        func rep(_ a: [String]) throws -> TestPlanFile.Repetition? { TestActions.commandLineRepetition(try #require(try? ArgumentParser.parse(a + ["test"]))) }
        #expect(try rep(["-test-iterations", "4"]) == .init(mode: .fixedIterations, count: 4))
        #expect(try rep(["-retry-tests-on-failure"]) == .init(mode: .retryOnFailure, count: 3))
        #expect(try rep(["-run-tests-until-failure", "-test-iterations", "7"]) == .init(mode: .untilFailure, count: 7))
        #expect(try rep(["-run-tests-until-failure"]) == .init(mode: .untilFailure, count: 100))
        #expect(try rep([]) == nil)
    }

    @Test func repetitionsCollapse() {
        func r(_ name: String, _ s: TestCaseResult.Status) -> TestCaseResult {
            TestCaseResult(library: .xctest, module: "M", suite: "C", name: name, status: s, duration: 1)
        }
        let runs = [r("a", .failed), r("b", .passed), r("a", .passed), r("b", .passed)]
        let retried = TestActions.collapseRepetitions(runs, mode: .retryOnFailure)
        #expect(retried.map(\.status) == [.passed, .passed] && retried[0].duration == 2)
        let fixed = TestActions.collapseRepetitions(runs, mode: .fixedIterations)
        #expect(fixed.map(\.status) == [.failed, .passed])
        #expect(TestActions.collapseRepetitions(runs, mode: nil).count == 4)
    }
}

@Suite struct RemoteTestHostTests {
    let env = ["YCODE_SIM_HOST": "u@h", "YCODE_SIM_DATA": "/data", "YCODE_SIM_RUNTIME": "/rt", "YCODE_SIM_SIMD": "/bin/ycode-sim",
               "YCODE_SIM_DEVICE": "p18", "YCODE_SIM_OPTIONS": "--device-type 'iPhone 18 Pro' --timeout-ms 5", "YCODE_SIM_ENV": "YCODE_WARM_BOOT=1"]

    @Test func settingsFromTheEnvironment() throws {
        let s = try #require(RemoteTestHost.Settings.from(environment: env))
        #expect(s.destination == "u@h" && s.devicePath == "/data/devices/p18" && s.remoteApp("A.app") == "/data/test-apps/A.app")
        #expect(s.options == ["--device-type", "iPhone 18 Pro", "--timeout-ms", "5"] && s.environment == ["YCODE_WARM_BOOT=1"])
        var partial = env
        partial["YCODE_SIM_SIMD"] = nil
        #expect(RemoteTestHost.Settings.from(environment: partial) == nil)
    }

    @Test func destinations() {
        #expect(RemoteTestHost.isYcodeSimulator("platform=iOS Simulator,name=Ycode Simulator,arch=arm64"))
        #expect(RemoteTestHost.isYcodeSimulator("platform=iOS Simulator,id=ycode-remote-simulator"))
        #expect(!RemoteTestHost.isYcodeSimulator("platform=iOS Simulator,name=iPhone 17"))
        #expect(!RemoteTestHost.isYcodeSimulator("platform=macOS,name=Ycode"))
    }

    @Test func remoteCommand() throws {
        let s = try #require(RemoteTestHost.Settings.from(environment: env))
        let host = RemoteTestHost(settings: s, context: XcodebuildContext.current(console: CapturingConsole().console))
        let plan = TestHostProtocol.Plan(session: "S", bundles: [.init(path: "T.xctest", module: "T")])
        let c = host.command(app: "/data/test-apps/A.app", bundleID: "org.x.A", plan: plan)
        #expect(c.hasPrefix("rm -f '/data/devices/p18/data/tmp/ycode-app.err' '/data/devices/p18/data/tmp/ycode-app.out'; echo YCODE-REMOTE-PID $$; "))
        #expect(c.contains("( tail --pid=$$ -n +1 -F '/data/devices/p18/data/tmp/ycode-app.err' 2>/dev/null | sed -u 's/^/YCODE-APP|/' & ); "))
        #expect(c.contains("exec env 'YCODE_WARM_BOOT=1' '/bin/ycode-sim' --device '/data/devices/p18' --runtime-root '/rt' '--device-type' 'iPhone 18 Pro'"))
        #expect(c.contains(" --install-app '/data/test-apps/A.app' --launch 'org.x.A'"))
        #expect(c.contains("--app-env 'DYLD_INSERT_LIBRARIES=@executable_path/Frameworks/libYcodeTestAgent.dylib'"))
        #expect(c.contains("--app-env 'YCODE_TEST_PLAN={\"bundles\":[{\"module\":\"T\""))
        #expect(c.hasSuffix(" 2>&1"))
    }

    @Test func words() {
        #expect(RemoteTestHost.words(#"a 'b c' "d\"e" f\ g"#) == ["a", "b c", "d\"e", "f g"])
        #expect(RemoteTestHost.words("  ").isEmpty)
    }

    /// Test builds for a simulator ask swift-build to embed the testing
    /// libraries in the host (its SKIP_COPYING_TEST_FRAMEWORKS escape hatch);
    /// other builds keep swift-build's default.
    @Test func simulatorTestBuildsEmbedTheTestingLibraries() {
        let copy = [("SKIP_COPYING_TEST_FRAMEWORKS", "NO")]
        for sdk in ["iphonesimulator", "iphonesimulator27.0", "/X/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk", "xrsimulator"] {
            #expect(TestActions.testFrameworkCopying(action: .buildForTesting, sdk: sdk).elementsEqual(copy, by: ==))
            #expect(TestActions.testFrameworkCopying(action: .test, sdk: sdk).elementsEqual(copy, by: ==))
        }
        #expect(TestActions.testFrameworkCopying(action: .build, sdk: "iphonesimulator").isEmpty)
        #expect(TestActions.testFrameworkCopying(action: .testWithoutBuilding, sdk: "iphonesimulator").isEmpty)
        #expect(TestActions.testFrameworkCopying(action: .buildForTesting, sdk: "macosx").isEmpty)
        #expect(TestActions.testFrameworkCopying(action: .buildForTesting, sdk: "iphoneos").isEmpty)
        #expect(TestActions.testFrameworkCopying(action: .buildForTesting, sdk: nil).isEmpty)
    }
}

@Suite struct HostedTestRunFileTests {
    @Test func hostedKeysRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-xctestrun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.path + "/Debug-iphonesimulator/App.app"
        try FileManager.default.createDirectory(atPath: app + "/PlugIns/AppTests.xctest", withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "App", "CFBundleIdentifier": "org.x.App"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Info.plist"))
        var t = TestTarget(blueprintName: "AppTests", projectName: "App", projectRelativePath: "App.xcodeproj", blueprintIdentifier: "",
                           moduleName: "AppTests", bundleIdentifier: "org.x.AppTests", bundlePath: app + "/PlugIns/AppTests.xctest",
                           executablePath: "", productsDirectory: app + "/PlugIns", testHost: app + "/App")
        t.platform = "iphonesimulator"
        let plist = XCTestRunFile.make(scheme: "App", containerName: "App", testPlan: "App", isDefaultPlan: true, targets: [t], testRoot: root.path)
        let entry = try #require(((plist["TestConfigurations"] as? [[String: Any]])?.first?["TestTargets"] as? [[String: Any]])?.first)
        #expect(entry["TestHostPath"] as? String == "__TESTROOT__/Debug-iphonesimulator/App.app")
        #expect(entry["TestBundlePath"] as? String == "__TESTHOST__/PlugIns/AppTests.xctest")
        #expect(entry["TestHostBundleIdentifier"] as? String == "org.x.App" && entry["IsAppHostedTestBundle"] as? Bool == true)
        let file = root.path + "/App.xctestrun"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: file))
        let read = try XCTestRunFile.read(file, developerDirectory: "/dev")
        let back = try #require(read.targets.first)
        #expect(back.testHost == app + "/App" && back.bundlePath == app + "/PlugIns/AppTests.xctest" && back.platform == "iphonesimulator")
    }
}

@Suite struct ResultBundleReaderTests {
    func outcome() -> TestActions.Outcome {
        var o = TestActions.Outcome()
        func target(_ config: String?) -> TestTarget {
            var t = TestTarget(blueprintName: "AppTests", projectName: "App", projectRelativePath: "App.xcodeproj", blueprintIdentifier: "",
                               moduleName: "AppTests", bundleIdentifier: "", bundlePath: "/b", executablePath: "", productsDirectory: "/p",
                               testHost: "/p/App.app/App")
            t.configuration = config
            return t
        }
        var failed = TestCaseResult(library: .xctest, module: "AppTests", suite: "AppTests", name: "testB", status: .failed, duration: 0.5)
        failed.issues = [.init(message: "XCTAssertEqual failed", file: "/src/A.swift", line: 12)]
        var skipped = TestCaseResult(library: .xctest, module: "AppTests", suite: "AppTests", name: "testC", status: .skipped, duration: 0)
        skipped.skipMessage = "later"
        let passed = TestCaseResult(library: .xctest, module: "AppTests", suite: "AppTests", name: "testA", status: .passed, duration: 0.25)
        var swift = TestCaseResult(library: .swiftTesting, module: "AppTests", suite: "Model", name: "doubles(_:)", status: .passed, duration: 0.1)
        swift.arguments = [.init(label: "n", value: "2")]
        for config in ["English", "German"] {
            let results = config == "English" ? [passed, failed, skipped, swift] : [passed]
            o.targets.append(.init(target: target(config), results: results, selected: false, starts: ["doubles(_:)": 1]))
            o.results += results
        }
        return o
    }

    @Test func writtenBundlesReadBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-xcresult-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Run.xcresult").path
        let s = ResultBundleSession(path: path, given: path, explicit: true, containerPath: "/w/App.xcodeproj", containerLabel: "App project",
                                    projectName: "App", schemeName: "App", runDestination: nil, sdk: nil)
        let capture = CapturingConsole()
        s.record(.init(commandName: "Test", taskName: "BuildAndAction", title: "Testing project App with scheme App", started: Date(), ended: Date(),
                       build: nil, tests: outcome(), testPlanName: "App", testRequested: true), quiet: true, console: capture.console)
        let r = try XCResultReader(URL(fileURLWithPath: path))
        #expect(try r.root().typeName == "ActionsInvocationRecord")
        let tests = try r.tests()
        #expect(tests.map(\.run) == ["English", "English", "English", "English", "German"])
        #expect(tests.map(\.identifier) == ["AppTests/testA()", "AppTests/testB()", "AppTests/testC()", "Model/doubles(_:)", "AppTests/testA()"])
        #expect(tests.map(\.status) == ["Success", "Failure", "Skipped", "Success", "Success"])
        #expect(tests[1].failures == [.init(message: "XCTAssertEqual failed", file: "/src/A.swift", line: 12)])
        #expect(tests[2].skipMessage == "Test skipped - later")
        #expect(tests[3].arguments == ["2"] && tests[0].duration == 0.25)
        let m = try r.metrics()
        #expect(m["testsCount"] == 5 && m["testsFailedCount"] == 1 && m["testsSkippedCount"] == 1)
    }

    @Test func objectEncodingRoundTrips() throws {
        let v = XCRValue.obj(XCRType("Outer", "Base"), [
            "name": .string("a:b [c]"), "count": .int(3), "items": .array([.bool(true), .double(1.5)]),
            "inner": .obj(XCRType("Outer", "Base"), ["name": .string("é")]),
        ])
        let back = try XCRValue.decode(XCRValue.encode(v))
        #expect(XCRValue.encode(back) == XCRValue.encode(v))
        #expect(back["inner"]?["name"]?.text == "é" && back["items"]?.items?.count == 2 && back.typeName == "Outer")
        #expect(throws: XCResultReader.Failure.self) { try XCRValue.decode(Array("[S3:Foo".utf8)) }
    }

    @Test func framesDecode() throws {
        let payload = [UInt8](repeating: 7, count: 300_000)
        #expect(try XCResultReader.unframe(Zstd.rawFrame(payload), id: "x") == payload)
        // An RLE block (type 1) and a compressed one (type 2).
        let rle: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x20, 5, UInt8((1 | (1 << 1) | (5 << 3)) & 0xFF), 0, 0, 9]
        #expect(try XCResultReader.unframe(rle, id: "x") == [9, 9, 9, 9, 9])
        let compressed: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x20, 5, UInt8(1 | (2 << 1) | (5 << 3)), 0, 0, 1, 2, 3, 4, 5]
        #expect(throws: XCResultReader.Failure.compressed("x")) { try XCResultReader.unframe(compressed, id: "x") }
    }
}
