import Foundation
import YcodeProject
import YcodeWorkspace

/// `test`, `test-without-building` and the test half of
/// `build-for-testing`. Tests run in the platform's own `xctest` runner;
/// swift-testing tests run there too (the testing library hooks into it).
/// See `specs/xcodebuild/test-actions.md`.
enum TestActions {
    struct Outcome {
        /// Results per test bundle, in run order.
        struct TargetRun {
            var target: TestTarget
            var results: [TestCaseResult]
            /// A selection (`-only-testing`, a plan's selected tests) was applied.
            var selected: Bool
            /// swift-testing suites in the order they started.
            /// When each swift-testing function started (an order index).
            var starts: [String: Int] = [:]
            /// The runner's console output (for the bundle's diagnostics).
            var output = ""
        }
        var targets: [TargetRun] = []
        var results: [TestCaseResult] = []
        var errors: [String] = []
        var startedAt = Date()
        var endedAt = Date()
        /// Code coverage of the run (coverage on and a profile merged).
        var coverage: CoverageData?
        var succeeded: Bool { errors.isEmpty && !results.contains { $0.status == .failed } }
    }

    // MARK: Targets

    /// The scheme's test plan: `-testPlan`, else the default plan reference.
    static func testPlan(_ inv: Invocation, plan: Plan) throws(XcodebuildFailure) -> (name: String, file: TestPlanFile?, isDefault: Bool) {
        guard let scheme = plan.scheme else { return ("", nil, true) }
        let refs = scheme.testPlans
        let bundle = scheme.url.map { URL(fileURLWithPath: $0.path.components(separatedBy: "/xcshareddata/").first ?? $0.path) }
        func load(_ ref: String) -> TestPlanFile? {
            let rel = ref.hasPrefix("container:") ? String(ref.dropFirst("container:".count)) : ref
            let base = bundle?.deletingLastPathComponent() ?? plan.container.baseDirectory
            return TestPlanFile(path: base.appendingPathComponent(rel).path)
        }
        if let wanted = inv.value("-testPlan") {
            guard let ref = refs.first(where: { URL(fileURLWithPath: $0.reference).deletingPathExtension().lastPathComponent == wanted }) else {
                let project = plan.container.mainProject?.name ?? plan.container.name
                throw XcodebuildFailure("Failed to build project \(project) with scheme \(scheme.name).: Scheme “\(scheme.name)” does not have an associated test plan named “\(wanted)”.",
                                        exitCode: ExitCode.usage)
            }
            return (wanted, load(ref.reference), ref.isDefault)
        }
        if let ref = refs.first(where: \.isDefault) ?? refs.first {
            return (URL(fileURLWithPath: ref.reference).deletingPathExtension().lastPathComponent, load(ref.reference), true)
        }
        return (scheme.name, nil, true)
    }

    /// The test bundles of a scheme run, located through their build settings.
    static func targets(_ inv: Invocation, plan: Plan, testPlan: TestPlanFile?, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> [TestTarget] {
        if let package = plan.package { return try packageTargets(package, plan: plan, context: ctx) }
        guard let scheme = plan.scheme else { return [] }
        var chosen: [SettingsTarget] = []
        func add(_ p: LoadedProject?, _ t: PBXObject?) {
            guard let p, let t, Container.isTestBundle(t), !chosen.contains(where: { $0.target.id == t.id && $0.project.url == p.url }) else { return }
            chosen.append(SettingsTarget(project: p, target: t))
        }
        if let testPlan {
            for e in testPlan.entries where e.enabled {
                for p in plan.container.projects { if let t = p.target(named: e.targetName) { add(p, t); break } }
            }
        } else {
            for tt in scheme.testables where !tt.skipped {
                let p = plan.container.project(for: tt.reference, schemeBundle: scheme.url)
                add(p, p?.proj[tt.reference.blueprintIdentifier] ?? p?.target(named: tt.reference.blueprintName))
            }
        }
        guard !chosen.isEmpty else { return [] }
        let settings: [[String: String]]
        do {
            settings = try ShowBuildSettings.provider(ctx).settings(container: plan.container, targets: chosen, parameters: plan.parameters(action: .build))
        } catch {
            throw XcodebuildFailure("Could not resolve the test bundles' build settings: \(error)", exitCode: ExitCode.software)
        }
        return zip(chosen, settings).map { t, s in
            let dir = s["TARGET_BUILD_DIR"] ?? s["BUILT_PRODUCTS_DIR"] ?? ""
            let bundle = dir + "/" + (s["FULL_PRODUCT_NAME"] ?? t.name + ".xctest")
            var target = TestTarget(
                blueprintName: t.name, projectName: t.project.name,
                projectRelativePath: XcodePIF.relativePath(t.project.url.path, from: plan.container.baseDirectory.path),
                blueprintIdentifier: t.target.id, moduleName: s["PRODUCT_MODULE_NAME"] ?? t.name,
                bundleIdentifier: s["PRODUCT_BUNDLE_IDENTIFIER"] ?? "", bundlePath: bundle,
                executablePath: dir + "/" + (s["EXECUTABLE_PATH"] ?? ""), productsDirectory: dir,
                testHost: s["TEST_HOST"].flatMap { $0.isEmpty ? nil : $0 })
            if let e = testPlan?.entries.first(where: { $0.targetName == t.name }) {
                target.only = e.selected
                target.skip = e.skipped
            }
            return target
        }
    }

    /// The test bundles of a package scheme, from their build settings.
    static func packageTargets(_ package: Plan.PackageBuild, plan: Plan, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> [TestTarget] {
        guard !package.tests.isEmpty else { return [] }
        guard let helper = SwiftBuildSettingsProvider.locate(environment: ctx.environment, executableDirectory: ctx.executableDirectory) else {
            throw XcodebuildFailure("ycodebuild needs the ycode-swb helper (swift-build) to build; set YCODE_SWB to its path.", exitCode: ExitCode.software)
        }
        let settings: [[String: String]]
        do {
            settings = try SwiftBuildSettingsProvider(helper: helper).settings(pif: URL(fileURLWithPath: package.pif), guids: package.tests,
                                                                              parameters: plan.parameters(action: .build))
        } catch {
            throw XcodebuildFailure("Could not resolve the test bundles' build settings: \(error)", exitCode: ExitCode.software)
        }
        return zip(package.tests, settings).map { guid, s in
            let dir = s["TARGET_BUILD_DIR"] ?? s["BUILT_PRODUCTS_DIR"] ?? ""
            let name = s["TARGET_NAME"] ?? guid
            return TestTarget(blueprintName: s["PRODUCT_NAME"] ?? name, projectName: plan.container.name, projectRelativePath: "",
                              blueprintIdentifier: guid, moduleName: s["PRODUCT_MODULE_NAME"] ?? name,
                              bundleIdentifier: s["PRODUCT_BUNDLE_IDENTIFIER"] ?? "",
                              bundlePath: dir + "/" + (s["FULL_PRODUCT_NAME"] ?? name + ".xctest"),
                              executablePath: dir + "/" + (s["EXECUTABLE_PATH"] ?? ""), productsDirectory: dir, testHost: nil)
        }
    }

    // MARK: Selection

    /// `-only-testing` / `-skip-testing` values: `Target[/Class[/method]]`.
    static func applySelection(_ inv: Invocation, to targets: [TestTarget]) -> [TestTarget] {
        func split(_ id: String) -> (target: String, rest: String) {
            guard let slash = id.firstIndex(of: "/") else { return (id, "") }
            return (String(id[..<slash]), String(id[id.index(after: slash)...]))
        }
        let only = inv.all("-only-testing").map(split)
        let skip = inv.all("-skip-testing").map(split)
        var out: [TestTarget] = []
        for var t in targets {
            if !only.isEmpty {
                let mine = only.filter { $0.target == t.blueprintName }
                if mine.isEmpty { continue }
                if mine.contains(where: { $0.rest.isEmpty }) { t.only = [] } else { t.only = mine.map(\.rest) }
            }
            let mySkips = skip.filter { $0.target == t.blueprintName }
            if mySkips.contains(where: { $0.rest.isEmpty }) { continue }
            t.skip += mySkips.map(\.rest)
            out.append(t)
        }
        return out
    }

    /// XCTest classes and methods of a bundle, from SwiftPM's open-source
    /// `swiftpm-xctest-helper` (shipped in the toolchain).
    static func xctestListing(_ t: TestTarget, context ctx: XcodebuildContext) -> [String: [String]] {
        guard let dev = ctx.developerDirectory else { return [:] }
        let helper = dev + "/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-xctest-helper"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ycodebuild-xctests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        guard run(helper, [t.bundlePath, out.path], environment: testEnvironment(t, ctx)).status == 0,
              let data = FileManager.default.contents(atPath: out.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var classes: [String: [String]] = [:]
        func walk(_ node: [String: Any], depth: Int) {
            let children = node["tests"] as? [[String: Any]] ?? []
            if depth == 2, let name = node["name"] as? String {
                let cls = name.hasPrefix(t.moduleName + ".") ? String(name.dropFirst(t.moduleName.count + 1)) : name
                classes[cls] = children.compactMap { $0["name"] as? String }
                return
            }
            for c in children { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return classes
    }

    /// swift-testing tests of a bundle (through `ycodebuild __list-swift-tests`).
    static func swiftListing(_ t: TestTarget, context ctx: XcodebuildContext) -> [SwiftTestingBridge.TestRecord] {
        guard FileManager.default.isExecutableFile(atPath: ctx.toolPath) else { return [] }
        let r = run(ctx.toolPath, ["__list-swift-tests", t.executablePath], environment: testEnvironment(t, ctx))
        return r.status == 0 ? SwiftTestingBridge.parse(r.output) : []
    }

    /// The `-XCTest` argument for a target's selection, or nil to run all.
    static func filter(_ t: TestTarget, xctests: [String: [String]], swiftTests: [SwiftTestingBridge.TestRecord]) -> String? {
        if t.only.isEmpty && t.skip.isEmpty { return nil }
        // Normalize `Class/method()` (test plans, XCTest) to `Class/method`.
        func norm(_ id: String) -> String {
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, xctests[parts[0]] != nil, parts[1].hasSuffix("()") { return parts[0] + "/" + parts[1].dropLast(2) }
            return id
        }
        let skip = Set(t.skip.map(norm))
        var units: [String]
        if !t.only.isEmpty {
            units = t.only.map(norm)
        } else {
            units = []
            for (cls, methods) in xctests.sorted(by: { $0.key < $1.key }) {
                if skip.contains(cls) { continue }
                let skipped = methods.filter { skip.contains(cls + "/" + $0) }
                units += skipped.isEmpty ? [cls] : methods.filter { !skipped.contains($0) }.map { cls + "/" + $0 }
            }
            // swift-testing: top-level suites and free functions.
            var tops: [String] = []
            for r in swiftTests {
                let top = String(r.path.split(separator: "/").first ?? "")
                if !top.isEmpty, !tops.contains(top), r.isSuite || !r.path.contains("/") { tops.append(top) }
            }
            for top in tops {
                if skip.contains(top) { continue }
                let members = swiftTests.filter { !$0.isSuite && $0.path.hasPrefix(top + "/") }
                let skipped = members.filter { skip.contains($0.path) }
                units += skipped.isEmpty ? [top] : members.filter { !skipped.contains($0) }.map(\.path)
            }
        }
        units = units.filter { !skip.contains($0) }
        return units.map { t.moduleName + "." + $0 }.joined(separator: ",")
    }

    // MARK: Running

    static func testEnvironment(_ t: TestTarget, _ ctx: XcodebuildContext) -> [String: String] {
        var env = ctx.environment
        let platform = (ctx.developerDirectory ?? "") + "/Platforms/MacOSX.platform/Developer"
        env["DYLD_FRAMEWORK_PATH"] = t.productsDirectory + ":" + platform + "/Library/Frameworks"
        env["DYLD_LIBRARY_PATH"] = t.productsDirectory + ":" + platform + "/usr/lib"
        env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] = t.productsDirectory
        for (k, v) in t.environment { env[k] = v }
        // A bundle built with coverage writes `default.profraw` into the
        // current directory when no profile path is given; keep such
        // stray profiles next to the products instead.
        if env["LLVM_PROFILE_FILE"] == nil { env["LLVM_PROFILE_FILE"] = t.productsDirectory + "/stray-%p.profraw" }
        return env
    }

    static func run(_ tool: String, _ args: [String], environment: [String: String], lines: ((String) -> Void)? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = lines == nil ? FileHandle.nullDevice : pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        var all = Data()
        var buffer = Data()
        let h = pipe.fileHandleForReading
        while true {
            let d = h.availableData
            if d.isEmpty { break }
            all.append(d)
            guard let lines else { continue }
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer = Data(buffer[(nl + 1)...])
            }
        }
        if let lines, !buffer.isEmpty { lines(String(decoding: buffer, as: UTF8.self)) }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: all, as: UTF8.self))
    }

    /// Runs every target's tests, echoing the runners' output unless quiet.
    /// With `profileDirectory` (coverage on), each runner writes its raw
    /// profile to `<dir>/<device id>/<UUID>-<pid>.profraw` and the profiles
    /// are merged into `Coverage.profdata` there afterwards.
    static func execute(_ targets: [TestTarget], quiet: Bool, context ctx: XcodebuildContext, profileDirectory: String? = nil) -> Outcome {
        var outcome = Outcome()
        let console = ctx.console
        guard let dev = ctx.developerDirectory else {
            outcome.errors.append("No developer directory: cannot locate the xctest runner.")
            return outcome
        }
        let xctest = dev + "/usr/bin/xctest"
        let profiles = profileDirectory.map { $0 + "/" + (Destinations.macProvisioningUDID() ?? "local") }
        if let profiles {
            try? FileManager.default.createDirectory(atPath: profiles, withIntermediateDirectories: true)
            // Profiles of earlier runs are not part of this one.
            for f in (try? FileManager.default.contentsOfDirectory(atPath: profiles)) ?? [] where f.hasSuffix(".profraw") || f == "Coverage.profdata" {
                try? FileManager.default.removeItem(atPath: profiles + "/" + f)
            }
        }
        defer { if let profiles { mergeProfiles(in: profiles, developerDirectory: dev) } }
        for var t in targets {
            if let profiles { t.environment["LLVM_PROFILE_FILE"] = profiles + "/" + UUID().uuidString + "-%p.profraw" }
            if let host = t.testHost {
                outcome.errors.append("\(t.blueprintName) runs inside \(URL(fileURLWithPath: host).lastPathComponent); tests hosted in an application are not supported by ycodebuild yet.")
                continue
            }
            guard FileManager.default.fileExists(atPath: t.bundlePath) else {
                outcome.errors.append("The test bundle \(t.bundlePath) does not exist; build it with build-for-testing first.")
                continue
            }
            let swiftTests = swiftListing(t, context: ctx)
            let xctests = (t.only.isEmpty && t.skip.isEmpty) ? [:] : xctestListing(t, context: ctx)
            var args: [String] = []
            if let f = filter(t, xctests: xctests, swiftTests: swiftTests) { args = ["-XCTest", f] }
            var parser = TestConsoleParser(module: t.moduleName, swiftTests: swiftTests)
            let r = run(xctest, args + [t.bundlePath], environment: testEnvironment(t, ctx)) { line in
                if !quiet { console.out(line) }
                parser.feed(line)
            }
            outcome.results += parser.results
            outcome.targets.append(.init(target: t, results: parser.results, selected: !t.only.isEmpty,
                                         starts: Dictionary(parser.results.map { ($0.name, parser.startIndex(of: $0.name)) }, uniquingKeysWith: { a, _ in a }),
                                         output: r.output))
            if r.status != 0, parser.results.isEmpty {
                outcome.errors.append("xctest (\(t.blueprintName)) exited with status \(r.status) without running tests.")
            }
        }
        outcome.endedAt = Date()
        return outcome
    }

    /// `llvm-profdata merge` of the raw profiles into `Coverage.profdata`.
    static func mergeProfiles(in dir: String, developerDirectory dev: String) {
        let raws = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".profraw") }.sorted()
        guard !raws.isEmpty else { return }
        let tool = dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-profdata"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        _ = run(tool, ["merge", "-o", dir + "/Coverage.profdata"] + raws.map { dir + "/" + $0 }, environment: ProcessInfo.processInfo.environment)
    }

    /// The closing report: session line, failing tests, banner.
    static func report(_ outcome: Outcome, action: BuildAction, resultBundle: String?, quiet: Bool, console: Console) -> Bool {
        if !quiet, let resultBundle {
            console.out()
            console.out("Test session results, code coverage, and logs:")
            console.out("\t" + resultBundle)
            console.out()
        }
        if outcome.succeeded {
            if !quiet {
                console.out("** \(action.bannerWord) SUCCEEDED **")
                console.out()
            }
            return true
        }
        if !outcome.errors.isEmpty {
            console.err("Testing failed:")
            for e in outcome.errors { console.err("\t" + e) }
            console.err()
        }
        let failing = outcome.results.filter { $0.status == .failed }
        if !failing.isEmpty {
            console.err("Failing tests:")
            for name in failing.map(\.failingName).uniqued() { console.err("\t" + name) }
            console.err()
        }
        console.err("** \(action.bannerWord) FAILED **")
        console.err()
        return false
    }
}
