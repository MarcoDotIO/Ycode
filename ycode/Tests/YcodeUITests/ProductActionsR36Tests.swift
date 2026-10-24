import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeWorkspace
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Build requests an engine was asked for.
final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [BuildRequest] = []
    var all: [BuildRequest] { lock.lock(); defer { lock.unlock() }; return list }
    func append(_ r: BuildRequest) { lock.lock(); list.append(r); lock.unlock() }
}

/// An engine that records each request and succeeds.
struct RecordingEngine: BuildEngine {
    let box: RecordedRequests
    var name: String { "recording" }
    func start(_ request: BuildRequest) -> BuildOperation {
        box.append(request)
        let (s, c) = AsyncStream<BuildEvent>.makeStream()
        c.yield(.output("built"))
        c.yield(.finished(BuildResult(status: .succeeded, exitCode: 0, issues: [])))
        c.finish()
        return BuildOperation(events: s, cancel: {})
    }
}

/// A hand-written macOS command-line tool project: main.swift uses a type
/// from Greeter.swift; one shared scheme with two test plans.
func writeToolProject(at dir: URL) throws -> URL {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    func write(_ rel: String, _ text: String) throws {
        let u = dir.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    try write("Tool/main.swift", "print(Greeter(name: \"tool\").line)\n")
    try write("Tool/Greeter.swift", "struct Greeter {\n    var name: String\n    var line: String { \"hello, \\(name)\" }\n}\n")
    try write("Tool/util.c", "#define TWICE(x) ((x) * 2)\nint twice(int v) { return TWICE(v); }\n")
    try write("Tool.xcodeproj/project.pbxproj", """
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	classes = {
    	};
    	objectVersion = 77;
    	objects = {
    		C10000000000000000000001 = {isa = PBXBuildFile; fileRef = C10000000000000000000002; };
    		C10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
    		C10000000000000000000003 = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = Tool; sourceTree = BUILT_PRODUCTS_DIR; };
    		C10000000000000000000004 = {isa = PBXGroup; children = (C10000000000000000000005, C10000000000000000000006); sourceTree = "<group>"; };
    		C10000000000000000000005 = {isa = PBXGroup; children = (C10000000000000000000002, C10000000000000000000012, C10000000000000000000014); path = Tool; sourceTree = "<group>"; };
    		C10000000000000000000006 = {isa = PBXGroup; children = (C10000000000000000000003); name = Products; sourceTree = "<group>"; };
    		C10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = C10000000000000000000008; buildPhases = (C10000000000000000000009); buildRules = (); dependencies = (); name = Tool; productName = Tool; productReference = C10000000000000000000003; productType = "com.apple.product-type.tool"; };
    		C10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (C1000000000000000000000A, C1000000000000000000000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    		C10000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C10000000000000000000001, C10000000000000000000011, C10000000000000000000013); runOnlyForDeploymentPostprocessing = 0; };
    		C10000000000000000000011 = {isa = PBXBuildFile; fileRef = C10000000000000000000012; };
    		C10000000000000000000012 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Greeter.swift; sourceTree = "<group>"; };
    		C10000000000000000000013 = {isa = PBXBuildFile; fileRef = C10000000000000000000014; };
    		C10000000000000000000014 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = util.c; sourceTree = "<group>"; };
    		C1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"; }; name = Debug; };
    		C1000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; }; name = Release; };
    		C1000000000000000000000C = {isa = PBXProject; buildConfigurationList = C1000000000000000000000D; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = C10000000000000000000004; productRefGroup = C10000000000000000000006; preferredProjectObjectVersion = 77; projectDirPath = ""; projectRoot = ""; targets = (C10000000000000000000007); };
    		C1000000000000000000000D = {isa = XCConfigurationList; buildConfigurations = (C1000000000000000000000E, C1000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    		C1000000000000000000000E = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Debug; };
    		C1000000000000000000000F = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Release; };
    	};
    	rootObject = C1000000000000000000000C;
    }

    """)
    try write("Tool.xcodeproj/xcshareddata/xcschemes/Tool.xcscheme", """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme
       LastUpgradeVersion = "2600"
       version = "1.7">
       <BuildAction
          parallelizeBuildables = "YES"
          buildImplicitDependencies = "YES">
       </BuildAction>
       <TestAction
          buildConfiguration = "Debug"
          selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
          selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
          shouldUseLaunchSchemeArgsEnv = "YES">
          <TestPlans>
             <TestPlanReference
                reference = "container:Smoke.xctestplan"
                default = "YES">
             </TestPlanReference>
             <TestPlanReference
                reference = "container:Full.xctestplan">
             </TestPlanReference>
          </TestPlans>
       </TestAction>
       <LaunchAction
          buildConfiguration = "Debug">
       </LaunchAction>
       <ProfileAction
          buildConfiguration = "Release">
       </ProfileAction>
       <AnalyzeAction
          buildConfiguration = "Debug">
       </AnalyzeAction>
       <ArchiveAction
          buildConfiguration = "Release"
          revealArchiveInOrganizer = "YES">
       </ArchiveAction>
    </Scheme>

    """)
    return dir.appendingPathComponent("Tool.xcodeproj")
}

/// A shell script standing in for `swift`: records its arguments, then
/// prints `output`.
func fakeTool(at url: URL, record: URL, output: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\necho \"$@\" >> '\(record.path)'\ncat <<'EOF'\n\(output)\nEOF\n".write(to: url, atomically: true, encoding: .utf8)
}

@MainActor
@Suite(.serialized) struct ProductActionsR36Tests {
    func scratch(_ name: String) -> URL {
        ycodeDir.appendingPathComponent(".build-ide/r36/\(name)-\(UUID().uuidString)")
    }

    func window(_ session: WorkspaceSession) -> WorkspaceWindowController {
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        return wc
    }

    /// Build For ▸ Running / Profiling build the scheme with the Run and
    /// Profile actions' configurations; Build For ▸ Testing builds the
    /// tests with the test tool.
    @Test func buildForPurposes() async throws {
        let dir = scratch("build-for")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let box = RecordedRequests()
        session.engine = RecordingEngine(box: box)
        #expect(await session.buildFor(.running).status == .succeeded)
        #expect(await session.buildFor(.profiling).status == .succeeded)
        #expect(box.all.map(\.configuration) == ["Debug", "Release"] && box.all.allSatisfy { $0.action == .build && $0.scheme == "Tool" })
        #expect(session.activity == .finished("Build Succeeded"))
        #expect(session.reports.first?.title == "Build Tool")

        // Testing: the test tool's build-for-testing, its issues shown.
        let record = dir.appendingPathComponent("args.txt"), tool = dir.appendingPathComponent("xcodebuild.sh")
        try fakeTool(at: tool, record: record, output: "\(dir.path)/Tool/main.swift:1:1: warning: careful\n** TEST BUILD SUCCEEDED **")
        session.testRunner.xcodebuild = ["/bin/sh", tool.path]
        let r = await session.buildFor(.testing)
        #expect(r.status == .succeeded && box.all.count == 2)
        let args = try String(contentsOf: record, encoding: .utf8)
        #expect(args.contains("-scheme Tool") && args.contains("-configuration Debug") && args.hasSuffix("build-for-testing\n"))
        #expect(session.issues.map(\.message) == ["careful"])
    }

    /// Test Without Building, Test Again, Test Without Building Again,
    /// Clear Test Results, with a stand-in `swift`.
    @Test func testWithoutBuildingAndAgain() async throws {
        let dir = scratch("twb")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTestPackage(at: dir.appendingPathComponent("Calc"))
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir.appendingPathComponent("Calc")))
        let record = dir.appendingPathComponent("args.txt"), tool = dir.appendingPathComponent("swift.sh")
        try fakeTool(at: tool, record: record, output: "Test Case '-[CalcTests.CalcTests testAdds]' passed (0.001 seconds).")
        session.testRunner.swift = ["/bin/sh", tool.path]
        let wc = window(session)
        let again = NSMenuItem(title: "Test Again", action: #selector(WorkspaceWindowController.testAgain(_:)), keyEquivalent: "")
        #expect(!wc.validateMenuItem(again)) // nothing tested yet

        _ = await session.runTests(withoutBuilding: true)
        let adds = try #require(session.tests.first { $0.name == "testAdds" })
        #expect(session.testResults[adds] == .passed)
        #expect(session.lastTestRun == .init(tests: [], withoutBuilding: true))
        #expect(wc.validateMenuItem(again))

        _ = await session.runTests(only: [adds])
        _ = await session.testAgain(withoutBuilding: true)
        _ = await session.testAgain()
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
        #expect(lines == ["test --skip-build", "test --filter CalcTests.testAdds",
                          "test --skip-build --filter CalcTests.testAdds", "test --filter CalcTests.testAdds"])

        let clear = NSMenuItem(title: "Clear Test Results", action: #selector(WorkspaceWindowController.clearTestResults(_:)), keyEquivalent: "")
        #expect(wc.validateMenuItem(clear))
        wc.clearTestResults(nil)
        #expect(session.testResults.isEmpty && !wc.validateMenuItem(clear))
    }

    /// Perform Action ▸ Test (⌃⌥⌘U): the test at the caret, or the suite
    /// declared on the caret's line.
    @Test func testAtCaret() async throws {
        let dir = scratch("caret")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTestPackage(at: dir.appendingPathComponent("Calc"))
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir.appendingPathComponent("Calc")))
        let wc = window(session)
        await session.testsDiscovered()   // read in the background
        let file = dir.appendingPathComponent("Calc/Tests/CalcTests/CalcTests.swift").path
        wc.open(path: file, line: 7)
        #expect(wc.selectedTests.map(\.identifier) == ["CalcTests/testBroken"])
        wc.open(path: file, line: 5)
        #expect(wc.selectedTests.map(\.identifier) == ["CalcTests/testAdds", "CalcTests/testBroken"])
        #expect(session.tests(atCaret: file, line: 1).isEmpty)
    }

    /// Run Without Building launches the last build's product; with none
    /// it says so and builds nothing.
    @Test func runWithoutBuildingNeedsAProduct() async throws {
        let dir = scratch("rwb")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let box = RecordedRequests()
        session.engine = RecordingEngine(box: box)
        await session.run(program: dir.appendingPathComponent("missing/Tool").path, building: false)
        #expect(box.all.isEmpty && session.reports.isEmpty)
        #expect(session.console.contains("Tool has not been built"))
        #expect(session.activity == .finished("Run Failed"))
    }

    /// Clean Build Folder… asks; Clean Build Folder Immediately cleans.
    @Test func cleanConfirmation() async throws {
        let dir = scratch("clean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let box = RecordedRequests()
        session.engine = RecordingEngine(box: box)
        let wc = window(session)
        let alert = wc.confirmCleanBuildFolder()
        #expect(alert.messageText == "Clean the build folder of \u{201C}Tool\u{201D}?")
        #expect(alert.buttons.map(\.title) == ["Clean", "Cancel"])
        #expect(box.all.isEmpty) // nothing until confirmed
        _ = await session.build(.clean)
        #expect(box.all.map(\.action) == [.clean] && session.activity == .finished("Clean Succeeded"))
    }

    /// Run… / Test… / Analyze… / Archive… open the scheme editor on the
    /// action and run it when the editor closes; an autocreated scheme runs
    /// at once.
    @Test func ellipsisVariantsOpenTheSchemeEditor() throws {
        let dir = scratch("ellipsis")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = window(session)
        var ran = 0
        let editor = try #require(wc.editSchemeThenPerform(action: 2) { ran += 1 })
        _ = editor.view
        #expect(editor.selectedAction == 2 && ran == 0)
        editor.closeSheet()
        #expect(ran == 1)

        let pkgDir = scratch("ellipsis-pkg")
        defer { try? FileManager.default.removeItem(at: pkgDir) }
        try writeTestPackage(at: pkgDir)
        let pkg = window(WorkspaceSession(model: try WorkspaceModel(url: pkgDir)))
        #expect(pkg.editSchemeThenPerform(action: 1) { ran += 1 } == nil && ran == 2)
        // The variants are enabled commands now (§2.9).
        for sel in ["runProductEditingScheme:", "testProductEditingScheme:", "analyzeProductEditingScheme:", "archiveProductEditingScheme:"] {
            #expect(CommandTable.allCommands.contains { $0.action == sel && $0.isAlternate })
        }
    }

    /// Product ▸ Destination: rows under the labels, the current one
    /// checked; Select Next / Previous Destination; Show All lists
    /// Incompatible in the pop-up itself.
    @Test func destinationSubmenu() throws {
        let dir = scratch("dest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = window(session)
        func sim(_ n: String, _ v: String, _ id: String) -> Destination {
            Destination(name: n, specifier: "platform=iOS Simulator,id=\(id)", platform: "iOS", kind: .simulator, osVersion: v, identifier: id)
        }
        wc.setDestinationGroups([DestinationGroup(title: "iOS Simulators", destinations: [sim("iPhone 17", "26.1", "A"), sim("iPad Air", "26.1", "B")])])
        session.destination = .myMac
        let bar = MainMenu.make()
        let menu = try #require(bar.item(withTitle: "Product")?.submenu?.item(withTitle: "Destination")?.submenu)
        DynamicMenus.fillDestinations(menu, model: wc.destinationMenuModel(), current: session.destination, target: wc)
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles == ["Choose Destination", "Select Next Destination", "Select Previous Destination", "—", "Show All Run Destinations", "—",
                           "Devices", "My Mac", "—", "Simulators", "—", "Build", "Any Mac", "—", "Incompatible", "—", "Manage Devices…"])
        // A Mac tool: the simulators are incompatible (mismatched platform).
        let incompatible = try #require(menu.item(withTitle: "Incompatible")?.submenu)
        #expect(incompatible.items.map(\.title) == ["iPhone 17 (mismatched platform) 26.1", "iPad Air (mismatched platform) 26.1"])
        #expect(incompatible.items.allSatisfy { !$0.isEnabled })
        let myMac = try #require(menu.item(withTitle: "My Mac"))
        #expect(wc.validateMenuItem(myMac) && myMac.state == .on)

        // Next / previous step through My Mac and Any Mac, wrapping.
        wc.selectNextDestination(nil)
        #expect(session.destination == .anyMac)
        wc.selectNextDestination(nil)
        #expect(session.destination == .myMac)
        wc.selectPreviousDestination(nil)
        #expect(session.destination == .anyMac)
        wc.selectDestinationRow(myMac)
        #expect(session.destination == .myMac)

        // Show All Run Destinations: Incompatible expanded in the pop-up.
        wc.rebuildDestinationMenu(expandIncompatible: true)
        let popup = wc.destinationPopUp.menu!.items.map(\.title)
        #expect(popup.contains("Incompatible") && wc.destinationPopUp.menu!.item(withTitle: "Incompatible")?.submenu == nil)
        wc.rebuildDestinationMenu()
        #expect(wc.destinationPopUp.menu!.item(withTitle: "Incompatible")?.submenu != nil)
    }

    /// Product ▸ Test Plan: one row per plan, the default checked; Select
    /// Next / Previous; the chosen plan is passed to the runner.
    @Test func testPlans() throws {
        let dir = scratch("plans")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = window(session)
        #expect(session.testPlanRows == ["Smoke", "Full"] && session.effectiveTestPlan == "Smoke")
        let bar = MainMenu.make()
        let menu = try #require(bar.item(withTitle: "Product")?.submenu?.item(withTitle: "Test Plan")?.submenu)
        DynamicMenus.fillTestPlans(menu, rows: session.testPlanRows, plans: session.testPlanNames, active: session.effectiveTestPlan, target: wc)
        #expect(menu.items.suffix(3).map { $0.isSeparatorItem ? "—" : $0.title } == ["—", "Smoke", "Full"])
        #expect(menu.items.last?.state == .off && menu.items[menu.items.count - 2].state == .on)
        wc.selectNextTestPlan(nil)
        #expect(session.effectiveTestPlan == "Full")
        #expect(session.selectedTestRunner.command(for: BuildRequest(container: .project(dir.path), scheme: "Tool")).args.contains("Full"))
        wc.selectPreviousTestPlan(nil)
        wc.selectTestPlanRow(menu.items.last)
        #expect(session.effectiveTestPlan == "Full")

        let pkgDir = scratch("plans-pkg")
        defer { try? FileManager.default.removeItem(at: pkgDir) }
        try writeTestPackage(at: pkgDir)
        let pkg = WorkspaceSession(model: try WorkspaceModel(url: pkgDir))
        #expect(pkg.testPlanRows == ["\(pkg.scheme ?? "") (Autocreated)"] && pkg.testPlanNames.isEmpty)
    }

    /// The single-file actions are enabled by the focused file's language.
    @Test func fileActionEnablement() throws {
        let dir = scratch("file-enable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = window(session)
        func enabled(_ s: Selector) -> Bool { wc.validateMenuItem(NSMenuItem(title: "", action: s, keyEquivalent: "")) }
        wc.open(path: dir.appendingPathComponent("Tool/main.swift").path, line: nil)
        #expect(enabled(#selector(WorkspaceWindowController.compileFile(_:))) && enabled(#selector(WorkspaceWindowController.assembleFile(_:))))
        #expect(!enabled(#selector(WorkspaceWindowController.analyzeFile(_:))) && !enabled(#selector(WorkspaceWindowController.preprocessFile(_:))))
        #expect(MenuTitles.title(generic: "Compile File", in: wc.menuContext) == "Compile \u{201C}main.swift\u{201D}")
        wc.open(path: dir.appendingPathComponent("Tool/util.c").path, line: nil)
        #expect(enabled(#selector(WorkspaceWindowController.analyzeFile(_:))) && enabled(#selector(WorkspaceWindowController.preprocessFile(_:))))
    }

    /// T8: an iOS app without a development team gets the project-level
    /// signing warning, counted in the toolbar capsule; a Mac tool none.
    @Test func projectLevelSigningCheck() throws {
        let dir = scratch("t8")
        defer { try? FileManager.default.removeItem(at: dir) }
        var o = ProjectOptions()
        o.productName = "Phone"
        o.testing = .none
        let proj = try IOSAppTemplate.create(options: o, in: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let wc = window(session)
        #expect(session.projectIssues.map(\.message) == ["Signing for \u{201C}Phone\u{201D} requires a development team."])
        #expect(session.projectIssues.first?.severity == .warning && session.projectIssues.first?.location == nil)
        #expect(session.displayedIssues.contains(session.projectIssues[0]))
        #expect(wc.issueCapsule.warnings == 1)
        // Build issues come and go; the project check stays.
        session.clearIssues()
        #expect(session.displayedIssues.count == 1)

        let tool = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir.appendingPathComponent("tool"))))
        tool.refreshProjectIssues()
        #expect(tool.projectIssues.isEmpty)
    }

    /// The file's module context for a project: the target's module name,
    /// its Swift files, its settings.
    @Test func fileContextFromTheProject() throws {
        let dir = scratch("ctx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        session.destination = .myMac
        let main = dir.appendingPathComponent("Tool/main.swift").standardizedFileURL.path
        let ctx = session.fileBuildContext(for: main)
        #expect(ctx.moduleName == "Tool")
        #expect(ctx.moduleSources.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted() == ["Greeter.swift", "main.swift"])
        #expect(ctx.swiftVersion == "5.0" && ctx.defines == ["DEBUG"])
        #expect(ctx.targetTriple == "\(SwiftBuildEngine.hostArchitecture)-apple-macosx15.0")
        #expect(ctx.sdkPath?.contains("MacOSX") == true)
    }
}

/// Real compiler and test-tool runs through the session.
@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct ProductActionsR36RealTests {
    /// Compile “main.swift” of a project target: type-checked against the
    /// target's other file; Assemble opens the assembly; Preprocess and
    /// Analyze “util.c”.
    @Test func compileFileOfAProject() async throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/r36/compile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        session.destination = .myMac
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        let main = dir.appendingPathComponent("Tool/main.swift").path
        let compiled = await session.perform(.compile, file: main)
        #expect(compiled.result.status == .succeeded, "\(compiled.result.issues) \(session.buildLog)")
        let object = try #require(compiled.output)
        #expect(object.hasSuffix("/main.o") && FileManager.default.fileExists(atPath: object))
        #expect(session.activity == .finished("Compile Succeeded"))
        #expect(session.reports.first?.title == "Compile \u{201C}main.swift\u{201D}")

        // Through the menu command: Assemble opens the assembly.
        wc.open(path: main, line: nil)
        let task = try #require(wc.performFileAction(.assemble))
        let assembled = await task.value
        #expect(assembled.result.status == .succeeded)
        #expect(wc.editor.fileURL?.lastPathComponent == "main.s")

        let c = dir.appendingPathComponent("Tool/util.c").path
        let pre = await session.perform(.preprocess, file: c)
        #expect(try String(contentsOfFile: try #require(pre.output), encoding: .utf8).contains("((v) * 2)"))

        // An error comes back as a located issue.
        try "print(Greeter(name: 1).line)\n".write(toFile: main, atomically: true, encoding: .utf8)
        let failed = await session.perform(.compile, file: main)
        #expect(failed.result.status == .failed && failed.output == nil)
        #expect(session.issues.contains { $0.severity == .error && $0.location?.file.hasSuffix("main.swift") == true && $0.location?.line == 1 })
        #expect(session.activity == .finished("Compile Failed"))
    }

    /// Build For ▸ Testing, then Perform Action ▸ Test Without Building,
    /// on a real package.
    @Test func buildForTestingThenTestWithoutBuilding() async throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/r36/bft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTestPackage(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let built = await session.buildFor(.testing)
        #expect(built.status == .succeeded, "\(built.issues)")
        #expect(session.activity == .finished("Build Succeeded"))
        let outcomes = await session.runTests(withoutBuilding: true)
        #expect(outcomes.contains { $0.name == "testAdds" && $0.status == .passed })
        #expect(outcomes.contains { $0.name == "testBroken" && $0.status == .failed })
        let byName = Dictionary(uniqueKeysWithValues: session.tests.map { ($0.name, session.testResults[$0]) })
        #expect(byName["testAdds"] == .passed && byName["testBroken"] == .failed && byName["addsZero"] == .passed)
        #expect(session.buildLog.contains { $0.contains("--skip-build") } == false) // the log is the runner's output
        #expect(session.failedTestCount == 1)
    }
}
