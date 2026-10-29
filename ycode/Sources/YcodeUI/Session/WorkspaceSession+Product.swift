import Foundation
import YcodeBuild
import YcodeProject
import YcodeSettings
import YcodeWorkspace
import YcodeSubprocess

/// Product menu actions beyond Build / Run / Test (`specs/ide/reference-ui-5.md`
/// §2.9, R36): Build For ▸ Running / Testing / Profiling, Perform Action ▸
/// Test Without Building, Test Again, the single-file actions, Clear Test
/// Results, test plans, and the project-level checks of §11.6 (T8).
extension WorkspaceSession {
    /// One test run, for Test Again and Test Without Building Again.
    public struct TestRun: Equatable, Sendable {
        /// The tests that ran; empty = all.
        public var tests: [DiscoveredTest]
        public var withoutBuilding: Bool
    }

    /// Product ▸ Build For ▸ …
    public enum BuildPurpose: String, Sendable, CaseIterable {
        case running, testing, profiling

        /// The scheme action whose build configuration is used.
        var schemeAction: String {
            switch self {
            case .running: "LaunchAction"
            case .testing: "TestAction"
            case .profiling: "ProfileAction"
            }
        }
    }

    /// The scheme file of the selected scheme (nil when it is autocreated).
    var selectedScheme: Scheme? {
        guard let name = scheme else { return nil }
        return model.loadSchemes().first { $0.name == name }
    }

    /// The configuration a scheme action builds with: the scheme's, else
    /// Debug, or Release for Profile and Archive (`Scheme.configuration`).
    func configuration(for schemeAction: String) -> String {
        if let s = selectedScheme { return s.configuration(for: schemeAction) }
        return ["ProfileAction", "ArchiveAction"].contains(schemeAction) ? "Release" : "Debug"
    }

    /// The runner tests use (ycodebuild for swift-build), with the active
    /// test plan.
    var selectedTestRunner: TestRunner {
        var r = TestRunnerSelection.runner(testRunner, preference: buildSystemPreference)
        if let plan = activeTestPlan, testPlanNames.contains(plan) { r.testPlan = plan }
        return r
    }

    /// Product ▸ Build For ▸ Running (⇧⌘R) / Testing (⇧⌘U) / Profiling
    /// (⇧⌘I). Running and Profiling build the scheme with the Run or
    /// Profile action's configuration; Testing builds the tests only
    /// (`build-for-testing`), with the tool that runs them, so Test Without
    /// Building can run them afterwards.
    @discardableResult
    public func buildFor(_ purpose: BuildPurpose) async -> BuildResult {
        let subject = scheme ?? model.displayName
        var request = model.buildRequest(scheme: scheme, destination: destination, action: purpose == .testing ? .buildForTesting : .build)
        request.configuration = configuration(for: purpose.schemeAction)
        if purpose == .testing {
            let runner = selectedTestRunner
            return await performBuild(request, presentation: .init(action: .build, subject: subject), start: runner.buildForTesting)
        }
        let engine = self.engine
        return await performBuild(request, presentation: .init(action: .build, subject: subject), start: engine.start)
    }

    /// Product ▸ Perform Action ▸ Test Again (⌃⌥⌘G): the last test run
    /// again, building first. Test Without Building Again: the same tests,
    /// without building. Nil when nothing has been tested yet.
    @discardableResult
    public func testAgain(withoutBuilding: Bool = false) async -> [TestOutcome]? {
        guard let last = lastTestRun else { return nil }
        // Tests found again: the identifiers stay, the lines may move.
        discoverTests()
        await testsDiscovered()
        let again = last.tests.compactMap { t in tests.first { $0.identifier == t.identifier && $0.file == t.file } ?? t }
        return await runTests(only: again, withoutBuilding: withoutBuilding)
    }

    /// Product ▸ Clear Test Results (⌃⌥⌘K): every test back to "not run",
    /// and the capsule's failure count cleared.
    public func clearTestResults() {
        testResults = [:]
        failedTestCount = 0
        notify(.tests)
        notify(.issues)
    }

    /// Perform Action ▸ Test (⌃⌥⌘U) with no selection: the test whose
    /// declaration is at or above `line` in `file` (the caret), or every
    /// test of the suite declared on that line.
    public func tests(atCaret file: String, line: Int) -> [DiscoveredTest] {
        let suite = testsForDiamond(file: file, line: line)
        if !suite.isEmpty { return suite }
        let inFile = tests.filter { $0.file == file && $0.line <= line }
        guard let nearest = inFile.max(by: { $0.line < $1.line }) else { return [] }
        return [nearest]
    }

    // MARK: Run Without Building

    /// Run Without Building found no product to launch.
    func reportMissingProduct(_ path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        appendConsole("Ycode: \(name) has not been built. Build the scheme first (Product ▸ Build For ▸ Running).\n")
        setActivity(.finished("Run Failed"))
    }

    // MARK: Test plans (§2.9 item 21)

    /// The test plans of the selected scheme, by name (empty: the scheme
    /// has none and runs its autocreated plan).
    public var testPlanNames: [String] {
        (selectedScheme?.testPlans ?? []).map { Self.testPlanName($0.reference) }
    }

    /// A plan's name from its reference ("container:Tests/Smoke.xctestplan"
    /// → "Smoke").
    static func testPlanName(_ reference: String) -> String {
        let path = reference.split(separator: ":", maxSplits: 1).last.map(String.init) ?? reference
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// The Test Plan submenu's rows: one per plan, or "<scheme>
    /// (Autocreated)" when the scheme has none.
    public var testPlanRows: [String] {
        let names = testPlanNames
        return names.isEmpty ? ["\(scheme ?? model.displayName) (Autocreated)"] : names
    }

    /// The plan the next test run uses: the chosen one, else the scheme's
    /// default plan, else the first.
    public var effectiveTestPlan: String {
        let names = testPlanNames
        if let p = activeTestPlan, names.contains(p) { return p }
        if let d = selectedScheme?.testPlans.first(where: \.isDefault) {
            return Self.testPlanName(d.reference)
        }
        return testPlanRows[0]
    }

    /// Select Next / Previous Test Plan, wrapping.
    public func stepTestPlan(_ delta: Int) {
        let names = testPlanNames
        guard names.count > 1 else { return }
        let i = names.firstIndex(of: effectiveTestPlan) ?? 0
        activeTestPlan = names[(i + delta + names.count) % names.count]
    }

    // MARK: Single-file actions

    /// Perform Action ▸ Compile / Analyze / Preprocess / Assemble “<file>”.
    /// Returns the result and, when it succeeded, the output file
    /// (preprocessed source, assembly, object file or analyzer report).
    @discardableResult
    public func perform(_ action: FileAction, file: String, productsDirectory: String? = nil) async -> (result: BuildResult, output: String?) {
        // The SDK lookup runs xcrun once per SDK: off the main thread.
        let sdkName = fileActionSDKName
        _ = await Task.detached { SDKInfo.lookup(sdkName) }.value
        let ctx = fileBuildContext(for: file, productsDirectory: productsDirectory)
        let runner = FileActionRunner()
        let name = URL(fileURLWithPath: file).lastPathComponent
        let title = "\(action.title) \u{201C}\(name)\u{201D}"
        let p = BuildPresentation(running: "\(action.title) \(name)", reportAction: "Build", title: title,
                                  succeeded: "\(action.title) Succeeded", failed: "\(action.title) Failed",
                                  cancelled: "\(action.title) Cancelled", carriesOver: false)
        let request = model.buildRequest(scheme: scheme, destination: destination, action: action == .analyze ? .analyze : .build)
        let result = await performBuild(request, presentation: p, keepsRunningApp: true) { _ in runner.start(action, file: file, context: ctx) }
        let out = FileActionRunner.outputPath(action, file: file, context: ctx)
        return (result, result.status == .succeeded ? out : nil)
    }

    /// Whether a single-file action applies to the file (its language).
    public static func canPerform(_ action: FileAction, file: String?) -> Bool {
        guard let file, let lang = SourceLanguage(path: file) else { return false }
        return action.supports(lang)
    }

    /// Where single-file outputs go: a scratch folder per workspace.
    var fileActionOutputDirectory: String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ycode-file-actions")
            .appendingPathComponent(FileBuildContext.moduleIdentifier(model.displayName)).path
    }

    /// The SDK single-file actions compile against (the destination's).
    var fileActionSDKName: String {
        let platform = destination.map { $0.kind == .mac ? "macOS" : $0.platform } ?? "macOS"
        let simulator = destination.map { $0.kind == .simulator || $0.specifier.hasSuffix("Simulator") || $0.isYcodeRemoteSimulator } ?? false
        return Self.sdkName(platform: platform, simulator: simulator)
    }

    /// The module context of a file: for a project, the target whose
    /// Sources phase (or synchronized folder) holds it, with its build
    /// settings for the selected destination; for a package, the source
    /// folder (`Sources/<Module>` or `Tests/<Module>`) that holds it.
    public func fileBuildContext(for file: String, productsDirectory: String? = nil) -> FileBuildContext {
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        let language = SourceLanguage(path: path)
        let platform = destination.map { $0.kind == .mac ? "macOS" : $0.platform } ?? "macOS"
        let simulator = destination.map { $0.kind == .simulator || $0.specifier.hasSuffix("Simulator") || $0.isYcodeRemoteSimulator } ?? false
        let sdk = SDKInfo.lookup(fileActionSDKName)
        var ctx = FileBuildContext(moduleName: FileBuildContext.moduleIdentifier(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent),
                                   sdkPath: sdk?.path, outputDirectory: fileActionOutputDirectory)
        if model.kind == .package {
            let root = model.url.standardizedFileURL.path
            let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)).split(separator: "/").map(String.init) : []
            if rel.count >= 3, ["Sources", "Tests"].contains(rel[0]) {
                let moduleDir = URL(fileURLWithPath: root).appendingPathComponent(rel[0]).appendingPathComponent(rel[1])
                ctx.moduleName = FileBuildContext.moduleIdentifier(rel[1])
                ctx.moduleSources = Self.swiftFiles(under: moduleDir)
                if language != .swift { ctx.includePaths.append(moduleDir.appendingPathComponent("include").path) }
            }
            let config = "debug"
            for dir in [".build/\(config)/Modules", ".build/\(config)", ".ycode-build/Products/Debug"] {
                let p = URL(fileURLWithPath: root).appendingPathComponent(dir).path
                if FileManager.default.fileExists(atPath: p) { ctx.includePaths.append(p) }
            }
            return ctx
        }
        guard let owner = Self.target(compiling: path, in: model) else { return ctx }
        let builder = ProjectSettingsBuilder(proj: owner.proj, xcodeprojURL: owner.url)
        guard let resolved = try? builder.resolve(target: owner.target, configuration: configuration(for: "LaunchAction")) else {
            ctx.moduleSources = owner.sources.filter { $0.hasSuffix(".swift") }
            return ctx
        }
        let s = resolved.settings
        func list(_ name: String) -> [String] {
            MacroExpressionList.split(s[name]).filter { $0 != "$(inherited)" && !$0.isEmpty }
        }
        let product = s["PRODUCT_MODULE_NAME"].isEmpty ? (s["PRODUCT_NAME"].isEmpty ? owner.target : s["PRODUCT_NAME"]) : s["PRODUCT_MODULE_NAME"]
        ctx.moduleName = FileBuildContext.moduleIdentifier(product)
        ctx.moduleSources = owner.sources.filter { $0.hasSuffix(".swift") }
        if !s["SWIFT_VERSION"].isEmpty { ctx.swiftVersion = s["SWIFT_VERSION"] }
        if let setting = DestinationCatalog.deploymentTargetSetting(platform), !s[setting].isEmpty || sdk?.version != nil {
            let version = s[setting].isEmpty ? sdk!.version! : s[setting]
            ctx.targetTriple = Self.triple(platform: platform, version: version, simulator: simulator)
        }
        ctx.defines = language == .swift ? list("SWIFT_ACTIVE_COMPILATION_CONDITIONS") : list("GCC_PREPROCESSOR_DEFINITIONS")
        ctx.includePaths = list("HEADER_SEARCH_PATHS") + list("USER_HEADER_SEARCH_PATHS") + (language == .swift ? list("SWIFT_INCLUDE_PATHS") : [])
        ctx.frameworkPaths = list("FRAMEWORK_SEARCH_PATHS")
        // The products of the scheme's other targets (modules it imports).
        if let p = productsDirectory, FileManager.default.fileExists(atPath: p) {
            ctx.includePaths.append(p)
            ctx.frameworkPaths.append(p)
        }
        return ctx
    }

    /// The SDK of a platform: `macosx`, `iphoneos` / `iphonesimulator`, ….
    static func sdkName(platform: String, simulator: Bool) -> String {
        let names: [String: (String, String)] = ["macOS": ("macosx", "macosx"), "iOS": ("iphoneos", "iphonesimulator"),
                                                 "watchOS": ("watchos", "watchsimulator"), "tvOS": ("appletvos", "appletvsimulator"),
                                                 "visionOS": ("xros", "xrsimulator")]
        let n = names[platform] ?? ("macosx", "macosx")
        return simulator ? n.1 : n.0
    }

    /// The target triple: `<arch>-apple-<os><version>[-simulator]`.
    static func triple(platform: String, version: String, simulator: Bool) -> String {
        let os = ["macOS": "macosx", "iOS": "ios", "watchOS": "watchos", "tvOS": "tvos", "visionOS": "xros"][platform] ?? "macosx"
        let arch = platform == "macOS" || simulator ? SwiftBuildEngine.hostArchitecture : "arm64"
        return "\(arch)-apple-\(os)\(version)\(simulator ? "-simulator" : "")"
    }

    static func swiftFiles(under dir: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL)?.standardizedFileURL }.filter { $0.pathExtension == "swift" }.map(\.path).sorted()
    }

    /// The project target that compiles a file, and the target's source files.
    static func target(compiling path: String, in model: WorkspaceModel) -> (proj: PBXProj, url: URL, target: String, sources: [String])? {
        for (projPath, project) in model.projects.sorted(by: { $0.key < $1.key }) {
            let url = URL(fileURLWithPath: projPath)
            let dir = project.projectDirectory(xcodeprojURL: url)
            let parents = project.parentMap()
            for t in project.targets {
                var sources: [String] = []
                for phase in project.buildPhases(ofTarget: t.id) where phase.isa == "PBXSourcesBuildPhase" {
                    for bf in phase.references("files") {
                        if let ref = project.fileReference(ofBuildFile: bf),
                           let p = project.resolvedPath(of: ref.id, projectDirectory: dir, parents: parents) {
                            sources.append(URL(fileURLWithPath: p).standardizedFileURL.path)
                        }
                    }
                }
                for g in t.references("fileSystemSynchronizedGroups") {
                    if let p = project.resolvedPath(of: g, projectDirectory: dir, parents: parents) {
                        let folder = URL(fileURLWithPath: p).standardizedFileURL
                        sources += swiftFiles(under: folder)
                        if path.hasPrefix(folder.path + "/") && !sources.contains(path) { sources.append(path) }
                    }
                }
                if sources.contains(path), let name = t.string("name") { return (project, url, name, sources) }
            }
        }
        return nil
    }

    // MARK: Project-level checks (§11.6, T8)

    /// Re-runs the project checks; the capsule and the Issue navigator
    /// count their warnings.
    public func refreshProjectIssues() {
        let found = ProjectChecks.issues(in: model, configuration: configuration(for: "LaunchAction"))
        guard found != projectIssues else { return }
        projectIssues = found
        notify(.issues)
    }
}

/// Splits a list-valued build setting as the build system does: on
/// whitespace, with double quotes grouping.
enum MacroExpressionList {
    static func split(_ text: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, any = false
        for ch in text {
            if ch == "\"" { quoted.toggle(); any = true; continue }
            if !quoted && (ch == " " || ch == "\t") {
                if any { out.append(cur) }
                cur = ""; any = false
                continue
            }
            cur.append(ch); any = true
        }
        if any { out.append(cur) }
        return out
    }
}

/// An installed SDK's path and version (`xcrun --sdk <name>`), looked up
/// once per name.
enum SDKInfo {
    struct Info: Sendable { var path: String; var version: String? }
    nonisolated(unsafe) private static var cache: [String: Info?] = [:]
    private static let lock = NSLock()

    static func lookup(_ name: String) -> Info? {
        lock.lock()
        if let hit = cache[name] { lock.unlock(); return hit }
        lock.unlock()
        func run(_ args: [String]) -> String? {
            MainThreadGuard.blockingCall("xcrun \(args.joined(separator: " "))")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return p.terminationStatus == 0 && !s.isEmpty ? s : nil
        }
        let info = run(["--sdk", name, "--show-sdk-path"]).map { Info(path: $0, version: run(["--sdk", name, "--show-sdk-version"])) }
        lock.lock()
        cache[name] = info
        lock.unlock()
        return info
    }
}

/// Checks of the project itself, reported as project-level warnings
/// (`reference-ui-5.md` §11.6, T8; `reference-ui-3.md` §1 Signing).
public enum ProjectChecks {
    /// Product types that are signed for a device and so need a team.
    static let signedProductTypes: Set<String> = [
        "com.apple.product-type.application", "com.apple.product-type.app-extension",
        "com.apple.product-type.application.watchapp2", "com.apple.product-type.application.watchapp2-container",
        "com.apple.product-type.watchkit2-extension", "com.apple.product-type.extensionkit-extension",
        "com.apple.product-type.application.on-demand-install-capable",
    ]

    /// "Signing for “<target>” requires a development team." for each
    /// device-platform app or extension target that manages signing
    /// automatically and has no `DEVELOPMENT_TEAM`. Mac-only targets sign
    /// to run locally and need none. ("Update to recommended settings" is
    /// left out: the recommended set is not specified yet.)
    public static func issues(in model: WorkspaceModel, configuration: String) -> [Diagnostic] {
        var out: [Diagnostic] = []
        for (path, proj) in model.projects.sorted(by: { $0.key < $1.key }) {
            let builder = ProjectSettingsBuilder(proj: proj, xcodeprojURL: URL(fileURLWithPath: path))
            for t in proj.targets {
                guard let name = t.string("name"), signedProductTypes.contains(t.string("productType") ?? ""),
                      let s = try? builder.resolve(target: name, configuration: configuration).settings else { continue }
                let platforms = DestinationMenuModel.platforms(supportedPlatforms: s["SUPPORTED_PLATFORMS"].isEmpty ? nil : s["SUPPORTED_PLATFORMS"],
                                                               sdkroot: s["SDKROOT"])
                guard !platforms.subtracting(["macOS"]).isEmpty, s["CODE_SIGN_STYLE"] != "Manual",
                      s["DEVELOPMENT_TEAM"].isEmpty, s["CODE_SIGNING_ALLOWED"] != "NO" else { continue }
                out.append(Diagnostic(severity: .warning, message: ProjectEditorModel.noTeamWarning(target: name)[0]))
            }
        }
        return out
    }
}

/// A test run's activity texts (`reference-ui-6.md` §3.4), moved on by
/// the runner's output: "Test" when the action is accepted, the build
/// texts while the tests build ("Building • n/m", counted as for a build,
/// §3.2), "Configuring Debugger Actions" once the build is done, then
/// "Testing <scheme>" once the first test starts. It only moves forward.
@MainActor
public final class TestActivityProgress {
    public enum Phase: Int, Comparable, Sendable {
        case accepted, building, configuring, testing
        public static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }
    public private(set) var phase = Phase.accepted
    public private(set) var text: String
    let subject: String
    private var counter = LogTaskCounter()

    public init(subject: String) {
        self.subject = subject
        text = WorkspaceSession.RunActivityText.testAccepted
    }

    /// The new text after an output line, or nil when it stays.
    public func feed(_ line: String) -> String? {
        let next: String
        if Self.startsTesting(line) {
            guard phase < .testing else { return nil }
            phase = .testing
            next = "Testing \(subject)"
        } else if Self.endsBuilding(line) {
            guard phase < .configuring else { return nil }
            phase = .configuring
            next = WorkspaceSession.RunActivityText.configuringDebugger
        } else if phase <= .building, let p = counter.feed(line) {
            phase = .building
            next = WorkspaceSession.BuildActivityText.progress(done: p.done, total: p.total)
        } else {
            return nil
        }
        guard next != text else { return nil }
        text = next
        return next
    }

    /// The build part of a test run is done: SwiftPM's "Build complete!",
    /// xcodebuild's "** TEST BUILD SUCCEEDED **" or "Testing started".
    static func endsBuilding(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespaces)
        return l.hasPrefix("Build complete!") || l == "** TEST BUILD SUCCEEDED **" || l == "Testing started"
    }

    /// The first test starts: an XCTest suite or case line, or
    /// swift-testing's run start.
    static func startsTesting(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespaces)
        return l.hasPrefix("Test Suite '") || l.hasPrefix("Test Case '") || l.contains("Test run started")
    }
}
