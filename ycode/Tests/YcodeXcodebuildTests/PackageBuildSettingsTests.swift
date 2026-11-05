import Foundation
import Testing
@testable import YcodeXcodebuild

/// `-showBuildSettings` for a Swift package scheme
/// (`specs/xcodebuild/show-build-settings.md` §7).
@Suite struct PackageBuildSettingsTests {
    /// A package like `Tools`: a library product, an executable product,
    /// and a test target, with the target GUIDs SwiftPM's `dump-pif` prints.
    static let package = SwiftPackage(
        directory: "/work/Tools", name: "Tools",
        products: [.init(name: "GreetKit", isExecutable: false, targets: ["GreetKit"]),
                   .init(name: "greet", isExecutable: true, targets: ["greet"])],
        targets: [.init(name: "Core", type: "library", dependencies: [], path: "/work/Tools/Sources/Core"),
                  .init(name: "GreetKit", type: "library", dependencies: ["Core"], path: "/work/Tools/Sources/GreetKit"),
                  .init(name: "greet", type: "executable", dependencies: ["GreetKit"], path: "/work/Tools/Sources/greet"),
                  .init(name: "GreetKitTests", type: "test", dependencies: ["GreetKit"], path: "/work/Tools/Tests/GreetKitTests")],
        dependencies: [], scratch: "/tmp/scratch", swift: "/usr/bin/swift")

    static let pifTargets: [PackageBuildSettings.PIFTarget] = [
        ("PACKAGE-PRODUCT:tools_GreetKitTests.GreetKitTests", "GreetKitTests-product", "com.apple.product-type.bundle.unit-test"),
        ("PACKAGE-TARGET:GreetKitTests_test_runner", "GreetKitTests-test-runner", "com.apple.product-type.tool.swiftpm-test-runner"),
        ("PACKAGE-PRODUCT:tools_GreetKit.GreetKit", "GreetKit-product", "com.apple.product-type.library.static"),
        ("PACKAGE-PRODUCT:tools_greet.greet", "greet-product", "com.apple.product-type.tool"),
        ("PACKAGE-TARGET:GreetKit", "GreetKit", "org.swift.product-type.library.static"),
        ("PACKAGE-TARGET:greet-1025CFC2BF9C-testable", "greet", "org.swift.product-type.common.object"),
        ("PACKAGE-TARGET:Core", "Core", "org.swift.product-type.library.static"),
        ("PACKAGE-PRODUCT:tools-ToolsPackageTests.ToolsPackageTests", "ToolsPackageTests-product", "aggregate"),
        ("PACKAGE-TARGET:GreetKit--5A022E1B30D510D9-dynamic", "GreetKit", "com.apple.product-type.library.dynamic"),
    ]

    func names(_ scheme: String, _ action: BuildAction, requested: [String] = []) throws -> [String] {
        try PackageBuildSettings.targets(package: Self.package, scheme: scheme, action: action, requested: requested,
                                         pifTargets: Self.pifTargets).map(\.name)
    }

    @Test func buildPrintsTheSchemesProductTargets() throws {
        #expect(try names("greet", .build) == ["greet-product"])
        #expect(try names("GreetKit", .build) == ["GreetKit-product"])
        #expect(try names("Tools-Package", .build) == ["GreetKit-product", "greet-product"])
        #expect(try names("Tools-Package", .archive) == ["GreetKit-product", "greet-product"])
    }

    @Test func testActionsAddTheSchemesTestBundles() throws {
        // The primary product (the first executable) carries the tests.
        #expect(try names("greet", .test) == ["greet-product", "GreetKitTests-product"])
        #expect(try names("Tools-Package", .buildForTesting) == ["GreetKit-product", "greet-product", "GreetKitTests-product"])
        #expect(try names("GreetKit", .testWithoutBuilding) == ["GreetKit-product"])
    }

    @Test func docbuildPrintsTheProductsModules() throws {
        #expect(try names("GreetKit", .docbuild) == ["GreetKit"])
        let guids = try PackageBuildSettings.targets(package: Self.package, scheme: "GreetKit", action: .docbuild, requested: [],
                                                     pifTargets: Self.pifTargets).map(\.guid)
        #expect(guids == ["PACKAGE-TARGET:GreetKit"])
    }

    @Test func targetOptionPicksModulesOrBuildDescriptionTargets() throws {
        let chosen = try PackageBuildSettings.targets(package: Self.package, scheme: "GreetKit", action: .build,
                                                      requested: ["GreetKit", "greet-product", "Core"], pifTargets: Self.pifTargets)
        // The module's static target, not its dynamic twin of the same name.
        #expect(chosen.map(\.guid) == ["PACKAGE-TARGET:GreetKit", "PACKAGE-PRODUCT:tools_greet.greet", "PACKAGE-TARGET:Core"])
        let failure = #expect(throws: XcodebuildFailure.self) { try names("GreetKit", .build, requested: ["Nope"]) }
        #expect(failure?.messages == ["The package 'Tools' does not contain a target named 'Nope'."])
        #expect(failure?.exitCode == ExitCode.dataError)
    }

    func context(arch: String) -> XcodebuildContext {
        XcodebuildContext(cwd: "/work/Tools", environment: [:], toolPath: "/usr/local/bin/ycodebuild", developerDirectory: nil,
                          home: "/home/tester", user: "tester", hostArchitecture: arch, console: CapturingConsole().console)
    }

    @Test func destinationIsThisComputerByDefault() throws {
        let linux = try PackageBuildSettings.runDestination(nil, context: context(arch: "arm64"), isLinux: true)
        #expect(linux == RunDestination(platform: "linux", sdk: "linux", targetArchitecture: "aarch64", supportedArchitectures: ["aarch64"]))
        let pc = try PackageBuildSettings.runDestination(nil, context: context(arch: "x86_64"), isLinux: true)
        #expect(pc?.targetArchitecture == "x86_64" && pc?.platform == "linux")
        let mac = try PackageBuildSettings.runDestination(nil, context: context(arch: "arm64"), isLinux: false)
        #expect(mac == .hostMac(architecture: "arm64"))
    }

    @Test func explicitDestinations() throws {
        let ctx = context(arch: "x86_64")
        #expect(try PackageBuildSettings.runDestination("platform=Linux,arch=arm64", context: ctx, isLinux: true)?.targetArchitecture == "aarch64")
        #expect(try PackageBuildSettings.runDestination("platform=Linux", context: ctx, isLinux: false)?.sdk == "linux")
        #expect(try PackageBuildSettings.runDestination("generic/platform=Linux", context: ctx, isLinux: true) == nil)
        #expect(try PackageBuildSettings.runDestination("platform=macOS,arch=arm64", context: ctx, isLinux: true) == .hostMac(architecture: "arm64"))
        #expect(try PackageBuildSettings.runDestination("generic/platform=iOS", context: ctx, isLinux: false) == nil)
        #expect(throws: XcodebuildFailure.self) { try PackageBuildSettings.runDestination("platform=Plan 9", context: ctx, isLinux: true) }
    }

    @Test func swiftPMsStateFolderIsPerUser() {
        // Another user's folder in a shared /tmp cannot be written.
        #expect(SwiftPackage.scratchFolder(userID: 1001) == "ycodebuild-spm-1001")
        #expect(SwiftPackage.scratchFolder(userID: 1000) != SwiftPackage.scratchFolder(userID: 1001))
    }

    @Test func testActionsEvaluateWithTheBuildAction() {
        // swift-build has no test action and exports nothing for one.
        #expect(Plan.buildSystemAction(.test) == "build")
        #expect(Plan.buildSystemAction(.testWithoutBuilding) == "build")
        #expect(Plan.buildSystemAction(.buildForTesting) == "build")
        #expect(Plan.buildSystemAction(.docbuild) == "docbuild")
        #expect(Plan.buildSystemAction(.archive) == "archive")
    }
}

/// Records what a package query asks swift-build for, and answers with a
/// few settings per target.
final class RecordingPackageSettings: SettingsProvider, @unchecked Sendable {
    var guids: [String] = []
    var parameters: BuildParameters?
    var pif: URL?

    func settings(container: Container, targets: [SettingsTarget], parameters: BuildParameters) throws -> [[String: String]] {
        Issue.record("a package query asked for project settings")
        return []
    }

    func settings(pif: URL, guids: [String], parameters: BuildParameters) throws -> [[String: String]] {
        self.pif = pif
        self.guids = guids
        self.parameters = parameters
        return guids.map { ["TARGET_GUID": $0, "ACTION": parameters.action, "CONFIGURATION": parameters.configuration, "EMPTY": ""] }
    }
}

/// Through the toolchain's SwiftPM (skipped without a `swift` on `PATH`):
/// the package is read and its PIF dumped as for a build, then each
/// section printed. With the `ycode-swb` helper, swift-build's own values.
@Suite(.serialized, .timeLimit(.minutes(10))) struct PackageBuildSettingsEndToEndTests {
    static var swiftAvailable: Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .contains { FileManager.default.isExecutableFile(atPath: "\($0)/swift") }
    }

    /// `Tools`: a library product with an internal dependency, an
    /// executable, and tests.
    static func writePackage() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ycodebuild-pkgsettings-\(UUID().uuidString)/Tools")
        for sub in ["Sources/Core", "Sources/GreetKit", "Sources/greet", "Tests/GreetKitTests"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "Tools",
            products: [.library(name: "GreetKit", targets: ["GreetKit"]), .executable(name: "greet", targets: ["greet"])],
            targets: [
                .target(name: "Core"),
                .target(name: "GreetKit", dependencies: ["Core"]),
                .executableTarget(name: "greet", dependencies: ["GreetKit"]),
                .testTarget(name: "GreetKitTests", dependencies: ["GreetKit"]),
            ]
        )

        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public let core = 1\n".write(to: dir.appendingPathComponent("Sources/Core/Core.swift"), atomically: true, encoding: .utf8)
        try "import Core\npublic func hello() -> String { \"hi \\(core)\" }\n"
            .write(to: dir.appendingPathComponent("Sources/GreetKit/GreetKit.swift"), atomically: true, encoding: .utf8)
        try "import GreetKit\nprint(hello())\n".write(to: dir.appendingPathComponent("Sources/greet/main.swift"), atomically: true, encoding: .utf8)
        try "import XCTest\n@testable import GreetKit\nfinal class GreetKitTests: XCTestCase { func testHello() { XCTAssertEqual(hello(), \"hi 1\") } }\n"
            .write(to: dir.appendingPathComponent("Tests/GreetKitTests/GreetKitTests.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    func run(_ args: [String], cwd: String, settings: SettingsProvider?, helper: String? = nil) -> (out: String, err: String, code: Int32) {
        let capture = CapturingConsole()
        var ctx = XcodebuildContext.current(console: capture.console)
        ctx.cwd = cwd
        ctx.settingsProvider = settings
        ctx.executableDirectory = nil
        ctx.environment["YCODE_SWB"] = helper
        if helper == nil { ctx.environment["PATH"] = (ctx.environment["PATH"] ?? "").split(separator: ":").filter {
            !FileManager.default.isExecutableFile(atPath: "\($0)/ycode-swb")
        }.joined(separator: ":") }
        let code = Xcodebuild.run(args, context: ctx)
        return (capture.stdout, capture.stderr, code)
    }

    @Test func oneSectionPerTargetTheSchemeBuilds() throws {
        guard Self.swiftAvailable else { return }
        let dir = try Self.writePackage()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let recorder = RecordingPackageSettings()
        let text = run(["-scheme", "Tools-Package", "-showBuildSettings", "-configuration", "Release", "MY_SETTING=1"],
                       cwd: dir.path, settings: recorder)
        #expect(text.code == 0, "\(text.err)")
        #expect(recorder.guids == ["PACKAGE-PRODUCT:tools_GreetKit.GreetKit", "PACKAGE-PRODUCT:tools_greet.greet"])
        #expect(recorder.parameters?.configuration == "Release")
        #expect(recorder.parameters?.overrides.contains { $0 == ("MY_SETTING", "1") } == true)
        #expect(recorder.parameters?.arena?.buildProductsPath.hasSuffix("/Build/Products") == true)
        #expect(recorder.parameters?.runDestination?.platform == (PackageBuildSettings.isLinuxHost ? "linux" : "macosx"))
        #expect(text.out.contains("Resolve Package Graph"))
        #expect(text.out.contains("Build settings from command line:\n    MY_SETTING = 1\n\n"))
        #expect(text.out.contains("""
        Build settings for action build and target GreetKit-product:
            ACTION = build
            CONFIGURATION = Release
            EMPTY = \("")
            TARGET_GUID = PACKAGE-PRODUCT:tools_GreetKit.GreetKit

        Build settings for action build and target greet-product:
        """))

        let json = run(["-scheme", "greet", "-showBuildSettings", "-json", "test"], cwd: dir.path, settings: recorder)
        #expect(json.code == 0, "\(json.err)")
        let list = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]])
        #expect(list.map { $0["target"] as? String } == ["greet-product", "GreetKitTests-product"])
        #expect(list.allSatisfy { $0["action"] as? String == "test" })
        #expect((list.first?["buildSettings"] as? [String: String])?["EMPTY"] == "")
        #expect(recorder.parameters?.action == "build")
        // Test runs of packages gather coverage, and so do their settings.
        #expect(recorder.parameters?.synthesized.contains { $0.0 == "CLANG_COVERAGE_MAPPING" } == true)
        // The package folder is left as it was.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Package.swift", "Sources", "Tests"])
    }

    @Test func withoutTheHelperItSaysWhatItNeeds() throws {
        guard Self.swiftAvailable else { return }
        let dir = try Self.writePackage()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = run(["-scheme", "greet", "-showBuildSettings"], cwd: dir.path, settings: nil)
        #expect(r.code == ExitCode.software)
        #expect(r.err.contains("needs the ycode-swb helper (swift-build)"))
    }

    @Test func swiftBuildsValues() throws {
        guard Self.swiftAvailable, let helper = SwiftBuildEndToEndTests.helper else { return }
        let dir = try Self.writePackage()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let dd = dir.deletingLastPathComponent().path + "/DerivedData"
        let r = run(["-scheme", "Tools-Package", "-showBuildSettings", "-json", "-derivedDataPath", dd], cwd: dir.path, settings: nil, helper: helper)
        #expect(r.code == 0, "\(r.err)")
        let list = try #require(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]])
        #expect(list.map { $0["target"] as? String } == ["GreetKit-product", "greet-product"])
        let kit = try #require(list.first?["buildSettings"] as? [String: String])
        let tool = try #require(list.last?["buildSettings"] as? [String: String])
        #expect(kit.count > 300 && tool.count > 300)
        #expect(kit["PRODUCT_MODULE_NAME"] == "GreetKit")
        #expect(kit["PROJECT_NAME"] == "Tools")
        #expect(tool["TARGET_NAME"] == "greet")
        #expect(tool["EXECUTABLE_PATH"] == "greet")
        #expect(tool["PRODUCT_TYPE"] == "com.apple.product-type.tool")
        #expect(tool["BUILT_PRODUCTS_DIR"]?.hasPrefix(PathText.withoutPrivatePrefix(dd) + "/Build/Products/Debug") == true)
        #if os(Linux)
        #expect(tool["PLATFORM_NAME"] == "linux")
        #expect(tool["SDK_NAME"] == "linux")
        #else
        #expect(tool["PLATFORM_NAME"] == "macosx")
        #endif
    }
}
