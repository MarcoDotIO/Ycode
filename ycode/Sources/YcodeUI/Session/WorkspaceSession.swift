import Foundation
import YcodeBuild
import YcodeDebug
import YcodeLanguage

/// The non-visual state of one workspace window: the selected scheme and
/// destination, the running build or debug session, issues, breakpoints and
/// the console. Views observe it through `onChange`. See
/// `specs/ide/workspace-window.md` §Activity and `specs/ide/debug.md`.
@MainActor
public final class WorkspaceSession {
    public enum Activity: Equatable {
        case idle
        case building(String)
        case running(String)
        case paused(String)
        case finished(String)
    }

    public enum Change { case activity, issues, breakpoints, console, debugState, reports, tests, process }

    public var model: WorkspaceModel
    public var scheme: String?
    public var destination: RunDestination?
    /// The build engine chosen in Settings ▸ Locations ▸ Build System.
    public var engine: BuildEngine = BuildSystemPreference.current().makeEngine()
    public private(set) var activity: Activity = .idle
    /// Issues of the last build.
    public internal(set) var issues: [Diagnostic] = []
    /// Tests that failed in the last test run (the toolbar issue capsule).
    public internal(set) var failedTestCount = 0
    /// The product of the current or last debug run ("Finished running <product>").
    public internal(set) var runningProduct: String?
    /// Settings ▸ General ▸ Issues: show live issues.
    public var includeLiveIssues = true { didSet { notify(.issues) } }
    /// Package resolution failures (shown with the build issues).
    public var packageIssues: [Diagnostic] = [] { didSet { notify(.issues) } }
    /// Project-level checks (`reference-ui-5.md` §11.6, T8): warnings about
    /// the project itself, such as signing without a development team.
    /// They count in the toolbar capsule; see `refreshProjectIssues()`.
    public internal(set) var projectIssues: [Diagnostic] = []
    /// The last test run (Test Again, Test Without Building Again).
    public internal(set) var lastTestRun: TestRun?
    /// Product ▸ Test Plan: the chosen plan of the scheme (nil = its
    /// default plan).
    public var activeTestPlan: String?
    /// The language service, once started.
    public internal(set) var language: LanguageService?

    /// Build issues plus live issues from the language server, without
    /// duplicates; this is what the issue navigator and editor show.
    public var displayedIssues: [Diagnostic] {
        var seen = Set<Diagnostic>()
        let live = includeLiveIssues ? (language?.liveIssues ?? [:]).keys.sorted().flatMap { language!.liveIssues[$0]! } : []
        return (projectIssues + packageIssues + issues + live).filter { seen.insert(Diagnostic(severity: $0.severity, message: $0.message, location: $0.location)).inserted }
    }

    func languageIssuesChanged() { notify(.issues) }
    public var breakpoints = BreakpointStore() {
        didSet {
            notify(.breakpoints)
            breakpointFile?.save(breakpoints)
            Task { await syncBreakpoints() }
        }
    }
    /// The workspace's breakpoint files, once attached (reference-ui-5.md §10.1).
    public private(set) var breakpointFile: BreakpointPersistence?

    /// Loads the stored breakpoints and saves every later change of the set.
    public func attachBreakpointFile(user: String = NSUserName()) {
        let file = BreakpointPersistence(container: model.url, isPackage: model.kind == .package, user: user)
        breakpointFile = file
        breakpoints = file.load()
    }
    public private(set) var console = ""
    public private(set) var buildLog: [String] = []
    /// Arrival time of each `buildLog` line, from `buildLogStarted`.
    private var buildLogTimes: [TimeInterval] = []
    private var buildLogStarted = Date()
    func appendBuildLog(_ line: String) {
        buildLog.append(line)
        buildLogTimes.append(Date().timeIntervalSince(buildLogStarted))
    }
    func resetBuildLog() {
        buildLog = []
        buildLogTimes = []
        buildLogStarted = Date()
    }
    /// Tests found in the workspace's sources, and the last outcome of each.
    public private(set) var tests: [DiscoveredTest] = []
    /// The test discovery running in the background, if any.
    public private(set) var testDiscovery: Task<Void, Never>?
    private var testDiscoveryGeneration = 0
    public internal(set) var testResults: [DiscoveredTest: TestOutcome.Status] = [:]
    public var testRunner = TestRunner()
    /// The chosen build system; swift-build runs project tests through
    /// ycodebuild (TestRunnerSelection).
    public var buildSystemPreference: BuildSystemPreference = .current()

    /// Re-reads the sources for tests (the Test navigator).
    /// Finds the workspace's tests off the main thread (it reads every
    /// source file), then publishes them (`.tests`). A later call replaces
    /// a read still running.
    @discardableResult
    public func discoverTests() -> Task<Void, Never> {
        testDiscoveryGeneration += 1
        let generation = testDiscoveryGeneration, root = model.root
        let task = Task { [weak self] in
            let found = await Task.detached { TestDiscovery.tests(in: root) }.value
            guard let self, generation == self.testDiscoveryGeneration else { return }
            self.tests = found
            self.testDiscovery = nil
            self.notify(.tests)
        }
        testDiscovery = task
        return task
    }

    /// Waits until the tests have been found (tests of Ycode).
    public func testsDiscovered() async {
        while let t = testDiscovery { await t.value }
    }

    /// The tests a diamond at `file:line` runs: the test declared there, or
    /// every test of the suite declared there.
    public func testsForDiamond(file: String, line: Int) -> [DiscoveredTest] {
        if let t = tests.first(where: { $0.file == file && $0.line == line }) { return [t] }
        return tests.filter { $0.file == file && $0.suiteLine == line }
    }

    /// The filter form for the runner: `Suite/name` for packages;
    /// `<Target>/Suite/name` for projects (xcodebuild `-only-testing:`),
    /// the target being the one whose sources hold the test's file.
    public func runnerIdentifier(_ t: DiscoveredTest) -> String {
        guard model.kind != .package, let target = model.targetName(compiling: t.file) else { return t.identifier }
        return "\(target)/\(t.identifier)"
    }

    /// The SDK a destination builds against ("macOS 27.2" for the Mac).
    static func sdkName(for destination: String) -> String {
        let lower = destination.lowercased()
        guard destination.isEmpty || lower.contains("mac") else { return "" }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    /// Where a build or test ran, for its report.
    func reportContext(action: String, started: Date) -> ReportContext {
        var c = ReportContext()
        c.action = action
        c.scheme = scheme
        c.containerKind = model.kind == .package ? "Package" : "Project"
        c.containerName = model.displayName
        let s = scheme.flatMap { name in model.loadSchemes().first { $0.name == name } }
        c.configuration = s?.configuration(for: action == "Test" ? "TestAction" : "LaunchAction") ?? "Debug"
        c.destination = destination?.name ?? ""
        c.sdk = Self.sdkName(for: c.destination)
        c.duration = Date().timeIntervalSince(started)
        if action == "Test" {
            // The plan that ran (Product ▸ Test Plan), else the autocreated one.
            c.plan = effectiveTestPlan
            c.testTargets = max(1, Set(tests.map { model.kind == .package ? URL(fileURLWithPath: $0.file).deletingLastPathComponent().lastPathComponent : (model.targetName(compiling: $0.file) ?? "") }).count)
        }
        return c
    }

    /// Product ▸ Test (⌘U), or one test's diamond: runs tests and records
    /// pass/fail per discovered test. `only` holds `Suite/name` identifiers.
    /// `withoutBuilding`: Perform Action ▸ Test Without Building (⌃⌘U), the
    /// tests an earlier Build For ▸ Testing built.
    @discardableResult
    public func runTests(only: [DiscoveredTest] = [], withoutBuilding: Bool = false) async -> [TestOutcome] {
        stop()
        lastTestRun = TestRun(tests: only, withoutBuilding: withoutBuilding)
        // Re-read before each run so tests added since are found (testing.md §Discovery).
        discoverTests()
        await testsDiscovered()
        resetBuildLog()
        let testStarted = Date()
        setActivity(.building("Testing \(scheme ?? model.displayName)"))
        let request = model.buildRequest(scheme: scheme, destination: destination, action: withoutBuilding ? .testWithoutBuilding : .test)
        // Code coverage when the scheme's test action gathers it: SwiftPM's
        // own export for packages, ycodebuild's summary for projects.
        var runner = selectedTestRunner
        runner.coverage = gathersCoverage
        let summary = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-coverage-\(UUID().uuidString).json").path
        if runner.coverage { runner.coverageSummaryPath = summary }
        defer { try? FileManager.default.removeItem(atPath: summary) }
        let (code, outcomes) = await runner.run(request, only: only.map(runnerIdentifier)) { line in
            Task { @MainActor [weak self] in self?.appendBuildLog(line) }
        }
        try? await Task.sleep(nanoseconds: 50_000_000) // let queued log lines land
        for t in (only.isEmpty ? tests : only) {
            testResults[t] = outcomes.first { t.matches($0) }?.status
        }
        let failures = outcomes.flatMap(\.failures)
        issues = failures
        notify(.issues)
        notify(.tests)
        let ok = code == 0 && !outcomes.contains { $0.status == .failed }
        var report = BuildReport(title: "Test \(scheme ?? model.displayName)", date: Date(), succeeded: ok, log: buildLog,
                                 errorCount: outcomes.filter { $0.status == .failed }.count, warningCount: 0)
        report.context = reportContext(action: "Test", started: testStarted)
        report.context.tests = outcomes
        report.context.issues = failures
        report.context.logTimes = buildLogTimes
        if runner.coverage { report.context.coverage = await Task.detached { Self.coverage(request: request, runner: runner, summary: summary) }.value }
        reports.insert(report, at: 0)
        pruneReports()
        notify(.reports)
        failedTestCount = outcomes.filter { $0.status == .failed }.count
        notify(.issues)
        // reference-ui-2.md §2: "Test Completed" whatever the outcome; the
        // toolbar capsule shows the failures.
        setActivity(.finished(ok ? "Test Succeeded" : "Test Completed"))
        return outcomes
    }

    /// The selected scheme's test action gathers code coverage
    /// (`codeCoverageEnabled="YES"`).
    public var gathersCoverage: Bool {
        guard let name = scheme, let s = model.loadSchemes().first(where: { $0.name == name }) else { return false }
        return s.document.child("TestAction")?["codeCoverageEnabled"] == "YES"
    }

    /// The Coverage page's rows after a run with coverage.
    nonisolated static func coverage(request: BuildRequest, runner: TestRunner, summary: String) -> [CoverageItem] {
        if case .package(let dir) = request.container {
            return runner.packageCoverageJSON(packageDirectory: dir).map(CoverageModel.parseLLVMCovExport) ?? []
        }
        return FileManager.default.contents(atPath: summary).map(CoverageModel.parseYcodebuildSummary) ?? []
    }

    /// Finished builds, newest first (the Report navigator).
    public private(set) var reports: [BuildReport] = []

    /// Adds a finished operation (e.g. a package resolution) to the reports.
    public func recordReport(_ r: BuildReport) {
        reports.insert(r, at: 0)
        pruneReports()
        notify(.reports)
    }

    /// Settings ▸ General ▸ Local report history: older reports beyond it
    /// are dropped.
    public var reportHistoryLimit = 20 {
        didSet { if reportHistoryLimit < reports.count { pruneReports(); notify(.reports) } }
    }

    func pruneReports() {
        if reports.count > max(1, reportHistoryLimit) { reports.removeLast(reports.count - max(1, reportHistoryLimit)) }
    }

    /// Settings ▸ General ▸ Stop build on first error: the build is
    /// cancelled when its first error arrives, and reported as failed with
    /// the issues that arrived until it stopped.
    public var stopOnFirstError = true
    private var stoppedOnFirstError = false

    // Debugging
    public internal(set) var debugClient: DAPClient?
    /// The app running on a simulator (Mac or the remote Ycode simulator).
    public internal(set) var simulatorRun: SimulatorRunState?
    /// Console lines with their source (for the console filter).
    public private(set) var consoleEntries: [ConsoleEntry] = []
    /// The adapter's description of the last stop (e.g. "watchpoint 1").
    public private(set) var lastStopDescription: String?
    /// Commands typed into the console, oldest first (↑/↓ history).
    public private(set) var consoleHistory: [String] = []
    /// Watch expressions ("Add Expression…") and their last values.
    public var watchExpressions: [String] = [] { didSet { Task { await refreshWatches() } } }
    public private(set) var watchValues: [Variable] = []
    /// Watchpoints set from the variables view.
    public private(set) var watchpoints: [Watchpoint] = []
    /// The variables view also lists register scopes (Settings / the
    /// variables view's Registers toggle).
    public var showRegisters = false { didSet { if oldValue != showRegisters { Task { await loadVariables(frameID: selectedFrameID) } } } }
    /// Debug ▸ Debug Workflow ▸ Always Show Disassembly.
    public var alwaysShowDisassembly = false { didSet { Task { await refreshDisassembly() } } }
    /// The disassembly around the selected frame's PC, and the PC's index.
    public private(set) var disassembly: [Instruction] = []
    public private(set) var disassemblyPCIndex: Int?
    /// Which container (scope or parent) each shown variable came from.
    public private(set) var variableContainers: [String: Int] = [:]
    public private(set) var stoppedThread: Int?
    /// Continue To Current Line's breakpoint, removed at the next stop.
    public internal(set) var temporaryBreakpoint: (file: String, line: Int)?
    // Debugger UI state (WorkspaceSession+DebugUI.swift).
    /// "A" (argument) or "L" (local) per shown variable name.
    public internal(set) var variableBadges: [String: String] = [:]
    /// True while a stop's variables are being fetched (the spinner).
    public internal(set) var isLoadingVariables = false
    var exitLinePrinted = false
    var killReported = false
    /// Adapter breakpoint ids ("n.m") by "file:line", and hits per id.
    public internal(set) var breakpointIDs: [String: String] = [:]
    public internal(set) var breakpointHits: [String: Int] = [:]
    /// The stop's editor annotation ("Thread 1: breakpoint 1.1 (1)").
    public internal(set) var stopAnnotation: (file: String, line: Int, text: String)?
    /// Increments on each stop (the window selects the Debug navigator once per stop).
    public internal(set) var stopCount = 0
    /// The last stop for which the window selected the Debug navigator.
    public var autoSelectedStop = 0
    public internal(set) var processGauges = ProcessGauges()
    var gaugeSampler: ProcessGaugeSampler?
    var gaugeTimer: Timer?
    public private(set) var frames: [StackFrame] = []
    public private(set) var variables: [Variable] = []
    public private(set) var threads: [DebugThread] = []
    /// The frame the variables view shows (top frame when stopping).
    public private(set) var selectedFrameID: Int?
    /// The file and line the debugger stopped at, for the editor highlight.
    public var currentLocation: (file: String, line: Int)? {
        let f = frames.first { $0.id == selectedFrameID } ?? frames.first
        return f.flatMap { f in f.file.map { ($0, f.line) } }
    }

    private var currentBuild: BuildOperation?
    private var observers: [(Change) -> Void] = []

    public init(model: WorkspaceModel) {
        self.model = model
        scheme = model.schemeNames.first
        destination = model.destinations.first
    }

    public func observe(_ f: @escaping (Change) -> Void) { observers.append(f) }
    func notify(_ c: Change) { observers.forEach { $0(c) } }

    public var isBusy: Bool {
        switch activity { case .building, .running, .paused: true; default: false }
    }

    // MARK: Build

    /// Build (⌘B), Clean (⇧⌘K), Test (⌘U), Analyze (⇧⌘B).
    @discardableResult
    public func build(_ action: BuildRequest.Action = .build) async -> BuildResult {
        let request = model.buildRequest(scheme: scheme, destination: destination, action: action)
        let engine = self.engine
        return await performBuild(request, presentation: .init(action: action, subject: scheme ?? model.displayName), start: engine.start)
    }

    /// How a build-like operation shows in the activity view and the
    /// Report navigator.
    struct BuildPresentation {
        /// The activity text while it runs ("Building App").
        var running: String
        /// The report's action ("Build", "Clean", "Test").
        var reportAction: String
        /// The report title ("Build App").
        var title: String
        /// The finished activity text per status.
        var succeeded: String, failed: String, cancelled: String
        /// Whether the build log carries over the scheme's earlier steps.
        var carriesOver: Bool

        init(running: String, reportAction: String, title: String, succeeded: String, failed: String, cancelled: String, carriesOver: Bool) {
            self.running = running
            self.reportAction = reportAction
            self.title = title
            self.succeeded = succeeded
            self.failed = failed
            self.cancelled = cancelled
            self.carriesOver = carriesOver
        }

        init(action: BuildRequest.Action, subject: String) {
            let verb = action == .clean ? "Cleaning" : (action == .test ? "Testing" : "Building")
            let noun = action == .clean ? "Clean" : "Build"
            let verbTitle = action == .clean ? "Clean" : (action == .test ? "Test" : "Build")
            self.init(running: "\(verb) \(subject)", reportAction: verbTitle, title: "\(verbTitle) \(subject)",
                      succeeded: "\(noun) Succeeded", failed: "\(noun) Failed", cancelled: "Build Cancelled", carriesOver: action != .clean)
        }
    }

    /// Runs one build operation: the activity view, issues (stop on the
    /// first error), the build log and the report. It stops a running build
    /// and, unless `keepsRunningApp` (single-file actions), the running app.
    @discardableResult
    func performBuild(_ request: BuildRequest, presentation p: BuildPresentation, keepsRunningApp: Bool = false,
                      start: (BuildRequest) -> BuildOperation) async -> BuildResult {
        if keepsRunningApp { currentBuild?.cancel() } else { stop() }
        issues = []
        resetBuildLog()
        notify(.issues)
        let started = Date()
        setActivity(.building(p.running))
        let op = start(request)
        currentBuild = op
        stoppedOnFirstError = false
        var result = BuildResult(status: .cancelled, exitCode: -1, issues: [])
        for await event in op.events {
            handle(event)
            if case .finished(let r) = event { result = r }
        }
        currentBuild = nil
        if stoppedOnFirstError {
            if result.issues.isEmpty { result.issues = issues }
            result.status = .failed
        }
        let summary: String = switch result.status {
        case .succeeded: p.succeeded
        case .failed: p.failed
        case .cancelled: p.cancelled
        }
        issues = result.issues.filter { $0.severity != .note || $0.location != nil }
        notify(.issues)
        var report = BuildReport(title: p.title, date: Date(),
                                 succeeded: result.status == .succeeded, log: buildLog,
                                 errorCount: result.errorCount, warningCount: result.warningCount)
        report.context = reportContext(action: p.reportAction, started: started)
        report.context.issues = issues
        report.context.logTimes = buildLogTimes
        // The build log's All scope: steps of the scheme's earlier builds
        // (since its last clean) that this build did not run again.
        if p.carriesOver, let prev = reports.first(where: { $0.schemeName == report.schemeName && ($0.kind == .build || $0.kind == .clean) }),
           prev.kind == .build {
            report.context.carriedOver = BuildLogModel.carriedOver(from: prev, into: report)
        }
        reports.insert(report, at: 0)
        pruneReports()
        notify(.reports)
        setActivity(.finished(summary))
        return result
    }

    private func handle(_ event: BuildEvent) {
        switch event {
        case .output(let line): appendBuildLog(line)
        case .activity(let text): setActivity(.building(text))
        case .issue(let d):
            issues.append(d)
            notify(.issues)
            if stopOnFirstError, d.severity == .error, !stoppedOnFirstError, let op = currentBuild {
                stoppedOnFirstError = true
                op.cancel()
            }
        case .finished: break
        }
    }

    func setActivity(_ a: Activity) {
        activity = a
        notify(.activity)
    }

    // MARK: Run and debug

    /// Run (⌘R): build, then launch `program` under lldb-dap. With
    /// `building` false (Perform Action ▸ Run Without Building, ⌃⌘R) the
    /// product of the last build is launched as it is.
    public func run(program: String?, adapter: DAPTransport? = nil, building: Bool = true) async {
        if building {
            let result = await build(.build)
            guard result.status == .succeeded else { return }
        }
        guard let program else {
            appendConsole("Ycode: the scheme's executable could not be determined.\n")
            return
        }
        guard building || FileManager.default.fileExists(atPath: program) else {
            reportMissingProduct(program)
            return
        }
        await debug(program: program, adapter: adapter)
    }

    /// What the scheme's Run action passes to the program
    /// (`specs/ide/schemes.md` Run ▸ Arguments / Options): enabled
    /// arguments, each split into words as a shell would; enabled
    /// environment variables; the custom working directory, if any.
    public struct LaunchOptions: Equatable, Sendable {
        public var arguments: [String] = []
        public var environment: [String: String] = [:]
        public var workingDirectory: String?
    }

    /// The launch options of the selected scheme (none for packages or
    /// when the scheme file is not found).
    public var launchOptions: LaunchOptions {
        guard let name = scheme, let s = model.loadSchemes().first(where: { $0.name == name }) else { return LaunchOptions() }
        var o = LaunchOptions()
        o.arguments = s.launchArguments.filter(\.isEnabled).flatMap { RemoteSimulator.words($0.value) }
        for v in s.launchEnvironment where v.isEnabled && !v.key.isEmpty { o.environment[v.key] = v.value }
        if let d = s.customWorkingDirectory, !d.isEmpty { o.workingDirectory = d }
        return o
    }

    /// Starts a debug session for `program`. `adapter` defaults to lldb-dap.
    public func debug(program: String, adapter: DAPTransport? = nil) async {
        let transport: DAPTransport
        if let adapter { transport = adapter } else {
            guard let path = await Task.detached(operation: { LLDBDAP.locate() }).value else {
                appendConsole("Ycode: lldb-dap was not found.\n")
                return
            }
            transport = ProcessTransport(executable: path)
        }
        do {
            let client = try DAPClient(transport: transport)
            debugClient = client
            adapterInitialized = false
            beginDebugSession(product: URL(fileURLWithPath: program).lastPathComponent)
            setActivity(.running(DebugPresentation.runningTitle(runningProduct)))
            Task { [weak self] in
                for await e in client.events { await self?.handle(e) }
                self?.sessionEnded()
            }
            try await client.initialize()
            var o = launchOptions
            // An instrumented program writes default.profraw into its
            // working directory unless told otherwise; a per-run UUID keeps
            // the names unique. (A `%` in an environment value is passed
            // through by lldb-dap unchanged; the earlier "no output, no exit
            // event" symptom was a slow first launch under lldb, not `%`.)
            if o.environment["LLVM_PROFILE_FILE"] == nil {
                o.environment["LLVM_PROFILE_FILE"] = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-run-\(UUID().uuidString).profraw").path
            }
            try await client.launch(program: program, cwd: o.workingDirectory ?? URL(fileURLWithPath: program).deletingLastPathComponent().path,
                                    threadFormat: DebugThread.format, arguments: o.arguments, environment: o.environment)
        } catch {
            appendConsole("Ycode: \(error)\n")
            sessionEnded()
        }
    }

    /// The debugged process's ID, from lldb-dap's `process` event.
    public internal(set) var debuggedPID: Int?

    func handle(_ e: DAPEvent) async {
        guard let client = debugClient else { return }
        switch e.event {
        case "process":
            debuggedPID = e.body["systemProcessId"]?.int
            startGaugeSampling()
        case "initialized":
            adapterInitialized = true
            await syncBreakpoints()
            try? await client.configurationDone()
        case "output":
            if let text = e.body["output"]?.string {
                let category = e.body["category"]?.string ?? "console"
                appendConsole(text, kind: ["stdout", "stderr"].contains(category) ? .target : .debugger)
            }
        case "stopped":
            if temporaryBreakpoint != nil {
                temporaryBreakpoint = nil
                await syncBreakpoints()
            }
            var thread = e.body["threadId"]?.int
            if thread == nil { thread = try? await client.threads().first?.id }
            stoppedThread = thread
            await refreshStopState()
            lastStopDescription = e.body["description"]?.string ?? e.body["text"]?.string
            // lldb-dap reports watchpoint hits as reason "breakpoint" with
            // a "watchpoint N" description.
            let reason = (lastStopDescription?.hasPrefix("watchpoint") == true ? lastStopDescription : nil) ?? e.body["reason"]?.string ?? "stopped"
            noteStop(e.body, threadID: thread, reason: reason)
            // Ordinary stops read "Paused <product>"; others keep their
            // reason ("Paused <product>: watchpoint N", "…: exception").
            let plain = ["breakpoint", "step", "pause", "entry", "goto", "function breakpoint"].contains(reason)
            setActivity(.paused(DebugPresentation.pausedTitle(runningProduct) + (plain ? "" : ": \(reason)")))
        case "continued":
            clearStopState()
            setActivity(.running(DebugPresentation.runningTitle(runningProduct)))
        case "exited":
            // Its own paragraph after the program's output (reference-ui-2.md §9).
            let lead = console.isEmpty || console.hasSuffix("\n\n") ? "" : (console.hasSuffix("\n") ? "\n" : "\n\n")
            appendConsole(lead + "Program ended with exit code: \(e.body["exitCode"]?.int ?? 0)\n")
            exitLinePrinted = true
        case "terminated":
            client.close()
        default:
            break
        }
    }

    private func refreshStopState() async {
        guard let client = debugClient, let t = stoppedThread else { return }
        childrenCache = [:]
        threads = (try? await client.threads()) ?? []
        frames = (try? await client.stackTrace(threadID: t, levels: 50)) ?? []
        isLoadingVariables = true
        notify(.debugState)
        await loadVariables(frameID: frames.first?.id)
        await refreshWatches()
        await refreshDisassembly()
    }

    /// Shows a frame's variables (a click in the Debug navigator).
    public func selectFrame(_ id: Int) async {
        guard frames.contains(where: { $0.id == id }) else { return }
        await loadVariables(frameID: id)
        // Watch expressions and the disassembly follow the selected frame.
        await refreshWatches()
        await refreshDisassembly()
    }

    private func loadVariables(frameID: Int?) async {
        selectedFrameID = frameID
        // A reload (new stop, frame, edit or console command) may change
        // values, so expanded children are fetched again.
        childrenCache = [:]
        var vars: [Variable] = []
        variableContainers = [:]
        var badges: [String: String] = [:]
        let frameName = frames.first { $0.id == frameID }?.name
        if let client = debugClient, let frameID, let scopes = try? await client.scopes(frameID: frameID) {
            // Registers stay out of the default view (an open question).
            for s in scopes where showRegisters || (!s.expensive && !s.name.localizedCaseInsensitiveContains("register")) {
                let list = (try? await client.variables(reference: s.variablesReference)) ?? []
                for v in list where variableContainers[v.name] == nil {
                    variableContainers[v.name] = s.variablesReference
                    badges[v.name] = DebugPresentation.badge(name: v.name, scope: s.name, frameName: frameName)
                }
                vars += list
            }
        }
        variableBadges = badges
        isLoadingVariables = false
        variables = vars
        notify(.debugState)
    }

    /// The children of an expandable variable (nonzero reference). Valid
    /// only while stopped at the same place.
    public func children(of reference: Int) async -> [Variable] {
        guard reference != 0, let client = debugClient else { return [] }
        // Fetched once per stop: references are valid until the program
        // resumes (debug.md §Variables view).
        if let cached = childrenCache[reference] { return cached }
        let list = (try? await client.variables(reference: reference)) ?? []
        childrenCache[reference] = list
        return list
    }

    /// Children already fetched in this stop, by `variablesReference`.
    private var childrenCache: [Int: [Variable]] = [:]

    func clearStopState() {
        childrenCache = [:]
        stoppedThread = nil
        disassembly = []
        disassemblyPCIndex = nil
        frames = []
        variables = []
        threads = []
        selectedFrameID = nil
        notify(.debugState)
    }

    func sessionEnded() {
        debugClient = nil
        adapterInitialized = false
        temporaryBreakpoint = nil
        clearStopState()
        endDebugSession()
        if isBusy { setActivity(.finished(DebugPresentation.finishedTitle(runningProduct))) }
    }

    /// Files whose breakpoints were sent in this debug session; a file
    /// whose last breakpoint goes away gets an empty set (it replaces the
    /// file's set in the adapter).
    private var sentBreakpointFiles: Set<String> = []
    /// DAP: breakpoints are configured after the adapter's `initialized`
    /// event; changes before it wait for that event's full sync.
    var adapterInitialized = false
    /// The breakpoint sync in progress; each sync runs after the previous
    /// one, so the adapter's final sets are the latest ones.
    private var breakpointSync: Task<Void, Never>?

    func syncBreakpoints() async {
        let previous = breakpointSync
        let next = Task { await previous?.value; await sendBreakpoints() }
        breakpointSync = next
        await next.value
    }

    private func sendBreakpoints() async {
        guard let client = debugClient else { sentBreakpointFiles = []; return }
        guard adapterInitialized else { return }
        var current = breakpoints.effectiveBreakpoints
        // Continue To Current Line's temporary breakpoint (§10.2).
        if let t = temporaryBreakpoint, !(current[t.file] ?? []).contains(where: { $0.line == t.line && $0.column == nil }) {
            current[t.file, default: []].append(SourceBreakpoint(line: t.line))
        }
        for (file, list) in current {
            let result = (try? await client.setBreakpoints(file: file, breakpoints: list)) ?? []
            recordBreakpointIDs(file: file, sent: list, result: result)
        }
        for file in sentBreakpointFiles.subtracting(current.keys) {
            _ = try? await client.setBreakpoints(file: file, breakpoints: [])
        }
        sentBreakpointFiles = Set(current.keys)
        _ = try? await client.setFunctionBreakpoints(breakpoints.effectiveFunctionBreakpoints)
        let known = Set(client.exceptionFilters.map(\.id))
        _ = try? await client.setExceptionBreakpoints(filters: breakpoints.isActive ? breakpoints.exceptionFilters.filter { known.contains($0) } : [])
    }

    public func appendConsole(_ s: String) { appendConsole(s, kind: .debugger) }

    /// Product ▸ Clear All Issues.
    public func clearIssues() {
        issues = []
        packageIssues = []
        notify(.issues)
    }

    /// Debug ▸ Console ▸ Clear Console.
    public func clearConsole() {
        console = ""
        consoleEntries = []
        notify(.console)
    }

    public func appendConsole(_ s: String, kind: ConsoleEntry.Kind) {
        console += s
        consoleEntries.append(ConsoleEntry(kind: kind, text: s, pid: kind == .target ? debuggedPID : nil))
        notify(.console)
    }

    // MARK: Console input, watches, watchpoints, disassembly, attach

    /// Runs a console line while paused (`evaluate`, context `repl`): LLDB
    /// commands (`po x`, `p x`, `expr …`, `bt`) and expressions. The line
    /// is echoed after an `(lldb)` prompt; the result follows.
    @discardableResult
    public func evaluateInConsole(_ line: String) async -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        consoleHistory.append(text)
        appendConsole("(lldb) \(text)\n", kind: .input)
        guard let client = debugClient else {
            appendConsole("error: no process is being debugged\n", kind: .debugger)
            return nil
        }
        do {
            let r = try await client.evaluateFull(text, frameID: selectedFrameID, context: "repl")
            let out = r.result.hasSuffix("\n") || r.result.isEmpty ? r.result : r.result + "\n"
            appendConsole(out, kind: .debugger)
            await loadVariables(frameID: selectedFrameID)
            return r.result
        } catch {
            // "error: <adapter message>", without the request name.
            let message = (error as? DAPError)?.message ?? "\(error)"
            appendConsole(message.hasPrefix("error:") ? message + "\n" : "error: \(message)\n", kind: .debugger)
            return nil
        }
    }

    /// The console text for a filter.
    public func consoleText(_ filter: ConsoleEntry.Filter, metadata: ConsoleMetadata = ConsoleMetadata()) -> String {
        Self.consoleText(consoleEntries.filter { filter.includes($0.kind) }, metadata: metadata)
    }

    /// Entries with the checked metadata columns as a line prefix.
    nonisolated public static func consoleText(_ shown: [ConsoleEntry], metadata: ConsoleMetadata) -> String {
        guard metadata.enabled, metadata.type || metadata.timestamp || metadata.pidTID else { return shown.map(\.text).joined() }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return shown.map { e in
            var prefix = ""
            if metadata.timestamp { prefix += f.string(from: e.date) + " " }
            if metadata.pidTID, let pid = e.pid { prefix += "\(pid) " }
            if metadata.type { prefix += (e.kind == .target ? "[Target] " : e.kind == .input ? "[Input] " : "[Debugger] ") }
            let lines = e.text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.enumerated().map { i, l in (i == lines.count - 1 && l.isEmpty) ? "" : prefix + l }.joined(separator: "\n")
        }.joined()
    }

    func refreshWatches() async {
        guard let client = debugClient, stoppedThread != nil else { watchValues = []; return }
        var out: [Variable] = []
        for w in watchExpressions {
            if let r = try? await client.evaluateFull(w, frameID: selectedFrameID, context: "watch") {
                out.append(Variable(name: w, value: r.result, type: r.type, variablesReference: r.variablesReference))
            } else {
                out.append(Variable(name: w, value: "<unavailable>"))
            }
        }
        watchValues = out
        notify(.debugState)
    }

    /// Assigns a new value to a shown variable (`setVariable`).
    @discardableResult
    public func setValue(_ value: String, of name: String, container: Int? = nil) async -> String? {
        guard let client = debugClient, let ref = container ?? variableContainers[name] else { return nil }
        let r = try? await client.setVariable(reference: ref, name: name, value: value)
        await loadVariables(frameID: selectedFrameID)
        return r
    }

    /// Print Description: `po <name>` in the console.
    @discardableResult
    public func printDescription(of name: String) async -> String? { await evaluateInConsole("po \(name)") }

    /// Watch <variable>: a write watchpoint (`dataBreakpointInfo` +
    /// `setDataBreakpoints` with every watchpoint).
    @discardableResult
    public func watch(_ name: String, container: Int? = nil, access: String = "write") async -> Watchpoint? {
        guard let client = debugClient, let ref = container ?? variableContainers[name],
              let info = try? await client.dataBreakpointInfo(reference: ref, name: name), let id = info.dataID else { return nil }
        // The requested access when offered (`write`, `read`, `readWrite`).
        let access = info.accessTypes.isEmpty || info.accessTypes.contains(access) ? access : info.accessTypes[0]
        var list = watchpoints.filter { $0.dataID != id }
        list.append(Watchpoint(name: name, dataID: id, description: info.description, accessType: access, verified: false))
        let result = (try? await client.setDataBreakpoints(list.map { ($0.dataID, $0.accessType) })) ?? []
        for i in list.indices where i < result.count { list[i].verified = result[i].verified }
        watchpoints = list
        notify(.breakpoints)
        return list.last
    }

    public func removeWatchpoint(_ w: Watchpoint) async {
        watchpoints.removeAll { $0.dataID == w.dataID }
        _ = try? await debugClient?.setDataBreakpoints(watchpoints.map { ($0.dataID, $0.accessType) })
        notify(.breakpoints)
    }

    func refreshDisassembly() async {
        guard alwaysShowDisassembly, let client = debugClient, stoppedThread != nil,
              let frame = frames.first(where: { $0.id == selectedFrameID }) ?? frames.first, let pc = frame.instructionPointer else {
            disassembly = []
            disassemblyPCIndex = nil
            notify(.debugState)
            return
        }
        let list = (try? await client.disassemble(memoryReference: pc, instructionOffset: -8, count: 40)) ?? []
        disassembly = list
        disassemblyPCIndex = list.firstIndex { Self.sameAddress($0.address, pc) }
        notify(.debugState)
    }

    static func sameAddress(_ a: String, _ b: String) -> Bool {
        func v(_ s: String) -> UInt64? { UInt64(s.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) }
        return v(a) != nil && v(a) == v(b)
    }

    /// Debug ▸ Attach to Process by PID or Name…: a pid (digits) or a
    /// process name (lldb waits for it to launch when `waitFor`).
    public func attach(to target: String, waitFor: Bool = false, adapter: DAPTransport? = nil) async {
        let transport: DAPTransport
        if let adapter { transport = adapter } else {
            guard let path = await Task.detached(operation: { LLDBDAP.locate() }).value else { appendConsole("Ycode: lldb-dap was not found.\n"); return }
            transport = ProcessTransport(executable: path)
        }
        do {
            let client = try DAPClient(transport: transport)
            debugClient = client
            adapterInitialized = false
            setActivity(.running("Attaching to \(target)"))
            Task { [weak self] in
                for await e in client.events { await self?.handle(e) }
                self?.sessionEnded()
            }
            try await client.initialize()
            let pid = Int(target)
            try await client.attach(pid: pid, program: pid == nil ? target : nil, waitFor: waitFor, threadFormat: DebugThread.format)
            beginDebugSession(product: pid == nil ? URL(fileURLWithPath: target).lastPathComponent : target)
            if pid != nil { debuggedPID = pid; startGaugeSampling() }
            setActivity(.running("Running \(target)"))
        } catch {
            appendConsole("Ycode: attach failed: \(error)\n")
            sessionEnded()
        }
    }

    /// Threads grouped by dispatch queue (threads without one under
    /// "Threads"), in first-appearance order.
    public var threadsByQueue: [(queue: String, threads: [DebugThread])] {
        var out: [(String, [DebugThread])] = []
        for t in threads {
            let q = t.queue ?? "Threads"
            if let i = out.firstIndex(where: { $0.0 == q }) { out[i].1.append(t) } else { out.append((q, [t])) }
        }
        return out
    }

    // MARK: Debug bar

    public func continueOrPause() async {
        guard let c = debugClient else { return }
        if let t = stoppedThread { try? await c.continue(threadID: t); clearStopState(); setActivity(.running(DebugPresentation.runningTitle(runningProduct))) }
        else if let t = try? await c.threads().first?.id { try? await c.pause(threadID: t) }
    }

    public func step(_ kind: String) async {
        guard let c = debugClient, let t = stoppedThread else { return }
        if alwaysShowDisassembly && kind != "out" {
            try? await c.stepInstruction(threadID: t, into: kind == "in")
            return
        }
        switch kind {
        case "in": try? await c.stepIn(threadID: t)
        case "out": try? await c.stepOut(threadID: t)
        default: try? await c.next(threadID: t)
        }
    }

    /// Stop (⌘.): cancels the build or ends the debug session.
    public func stop() {
        currentBuild?.cancel()
        if let c = debugClient {
            // A paused process is killed (SIGKILL, code 9).
            if stoppedThread != nil && !killReported {
                killReported = true
                appendConsole(DebugPresentation.killedLine + "\n", kind: .debugger)
            }
            Task { try? await c.disconnect(terminate: true); c.close() }
        }
    }
}

/// One piece of console output and where it came from.
public struct ConsoleEntry: Equatable, Sendable {
    public enum Kind: Sendable { case debugger, target, input }
    /// The console's filter pop-up.
    public enum Filter: String, CaseIterable, Sendable {
        case all = "All Output", debugger = "Debugger Output", target = "Target Output"
        func includes(_ k: Kind) -> Bool {
            switch self {
            case .all: true
            case .debugger: k != .target
            case .target: k == .target
            }
        }
    }
    public var kind: Kind
    public var text: String
    public var date = Date()
    /// The debugged process's ID (DAP `process` event), for PID:TID.
    public var pid: Int?
    public init(kind: Kind, text: String, date: Date = Date(), pid: Int? = nil) {
        self.kind = kind
        self.text = text
        self.date = date
        self.pid = pid
    }
}

/// The console's metadata columns (reference-ui-2.md §9): a master switch
/// (on) and per-column checkboxes (all off).
public struct ConsoleMetadata: Equatable, Sendable {
    public static let columns = ["Type", "Timestamp", "Library", "PID:TID", "Subsystem", "Category"]
    /// Columns Ycode's console has data for: Type, Timestamp and PID:TID.
    /// PID:TID shows the process ID from lldb-dap's `process` event; DAP
    /// output events carry no thread, so the TID part is left out. Library,
    /// Subsystem and Category stay disabled: they come from unified-logging
    /// (os_log) records, and Ycode's console source (lldb-dap `output`
    /// events: plain text plus stdout/stderr/console category) has none.
    public static let supportedColumns: Set<Int> = [0, 1, 3]
    public var pidTID: Bool { get { checked.contains(3) } set { set(3, newValue) } }
    public var enabled = true
    /// Indices into `columns` that are checked (none by default).
    public var checked: Set<Int> = []
    public init() {}
    public var type: Bool { get { checked.contains(0) } set { set(0, newValue) } }
    public var timestamp: Bool { get { checked.contains(1) } set { set(1, newValue) } }
    public func isOn(_ i: Int) -> Bool { checked.contains(i) }
    public mutating func set(_ i: Int, _ on: Bool) {
        guard Self.columns.indices.contains(i) else { return }
        if on { checked.insert(i) } else { checked.remove(i) }
    }
}

/// A watchpoint (data breakpoint) on a variable.
public struct Watchpoint: Equatable, Sendable {
    public var name: String
    public var dataID: String
    public var description: String
    public var accessType: String
    public var verified: Bool
}
