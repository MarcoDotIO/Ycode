import Foundation

/// A test bundle to run, with what the run needs to know about it.
/// See `specs/xcodebuild/test-actions.md`.
public struct TestTarget: Equatable, Sendable {
    public var blueprintName: String
    public var projectName: String
    /// `X.xcodeproj`, relative to the container's directory.
    public var projectRelativePath: String
    public var blueprintIdentifier: String
    public var moduleName: String
    public var bundleIdentifier: String
    /// Absolute path of the `.xctest` bundle.
    public var bundlePath: String
    /// Path of the bundle's executable.
    public var executablePath: String
    /// The products directory holding the bundle (`…/Build/Products/Debug`).
    public var productsDirectory: String
    /// `TEST_HOST`, for tests that run inside an application.
    public var testHost: String?
    public var only: [String] = []
    public var skip: [String] = []
    public var environment: [String: String] = [:]
    public var arguments: [String] = []
    /// `PRODUCT_TYPE` (`com.apple.product-type.bundle.unit-test`, `….ui-testing`).
    public var productType: String = ""
    /// `PLATFORM_NAME` of the build (`macosx`, `iphonesimulator`).
    public var platform: String = "macosx"
    /// UI tests: `TEST_TARGET_NAME`, the app the tests drive.
    public var uiTargetName: String?
    /// The test plan configuration this run belongs to (nil: none named).
    public var configuration: String?
    /// The plan's repetition for this run.
    public var repetition: TestPlanFile.Repetition?
    public var language: String?
    public var region: String?

    public var isUITest: Bool { productType == "com.apple.product-type.bundle.ui-testing" }
}

/// `.xctestrun` files (format version 2), documented in
/// `man xcodebuild.xctestrun`; the keys written are those observed in the
/// reference tool's files.
public enum XCTestRunFile {
    public static func fileName(scheme: String, testPlan: String, sdk: String, arch: String) -> String {
        "\(scheme)_\(testPlan)_\(sdk)-\(arch).xctestrun"
    }

    /// The plist for one test plan run.
    public static func make(scheme: String, containerName: String, testPlan: String, isDefaultPlan: Bool,
                            targets: [TestTarget], testRoot: String) -> [String: Any] {
        func rooted(_ p: String) -> String { p.hasPrefix(testRoot + "/") ? "__TESTROOT__" + p.dropFirst(testRoot.count) : p }
        let entries: [[String: Any]] = targets.map { t in
            // Hosted bundles (`man xcodebuild.xctestrun`): the host is the
            // application, the bundle is named relative to it.
            let app = TestActions.hostApp(t)?.app
            let products = rooted(t.productsDirectory)
            var d: [String: Any] = [
                "BlueprintName": t.blueprintName,
                "ClangProfileDataDirectoryPath": "__DERIVEDDATA__/Build/ProfileData",
                "DiagnosticCollectionPolicy": 1,
                "DSTROOTPath": "/tmp/\(t.projectName).dst",
                "IsMemoryTaggingAddressSanitizerEnabled": false,
                "PreferredScreenCaptureFormat": "screenRecording",
                "TestInteropMode": "complete",
                "BlueprintProviderName": t.projectName,
                "BlueprintProviderRelativePath": t.projectRelativePath,
                "BundleIdentifiersForCrashReportEmphasis": [t.bundleIdentifier].filter { !$0.isEmpty },
                "CommandLineArguments": t.arguments,
                "DefaultTestExecutionTimeAllowance": 600,
                "DependentProductPaths": [rooted(t.bundlePath)],
                "EnvironmentVariables": t.environment,
                "ProductModuleName": t.moduleName,
                "SystemAttachmentLifetime": "deleteOnSuccess",
                "TestBundlePath": rooted(t.bundlePath),
                "TestHostPath": t.testHost.map(rooted) ?? "__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest",
                "TestingEnvironmentVariables": [
                    "DYLD_FRAMEWORK_PATH": products + ":__SHAREDFRAMEWORKS__:__PLATFORMS__/MacOSX.platform/Developer/Library/Frameworks",
                    "DYLD_LIBRARY_PATH": products + ":__PLATFORMS__/MacOSX.platform/Developer/usr/lib",
                    "__XCODE_BUILT_PRODUCTS_DIR_PATHS": products,
                    "__XPC_DYLD_FRAMEWORK_PATH": products,
                    "__XPC_DYLD_LIBRARY_PATH": products,
                    "XCODE_SCHEME_NAME": scheme,
                    "XCODE_TEST_PLAN_NAME": testPlan,
                ],
                "TestLanguage": "",
                "TestRegion": "",
                "TestTimeoutsEnabled": false,
                "ToolchainsSettingValue": [String](),
                "UserAttachmentLifetime": "deleteOnSuccess",
            ]
            if !t.only.isEmpty { d["OnlyTestIdentifiers"] = t.only }
            if !t.skip.isEmpty { d["SkipTestIdentifiers"] = t.skip }
            if let app {
                d["TestHostPath"] = rooted(app)
                if t.bundlePath.hasPrefix(app + "/") { d["TestBundlePath"] = "__TESTHOST__" + t.bundlePath.dropFirst(app.count) }
                d["DependentProductPaths"] = [rooted(app), rooted(t.bundlePath)]
                if let id = TestActions.bundleIdentifier(ofApp: app) { d["TestHostBundleIdentifier"] = id }
                d["IsAppHostedTestBundle"] = true
            }
            if t.isUITest {
                d["IsUITestBundle"] = true
                if let target = t.uiTargetName { d["UITargetAppPath"] = rooted(t.productsDirectory.components(separatedBy: "/\(t.blueprintName)-Runner.app").first ?? t.productsDirectory) + "/" + target + ".app" }
            }
            return d
        }
        return [
            "__xctestrun_metadata__": ["FormatVersion": 2],
            "CodeCoverageBuildableInfos": [Any](),
            "ContainerInfo": ["ContainerName": containerName, "SchemeName": scheme],
            "TestConfigurations": [["IsEnabled": true, "Name": "Test Scheme Action", "TestTargets": entries]],
            "TestPlan": ["IsDefault": isDefaultPlan, "Name": testPlan],
        ]
    }

    /// The executable of an application bundle (iOS-style or macOS-style).
    static func executable(ofApp app: String) -> String {
        for (plist, dir) in [("Contents/Info.plist", "Contents/MacOS/"), ("Info.plist", "")] {
            if let data = FileManager.default.contents(atPath: app + "/" + plist),
               let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let exe = p["CFBundleExecutable"] as? String { return app + "/" + dir + exe }
        }
        return app + "/" + URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
    }

    /// What a test run file describes.
    public struct Contents {
        public var scheme: String?
        public var container: String?
        public var testPlan: String?
        public var targets: [TestTarget]
    }

    /// The test targets of a file, placeholders expanded.
    public static func read(_ path: String, developerDirectory: String) throws(XcodebuildFailure) -> Contents {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw XcodebuildFailure("Unable to read the test run file at \(path).", exitCode: ExitCode.noInput)
        }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent().path
        func expand(_ s: String) -> String {
            s.replacingOccurrences(of: "__TESTROOT__", with: root)
                .replacingOccurrences(of: "__PLATFORMS__", with: developerDirectory + "/Platforms")
                .replacingOccurrences(of: "__SHAREDFRAMEWORKS__", with: URL(fileURLWithPath: developerDirectory).deletingLastPathComponent().path + "/SharedFrameworks")
        }
        var targetDicts: [[String: Any]] = []
        if let configs = plist["TestConfigurations"] as? [[String: Any]] {
            for c in configs where (c["IsEnabled"] as? Bool) ?? true { targetDicts += c["TestTargets"] as? [[String: Any]] ?? [] }
        } else {
            // Format version 1: one dictionary per target at the top level.
            for (k, v) in plist where !k.hasPrefix("__") { if let d = v as? [String: Any] { targetDicts.append(d) } }
        }
        let targets: [TestTarget] = targetDicts.compactMap { d in
            var host = (d["TestHostPath"] as? String).map(expand)
            guard let bundle = (d["TestBundlePath"] as? String).map({ expand($0).replacingOccurrences(of: "__TESTHOST__", with: host ?? "") }) else { return nil }
            let name = d["BlueprintName"] as? String ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
            let shallow = !FileManager.default.fileExists(atPath: bundle + "/Contents")
            let exe = bundle + (shallow ? "/" : "/Contents/MacOS/") + URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
            // An application host: its executable (`CFBundleExecutable`).
            if let h = host, h.hasSuffix(".app") { host = Self.executable(ofApp: h) }
            var t = TestTarget(blueprintName: name, projectName: d["BlueprintProviderName"] as? String ?? "",
                               projectRelativePath: d["BlueprintProviderRelativePath"] as? String ?? "", blueprintIdentifier: "",
                               moduleName: d["ProductModuleName"] as? String ?? name, bundleIdentifier: "",
                               bundlePath: bundle, executablePath: exe,
                               productsDirectory: URL(fileURLWithPath: bundle).deletingLastPathComponent().path,
                               testHost: host.flatMap { $0.hasSuffix("/Agents/xctest") ? nil : $0 })
            t.only = d["OnlyTestIdentifiers"] as? [String] ?? []
            t.skip = d["SkipTestIdentifiers"] as? [String] ?? []
            t.environment = d["EnvironmentVariables"] as? [String: String] ?? [:]
            t.arguments = d["CommandLineArguments"] as? [String] ?? []
            if d["IsUITestBundle"] as? Bool == true {
                t.productType = "com.apple.product-type.bundle.ui-testing"
                t.uiTargetName = (d["UITargetAppPath"] as? String).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            }
            if bundle.contains("-iphonesimulator/") { t.platform = "iphonesimulator" }
            return t
        }
        let info = plist["ContainerInfo"] as? [String: Any]
        return Contents(scheme: info?["SchemeName"] as? String, container: info?["ContainerName"] as? String,
                        testPlan: (plist["TestPlan"] as? [String: Any])?["Name"] as? String, targets: targets)
    }
}

/// `.xctestplan` files (JSON): which targets a plan tests, which tests it
/// selects or skips, its configurations and their options (environment,
/// arguments, repetitions, language and region). The keys are those of
/// test plans in open-source projects (`specs/ide/testing.md`, "Test
/// plans"). Unknown keys are ignored.
public struct TestPlanFile: Sendable {
    public struct Entry: Equatable, Sendable {
        public var targetName: String
        public var identifier: String = ""
        public var containerPath: String = ""
        public var enabled: Bool
        public var selected: [String]
        public var skipped: [String]
        public var parallelizable: Bool?
        public init(targetName: String, enabled: Bool = true, selected: [String] = [], skipped: [String] = []) {
            self.targetName = targetName
            self.enabled = enabled
            self.selected = selected
            self.skipped = skipped
        }
    }

    /// Test repetition (`testRepetitionMode`, `maximumTestRepetitions`).
    public struct Repetition: Equatable, Sendable {
        public enum Mode: String, Sendable { case none, fixedIterations, untilFailure, retryOnFailure }
        public var mode: Mode
        public var count: Int
        public init(mode: Mode, count: Int) {
            self.mode = mode
            self.count = count
        }
    }

    /// A plan's options (`defaultOptions`, or a configuration's `options`
    /// over them). Nil: not set at this level.
    public struct Options: Equatable, Sendable {
        public struct Variable: Equatable, Sendable { public var key: String; public var value: String; public var enabled: Bool }
        public struct Argument: Equatable, Sendable { public var argument: String; public var enabled: Bool }
        public var environment: [Variable]?
        public var arguments: [Argument]?
        public var repetitionMode: Repetition.Mode?
        public var maximumRepetitions: Int?
        public var language: String?
        public var region: String?
        public var codeCoverage: Bool?
        public var testTimeoutsEnabled: Bool?
        public var defaultExecutionTimeAllowance: Int?
        public init() {}

        init(_ d: [String: Any]) {
            environment = (d["environmentVariableEntries"] as? [[String: Any]])?.compactMap { e in
                guard let k = e["key"] as? String else { return nil }
                return Variable(key: k, value: e["value"] as? String ?? "", enabled: e["enabled"] as? Bool ?? true)
            }
            arguments = (d["commandLineArgumentEntries"] as? [[String: Any]])?.compactMap { e in
                guard let a = e["argument"] as? String else { return nil }
                return Argument(argument: a, enabled: e["enabled"] as? Bool ?? true)
            }
            repetitionMode = (d["testRepetitionMode"] as? String).flatMap(Repetition.Mode.init(rawValue:))
            maximumRepetitions = d["maximumTestRepetitions"] as? Int
            language = d["language"] as? String
            region = d["region"] as? String
            // `codeCoverage` is a Bool or an object naming targets (on).
            if let b = d["codeCoverage"] as? Bool { codeCoverage = b } else if d["codeCoverage"] is [String: Any] { codeCoverage = true }
            testTimeoutsEnabled = d["testTimeoutsEnabled"] as? Bool
            defaultExecutionTimeAllowance = d["defaultTestExecutionTimeAllowance"] as? Int
        }

        /// These options over `base`: each option set here wins.
        public func over(_ base: Options) -> Options {
            var o = base
            if let environment { o.environment = environment }
            if let arguments { o.arguments = arguments }
            if let repetitionMode { o.repetitionMode = repetitionMode }
            if let maximumRepetitions { o.maximumRepetitions = maximumRepetitions }
            if let language { o.language = language }
            if let region { o.region = region }
            if let codeCoverage { o.codeCoverage = codeCoverage }
            if let testTimeoutsEnabled { o.testTimeoutsEnabled = testTimeoutsEnabled }
            if let defaultExecutionTimeAllowance { o.defaultExecutionTimeAllowance = defaultExecutionTimeAllowance }
            return o
        }

        /// The enabled environment variables.
        public var enabledEnvironment: [String: String] {
            var out: [String: String] = [:]
            for v in environment ?? [] where v.enabled { out[v.key] = v.value }
            return out
        }

        /// The enabled arguments, in order.
        public var enabledArguments: [String] { (arguments ?? []).filter(\.enabled).map(\.argument) }

        /// The repetition: a mode other than none, with its maximum (3
        /// when the plan gives none: Ycode's choice, an OPEN QUESTION in
        /// `specs/ide/testing.md`).
        public var repetition: Repetition? {
            guard let m = repetitionMode, m != .none else { return nil }
            return Repetition(mode: m, count: max(1, maximumRepetitions ?? 3))
        }
    }

    public struct Configuration: Equatable, Sendable {
        public var id: String
        public var name: String
        public var options: Options
    }

    public var name: String
    public var entries: [Entry]
    public var defaultOptions = Options()
    public var configurations: [Configuration] = []

    public init(name: String, entries: [Entry]) {
        self.name = name
        self.entries = entries
    }

    public init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        self.init(data: data, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }

    public init?(data: Data, name: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.name = name
        entries = (obj["testTargets"] as? [[String: Any]] ?? []).compactMap { t in
            guard let target = t["target"] as? [String: Any], let n = target["name"] as? String else { return nil }
            var e = Entry(targetName: n, enabled: (t["enabled"] as? Bool) ?? true,
                          selected: t["selectedTests"] as? [String] ?? [], skipped: t["skippedTests"] as? [String] ?? [])
            e.identifier = target["identifier"] as? String ?? ""
            e.containerPath = target["containerPath"] as? String ?? ""
            e.parallelizable = t["parallelizable"] as? Bool
            return e
        }
        defaultOptions = Options(obj["defaultOptions"] as? [String: Any] ?? [:])
        configurations = (obj["configurations"] as? [[String: Any]] ?? []).map { c in
            Configuration(id: c["id"] as? String ?? "", name: c["name"] as? String ?? "", options: Options(c["options"] as? [String: Any] ?? [:]))
        }
    }

    /// The configurations a run uses: `-only-test-configuration` names
    /// (all when empty), minus `-skip-test-configuration` names. A plan
    /// without configurations has one, with the default options.
    public func configurations(only: [String], skip: [String]) -> [Configuration] {
        let all = configurations.isEmpty ? [Configuration(id: "", name: "Configuration 1", options: Options())] : configurations
        return all.filter { (only.isEmpty || only.contains($0.name)) && !skip.contains($0.name) }
    }

    /// The plan name of a scheme's reference (`container:Dir/Name.xctestplan` → `Name`).
    public static func name(ofReference ref: String) -> String {
        let rel = ref.hasPrefix("container:") ? String(ref.dropFirst("container:".count)) : ref
        return URL(fileURLWithPath: rel).deletingPathExtension().lastPathComponent
    }

    /// A configuration's effective options.
    public func options(for c: Configuration) -> Options { c.options.over(defaultOptions) }
}
