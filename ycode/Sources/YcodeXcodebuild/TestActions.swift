import Foundation
import YcodeSubprocess
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
            guard let ref = refs.first(where: { TestPlanFile.name(ofReference: $0.reference) == wanted }) else {
                let project = plan.container.mainProject?.name ?? plan.container.name
                throw XcodebuildFailure("Failed to build project \(project) with scheme \(scheme.name).: Scheme “\(scheme.name)” does not have an associated test plan named “\(wanted)”.",
                                        exitCode: ExitCode.usage)
            }
            return (wanted, load(ref.reference), ref.isDefault)
        }
        if let ref = refs.first(where: \.isDefault) ?? refs.first {
            return (TestPlanFile.name(ofReference: ref.reference), load(ref.reference), true)
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
            target.productType = s["PRODUCT_TYPE"] ?? ""
            target.platform = s["PLATFORM_NAME"] ?? "macosx"
            target.uiTargetName = s["TEST_TARGET_NAME"].flatMap { $0.isEmpty ? nil : $0 }
            if let e = testPlan?.entries.first(where: { $0.targetName == t.name }) {
                target.only = e.selected
                target.skip = e.skipped
            }
            return target
        }
    }

    /// Each target once per test plan configuration that runs
    /// (`-only-test-configuration`, `-skip-test-configuration`), with the
    /// configuration's environment, arguments, repetition, language and
    /// region. A plan with one configuration does not name it in results.
    static func expand(_ targets: [TestTarget], plan testPlan: TestPlanFile?, _ inv: Invocation) -> [TestTarget] {
        var out = expandConfigurations(targets, plan: testPlan, inv)
        if let r = commandLineRepetition(inv) { for i in out.indices { out[i].repetition = r } }
        return out
    }

    /// `-test-iterations N`, `-retry-tests-on-failure` (at most N, else 3
    /// tries), `-run-tests-until-failure` (at most N, else 100); they replace
    /// the plan's repetition (`man xcodebuild`).
    static func commandLineRepetition(_ inv: Invocation) -> TestPlanFile.Repetition? {
        let n = inv.value("-test-iterations").flatMap(Int.init).map { max(1, $0) }
        if inv.has("-retry-tests-on-failure") { return .init(mode: .retryOnFailure, count: n ?? 3) }
        if inv.has("-run-tests-until-failure") { return .init(mode: .untilFailure, count: n ?? 100) }
        if let n { return .init(mode: .fixedIterations, count: n) }
        return nil
    }

    static func expandConfigurations(_ targets: [TestTarget], plan testPlan: TestPlanFile?, _ inv: Invocation) -> [TestTarget] {
        guard let testPlan else { return targets }
        let configs = testPlan.configurations(only: inv.all("-only-test-configuration"), skip: inv.all("-skip-test-configuration"))
        var out: [TestTarget] = []
        for c in configs {
            let o = testPlan.options(for: c)
            for var t in targets {
                if testPlan.configurations.count > 1 { t.configuration = c.name }
                for (k, v) in o.enabledEnvironment { t.environment[k] = v }
                t.arguments += o.enabledArguments
                t.repetition = o.repetition
                t.language = o.language
                t.region = o.region
                out.append(t)
            }
        }
        return out
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

    /// The Ycode simulator a `-destination` names, from the `YCODE_SIM_*`
    /// variables (`RemoteTestHost.Settings`); nil for other destinations.
    static func remoteSimulator(_ inv: Invocation, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> RemoteTestHost.Settings? {
        guard inv.destinations.contains(where: RemoteTestHost.isYcodeSimulator) else { return nil }
        guard let s = RemoteTestHost.Settings.from(environment: ctx.environment) else {
            throw XcodebuildFailure("The Ycode simulator destination needs its host: set YCODE_SIM_HOST, YCODE_SIM_DATA, YCODE_SIM_RUNTIME and YCODE_SIM_SIMD (specs/xcodebuild/test-actions.md).",
                                    exitCode: ExitCode.usage)
        }
        return s
    }

    /// The test plan file a scheme's test action uses (`-testPlan`, else
    /// the default reference), without a plan.
    static func testPlanFile(_ inv: Invocation, scheme: Scheme, container: Container) -> TestPlanFile? {
        let refs = scheme.testPlans
        let wanted = inv.value("-testPlan")
        guard let ref = wanted.map({ w in refs.first { TestPlanFile.name(ofReference: $0.reference) == w } })
                ?? refs.first(where: \.isDefault) ?? refs.first else { return nil }
        let bundle = scheme.url.map { URL(fileURLWithPath: $0.path.components(separatedBy: "/xcshareddata/").first ?? $0.path) }
        let rel = ref.reference.hasPrefix("container:") ? String(ref.reference.dropFirst("container:".count)) : ref.reference
        let base = bundle?.deletingLastPathComponent() ?? container.baseDirectory
        return TestPlanFile(path: base.appendingPathComponent(rel).path)
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
        guard let pipe = try? SpawnPipe(childReads: false) else { return (-1, "") }
        p.standardOutput = pipe.childEnd
        p.standardError = lines == nil ? FileHandle.nullDevice : pipe.childEnd
        p.standardInput = FileHandle.nullDevice
        guard (try? p.runWithSignalsUnblocked(closingChildEndsOf: pipe)) != nil else { return (-1, "") }
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
    static func execute(_ targets: [TestTarget], quiet: Bool, context ctx: XcodebuildContext, profileDirectory: String? = nil,
                        remoteSimulator: RemoteTestHost.Settings? = nil) -> Outcome {
        var outcome = Outcome()
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
        // Hosted targets for the Ycode simulator run together, per host app, after the rest.
        var remote: [TestTarget] = []
        for var t in targets {
            if let profiles { t.environment["LLVM_PROFILE_FILE"] = profiles + "/" + UUID().uuidString + "-%p.profraw" }
            t.arguments += languageArguments(t)
            if t.testHost != nil || t.isUITest, t.platform != "macosx" {
                if remoteSimulator != nil { remote.append(t) } else {
                    outcome.errors.append("\(t.blueprintName) runs inside an app on the \(t.platform) platform: choose the Ycode simulator (-destination 'platform=iOS Simulator,name=Ycode Simulator') and describe its host in the YCODE_SIM_* variables (specs/xcodebuild/test-actions.md).")
                }
                continue
            }
            if t.testHost != nil, !t.isUITest {
                runHostedLocally(t, quiet: quiet, context: ctx, outcome: &outcome)
                continue
            }
            // Tool-hosted bundles, and UI test bundles: those run in the
            // platform's xctest runner too (Ycode has no UI automation
            // service; tests that drive an app through XCUIApplication fail
            // with XCTest's own message, testing.md "Ycode implementation").
            runToolHosted(t, xctest: xctest, quiet: quiet, context: ctx, outcome: &outcome)
        }
        if let remoteSimulator, !remote.isEmpty {
            RemoteTestHost(settings: remoteSimulator, context: ctx).run(remote, quiet: quiet, outcome: &outcome)
        }
        outcome.endedAt = Date()
        return outcome
    }

    /// A bundle in the platform's `xctest` runner; a plan's repetition
    /// runs it again (fixed iterations, until a failure, or the failing
    /// tests again until they pass).
    static func runToolHosted(_ t: TestTarget, xctest: String, quiet: Bool, context ctx: XcodebuildContext, outcome: inout Outcome) {
        let console = ctx.console
        let bundle = t.isUITest ? uiBundlePath(t) : t.bundlePath
        guard FileManager.default.fileExists(atPath: bundle) else {
            outcome.errors.append("The test bundle \(bundle) does not exist; build it with build-for-testing first.")
            return
        }
        var t = t
        t.bundlePath = bundle
        let swiftTests = swiftListing(t, context: ctx)
        var xctests = (t.only.isEmpty && t.skip.isEmpty) ? [:] : xctestListing(t, context: ctx)
        let rounds = t.repetition?.count ?? 1
        var all: [TestCaseResult] = []
        var output = ""
        var starts: [String: Int] = [:]
        var round = t
        for i in 0..<rounds {
            var args: [String] = []
            if xctests.isEmpty, !round.only.isEmpty { xctests = xctestListing(t, context: ctx) }
            if let f = filter(round, xctests: xctests, swiftTests: swiftTests) { args = ["-XCTest", f] }
            var parser = TestConsoleParser(module: t.moduleName, swiftTests: swiftTests)
            let r = run(xctest, args + [t.bundlePath], environment: testEnvironment(t, ctx)) { line in
                if !quiet { console.out(line) }
                parser.feed(line)
            }
            all += parser.results
            output += r.output
            if i == 0 { starts = Dictionary(parser.results.map { ($0.name, parser.startIndex(of: $0.name)) }, uniquingKeysWith: { a, _ in a }) }
            if r.status != 0, parser.results.isEmpty {
                outcome.errors.append("xctest (\(t.blueprintName)) exited with status \(r.status) without running tests.")
                break
            }
            let failing = parser.results.filter { $0.status == .failed }
            var stop = false
            switch t.repetition?.mode {
            case .fixedIterations: break
            case .untilFailure: stop = !failing.isEmpty
            case .retryOnFailure:
                stop = failing.isEmpty
                round.only = failing.map(\.identifier).uniqued()
                round.skip = []
            default: stop = true
            }
            if stop { break }
        }
        let results = collapseRepetitions(all, mode: t.repetition?.mode)
        outcome.results += results
        outcome.targets.append(.init(target: t, results: results, selected: !t.only.isEmpty, starts: starts, output: output))
    }

    /// One result per test (and test case) after repetitions: a retried
    /// test has the status of its last try; otherwise a test failed when
    /// any iteration failed. Durations add up.
    static func collapseRepetitions(_ results: [TestCaseResult], mode: TestPlanFile.Repetition.Mode?) -> [TestCaseResult] {
        guard let mode, mode != .none else { return results }
        var order: [String] = []
        var merged: [String: TestCaseResult] = [:]
        for r in results {
            let key = r.identifier + "|" + r.arguments.map(\.value).joined(separator: ",")
            guard var m = merged[key] else {
                order.append(key)
                merged[key] = r
                continue
            }
            m.duration += r.duration
            if mode == .retryOnFailure || r.status == .failed || m.status == .skipped {
                m.status = r.status
                m.issues = r.status == .failed ? m.issues + r.issues : r.issues
            }
            merged[key] = m
        }
        return order.compactMap { merged[$0] }
    }

    /// A UI test bundle: swift-build builds it into
    /// `<PRODUCT_NAME>-Runner.app/…/PlugIns`; ycodebuild runs it from there.
    static func uiBundlePath(_ t: TestTarget) -> String { t.bundlePath }

    /// The test plan's language and region as the host's argument-domain
    /// defaults (`-AppleLanguages (<language>)`, `-AppleLocale
    /// <language>_<region>`), for runs inside an app.
    static func languageArguments(_ t: TestTarget) -> [String] {
        guard t.testHost != nil || t.isUITest else { return [] }
        var a: [String] = []
        if let l = t.language, !l.isEmpty { a += ["-AppleLanguages", "(\(l))"] }
        if let r = t.region, !r.isEmpty { a += ["-AppleLocale", (t.language.map { $0.isEmpty ? "en" : $0 } ?? "en") + "_" + r] }
        return a
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
