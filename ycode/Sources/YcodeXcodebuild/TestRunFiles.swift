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
            guard let bundle = (d["TestBundlePath"] as? String).map(expand) else { return nil }
            let name = d["BlueprintName"] as? String ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
            let exe = bundle + "/Contents/MacOS/" + URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
            let host = (d["TestHostPath"] as? String).map(expand)
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
            return t
        }
        let info = plist["ContainerInfo"] as? [String: Any]
        return Contents(scheme: info?["SchemeName"] as? String, container: info?["ContainerName"] as? String,
                        testPlan: (plist["TestPlan"] as? [String: Any])?["Name"] as? String, targets: targets)
    }
}

/// `.xctestplan` files (JSON): which targets a plan tests and which tests
/// it selects or skips.
public struct TestPlanFile {
    public struct Entry { public var targetName: String; public var enabled: Bool; public var selected: [String]; public var skipped: [String] }
    public var name: String
    public var entries: [Entry]

    public init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        entries = (obj["testTargets"] as? [[String: Any]] ?? []).compactMap { t in
            guard let target = t["target"] as? [String: Any], let n = target["name"] as? String else { return nil }
            return Entry(targetName: n, enabled: (t["enabled"] as? Bool) ?? true,
                         selected: t["selectedTests"] as? [String] ?? [], skipped: t["skippedTests"] as? [String] ?? [])
        }
    }
}
