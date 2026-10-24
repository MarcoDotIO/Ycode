import Foundation

/// Build actions through swift-build (the `ycode-swb build` helper), with
/// the reference tool's log format, banners and exit codes.
/// See `specs/xcodebuild/build-actions.md`.
enum BuildActions {
    /// Actions ycodebuild performs; the rest are reported as gaps.
    static let supported: Set<BuildAction> = [.build, .analyze, .clean, .buildForTesting, .install, .test, .testWithoutBuilding, .archive, .docbuild]

    static func run(_ inv: Invocation, plan: Plan, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        if plan.actions.contains(where: { $0 == .test || $0 == .testWithoutBuilding }) {
            guard let s = plan.scheme else {
                throw XcodebuildFailure("The test action requires that the name of a scheme in the project is provided using the \"-scheme\" option. The \"-list\" option can be used to find the names of the schemes in the project.", exitCode: ExitCode.dataError)
            }
            if plan.package == nil && s.testables.isEmpty && s.testPlans.isEmpty {
                throw XcodebuildFailure("Scheme \(s.name) is not currently configured for the test action.", exitCode: ExitCode.noInput, trailingBlank: true)
            }
        }
        for a in plan.actions where !supported.contains(a) {
            throw Xcodebuild.unsupported("the \(a.rawValue) action")
        }
        guard let helper = SwiftBuildSettingsProvider.locate(environment: ctx.environment, executableDirectory: ctx.executableDirectory) else {
            throw XcodebuildFailure("ycodebuild needs the ycode-swb helper (swift-build) to build; set YCODE_SWB to its path.", exitCode: ExitCode.software)
        }
        // -resultBundlePath (checked for an existing file before the header).
        var session: ResultBundleSession?
        if let (path, given) = ResultBundleSession.requestedPath(inv, cwd: ctx.cwd) {
            let s = ResultBundleSession.make(plan: plan, path: path, given: given, explicit: true, context: ctx)
            s.announce(ctx.console)
            session = s
        }
        let projectName = plan.container.mainProject?.name ?? plan.container.name
        let quiet = inv.quiet
        for (index, action) in plan.actions.enumerated() {
            let started = Date()
            // The run destination is chosen again (with its warning) for
            // each further action.
            if index > 0, plan.scheme != nil {
                _ = try? Destinations.runDestination(for: inv.destinations, targets: plan.targets, configuration: plan.configuration,
                                                     overrides: plan.overrides, generic: action == .archive, context: ctx)
            }
            let names = ResultBundleSession.names(action, scheme: plan.scheme?.name, projectName: projectName,
                                                  containerWord: plan.container.kind == .workspace ? "workspace" : "project")
            func entry(_ build: BuildOutcome?, tests: TestActions.Outcome? = nil, testPlan: String? = nil, testRequested: Bool = false) -> ResultBundleSession.Action {
                ResultBundleSession.Action(commandName: names.command, taskName: names.task, title: names.title, started: started, ended: Date(),
                                           build: build, tests: tests, testPlanName: testPlan, testRequested: testRequested)
            }
            switch action {
            case .test, .testWithoutBuilding:
                let (name, file, _) = try TestActions.testPlan(inv, plan: plan)
                // Test runs always write a bundle: the requested one or a
                // default one in the DerivedData folder's Logs/Test.
                let bundle = session ?? plan.arena.map { arena in
                    let p = ResultBundleSession.defaultTestPath(arena: arena, scheme: plan.scheme?.name ?? projectName, date: started)
                    return ResultBundleSession.make(plan: plan, path: p, given: p, explicit: false, context: ctx)
                }
                var build: BuildOutcome?
                if action == .test {
                    let b = try runOne(.buildForTesting, inv: inv, plan: plan, helper: helper, context: ctx, banner: .test, successBanner: false)
                    build = b
                    if !b.ok {
                        bundle?.record(entry(b, testPlan: name, testRequested: true), quiet: quiet, console: ctx.console, announceWritten: false)
                        return ExitCode.dataError
                    }
                }
                let targets = TestActions.applySelection(inv, to: try TestActions.targets(inv, plan: plan, testPlan: file, context: ctx))
                ctx.console.outDeferred("Testing started")
                let profiles = plan.coverage ? plan.synthesized.last { $0.0 == "CLANG_PROFILE_DATA_DIRECTORY" }?.1 : nil
                var outcome = TestActions.execute(targets, quiet: quiet, context: ctx, profileDirectory: profiles)
                if let profiles, let dev = ctx.developerDirectory {
                    outcome.coverage = Coverage.collect(profile: Coverage.profilePath(profileDirectory: profiles),
                                                        targets: Coverage.targets(plan: plan, context: ctx), developerDirectory: dev)
                    if let out = ctx.environment[Coverage.summaryVariable], let c = outcome.coverage {
                        try? Coverage.summaryJSON(c).write(to: URL(fileURLWithPath: out))
                    }
                }
                bundle?.record(entry(build, tests: outcome, testPlan: name, testRequested: true), quiet: quiet, console: ctx.console, announceWritten: false)
                if !TestActions.report(outcome, action: action, resultBundle: bundle?.displayPath, quiet: quiet, console: ctx.console) { return ExitCode.dataError }
            case .buildForTesting:
                let b = try runOne(action, inv: inv, plan: plan, helper: helper, context: ctx, successBanner: false) { b in
                    session?.record(entry(b), quiet: quiet, console: ctx.console)
                }
                if b.ok { try writeTestRun(inv, plan: plan, context: ctx) }
                if !b.ok { return ExitCode.dataError }
                if !quiet { ctx.console.out("** \(action.bannerWord) SUCCEEDED **"); ctx.console.out() }
            case .archive:
                let b = try runOne(action, inv: inv, plan: plan, helper: helper, context: ctx, successBanner: false) { b in
                    if !b.ok { session?.record(entry(b), quiet: quiet, console: ctx.console) }
                }
                if !b.ok { return ExitCode.dataError }
                var outcome = b
                do {
                    // Without a scheme the archive action is only a build.
                    if plan.scheme != nil {
                        let path = try Archives.assemble(inv, plan: plan, context: ctx, created: started)
                        session?.archivePath = path
                    }
                } catch {
                    outcome.ok = false
                    session?.record(entry(outcome), quiet: quiet, console: ctx.console)
                    ctx.console.report(error)
                    ctx.console.err("** ARCHIVE FAILED **")
                    ctx.console.err()
                    return ExitCode.dataError
                }
                session?.record(entry(outcome), quiet: quiet, console: ctx.console)
                if !quiet { ctx.console.out("** \(action.bannerWord) SUCCEEDED **"); ctx.console.out() }
            default:
                let b = try runOne(action, inv: inv, plan: plan, helper: helper, context: ctx) { b in
                    session?.record(entry(b), quiet: quiet, console: ctx.console)
                }
                if !b.ok { return ExitCode.dataError }
            }
        }
        return 0
    }

    /// Writes `<scheme>_<plan>_<sdk>-<arch>.xctestrun` into the products
    /// directory after build-for-testing.
    static func writeTestRun(_ inv: Invocation, plan: Plan, context ctx: XcodebuildContext) throws(XcodebuildFailure) {
        guard let scheme = plan.scheme, let arena = plan.arena else { return }
        let (name, file, isDefault) = try TestActions.testPlan(inv, plan: plan)
        let targets = TestActions.applySelection(inv, to: try TestActions.targets(inv, plan: plan, testPlan: file, context: ctx))
        guard !targets.isEmpty else { return }
        let sdk = plan.overrides.last { $0.0 == "SDKROOT" }?.1 ?? SDKRegistry(developerDirectory: ctx.developerDirectory ?? "")
            .lookup("macosx", relativeTo: ctx.cwd)?.canonicalName ?? "macosx"
        let arch = plan.runDestination?.targetArchitecture ?? ctx.hostArchitecture
        let plist = XCTestRunFile.make(scheme: scheme.name, containerName: plan.container.name, testPlan: name, isDefaultPlan: isDefault,
                                       targets: targets, testRoot: arena.buildProductsPath)
        let path = arena.buildProductsPath + "/" + XCTestRunFile.fileName(scheme: scheme.name, testPlan: name, sdk: sdk, arch: arch)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw XcodebuildFailure("cannot write \(path): \(error)", exitCode: ExitCode.software)
        }
    }

    struct BuildOutcome {
        var ok: Bool
        var issues: [BuildLog.Issue]
        var started: Date
        var ended: Date
        var tasks: [BuildLog.TaskRecord] = []
    }

    static func runOne(_ action: BuildAction, inv: Invocation, plan: Plan, helper: String, context ctx: XcodebuildContext,
                       banner: BuildAction? = nil, successBanner: Bool = true,
                       beforeBanner: ((BuildOutcome) -> Void)? = nil) throws(XcodebuildFailure) -> BuildOutcome {
        let started = Date()
        let console = ctx.console
        let pif = XcodePIF(container: plan.container)
        let package = plan.package
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ycodebuild-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        var targets = plan.targets
        // `-alltargets` repeats the first target at the end of its listing;
        // build each target once.
        var seen = Set<String>()
        targets = targets.filter { seen.insert(pif.targetGUID($0.project, $0.target)).inserted }
        let guids = package.map { p in
            action == .docbuild && !p.documentation.isEmpty ? p.documentation : [.buildForTesting, .test].contains(action) ? p.build + p.tests : p.build
        }
            ?? targets.map { pif.targetGUID($0.project, $0.target) }
        let parameters = plan.parameters(action: action).json
        let request: [String: Any] = [
            // `clean` removes the whole build folder (Build/Products and
            // Build/Intermediates.noindex, or the legacy `build` directory).
            "command": action == .clean ? "cleanBuildFolder" : "build",
            "locationStyle": plan.locationStyle ?? (plan.scheme == nil ? "legacy" : "regular"),
            "pif": package?.pif ?? work.appendingPathComponent("workspace.pif.json").path,
            "parameters": parameters,
            "targets": guids,
            "containerPath": plan.container.url.path,
            "parallel": inv.has("-parallelizeTargets") || plan.scheme?.parallelizeBuildables ?? true,
            "implicitDependencies": plan.scheme?.buildImplicitDependencies ?? true,
            "hideShellScriptEnvironment": inv.has("-hideShellScriptEnvironment"),
            "continueAfterErrors": false,
            // archive turns on the build system's archive validations and
            // signs without the debugging entitlement.
            "schemeCommand": action == .archive ? "archive" : [.buildForTesting, .test, .testWithoutBuilding].contains(action) ? "test" : "launch",
            "debuggable": action != .archive,
        ]
        let requestURL = work.appendingPathComponent("build.json")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            if package == nil { try pif.serialized().write(to: work.appendingPathComponent("workspace.pif.json")) }
            try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]).write(to: requestURL)
        } catch {
            throw XcodebuildFailure("cannot prepare the build: \(error)", exitCode: ExitCode.software)
        }

        if !inv.quiet {
            // The reference tool's own preparation steps, which ycodebuild
            // performs too (request, project description, operation).
            for step in ["CreateBuildRequest", "SendProjectDescription", "CreateBuildOperation"] { console.out(step); console.out() }
        }
        var log = BuildLog(quiet: inv.quiet, console: console, schemeName: plan.scheme?.name, projectName: plan.container.mainProject?.name ?? plan.container.name)
        if plan.container.kind == .workspace { log.containerWord = "workspace" }
        log.deferTargetIssues = action == .archive || action == .docbuild
        let raw = ctx.environment["YCODEBUILD_RAW_EVENTS"].flatMap { FileHandle(forWritingAtPath: $0) ?? (fm.createFile(atPath: $0, contents: nil) ? FileHandle(forWritingAtPath: $0) : nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["build", requestURL.path]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            throw XcodebuildFailure("cannot run \(helper): \(error)", exitCode: ExitCode.software)
        }
        var buffer = Data()
        let handle = out.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                raw?.write(line + Data([0x0A]))
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { log.handle(obj) }
            }
        }
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus == 2 {
            log.internalError(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let outcome = BuildOutcome(ok: log.succeeded == true, issues: log.issues, started: started, ended: Date(), tasks: log.finishedTasks)
        // The result bundle is written (and announced) before the banner.
        beforeBanner?(outcome)
        _ = log.finish(action: banner ?? action, successBanner: successBanner)
        return outcome
    }
}

/// Turns swift-build messages into the reference tool's build log.
struct BuildLog {
    var quiet: Bool
    var console: Console
    var schemeName: String?
    var projectName: String
    /// "project", or "workspace" for workspaces and packages.
    var containerWord = "project"
    var targets: [Int: (name: String, project: String)] = [:]
    var tasks: [Int: (rule: String, target: Int?)] = [:]
    var failed: [String] = []
    var succeeded: Bool?
    var errorCount = 0
    /// Every error and warning, for the result bundle.
    struct Issue: Equatable {
        var kind: String
        var message: String
        var file: String?
        var line: Int?
        var targetName: String?
        var column: Int? = nil
        /// The compiler's category (`Semantic Issue`), when it gives one.
        var category: String? = nil
        /// The task that reported it.
        var taskID: Int? = nil
    }
    var issues: [Issue] = []
    /// Tasks as the result bundle's build log records them.
    struct TaskRecord {
        var id: Int
        var title: String
        var details: String
        var output: String
        var started: Date
        var duration: Double
        var succeeded: Bool
    }
    var openTasks: [Int: TaskRecord] = [:]
    var finishedTasks: [TaskRecord] = []

    init(quiet: Bool, console: Console, schemeName: String?, projectName: String) {
        self.quiet = quiet
        self.console = console
        self.schemeName = schemeName
        self.projectName = projectName
    }

    func suffix(_ target: Int?) -> String {
        guard let t = target, let info = targets[t] else { return "" }
        return " (in target '\(info.name)' from project '\(info.project)')"
    }

    static func decodeData(_ s: Any?) -> String {
        guard let s = s as? String else { return "" }
        if let d = Data(base64Encoded: s) { return String(decoding: d, as: UTF8.self) }
        return s
    }

    /// `path:line:column: kind: message`, as compilers print issues.
    func issueLine(_ m: [String: Any]) -> String {
        let kind = m["kind"] as? String ?? "error"
        let message = m["message"] as? String ?? ""
        var prefix = ""
        if let loc = m["location"] as? [String: Any], let path = loc["path"] as? String {
            prefix = path
            if let line = loc["line"] as? Int { prefix += ":\(line)" ; if let c = loc["column"] as? Int { prefix += ":\(c)" } }
            prefix += ": "
        }
        return prefix + kind + ": " + message
    }

    /// A task header was printed and its separating blank line is due:
    /// it comes when a task ends or before the next header.
    var sectionOpen = false

    mutating func closeSection() {
        if sectionOpen { console.out() }
        sectionOpen = false
    }

    /// Output held back in quiet mode until the task ends.
    var pendingOutput: [Int: String] = [:]

    /// Target-level issues are printed after the build's last task, just
    /// before the banner (the reference's placement for `archive` and
    /// `docbuild`), instead of when they arrive.
    var deferTargetIssues = false
    var deferredIssues: [String] = []

    /// Whether a successful task's output is shown in quiet mode: it has an
    /// error or warning line that is not a tool's own log line
    /// (`<date> <time> <process>[<pid>:<thread>] …`).
    static func hasIssueLines(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            guard line.contains("error:") || line.contains("warning:") else { return false }
            return line.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ \S+\[\d+:\d+\] "#, options: .regularExpression) == nil
        }
    }

    mutating func handle(_ m: [String: Any]) {
        switch m["kind"] as? String ?? "" {
        case "targetStarted":
            if let id = m["id"] as? Int {
                targets[id] = (m["name"] as? String ?? "", m["projectName"] as? String ?? projectName)
            }
        case "taskStarted":
            guard let id = m["id"] as? Int else { return }
            let rule = m["ruleInfo"] as? String ?? ""
            let target = m["targetID"] as? Int
            tasks[id] = (rule, target)
            var details = rule + suffix(target)
            if let cmd = m["commandLineDisplayString"] as? String, !cmd.isEmpty { details += "\n" + cmd }
            openTasks[id] = TaskRecord(id: id, title: m["executionDescription"] as? String ?? rule, details: details, output: "",
                                       started: Date(), duration: 0, succeeded: true)
            guard !quiet else { return }
            closeSection()
            console.out(rule + suffix(target))
            // The command display already carries its 4-space indentation
            // and the `cd` line.
            if var cmd = m["commandLineDisplayString"] as? String, !cmd.isEmpty {
                while cmd.hasSuffix("\n") { cmd.removeLast() }
                console.out(cmd)
            }
            sectionOpen = true
        case "taskOutput":
            let text = m["data"] as? String ?? ""
            guard !text.isEmpty else { return }
            if let id = m["taskID"] as? Int { openTasks[id]?.output += text }
            if quiet {
                if let id = m["taskID"] as? Int { pendingOutput[id, default: ""] += text }
                return
            }
            console.rawOut(text.hasSuffix("\n") ? text : text + "\n")
        case "output":
            // Output not tied to a task (task output also arrives as
            // `taskOutput`, in plain text).
            guard m["locationContext"] == nil || (m["locationContext"] as? [String: Any])?["taskID"] == nil, !quiet else { return }
            let text = Self.decodeData(m["data"])
            if !text.isEmpty { console.rawOut(text.hasSuffix("\n") ? text : text + "\n") }
        case "taskComplete":
            guard let id = m["id"] as? Int else { return }
            if !quiet { closeSection() }
            let failedTask = m["result"] as? String == "failed"
            if failedTask, let t = tasks[id] { failed.append(t.rule + suffix(t.target)) }
            if var rec = openTasks.removeValue(forKey: id) {
                rec.duration = Date().timeIntervalSince(rec.started)
                rec.succeeded = !failedTask
                finishedTasks.append(rec)
            }
            if quiet, let text = pendingOutput.removeValue(forKey: id), failedTask || Self.hasIssueLines(text) {
                console.rawOut(text.hasSuffix("\n") ? text : text + "\n")
            }
        case "error", "warning", "note", "remark":
            let kind = m["kind"] as! String
            let context = m["locationContext"] as? [String: Any]
            if kind == "error" || kind == "warning" {
                let loc = m["location"] as? [String: Any]
                let taskID = context?["taskID"] as? Int
                let targetID = context?["targetID"] as? Int ?? taskID.flatMap { tasks[$0]?.target }
                let component = m["component"] as? [String: Any]
                let issue = Issue(kind: kind, message: m["message"] as? String ?? "", file: loc?["path"] as? String,
                                  line: loc?["line"] as? Int, targetName: targetID.flatMap { targets[$0]?.name },
                                  column: loc?["column"] as? Int, category: Self.category(component, kind: kind), taskID: taskID)
                if !issues.contains(issue) { issues.append(issue) }
            }
            // Issues of a task are in its own output already, except those
            // the build system itself reports for the task
            // (`appendToOutputStream`), printed in the task's section.
            if context?["locationType"] as? String == "task" {
                if kind == "error" { errorCount += 1 }
                if m["appendToOutputStream"] as? Bool == true, kind == "error" || kind == "warning" || !quiet {
                    let target = (context?["taskID"] as? Int).flatMap { tasks[$0]?.target }
                    console.out(issueLine(m) + suffix(target))
                }
                return
            }
            if kind == "error" { errorCount += 1 }
            if quiet && (kind == "note" || kind == "remark") { return }
            var line = issueLine(m)
            let targetLevel = context?["locationType"] as? String == "target"
            if targetLevel { line += suffix(context?["targetID"] as? Int) }
            // Attached notes (such as the targets of the dependency graph)
            // follow, indented.
            let lines = [line] + (m["childDiagnostics"] as? [[String: Any]] ?? []).map { "    " + ($0["message"] as? String ?? "") }
            if targetLevel && deferTargetIssues {
                deferredIssues += lines
            } else {
                for l in lines { console.out(l) }
            }
        case "buildCompleted":
            if !quiet { closeSection() }
            for l in deferredIssues { console.out(l) }
            deferredIssues = []
            succeeded = (m["result"] as? String) == "ok"
        default:
            break
        }
    }

    /// The issue type the result bundle records: the compiler's
    /// category, `Swift Compiler Error`/`Warning` for Swift, else nil.
    static func category(_ component: [String: Any]?, kind: String) -> String? {
        if let c = component?["categoryName"] as? String, !c.isEmpty { return c }
        if (component?["componentType"] as? String) == "swiftCompiler" { return kind == "error" ? "Swift Compiler Error" : "Swift Compiler Warning" }
        return nil
    }

    mutating func internalError(_ text: String) {
        console.err("xcodebuild: error: \(text)")
        succeeded = false
    }

    /// Prints the banner; returns success.
    mutating func finish(action: BuildAction, successBanner: Bool = true) -> Bool {
        let ok = succeeded == true
        if ok {
            if !quiet && successBanner {
                console.out("** \(action.bannerWord) SUCCEEDED **")
                console.out()
            }
            return true
        }
        console.err("** \(action.bannerWord) FAILED **")
        console.err()
        if !quiet {
            console.err()
            console.err("The following build commands failed:")
            var lines = failed
            if let s = schemeName { lines.append("Building \(containerWord) \(projectName) with scheme \(s)") }
            else { lines.append("Building project \(projectName)") }
            for l in lines { console.err("\t" + l) }
            console.err("(\(lines.count) failure\(lines.count == 1 ? "" : "s"))")
        }
        return false
    }
}
