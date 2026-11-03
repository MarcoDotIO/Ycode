import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeSimFeatures
import YcodeWorkspace
@testable import YcodeXcodebuild
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// An engine that records requests, succeeds, and names a product under
/// `derived` (swift-build's layout), so the build folder is known.
struct ProductEngine: BuildEngine {
    let box: RecordedRequests
    let derived: String
    var name: String { "product" }
    func start(_ request: BuildRequest) -> BuildOperation { RecordingEngine(box: box).start(request) }
    func executablePath(for request: BuildRequest) -> String? { derived + "/Products/Debug/Tool" }
}

/// IDE-QUICKWINS (`docs/PARITY.md` gap 11): the menu wiring of the Product,
/// Debug and Editor items whose features already existed.
@MainActor
@Suite(.serialized) struct IDEQuickWinsUITests {
    func scratch(_ name: String) -> URL {
        ycodeDir.appendingPathComponent(".build-ide/quickwins-ui/\(name)-\(UUID().uuidString)")
    }

    func window(_ session: WorkspaceSession) -> WorkspaceWindowController {
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        return wc
    }

    func item(_ action: String) -> NSMenuItem { NSMenuItem(title: action, action: Selector(action), keyEquivalent: "") }

    /// The items are commands now, with their reference shortcuts.
    @Test func itemsArePerformed() {
        let wired = ["deleteDerivedData:", "buildDocumentation:", "exportLocalizations:", "importLocalizations:",
                     "disableAllEnvironmentOverrides:", "toggleCodeCoverage:"] + DebugAppearanceMenu.actions
        for a in wired { #expect(CommandTable.allCommands.contains { $0.action == a && $0.isAvailable }, "\(a)") }
        #expect(CommandTable.allCommands.first { $0.action == "buildDocumentation:" }?.shortcutText == "⌃⇧⌘D")
        for t in ["Delete Derived Data…", "Build Documentation", "Export Localizations…", "Import Localizations…", "Code Coverage"] {
            #expect(!CommandTable.allCommands.contains { $0.title == t && !$0.isAvailable }, "\(t)")
        }
    }

    /// Export / Import Localizations are enabled for a project and disabled
    /// in a package; Build Documentation needs a scheme.
    @Test func toolItemsEnablement() throws {
        let dir = scratch("enable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = window(WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir.appendingPathComponent("p")))))
        for a in ["exportLocalizations:", "importLocalizations:", "buildDocumentation:", "deleteDerivedData:"] { #expect(wc.validateMenuItem(item(a)), "\(a)") }
        try writeTestPackage(at: dir.appendingPathComponent("Calc"))
        let pkg = window(WorkspaceSession(model: try WorkspaceModel(url: dir.appendingPathComponent("Calc"))))
        #expect(!pkg.validateMenuItem(item("exportLocalizations:")) && !pkg.validateMenuItem(item("importLocalizations:")))
        #expect(pkg.validateMenuItem(item("buildDocumentation:")))
    }

    /// Export Localizations… into a folder, then Import: through the window
    /// (the panels' completions), ycodebuild in process.
    @Test func exportAndImportThroughTheWindow() async throws {
        let dir = scratch("loc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeLocalizedProject(at: dir)
        let wc = window(WorkspaceSession(model: try WorkspaceModel(url: proj)))
        let folder = dir.appendingPathComponent("Loc Localizations")
        let e = try #require(await wc.exportLocalizations(into: folder))
        #expect(e.succeeded && e.products.map { URL(fileURLWithPath: $0).lastPathComponent } == ["en.xcloc", "fr.xcloc"], "\(e.output)")
        let i = try #require(await wc.importLocalizations(from: folder.appendingPathComponent("fr.xcloc")))
        #expect(i.succeeded, "\(i.output)")
        #expect(wc.session.reports.count == 2 && wc.session.activity == .finished("Import Localizations Succeeded"))
    }

    /// Build Documentation runs docbuild for the scheme and reports the
    /// archives under its derived data.
    @Test func buildDocumentationRunsDocbuild() async throws {
        let dir = scratch("doc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let wc = window(WorkspaceSession(model: try WorkspaceModel(url: proj)))
        let calls = Calls()
        let out = try #require(await wc.buildDocumentation { args, cwd in
            calls.add(args, cwd)
            let archive = cwd + "/.ycode-build/Documentation/Build/Products/Debug/Tool.doccarchive"
            try? FileManager.default.createDirectory(atPath: archive, withIntermediateDirectories: true)
            return (0, "** BUILD DOCUMENTATION SUCCEEDED **")
        })
        #expect(calls.all.first?.0 == ["-project", proj.path, "-scheme", "Tool", "-derivedDataPath", dir.path + "/.ycode-build/Documentation", "docbuild"])
        #expect(out.succeeded && out.products == [dir.path + "/.ycode-build/Documentation/Build/Products/Debug/Tool.doccarchive"])
        #expect(wc.session.reports.first?.title == "Build Documentation Tool")
    }

    /// Delete Derived Data… names the folder and deletes it once confirmed.
    @Test func deleteDerivedData() async throws {
        let dir = scratch("dd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let derived = dir.appendingPathComponent(".ycode-build")
        try FileManager.default.createDirectory(at: derived.appendingPathComponent("Products/Debug"), withIntermediateDirectories: true)
        session.engine = ProductEngine(box: RecordedRequests(), derived: derived.path)
        let wc = window(session)
        let alert = try #require(await wc.confirmDeleteDerivedData())
        #expect(alert.messageText == "Delete the derived data of \u{201C}Tool\u{201D}?" && alert.informativeText.hasPrefix(derived.path + " "))
        #expect(alert.buttons.map(\.title) == ["Delete", "Cancel"])
        #expect(FileManager.default.fileExists(atPath: derived.path))  // nothing until confirmed
        #expect(wc.deleteDerivedData(at: derived) && !FileManager.default.fileExists(atPath: derived.path))
        #expect(session.console.contains("deleted the derived data at \(derived.path)"))
    }

    /// Run ▸ Diagnostics edits the sanitizers (ASan's option only with
    /// ASan); Close writes them; the next build carries the settings.
    @Test func schemeDiagnosticsReachTheBuild() async throws {
        let dir = scratch("diag")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let box = RecordedRequests()
        session.engine = RecordingEngine(box: box)
        let scheme = try #require(session.model.loadSchemes().first { $0.name == "Tool" })
        let editor = SchemeEditorController(scheme: scheme, configurations: session.model.configurationNames)
        _ = editor.view
        editor.select(action: 1, tab: 3)
        func check(_ title: String, _ element: String = "LaunchAction") -> NSButton? {
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.accessibilityIdentifier() == "\(element).\(title)" { return b }
                return v.subviews.lazy.compactMap(find).first
            }
            return find(editor.view)
        }
        let asan = try #require(check("Address Sanitizer"))
        #expect(asan.isEnabled && asan.state == .off && check("Detect use of stack after return")?.isEnabled == false)
        #expect(check("Main Thread Checker") == nil)  // still a disabled plain row
        asan.performClick(nil)
        #expect(check("Detect use of stack after return")?.isEnabled == true)
        check("Thread Sanitizer")?.performClick(nil)   // TSan turns ASan off
        #expect(check("Address Sanitizer")?.state == .off && check("Thread Sanitizer")?.state == .on)
        editor.setSanitizer(\.undefinedBehaviorSanitizer, true)
        editor.select(action: 2)
        let testUB = try #require(check("Undefined Behavior Sanitizer", "TestAction"))
        #expect(testUB.state == .off)
        testUB.performClick(nil)
        editor.closeSheet()
        _ = await session.build(.build)
        _ = await session.buildFor(.running)
        let s = box.all.map { $0.settings.map { "\($0)=\($1)" } }
        #expect(s.first == ["ENABLE_THREAD_SANITIZER=YES", "ENABLE_UNDEFINED_BEHAVIOR_SANITIZER=YES"], "\(s)")
        #expect(session.model.diagnostics(scheme: "Tool", action: .test) == SchemeDiagnostics(undefinedBehaviorSanitizer: true))
    }

    /// Debug ▸ Simulate Location ▸ is the debug bar's menu: a note without
    /// a run on the Ycode simulator; the places and trips with one, each
    /// sending its location command.
    @Test func simulateLocationSubmenu() async throws {
        let dir = scratch("loc-menu")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = window(WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir))))
        let bar = MainMenu.make()
        let debug = try #require(bar.item(withTitle: "Debug")?.submenu)
        let sub = try #require(debug.item(withTitle: "Simulate Location")?.submenu)
        MenuBarDelegate.shared.update(sub, controller: wc)
        #expect(sub.items.map(\.title).contains("Location simulation needs a run on the Ycode simulator"))
        #expect(!sub.items.contains { $0.isEnabled && !$0.isSeparatorItem })
        let sent = Calls()
        wc.debugArea.simulatorRunKey = { "dev.ycode.Probe#42" }
        wc.debugArea.simulateLocationHandler = { words in sent.add(words, ""); return (true, "") }
        MenuBarDelegate.shared.update(sub, controller: wc)
        let places = sub.items.filter { $0.isEnabled && !$0.isSeparatorItem }
        #expect(places.first?.title == "Don't Simulate Location" && places.count == 1 + SimLocation.presets.count + SimLocation.builtInScenarios.count)
        let first = try #require(sub.items.first { $0.title == SimLocation.presets[0].name })
        _ = (first.target as? NSObject)?.perform(first.action, with: first)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sent.all.first?.0 == ["set", SimLocation.presets[0].coordinate.description])
        MenuBarDelegate.shared.update(sub, controller: wc)
        #expect(sub.items.first { $0.title == SimLocation.presets[0].name }?.state == .on)
    }

    /// View Debugging ▸ Appearance and Disable All Environment Overrides
    /// send the running app's overrides; disabled without such a run.
    @Test func appearanceAndDisableAllOverrides() async throws {
        let dir = scratch("appearance")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = window(WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir))))
        #expect(!wc.validateMenuItem(item("debugAppearanceDark:")) && !wc.validateMenuItem(item("disableAllEnvironmentOverrides:")))
        let applied = Applied()
        wc.debugArea.simulatorRunKey = { "dev.ycode.Probe#7" }
        wc.debugArea.applyEnvironmentOverrides = { o in applied.add(o); return (true, "") }
        #expect(wc.validateMenuItem(item("debugAppearanceDark:")) && !wc.validateMenuItem(item("disableAllEnvironmentOverrides:")))
        _ = await wc.chooseDebugAppearance(4)?.value
        #expect(applied.all.last?.values == [.appearance: "dark", .increaseContrast: "on"])
        let hc = item("debugAppearanceHighContrastDark:")
        #expect(wc.validateMenuItem(hc) && hc.state == .on)
        #expect(wc.validateMenuItem(item("disableAllEnvironmentOverrides:")))
        _ = await wc.disableAllOverrides()?.value
        #expect(applied.all.last?.isEmpty == true && wc.debugArea.environmentOverrides.isEmpty)
        let system = item("debugAppearanceSystem:")
        #expect(wc.validateMenuItem(system) && system.state == .on)
    }

    /// Editor ▸ Code Coverage: the gutter ribbon shows the open file's
    /// counts from the newest coverage run.
    @Test func codeCoverageRibbon() throws {
        let prefs = IsolatedPreferences("coverage")
        defer { prefs.restore() }
        let dir = scratch("cov")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let wc = window(session)
        let file = dir.appendingPathComponent("Tool/Greeter.swift").path
        wc.open(path: file, line: nil)
        var r = BuildReport(title: "Test Tool", date: Date(), succeeded: true, log: [], errorCount: 0, warningCount: 0)
        r.context.coverage = [CoverageItem(name: "Tool", coveredLines: 2, executableLines: 3,
                                           files: [CoverageItem(name: "Greeter.swift", coveredLines: 2, executableLines: 3, path: file, lineCounts: [-1, 5, 0, 5])])]
        session.recordReport(r)
        let toggle = item("toggleCodeCoverage:")
        #expect(wc.validateMenuItem(toggle) && toggle.state == .off)
        #expect(wc.editor.gutter.coverageText(line: 2) == nil)  // off by default
        wc.toggleCodeCoverage(nil)
        #expect(wc.validateMenuItem(toggle) && toggle.state == .on)
        #expect(wc.editor.gutter.coverageText(line: 1) == nil && wc.editor.gutter.coverageText(line: 2) == "5")
        #expect(wc.editor.gutter.coverageText(line: 3) == "0")
        wc.toggleCodeCoverage(nil)
        #expect(wc.editor.gutter.coverageText(line: 2) == nil && !Preferences.shared.showCodeCoverage)
    }

    /// File ▸ Open… of an `.xcresult`: a test report on its Tests page; an
    /// unreadable bundle says so.
    @Test func openResultBundle() throws {
        let dir = scratch("xcresult")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = window(WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir.appendingPathComponent("p")))))
        let path = dir.appendingPathComponent("Run.xcresult").path
        writeResultBundle(at: path)
        let r = try #require(wc.openResultBundle(URL(fileURLWithPath: path)))
        #expect(wc.session.reports.first == r && r.context.tests.count == 4)
        #expect(wc.editor.auxiliary is TestReportView)
        #expect(wc.openResultBundle(dir.appendingPathComponent("missing.xcresult")) == nil)
        #expect(wc.session.console.contains("cannot read missing.xcresult"))
    }

    /// Run Repeatedly: fixed iterations, until failure, retry on failure,
    /// with a stand-in `swift`; the Test navigator's row menu and the sheet.
    @Test func runTestsRepeatedly() async throws {
        let dir = scratch("repeat")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTestPackage(at: dir.appendingPathComponent("Calc"))
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir.appendingPathComponent("Calc")))
        let record = dir.appendingPathComponent("args.txt"), tool = dir.appendingPathComponent("swift.sh")
        try fakeTool(at: tool, record: record, output: "Test Case '-[CalcTests.CalcTests testAdds]' passed (0.001 seconds).\nTest Case '-[CalcTests.CalcTests testBroken]' failed (0.001 seconds).")
        session.testRunner.swift = ["/bin/sh", tool.path]
        session.discoverTests()
        await session.testsDiscovered()
        let adds = try #require(session.tests.first { $0.name == "testAdds" })
        let broken = try #require(session.tests.first { $0.name == "testBroken" })

        let fixed = await session.runTestsRepeatedly(only: [adds], repetition: TestRepetition(.fixed, maximum: 3))
        #expect(fixed.iterations.count == 3 && fixed.failedIterations == 0)
        let until = await session.runTestsRepeatedly(repetition: TestRepetition(.untilFailure, maximum: 5))
        #expect(until.iterations == [[]] && until.failedIterations == 1)
        let retry = await session.runTestsRepeatedly(repetition: TestRepetition(.retryOnFailure, maximum: 3))
        #expect(retry.iterations == [[], [broken], [broken]] && retry.failedIterations == 3)
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3 + 1 + 3 && lines.last == "test --filter CalcTests.testBroken")
        #expect(session.console.contains("Ycode: Retry on Failure: 3 iterations, 3 with failures."))
        #expect(session.testResults[broken] == .failed && session.testResults[adds] == .passed)
        // Stop ends a series before its next iteration.
        session.cancelRepetition()
        #expect(session.repetitionCancelled)

        let wc = window(session)
        let (alert, read) = wc.repetitionSheet(title: "testBroken")
        #expect(alert.messageText == "Run \u{201C}testBroken\u{201D} Repeatedly" && alert.buttons.map(\.title) == ["Run", "Cancel"])
        #expect(read() == TestRepetition(.fixed, maximum: TestRepetition.defaultMaximum))
        func find<T: NSView>(_ v: NSView?, _ id: String) -> T? {
            guard let v else { return nil }
            if let t = v as? T, v.accessibilityIdentifier() == id { return t }
            return v.subviews.lazy.compactMap { find($0, id) }.first
        }
        let mode: NSPopUpButton? = find(alert.accessoryView, "repetitionMode")
        let max: NSTextField? = find(alert.accessoryView, "repetitionMaximum")
        mode?.selectItem(at: 2)
        max?.stringValue = "7"
        #expect(read() == TestRepetition(.retryOnFailure, maximum: 7))
        // The Test navigator has a row menu filled by the window.
        #expect(wc.navigator.testRowMenu != nil)
        wc.navigator.select(5)
        let menu = NSMenu()
        wc.navigator.rebuildRowMenu(menu)
        #expect(menu.items.isEmpty)  // no row selected
    }
}

final class Applied: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [EnvironmentOverrides] = []
    var all: [EnvironmentOverrides] { lock.withLock { list } }
    func add(_ o: EnvironmentOverrides) { lock.withLock { list.append(o) } }
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
