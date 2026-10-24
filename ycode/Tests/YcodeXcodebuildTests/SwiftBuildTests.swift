import Foundation
import Testing
@testable import YcodeXcodebuild

/// End-to-end through swift-build, with the `ycode-swb` helper from
/// `YCODE_SWB` or the local scratch build (see ycode/Tools/ycode-swb).
/// Skipped when no helper is available.
@Suite(.serialized, .timeLimit(.minutes(10))) struct SwiftBuildEndToEndTests {
    static var helper: String? {
        let env = ProcessInfo.processInfo.environment
        if let h = SwiftBuildSettingsProvider.locate(environment: env, executableDirectory: nil) { return h }
        let ycode = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["Tools/ycode-swb/.build/debug/ycode-swb", ".build-xcb-scratch/swb-helper/debug/ycode-swb"] {
            let p = ycode.appendingPathComponent(rel).path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func run(_ args: [String], cwd: String, helper: String) -> (out: String, err: String, code: Int32) {
        let capture = CapturingConsole()
        var ctx = XcodebuildContext.current(console: capture.console)
        ctx.cwd = cwd
        ctx.environment["YCODE_SWB"] = helper
        // The built tool lists swift-testing tests in a child process.
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/ycodebuild").path
        ctx.toolPath = FileManager.default.isExecutableFile(atPath: built) ? built : "/usr/local/bin/ycodebuild"
        let code = Xcodebuild.run(args, context: ctx)
        return (capture.stdout, capture.stderr, code)
    }

    @Test func settingsAndBuild() throws {
        #if os(macOS)
        guard let helper = Self.helper else { return }
        let proj = try writeMultiProject()
        let dir = proj.deletingLastPathComponent().path
        // Settings come from swift-build: hundreds of them, with the
        // reference tool's GUID scheme and legacy build locations.
        let s = run(["-showBuildSettings", "-json", "-target", "App"], cwd: dir, helper: helper)
        #expect(s.code == 0)
        let list = try JSONSerialization.jsonObject(with: Data(s.out.utf8)) as? [[String: Any]]
        let settings = try #require(list?.first?["buildSettings"] as? [String: String])
        #expect(settings.count > 400)
        #expect(settings["PROJECT_GUID"] == MD5.hex("Multi.xcodeproj"))
        #expect(settings["BUILT_PRODUCTS_DIR"] == dir + "/build/Debug")
        #expect(settings["MY_BASE"] == "base")

        // Build the scheme (the tool links the library it depends on), run it.
        let dd = dir + "/DerivedData"
        let b = run(["-scheme", "App", "-derivedDataPath", dd, "build"], cwd: dir, helper: helper)
        #expect(b.code == 0, "\(b.err)")
        #expect(b.out.contains("** BUILD SUCCEEDED **\n"))
        #expect(b.out.contains("(in target 'App' from project 'Multi')"))
        #expect(FileManager.default.isExecutableFile(atPath: dd + "/Build/Products/Debug/App"))
        let c = run(["-scheme", "App", "-derivedDataPath", dd, "clean"], cwd: dir, helper: helper)
        #expect(c.code == 0 && c.out.contains("** CLEAN SUCCEEDED **"))
        #expect(!FileManager.default.fileExists(atPath: dd + "/Build/Products/Debug/App"))

        // A compile error fails with exit 65 and the failure summary.
        try "int main(void) { return x; }\n".write(toFile: dir + "/App/main.c", atomically: true, encoding: .utf8)
        let f = run(["-scheme", "App", "-derivedDataPath", dd, "-quiet", "build"], cwd: dir, helper: helper)
        #expect(f.code == 65)
        #expect(f.out.contains("error: use of undeclared identifier 'x'"))
        #expect(f.err.hasSuffix("** BUILD FAILED **\n\n"))
        #endif
    }

    /// `xcrun xcresulttool get <args> --path <bundle>` as JSON, when the tool exists.
    func xcresulttool(_ args: [String], _ bundle: String) -> [String: Any]? {
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return nil }
        let r = TestActions.run("/usr/bin/xcrun", ["xcresulttool", "get"] + args + ["--path", bundle], environment: ProcessInfo.processInfo.environment)
        guard r.status == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any]
        #else
        return nil
        #endif
    }

    @Test func resultBundleAndArchive() throws {
        #if os(macOS)
        guard let helper = Self.helper else { return }
        let proj = try writeMultiProject()
        let dir = proj.deletingLastPathComponent().path
        let dd = dir + "/DerivedData"
        // A build writes the bundle and says so before the banner.
        let bundle = dir + "/build.xcresult"
        let b = run(["-scheme", "App", "-derivedDataPath", dd, "-resultBundlePath", bundle, "build"], cwd: dir, helper: helper)
        #expect(b.code == 0, "\(b.err)")
        #expect(b.out.contains("Writing result bundle at path:\n\t\(bundle)\n\n"))
        #expect(b.out.contains("Result bundle written to path:\n\t\(bundle)\n\n** BUILD SUCCEEDED **"))
        #expect(FileManager.default.fileExists(atPath: bundle + "/Info.plist"))
        if let results = xcresulttool(["build-results"], bundle) {
            #expect(results["status"] as? String == "succeeded")
            #expect(results["actionTitle"] as? String == "Build \"App\"")
        }
        // An existing bundle is an error before anything runs.
        let again = run(["-scheme", "App", "-derivedDataPath", dd, "-resultBundlePath", bundle, "build"], cwd: dir, helper: helper)
        #expect(again.code == 64 && again.out.isEmpty && again.err.hasPrefix("xcodebuild: error: Existing file at -resultBundlePath"))

        // archive: the installed tool under Products, the plist keys.
        let archive = dir + "/App.xcarchive"
        let a = run(["-scheme", "App", "-derivedDataPath", dd, "-archivePath", archive, "archive"], cwd: dir, helper: helper)
        #expect(a.code == 0, "\(a.err)")
        #expect(a.out.hasSuffix("** ARCHIVE SUCCEEDED **\n\n"))
        #expect(FileManager.default.isExecutableFile(atPath: archive + "/Products/usr/local/bin/App"))
        #expect(FileManager.default.fileExists(atPath: archive + "/dSYMs"))
        let info = try #require(NSDictionary(contentsOfFile: archive + "/Info.plist") as? [String: Any])
        #expect(info["ArchiveVersion"] as? Int == 2 && info["Name"] as? String == "App" && info["SchemeName"] as? String == "App")
        #expect(info["ApplicationProperties"] == nil)
        // A tool archive cannot be exported.
        let options = dir + "/export.plist"
        try (try PropertyListSerialization.data(fromPropertyList: ["method": "mac-application"], format: .xml, options: 0)).write(to: URL(fileURLWithPath: options))
        let x = run(["-exportArchive", "-archivePath", archive, "-exportPath", dir + "/out", "-exportOptionsPlist", options], cwd: dir, helper: helper)
        #expect(x.code == 70 && x.out == "** EXPORT FAILED **\n\n")
        #endif
    }

    @Test func testActionAndResultBundle() throws {
        #if os(macOS)
        guard let helper = Self.helper else { return }
        let proj = try writeCalcProject()
        let dir = proj.deletingLastPathComponent().path
        let dd = dir + "/DerivedData"
        let bundle = dir + "/test.xcresult"
        let t = run(["-scheme", "CalcTests", "-derivedDataPath", dd, "-resultBundlePath", bundle, "test"], cwd: dir, helper: helper)
        #expect(t.code == 65, "\(t.err)")
        #expect(t.out.contains("Test Case '-[CalcTests.AddTests testAdd]' passed"))
        #expect(t.out.contains("Test session results, code coverage, and logs:\n\t\(bundle)\n\n"))
        // Not a terminal: "Testing started" comes last.
        #expect(t.out.hasSuffix("Testing started\n"))
        #expect(t.err.contains("Failing tests:\n\tFailingTests.testWrong()\n\tSwiftFailing.wrong()\n\n** TEST FAILED **"), "\(t.err)")
        if let summary = xcresulttool(["test-results", "summary"], bundle) {
            #expect(summary["result"] as? String == "Failed")
            #expect(summary["failedTests"] as? Int == 2)
            #expect(summary["skippedTests"] as? Int == 1)
            #expect(summary["passedTests"] as? Int == 6)
        }
        // build-for-testing writes a test run file; running it needs no project.
        let bft = run(["-scheme", "CalcTests", "-derivedDataPath", dd, "build-for-testing"], cwd: dir, helper: helper)
        #expect(bft.code == 0 && bft.out.contains("** TEST BUILD SUCCEEDED **"))
        let products = dd + "/Build/Products"
        let runFile = try #require(try FileManager.default.contentsOfDirectory(atPath: products).first { $0.hasSuffix(".xctestrun") })
        let twb = run(["-xctestrun", products + "/" + runFile, "-only-testing:CalcTests/AddTests", "test-without-building"], cwd: "/", helper: helper)
        #expect(twb.code == 0, "\(twb.err)")
        #expect(twb.out.contains("** TEST EXECUTE SUCCEEDED **"))
        #expect(twb.out.contains(dd + "/Logs/Test/Test-CalcTests-"))
        // docbuild: a documentation archive per module, next to the products.
        let doc = run(["-scheme", "CalcKit", "-derivedDataPath", dd, "docbuild"], cwd: dir, helper: helper)
        #expect(doc.code == 0 && doc.out.contains("** BUILD DOCUMENTATION SUCCEEDED **"), "\(doc.err)")
        #expect(FileManager.default.fileExists(atPath: products + "/Debug/CalcKit.doccarchive/data"))
        #endif
    }

    /// A Swift package folder: schemes, the destination requirement, build
    /// and test through SwiftPM's build description.
    @Test func packageFolder() throws {
        #if os(macOS)
        guard let helper = Self.helper else { return }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ycodebuild-pkg-\(UUID().uuidString)/Tools")
        for sub in ["Sources/GreetKit", "Sources/greet", "Tests/GreetKitTests"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Tools",
            platforms: [.macOS(.v14)],
            products: [.library(name: "GreetKit", targets: ["GreetKit"]), .executable(name: "greet", targets: ["greet"])],
            targets: [
                .target(name: "GreetKit"),
                .executableTarget(name: "greet", dependencies: ["GreetKit"]),
                .testTarget(name: "GreetKitTests", dependencies: ["GreetKit"]),
            ]
        )

        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func greeting(for name: String) -> String { \"Hi \\(name)\" }\n"
            .write(to: dir.appendingPathComponent("Sources/GreetKit/GreetKit.swift"), atomically: true, encoding: .utf8)
        try "import GreetKit\nprint(greeting(for: \"x\"))\n".write(to: dir.appendingPathComponent("Sources/greet/main.swift"), atomically: true, encoding: .utf8)
        try "import XCTest\n@testable import GreetKit\nfinal class GreetKitTests: XCTestCase {\n    func testGreeting() { XCTAssertEqual(greeting(for: \"a\"), \"Hi a\") }\n}\n"
            .write(to: dir.appendingPathComponent("Tests/GreetKitTests/GreetKitTests.swift"), atomically: true, encoding: .utf8)
        let cwd = dir.path
        let list = run(["-list", "-json"], cwd: cwd, helper: helper)
        #expect(list.code == 0, "\(list.err)")
        let obj = try JSONSerialization.jsonObject(with: Data(list.out.utf8)) as? [String: Any]
        #expect((obj?["workspace"] as? [String: Any])?["schemes"] as? [String] == ["greet", "GreetKit", "Tools-Package"])
        let noDest = run(["-scheme", "greet", "build"], cwd: cwd, helper: helper)
        #expect(noDest.code == 70 && noDest.err.contains("requires that a destination is provided"))
        let notTest = run(["-scheme", "GreetKit", "-destination", "platform=macOS", "test"], cwd: cwd, helper: helper)
        #expect(notTest.code == 66 && notTest.err.contains("Scheme GreetKit is not currently configured for the test action."))
        let dd = dir.deletingLastPathComponent().path + "/DerivedData"
        let b = run(["-scheme", "greet", "-destination", "platform=macOS", "-derivedDataPath", dd, "build"], cwd: cwd, helper: helper)
        #expect(b.code == 0, "\(b.err)")
        #expect(b.out.contains("(in target 'greet-product' from project 'Tools')") && b.out.contains("** BUILD SUCCEEDED **"))
        #expect(fm.isExecutableFile(atPath: dd + "/Build/Products/Debug/greet"))
        let t = run(["-scheme", "Tools-Package", "-destination", "platform=macOS", "-derivedDataPath", dd, "test"], cwd: cwd, helper: helper)
        #expect(t.code == 0, "\(t.err)")
        #expect(t.out.contains("Test Case '-[GreetKitTests.GreetKitTests testGreeting]' passed") && t.out.contains("** TEST SUCCEEDED **"))
        // The package folder itself is left as it was.
        #expect(try fm.contentsOfDirectory(atPath: cwd).sorted() == ["Package.swift", "Sources", "Tests"])
        #endif
    }
}
