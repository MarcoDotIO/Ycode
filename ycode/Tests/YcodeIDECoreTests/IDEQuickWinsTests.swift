import Foundation
import Testing
import YcodeBuild
import YcodeProject
import YcodeSimFeatures
import YcodeWorkspace
@testable import YcodeXcodebuild
@testable import YcodeIDECore

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// IDE-QUICKWINS: the models behind the wired Product, Debug and Editor
/// items (`docs/PARITY.md` gap 11).
@MainActor
@Suite(.serialized) struct IDEQuickWinsTests {
    func scratch(_ name: String) -> URL {
        ycodeDir.appendingPathComponent(".build-ide/quickwins/\(name)-\(UUID().uuidString)")
    }

    // MARK: Diagnostics

    /// The sanitizers read and write the action's attributes; ASan and
    /// TSan exclude each other; stack use after return needs ASan.
    @Test func schemeDiagnosticsAttributes() throws {
        let dir = scratch("diag")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let url = proj.appendingPathComponent("xcshareddata/xcschemes/Tool.xcscheme")
        var s = try Scheme(contentsOf: url, isShared: true)
        #expect(s.diagnostics().isEmpty && s.diagnostics(for: "TestAction").isEmpty)
        var d = SchemeDiagnostics()
        d.set(\.addressSanitizer, true)
        d.set(\.stackUseAfterReturn, true)
        d.set(\.undefinedBehaviorSanitizer, true)
        s.setDiagnostics(d)
        try s.save()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("enableAddressSanitizer = \"YES\"") && text.contains("enableASanStackUseAfterReturn = \"YES\"")
            && text.contains("enableUBSanitizer = \"YES\"") && !text.contains("enableThreadSanitizer"))
        let back = try Scheme(contentsOf: url, isShared: true)
        #expect(back.diagnostics() == d && back.diagnostics(for: "TestAction").isEmpty)
        // TSan turns ASan (and its option) off; turning it off removes the attributes.
        d.set(\.threadSanitizer, true)
        #expect(d == SchemeDiagnostics(threadSanitizer: true, undefinedBehaviorSanitizer: true))
        d.set(\.addressSanitizer, true)
        #expect(!d.threadSanitizer && d.addressSanitizer && !d.stackUseAfterReturn)
        var off = back
        off.setDiagnostics(SchemeDiagnostics())
        #expect(!off.serialized().contains("Sanitizer"))
    }

    /// Builds get the swift-build settings of the scheme action that
    /// applies (Run for build and analyze, Test for test builds, none for
    /// clean); runs get ASan's stack-use-after-return option.
    @Test func diagnosticsReachBuildsAndRuns() throws {
        let dir = scratch("diag-build")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let url = proj.appendingPathComponent("xcshareddata/xcschemes/Tool.xcscheme")
        var s = try Scheme(contentsOf: url, isShared: true)
        s.setDiagnostics(SchemeDiagnostics(addressSanitizer: true, stackUseAfterReturn: true, undefinedBehaviorSanitizer: true))
        s.setDiagnostics(SchemeDiagnostics(threadSanitizer: true), for: "TestAction")
        var env = s.launchEnvironment
        env.append(.init("ASAN_OPTIONS", "halt_on_error=0", enabled: true))
        s.setLaunchEnvironment(env)
        try s.save()
        let model = try WorkspaceModel(url: proj)
        func settings(_ a: BuildRequest.Action) -> [String] { model.buildRequest(scheme: "Tool", destination: nil, action: a).settings.map { "\($0)=\($1)" } }
        #expect(settings(.build) == ["ENABLE_ADDRESS_SANITIZER=YES", "ENABLE_UNDEFINED_BEHAVIOR_SANITIZER=YES"])
        #expect(settings(.analyze) == settings(.build))
        #expect(settings(.test) == ["ENABLE_THREAD_SANITIZER=YES"] && settings(.buildForTesting) == settings(.test))
        #expect(settings(.clean).isEmpty)
        // A package has no scheme file: nothing.
        #expect(SchemeDiagnostics.schemeAction(for: .clean) == nil)
        let session = WorkspaceSession(model: model)
        session.scheme = "Tool"
        #expect(session.launchOptions.environment["ASAN_OPTIONS"] == "halt_on_error=0:detect_stack_use_after_return=1")
        var e: [String: String] = [:]
        SchemeDiagnostics(addressSanitizer: true).applyLaunchEnvironment(&e)
        #expect(e.isEmpty)
        SchemeDiagnostics(addressSanitizer: true, stackUseAfterReturn: true).applyLaunchEnvironment(&e)
        #expect(e == ["ASAN_OPTIONS": "detect_stack_use_after_return=1"])
    }

    // MARK: Tool actions

    /// The command lines of Export / Import Localizations and Build
    /// Documentation; the languages; what the logs name.
    @Test func toolActionCommandLines() throws {
        let p = URL(fileURLWithPath: "/w/App.xcodeproj")
        #expect(IDEToolActions.exportArguments(project: p, to: URL(fileURLWithPath: "/w/App Localizations"), languages: ["en", "fr"])
            == ["-exportLocalizations", "-localizationPath", "/w/App Localizations", "-project", "/w/App.xcodeproj", "-exportLanguage", "en", "-exportLanguage", "fr"])
        #expect(IDEToolActions.importArguments(project: p, from: URL(fileURLWithPath: "/w/fr.xcloc"))
            == ["-importLocalizations", "-localizationPath", "/w/fr.xcloc", "-project", "/w/App.xcodeproj"])
        #expect(IDEToolActions.exportFolderName(project: p) == "App Localizations")
        #expect(IDEToolActions.createdLocalizations(in: "x\n2026-10-30 10:00:00 An xcloc was created at /w/out/fr.xcloc\n") == ["/w/out/fr.xcloc"])
        let d = IDEToolActions.docbuildArguments(container: .project("/w/App.xcodeproj"), scheme: "App")
        #expect(d.arguments == ["-project", "/w/App.xcodeproj", "-scheme", "App", "-derivedDataPath", "/w/.ycode-build/Documentation", "docbuild"])
        #expect(d.cwd == "/w" && d.derivedData == "/w/.ycode-build/Documentation")
        let pkg = IDEToolActions.docbuildArguments(container: .package("/w/Calc"), scheme: "Calc")
        #expect(pkg.arguments == ["-scheme", "Calc", "-derivedDataPath", "/w/Calc/.ycode-build/Documentation", "docbuild"] && pkg.cwd == "/w/Calc")

        let dir = scratch("langs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let model = try WorkspaceModel(url: proj)
        // developmentRegion en, knownRegions (en, Base) in the fixture.
        #expect(IDEToolActions.exportLanguages(model.projects[proj.path]) == ["en"])
        #expect(IDEToolActions.localizationProject(model) == proj)
    }

    /// The archives under a docbuild's derived data; the derived data
    /// folder of both build-folder layouts; deleting it.
    @Test func archivesAndDerivedData() throws {
        let dir = scratch("dd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for p in ["Build/Products/Debug/CalcKit.doccarchive/data", "Build/Products/Debug/Other.txt", "Build/Products/Release/A.doccarchive"] {
            try fm.createDirectory(at: dir.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        #expect(IDEToolActions.documentationArchives(derivedData: dir.path) == [
            dir.path + "/Build/Products/Debug/CalcKit.doccarchive", dir.path + "/Build/Products/Release/A.doccarchive",
        ])
        #expect(IDEToolActions.documentationArchives(derivedData: dir.path + "/none").isEmpty)
        let swb = URL(fileURLWithPath: "/w/.ycode-build"), xcb = URL(fileURLWithPath: "/dd/App-abc/Build")
        #expect(IDEToolActions.derivedDataFolder(buildFolder: swb) == swb)
        #expect(IDEToolActions.derivedDataFolder(buildFolder: xcb).path == "/dd/App-abc")
        #expect(IDEToolActions.deleteDerivedData(dir) && !fm.fileExists(atPath: dir.path))
        #expect(IDEToolActions.deleteDerivedData(dir))  // already gone
    }

    /// A tool action: the activity texts, the report, the products.
    @Test func toolActionRecordsAReport() async throws {
        let dir = scratch("tool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let calls = Calls()
        let ok = await session.exportLocalizations(to: dir.appendingPathComponent("out")) { args, cwd in
            calls.add(args, cwd)
            return (0, "Localization Export started for Tool project\n2026-10-30 10:00:00 An xcloc was created at /x/en.xcloc\n")
        }
        #expect(ok?.succeeded == true && ok?.products == ["/x/en.xcloc"])
        #expect(calls.all.first?.0.prefix(2) == ["-exportLocalizations", "-localizationPath"] && calls.all.first?.1 == dir.path)
        #expect(session.reports.first?.title == "Export Localizations Tool" && session.reports.first?.succeeded == true)
        #expect(session.activity == .finished("Export Localizations Succeeded"))
        let bad = await session.buildDocumentation { _, _ in (65, "xcodebuild: error: no\n** BUILD DOCUMENTATION FAILED **") }
        #expect(bad?.succeeded == false && bad?.products == [])
        #expect(session.activity == .finished("Build Documentation Failed") && session.reports.first?.errorCount == 1)
        // A package has no project to localize.
        let pkg = scratch("tool-pkg")
        defer { try? FileManager.default.removeItem(at: pkg) }
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"P\")\n".write(to: pkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let ps = WorkspaceSession(model: try WorkspaceModel(url: pkg))
        #expect(await ps.exportLocalizations(to: pkg) == nil && IDEToolActions.localizationProject(ps.model) == nil)
    }

    /// Export and import through ycodebuild in this process: a project with
    /// a localized `.strings` group gives `fr.xcloc`; a translated XLIFF
    /// comes back into `fr.lproj`.
    @Test func exportAndImportLocalizationsInProcess() async throws {
        let dir = scratch("loc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeLocalizedProject(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        #expect(IDEToolActions.exportLanguages(session.model.projects[proj.path]) == ["en", "fr"])
        let out = dir.appendingPathComponent("Loc Localizations")
        let e = try #require(await session.exportLocalizations(to: out))
        #expect(e.succeeded, "\(e.output)")
        #expect(e.products == [out.path + "/en.xcloc", out.path + "/fr.xcloc"])
        let xliff = out.appendingPathComponent("fr.xcloc/Localized Contents/fr.xliff")
        let text = try String(contentsOf: xliff, encoding: .utf8)
        #expect(text.contains("<target>Au revoir</target>"))
        try text.replacingOccurrences(of: "<target>Au revoir</target>", with: "<target>Salut</target>").write(to: xliff, atomically: true, encoding: .utf8)
        let i = try #require(await session.importLocalizations(from: out.appendingPathComponent("fr.xcloc")))
        #expect(i.succeeded, "\(i.output)")
        #expect(try String(contentsOf: dir.appendingPathComponent("Loc/fr.lproj/Greetings.strings"), encoding: .utf8).contains("\"Goodbye\" = \"Salut\";"))
        #expect(session.reports.map(\.title) == ["Import Localizations Loc", "Export Localizations Loc"])
    }

    // MARK: Result bundles

    /// An `.xcresult` read back as a test report: outcomes, failures as
    /// issues, the report kind.
    @Test func resultBundleReport() throws {
        let dir = scratch("xcresult")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Run.xcresult").path
        writeResultBundle(at: path)
        let r = try ResultBundleReport.report(URL(fileURLWithPath: path))
        #expect(r.title == "Test Run" && !r.succeeded && r.errorCount == 1 && r.kind == .test)
        #expect(r.context.tests.map { "\($0.suite ?? "")/\($0.name) \($0.status.rawValue)" }
            == ["AppTests/testA passed", "AppTests/testB failed", "AppTests/testC skipped", "Model/doubles passed"])
        #expect(r.context.issues.first?.message == "XCTAssertEqual failed" && r.context.issues.first?.location?.line == 12)
        #expect(throws: (any Error).self) { try ResultBundleReport.report(dir.appendingPathComponent("none.xcresult")) }
    }

    // MARK: Repetitions

    @Test func repetitionModes() {
        let a = DiscoveredTest(file: "/t/A.swift", suite: "A", name: "testOne", line: 3, kind: .xctest)
        let b = DiscoveredTest(file: "/t/A.swift", suite: "A", name: "testTwo", line: 5, kind: .xctest)
        let pass = [TestOutcome(suite: "A", name: "testOne", status: .passed), TestOutcome(suite: "A", name: "testTwo", status: .passed)]
        let fail = [TestOutcome(suite: "A", name: "testOne", status: .passed), TestOutcome(suite: "A", name: "testTwo", status: .failed)]
        let fixed = TestRepetition(.fixed, maximum: 3)
        #expect(fixed.next(after: 1, outcomes: fail, selection: [a, b], discovered: [a, b]) == [a, b])
        #expect(fixed.next(after: 3, outcomes: pass, selection: [a, b], discovered: [a, b]) == nil)
        let until = TestRepetition(.untilFailure, maximum: 10)
        #expect(until.next(after: 1, outcomes: pass, selection: [], discovered: [a, b]) == [])
        #expect(until.next(after: 2, outcomes: fail, selection: [], discovered: [a, b]) == nil)
        let retry = TestRepetition(.retryOnFailure, maximum: 3)
        #expect(retry.next(after: 1, outcomes: fail, selection: [], discovered: [a, b]) == [b])
        #expect(retry.next(after: 2, outcomes: pass, selection: [b], discovered: [a, b]) == nil)
        #expect(retry.next(after: 3, outcomes: fail, selection: [b], discovered: [a, b]) == nil)
        #expect(TestRepetition(.fixed, maximum: 0).maximum == 1)
        #expect(TestRepetition.summary(iterations: 3, failedIterations: 1, mode: .fixed) == "Ycode: Fixed Iterations: 3 iterations, 1 with failures.")
    }

    // MARK: Appearance

    @Test func debugAppearanceItems() {
        var o = EnvironmentOverrides()
        o.values[.boldText] = "on"
        let hcDark = DebugAppearanceMenu.apply(4, to: o)
        #expect(hcDark.values == [.appearance: "dark", .increaseContrast: "on", .boldText: "on"])
        #expect(DebugAppearanceMenu.checkedIndex(hcDark) == 4)
        let light = DebugAppearanceMenu.apply(1, to: hcDark)
        #expect(light.values == [.appearance: "light", .boldText: "on"] && DebugAppearanceMenu.checkedIndex(light) == 1)
        #expect(DebugAppearanceMenu.apply(0, to: light).values == [.boldText: "on"] && DebugAppearanceMenu.checkedIndex(o) == 0)
        #expect(DebugAppearanceMenu.titles.count == DebugAppearanceMenu.actions.count)
    }

    // MARK: Coverage

    /// Line counts from llvm-cov segments and from ycodebuild's summary;
    /// the session finds a file's counts in the newest coverage report.
    @Test func coverageLines() throws {
        // A function on lines 1–3 run twice, an unexecuted branch on line 2.
        let segments: [[Any]] = [[1, 10, 2, true, true, false], [2, 5, 0, true, true, false], [2, 9, 2, true, false, false], [3, 2, 0, false, false, false]]
        #expect(Coverage.lineCounts(llvmCovSegments: segments) == [2, 2, 2])
        let summary = Data(#"{"targets":[{"name":"Calc","coveredLines":2,"executableLines":3,"files":[{"path":"/w/Calc/A.swift","coveredLines":2,"executableLines":3,"lines":[-1,4,0,4]}]}]}"#.utf8)
        let items = CoverageModel.parseYcodebuildSummary(summary)
        #expect(items.first?.files.first?.path == "/w/Calc/A.swift" && items.first?.files.first?.lineCounts == [-1, 4, 0, 4])
        let export = Data(#"{"data":[{"files":[{"filename":"/p/Sources/Lib/L.swift","segments":[[1,1,3,true,true,false],[1,20,0,false,false,false]],"summary":{"lines":{"count":1,"covered":1}}}]}]}"#.utf8)
        #expect(CoverageModel.parseLLVMCovExport(export).first?.files.first?.lineCounts == [3])

        let dir = scratch("cov")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        #expect(session.coverageLineCounts(file: "/w/Calc/A.swift") == nil)
        var r = BuildReport(title: "Test Calc", date: Date(), succeeded: true, log: [], errorCount: 0, warningCount: 0)
        r.context.coverage = items
        session.recordReport(r)
        session.recordReport(BuildReport(title: "Build Calc", date: Date(), succeeded: true, log: [], errorCount: 0, warningCount: 0))
        #expect(session.coverageLineCounts(file: "/w/Calc/A.swift") == [-1, 4, 0, 4])
        #expect(WorkspaceSession.coverageMarks([-1, 4, 0, 4]) == [2: 4, 3: 0, 4: 4])
    }
}

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [([String], String)] = []
    var all: [([String], String)] { lock.withLock { list } }
    func add(_ a: [String], _ c: String) { lock.withLock { list.append((a, c)) } }
}

/// A macOS app project with a localized `Greetings.strings` (en, fr).
func writeLocalizedProject(at dir: URL) throws -> URL {
    let fm = FileManager.default
    for sub in ["Loc.xcodeproj", "Loc/en.lproj", "Loc/fr.lproj"] { try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
    try "print(1)\n".write(to: dir.appendingPathComponent("Loc/main.swift"), atomically: true, encoding: .utf8)
    try "/* Farewell */\n\"Goodbye\" = \"Goodbye\";\n".write(to: dir.appendingPathComponent("Loc/en.lproj/Greetings.strings"), atomically: true, encoding: .utf8)
    try "/* Farewell */\n\"Goodbye\" = \"Au revoir\";\n".write(to: dir.appendingPathComponent("Loc/fr.lproj/Greetings.strings"), atomically: true, encoding: .utf8)
    try """
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	classes = {
    	};
    	objectVersion = 77;
    	objects = {
    		E10000000000000000000001 = {isa = PBXBuildFile; fileRef = E10000000000000000000002; };
    		E10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
    		E10000000000000000000003 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Loc.app; sourceTree = BUILT_PRODUCTS_DIR; };
    		E10000000000000000000004 = {isa = PBXGroup; children = (E10000000000000000000005, E10000000000000000000006); sourceTree = "<group>"; };
    		E10000000000000000000005 = {isa = PBXGroup; children = (E10000000000000000000002, E10000000000000000000022); path = Loc; sourceTree = "<group>"; };
    		E10000000000000000000006 = {isa = PBXGroup; children = (E10000000000000000000003); name = Products; sourceTree = "<group>"; };
    		E10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = E10000000000000000000008; buildPhases = (E10000000000000000000009, E10000000000000000000010); buildRules = (); dependencies = (); name = Loc; productName = Loc; productReference = E10000000000000000000003; productType = "com.apple.product-type.application"; };
    		E10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (E1000000000000000000000A, E1000000000000000000000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    		E10000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (E10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
    		E10000000000000000000010 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (E10000000000000000000023); runOnlyForDeploymentPostprocessing = 0; };
    		E10000000000000000000022 = {isa = PBXVariantGroup; children = (E10000000000000000000024, E10000000000000000000025); name = Greetings.strings; sourceTree = "<group>"; };
    		E10000000000000000000023 = {isa = PBXBuildFile; fileRef = E10000000000000000000022; };
    		E10000000000000000000024 = {isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = en; path = en.lproj/Greetings.strings; sourceTree = "<group>"; };
    		E10000000000000000000025 = {isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = fr; path = fr.lproj/Greetings.strings; sourceTree = "<group>"; };
    		E1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.samples.Loc; CODE_SIGN_IDENTITY = "-"; SWIFT_VERSION = 5.0; }; name = Debug; };
    		E1000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.ycode.samples.Loc; CODE_SIGN_IDENTITY = "-"; SWIFT_VERSION = 5.0; }; name = Release; };
    		E1000000000000000000000C = {isa = PBXProject; buildConfigurationList = E1000000000000000000000D; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, fr, Base); mainGroup = E10000000000000000000004; productRefGroup = E10000000000000000000006; preferredProjectObjectVersion = 77; projectDirPath = ""; projectRoot = ""; targets = (E10000000000000000000007); };
    		E1000000000000000000000D = {isa = XCConfigurationList; buildConfigurations = (E1000000000000000000000E, E1000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    		E1000000000000000000000E = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Debug; };
    		E1000000000000000000000F = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Release; };
    	};
    	rootObject = E1000000000000000000000C;
    }

    """.write(to: dir.appendingPathComponent("Loc.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
    return dir.appendingPathComponent("Loc.xcodeproj")
}

/// A result bundle written by ycodebuild's own writer: AppTests with a
/// pass, a failure (at /src/A.swift:12) and a skip, and a Swift Testing pass.
func writeResultBundle(at path: String) {
    func target() -> TestTarget {
        TestTarget(blueprintName: "AppTests", projectName: "App", projectRelativePath: "App.xcodeproj", blueprintIdentifier: "",
                   moduleName: "AppTests", bundleIdentifier: "", bundlePath: "/b", executablePath: "", productsDirectory: "/p", testHost: "/p/App.app/App")
    }
    var o = TestActions.Outcome()
    var failed = TestCaseResult(library: .xctest, module: "AppTests", suite: "AppTests", name: "testB", status: .failed, duration: 0.5)
    failed.issues = [.init(message: "XCTAssertEqual failed", file: "/src/A.swift", line: 12)]
    let skipped = TestCaseResult(library: .xctest, module: "AppTests", suite: "AppTests", name: "testC", status: .skipped, duration: 0)
    let passed = TestCaseResult(library: .xctest, module: "AppTests", suite: "AppTests", name: "testA", status: .passed, duration: 0.25)
    let swift = TestCaseResult(library: .swiftTesting, module: "AppTests", suite: "Model", name: "doubles()", status: .passed, duration: 0.1)
    let results = [passed, failed, skipped, swift]
    o.targets.append(.init(target: target(), results: results, selected: false, starts: [:]))
    o.results += results
    let s = ResultBundleSession(path: path, given: path, explicit: true, containerPath: "/w/App.xcodeproj", containerLabel: "App project",
                                projectName: "App", schemeName: "App", runDestination: nil, sdk: nil)
    s.record(.init(commandName: "Test", taskName: "BuildAndAction", title: "Testing project App with scheme App", started: Date(), ended: Date(),
                   build: nil, tests: o, testPlanName: "App", testRequested: true), quiet: true, console: CapturingConsole().console)
}
