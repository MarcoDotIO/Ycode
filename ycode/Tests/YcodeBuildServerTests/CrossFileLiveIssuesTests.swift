import Foundation
import Testing
import YcodeBuild
@testable import YcodeBuildServer
import YcodeIDECore
import YcodeLanguage

/// P-070 (`specs/ide/parity-inventory.md`): live issues in a template-style
/// app project come from the target's real compiler arguments, through the
/// session's language service and Ycode's build server, as in the IDE. A
/// type declared in another file of the app (`Counter`) resolves in
/// `ContentView.swift`, and the test targets' `import XCTest` (and the unit
/// tests' `@testable import` of the app) are not errors.
///
/// macOS: the iOS App template with XCTest unit and UI tests (synchronized
/// folders, app-hosted unit tests), needs the iOS Simulator SDK. Elsewhere:
/// the same layout with portable sources (Foundation, XCTest).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(8))) struct CrossFileLiveIssuesTests {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `ycode-bsp` of this build (any scratch path; B5LiveDiagnosticsTests).
    static var server: String? { B5LiveDiagnosticsTests.server }

    static let counter = """
    import Foundation

    struct Counter {
        var value = 0
        mutating func increment() { value += 1 }
    }

    """

    /// The project and the files to open: (app view using `Counter`, test files).
    func makeProject(in dir: URL) throws -> (project: URL, view: URL, tests: [URL]) {
        #if os(macOS)
        if SourceKitLSPBuildServerTests.hasIOSSimulatorSDK {
            let d = try #require(ProjectTemplates.find("ios.app"))
            let form = d.makeForm([TemplateOptionID.productName: "CounterApp", TemplateOptionID.organizationIdentifier: "org.ycode.tests",
                                   TemplateOptionID.testingSystem: "XCTest"])
            let project = try ProjectGenerator.create(d, form, in: dir)
            let root = project.deletingLastPathComponent()
            try Self.counter.write(to: root.appendingPathComponent("CounterApp/Counter.swift"), atomically: true, encoding: .utf8)
            let view = root.appendingPathComponent("CounterApp/ContentView.swift")
            var text = try String(contentsOf: view, encoding: .utf8)
            let open = try #require(text.range(of: "View {\n"))
            text.insert(contentsOf: "    @State private var counter = Counter()\n", at: open.upperBound)
            try text.write(to: view, atomically: true, encoding: .utf8)
            return (project, view, [root.appendingPathComponent("CounterAppTests/CounterAppTests.swift"),
                                    root.appendingPathComponent("CounterAppUITests/CounterAppUITests.swift")])
        }
        #endif
        let project = try TemplateStyleProject.write(in: dir, counter: Self.counter)
        let root = project.deletingLastPathComponent()
        return (project, root.appendingPathComponent("CounterApp/ContentView.swift"),
                [root.appendingPathComponent("CounterAppTests/CounterAppTests.swift")])
    }

    @Test func crossFileTypesAndTestImportsResolve() async throws {
        guard SourceKitLSP.locate() != nil, let bsp = Self.server else { return }
        let dir = try freshScratch("p070-cross-file")
        // A fresh index arena, and module emission slowed down: sourcekit-lsp
        // diagnoses the opened files before the app's module exists, as on
        // a first open of a project (the unit tests' `@testable import`).
        let swiftc = try Self.slowSwiftc(in: dir)
        setenv("YCODE_BSP", bsp, 1)
        setenv("YCODE_DERIVED_DATA", dir.appendingPathComponent("DD").path, 1)
        if let swiftc { setenv("YCODE_SWIFTC", swiftc, 1) }
        defer { for v in ["YCODE_BSP", "YCODE_DERIVED_DATA", "YCODE_SWIFTC"] { unsetenv(v) } }
        let (project, view, tests) = try makeProject(in: dir)
        // The text must reference the other file's type.
        #expect(try String(contentsOf: view, encoding: .utf8).contains("Counter()"))

        let session = WorkspaceSession(model: try WorkspaceModel(url: project))
        session.scheme = "CounterApp"
        let documents = try ([view] + tests).map { (url: $0, text: try String(contentsOf: $0, encoding: .utf8)) }
        await session.startLanguageService(opening: documents)
        let language = try #require(session.language)
        defer { Task { await language.stop() } }
        // The session went through the build server.
        #expect(session.languageServedContext != nil)

        let paths = Set(documents.map { $0.url.standardizedFileURL.path })
        func errors() -> [Diagnostic] {
            session.displayedIssues.filter { $0.severity == .error && paths.contains(($0.location?.file).map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "") }
        }
        // Every file answered, and no error is left, with no edit: the
        // session sends files with errors again when the server's work ends.
        _ = await poll(300) { paths.isSubset(of: language.liveDiagnostics.keys) && errors().isEmpty }
        #expect(paths.isSubset(of: language.liveDiagnostics.keys), "answered: \(language.liveDiagnostics.keys.sorted())")
        #expect(errors().isEmpty, "\(errors().map { "\(($0.location?.file as NSString?)?.lastPathComponent ?? ""): \($0.message)" })")

        // A real error in the view is still reported, in display form (P-121).
        let broken = documents[0].text + "\nlet broken: Int = \"x\"\n"
        language.change(view, text: broken)
        #expect(await poll(60) { errors().contains { $0.message.hasPrefix("Cannot convert") } },
                "\(errors().map(\.message))")
    }

    /// A `swiftc` that waits 6 s before compiling (nil when none is found).
    static func slowSwiftc(in dir: URL) throws -> String? {
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--find", "swiftc"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let real = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        let real = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/swiftc" }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
        #endif
        guard !real.isEmpty else { return nil }
        let wrapper = dir.appendingPathComponent("slow-swiftc")
        try "#!/bin/sh\nsleep 6\nexec '\(real)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper.path
    }

    func poll(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }
}

/// A project laid out as the App template writes it (objectVersion 77,
/// synchronized folders `CounterApp` and `CounterAppTests`, app-hosted unit
/// tests that `@testable import` the app), with portable sources.
enum TemplateStyleProject {
    static func write(in dir: URL, counter: String) throws -> URL {
        let fm = FileManager.default
        let root = dir.appendingPathComponent("CounterApp")
        for sub in ["CounterApp.xcodeproj", "CounterApp", "CounterAppTests"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let files: [String: String] = [
            "CounterApp/main.swift": "let view = ContentView()\nprint(view.body)\n",
            "CounterApp/Counter.swift": counter,
            "CounterApp/ContentView.swift": """
            import Foundation

            struct ContentView {
                var counter = Counter()
                var body: String { "Count \\(counter.value)" }
            }

            """,
            "CounterAppTests/CounterAppTests.swift": """
            import XCTest
            @testable import CounterApp

            final class CounterAppTests: XCTestCase {
                func testIncrement() {
                    var c = Counter()
                    c.increment()
                    XCTAssertEqual(c.value, 1)
                }
            }

            """,
            "CounterApp.xcodeproj/project.pbxproj": pbxproj,
        ]
        for (path, text) in files { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        return root.appendingPathComponent("CounterApp.xcodeproj")
    }

    static let pbxproj = """
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	classes = {
    	};
    	objectVersion = 77;
    	objects = {
    		A0000000000000000000000A = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = CounterApp; sourceTree = BUILT_PRODUCTS_DIR; };
    		A0000000000000000000000B = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = CounterAppTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
    		A0000000000000000000001A = {isa = PBXFileSystemSynchronizedRootGroup; path = CounterApp; sourceTree = "<group>"; };
    		A0000000000000000000001B = {isa = PBXFileSystemSynchronizedRootGroup; path = CounterAppTests; sourceTree = "<group>"; };
    		A0000000000000000000003A = {isa = PBXGroup; children = (A0000000000000000000001A, A0000000000000000000001B, A0000000000000000000003B); sourceTree = "<group>"; };
    		A0000000000000000000003B = {isa = PBXGroup; children = (A0000000000000000000000A, A0000000000000000000000B); name = Products; sourceTree = "<group>"; };
    		A0000000000000000000004A = {isa = PBXNativeTarget; buildConfigurationList = A0000000000000000000009A; buildPhases = (A0000000000000000000005A); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (A0000000000000000000001A); name = CounterApp; productName = CounterApp; productReference = A0000000000000000000000A; productType = "com.apple.product-type.tool"; };
    		A0000000000000000000004B = {isa = PBXNativeTarget; buildConfigurationList = A0000000000000000000009B; buildPhases = (A0000000000000000000005B); buildRules = (); dependencies = (A0000000000000000000007B); fileSystemSynchronizedGroups = (A0000000000000000000001B); name = CounterAppTests; productName = CounterAppTests; productReference = A0000000000000000000000B; productType = "com.apple.product-type.bundle.unit-test"; };
    		A0000000000000000000005A = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
    		A0000000000000000000005B = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
    		A0000000000000000000007B = {isa = PBXTargetDependency; target = A0000000000000000000004A; targetProxy = A0000000000000000000007D; };
    		A0000000000000000000007D = {isa = PBXContainerItemProxy; containerPortal = A0000000000000000000008A; proxyType = 1; remoteGlobalIDString = A0000000000000000000004A; remoteInfo = CounterApp; };
    		A0000000000000000000008A = {isa = PBXProject; buildConfigurationList = A0000000000000000000009D; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A0000000000000000000003A; preferredProjectObjectVersion = 77; productRefGroup = A0000000000000000000003B; projectDirPath = ""; projectRoot = ""; targets = (A0000000000000000000004A, A0000000000000000000004B); };
    		A000000000000000000000AA = {isa = XCBuildConfiguration; buildSettings = {ENABLE_TESTABILITY = YES; SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0; SWIFT_VERSION = 5.0; }; name = Debug; };
    		A000000000000000000000BA = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
    		A000000000000000000000CA = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; BUNDLE_LOADER = "$(TEST_HOST)"; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/CounterApp"; }; name = Debug; };
    		A0000000000000000000009A = {isa = XCConfigurationList; buildConfigurations = (A000000000000000000000BA); defaultConfigurationName = Debug; };
    		A0000000000000000000009B = {isa = XCConfigurationList; buildConfigurations = (A000000000000000000000CA); defaultConfigurationName = Debug; };
    		A0000000000000000000009D = {isa = XCConfigurationList; buildConfigurations = (A000000000000000000000AA); defaultConfigurationName = Debug; };
    	};
    	rootObject = A0000000000000000000008A;
    }

    """
}
