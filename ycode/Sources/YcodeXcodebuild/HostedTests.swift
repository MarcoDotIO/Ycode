import Foundation

/// Tests hosted in an application (`TEST_HOST`) and UI test bundles: the
/// bundle runs inside the host app, loaded by Ycode's test agent
/// (`libYcodeTestAgent.dylib`, `Sources/YcodeTestAgent`). The host app is
/// started with `DYLD_INSERT_LIBRARIES` naming the agent and
/// `YCODE_TEST_PLAN` describing the run; the agent reports on the app's
/// standard error in lines `##ycode-test## <JSON>` (the test-host
/// protocol) next to the libraries' own console lines, which the console
/// parser reads as for tool-hosted bundles.
/// See `specs/ide/testing.md` and `specs/xcodebuild/test-actions.md`,
/// "Ycode implementation".
public enum TestHostProtocol {
    public static let prefix = "##ycode-test## "

    /// One report of the agent.
    public struct Event: @unchecked Sendable {
        public var kind: String
        public var fields: [String: Any]
        public subscript(_ key: String) -> Any? { fields[key] }
        public func string(_ key: String) -> String? { fields[key] as? String }
    }

    /// Splits a line of the host's output into the text before a report
    /// (the app's own output, if any) and the report.
    public static func split(_ line: String) -> (text: String?, event: Event?) {
        guard let r = line.range(of: prefix) else { return (line, nil) }
        let before = String(line[..<r.lowerBound])
        let json = line[r.upperBound...]
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let kind = obj["kind"] as? String else { return (line, nil) }
        return (before.isEmpty ? nil : before, Event(kind: kind, fields: obj))
    }

    /// The agent's run description (`YCODE_TEST_PLAN`).
    public struct Plan: Equatable, Sendable {
        public struct Bundle: Equatable, Sendable {
            /// Absolute, `@executable_path/…`, or a name in the host's PlugIns folder.
            public var path: String
            public var module: String
            public var only: [String]
            public var skip: [String]
            public init(path: String, module: String, only: [String] = [], skip: [String] = []) {
                self.path = path
                self.module = module
                self.only = only
                self.skip = skip
            }
        }
        public var session: String
        public var bundles: [Bundle]
        public var repetition: TestPlanFile.Repetition?
        public var launchTimeout: Double = 30

        public init(session: String = UUID().uuidString, bundles: [Bundle], repetition: TestPlanFile.Repetition? = nil) {
            self.session = session
            self.bundles = bundles
            self.repetition = repetition
        }

        public var json: String {
            var o: [String: Any] = [
                "session": session, "launchTimeout": launchTimeout,
                "bundles": bundles.map { ["path": $0.path, "module": $0.module, "only": $0.only, "skip": $0.skip] as [String: Any] },
            ]
            if let r = repetition, r.mode != .none { o["repetition"] = ["mode": r.mode.rawValue, "count": r.count] }
            let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Where Ycode's test agent for an SDK is: `YCODE_TEST_AGENT` (macOS)
    /// or `YCODE_TEST_AGENT_<SDK>` (`YCODE_TEST_AGENT_IPHONESIMULATOR`),
    /// else `libYcodeTestAgent.dylib` next to ycodebuild (macOS) or in its
    /// `<sdk>/` folder (`iphonesimulator/libYcodeTestAgent.dylib`, which
    /// `SimGuestAgents/build-test-agent.sh` builds).
    public static func agent(sdk: String, environment env: [String: String], executableDirectory: String?) -> String? {
        let fm = FileManager.default
        let name = "libYcodeTestAgent.dylib"
        var candidates: [String] = []
        if sdk == "macosx" {
            if let p = env["YCODE_TEST_AGENT"] { candidates.append(p) }
            if let d = executableDirectory { candidates.append(d + "/" + name) }
        } else {
            if let p = env["YCODE_TEST_AGENT_" + sdk.uppercased()] { candidates.append(p) }
            if let d = executableDirectory { candidates.append(d + "/" + sdk + "/" + name) }
        }
        return candidates.first { fm.fileExists(atPath: $0) }
    }
}

/// Collects one host run: routes the host's output lines to the parser
/// of the bundle that is running, keeps the agent's reports, and knows
/// whether the run finished.
final class HostRunCollector: @unchecked Sendable {
    struct Part {
        var target: TestTarget
        var parser: TestConsoleParser
        var output = ""
        var loaded = false
    }
    let session: String
    private(set) var parts: [Part]
    private var current: Int?
    private(set) var agentLoaded = false
    private(set) var finished = false
    private(set) var errors: [String] = []
    /// The test that started last and has not finished (a crash's culprit).
    private(set) var running: String?
    /// Lines that belong to no bundle (the host's own output before and after).
    private(set) var hostOutput = ""
    private let lock = NSLock()
    let echo: (String) -> Void

    init(session: String, targets: [TestTarget], echo: @escaping (String) -> Void) {
        self.session = session
        self.parts = targets.map { Part(target: $0, parser: TestConsoleParser(module: $0.moduleName, swiftTests: [])) }
        self.echo = echo
    }

    func feed(_ line: String) {
        lock.lock()
        let (text, event) = TestHostProtocol.split(line)
        if let event, event.string("session") == session || event.string("session") == nil {
            handle(event)
        } else if event != nil {
            // A report of another session (a stale output file): ignored.
        }
        let shown = event == nil ? line : text
        lock.unlock()
        if let shown {
            echo(shown)
            lock.lock()
            if let i = current {
                parts[i].parser.feed(shown)
                parts[i].output += shown + "\n"
            } else {
                hostOutput += shown + "\n"
            }
            lock.unlock()
        }
    }

    private func handle(_ e: TestHostProtocol.Event) {
        switch e.kind {
        case "agentLoaded": agentLoaded = true
        case "bundleStarted":
            let path = e.string("path") ?? ""
            current = parts.firstIndex { p in
                !p.loaded && (p.target.bundlePath == path || path.hasSuffix("/" + URL(fileURLWithPath: p.target.bundlePath).lastPathComponent)
                              || path == URL(fileURLWithPath: p.target.bundlePath).lastPathComponent)
            } ?? parts.firstIndex { !$0.loaded }
        case "bundleLoaded":
            if let i = current { parts[i].loaded = true }
        case "bundleFinished":
            if let i = current { parts[i].loaded = true }
            current = nil
        case "swiftTest":
            guard let i = current, let id = e.string("id") else { return }
            parts[i].parser.addSwiftTest(SwiftTestingBridge.TestRecord(id: id, name: e.string("name") ?? "", isSuite: e["isSuite"] as? Bool ?? false,
                                                                     file: e.string("file"), line: e["line"] as? Int))
        case "testStarted":
            let suite = e.string("suite") ?? ""
            running = (suite.isEmpty ? "" : suite + "/") + (e.string("name") ?? "")
        case "testFinished": running = nil
        case "error": errors.append(e.string("message") ?? "The test agent reported an error.")
        case "runFinished": finished = true
        default: break
        }
    }

    var isAgentLoaded: Bool { lock.withLock { agentLoaded } }
    var isFinished: Bool { lock.withLock { finished } }
}

extension TestActions {
    /// Builds of hosted tests for a simulator copy the testing libraries
    /// into the host app's `Frameworks` folder: swift-build's own test-host
    /// task (open-source swift-build, `XCTestHostTaskProducer`), which it
    /// skips by default for Xcode 27 and later (`SKIP_COPYING_TEST_FRAMEWORKS`
    /// = YES, because devices get them from their developer disk image).
    /// The Ycode simulator's runtime has none of them, so these builds set
    /// the setting's escape hatch, NO. macOS hosts find them through
    /// `DYLD_FRAMEWORK_PATH`, as tool-hosted runs do.
    /// `sdk`: the run destination's SDK, else the `SDKROOT` override
    /// (`iphonesimulator`, `iphonesimulator27.0` or an SDK path).
    static func testFrameworkCopying(action: BuildAction, sdk: String?) -> [(String, String)] {
        guard [.buildForTesting, .test].contains(action),
              let sdk, (sdk as NSString).lastPathComponent.lowercased().contains("simulator") else { return [] }
        return [("SKIP_COPYING_TEST_FRAMEWORKS", "NO")]
    }

    /// The agent's selection for a target: `-only-testing`, plan entries.
    static func hostedSelection(_ t: TestTarget) -> (only: [String], skip: [String]) {
        (t.only, t.skip)
    }

    /// The host app of a hosted target: `TEST_HOST` names its executable.
    /// Returns (app bundle, executable).
    static func hostApp(_ t: TestTarget) -> (app: String, executable: String)? {
        guard let exe = t.testHost else { return nil }
        var url = URL(fileURLWithPath: exe)
        while url.path != "/" && url.pathExtension != "app" { url.deleteLastPathComponent() }
        guard url.pathExtension == "app" else { return nil }
        return (url.path, exe)
    }

    /// The bundle identifier of an app bundle (iOS: `Info.plist` at the
    /// top; macOS: `Contents/Info.plist`).
    static func bundleIdentifier(ofApp app: String) -> String? {
        for rel in ["Info.plist", "Contents/Info.plist"] {
            if let data = FileManager.default.contents(atPath: app + "/" + rel),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let id = plist["CFBundleIdentifier"] as? String { return id }
        }
        return nil
    }

    /// The bundle path the agent opens: relative to the host's PlugIns
    /// folder when the bundle is in it (`@executable_path/…` would also
    /// work, but the folder name is the same on every device).
    static func agentBundlePath(_ t: TestTarget, app: String) -> String {
        let plugins = [app + "/PlugIns/", app + "/Contents/PlugIns/"]
        for p in plugins where t.bundlePath.hasPrefix(p) { return String(t.bundlePath.dropFirst(p.count)) }
        return t.bundlePath
    }

    /// Runs hosted targets that share a host on this Mac: one launch of the
    /// host per bundle (bundles do not share a process).
    static func runHostedLocally(_ t: TestTarget, quiet: Bool, context ctx: XcodebuildContext, outcome: inout Outcome) {
        let console = ctx.console
        guard let (app, exe) = hostApp(t) else {
            outcome.errors.append("\(t.blueprintName): the test host \(t.testHost ?? "") is not inside an application bundle.")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            outcome.errors.append("The test host \(exe) does not exist; build it with build-for-testing first.")
            return
        }
        guard FileManager.default.fileExists(atPath: t.bundlePath) else {
            outcome.errors.append("The test bundle \(t.bundlePath) does not exist; build it with build-for-testing first.")
            return
        }
        guard let agent = TestHostProtocol.agent(sdk: "macosx", environment: ctx.environment, executableDirectory: ctx.executableDirectory) else {
            outcome.errors.append("\(t.blueprintName) runs inside \(URL(fileURLWithPath: app).lastPathComponent), which needs Ycode's test agent: build it (swift build --product YcodeTestAgent) next to ycodebuild, or set YCODE_TEST_AGENT to its path.")
            return
        }
        let sel = hostedSelection(t)
        var plan = TestHostProtocol.Plan(bundles: [.init(path: agentBundlePath(t, app: app), module: t.moduleName, only: sel.only, skip: sel.skip)],
                                         repetition: t.repetition)
        plan.launchTimeout = 30
        var env = testEnvironment(t, ctx)
        let inserted = [env["DYLD_INSERT_LIBRARIES"], agent].compactMap { $0 }.filter { !$0.isEmpty }
        env["DYLD_INSERT_LIBRARIES"] = inserted.joined(separator: ":")
        env["YCODE_TEST_PLAN"] = plan.json
        let collector = HostRunCollector(session: plan.session, targets: [t]) { line in if !quiet { console.out(line) } }
        // Window restoration would reopen documents of earlier runs.
        let args = t.arguments + ["-ApplePersistenceIgnoreState", "YES"]
        let status = runHost(exe, args, environment: env, collector: collector,
                             agentTimeout: Double(ctx.environment["YCODE_TEST_AGENT_TIMEOUT"] ?? "") ?? 60,
                             timeout: Double(ctx.environment["YCODE_TEST_HOST_TIMEOUT"] ?? "") ?? 3600)
        collect(collector, status: status, hostName: URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent, into: &outcome)
    }

    /// How a host run ended.
    enum HostStatus: Equatable { case exited(Int32), noAgent, timedOut, couldNotStart(String) }

    /// Runs a host process, feeding its merged output to the collector.
    /// Kills it when the agent has not reported within `agentTimeout`
    /// seconds (the host ignored `DYLD_INSERT_LIBRARIES`: a hardened
    /// runtime without the exception, or library validation) or the run
    /// takes longer than `timeout`.
    static func runHost(_ exe: String, _ args: [String], environment: [String: String], collector: HostRunCollector,
                        agentTimeout: Double, timeout: Double) -> HostStatus {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        p.currentDirectoryURL = URL(fileURLWithPath: exe).deletingLastPathComponent()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .couldNotStart("\(error)") }
        let verdict = Verdict()
        let started = Date()
        var finishedAt: Date?
        let watchdog = Watchdog("ycodebuild.test-host.watchdog") {
            guard p.isRunning else { return false }
            let elapsed = Date().timeIntervalSince(started)
            if !collector.isAgentLoaded && elapsed > agentTimeout {
                verdict.set(.noAgent)
                p.terminate()
                return false
            }
            if elapsed > timeout {
                verdict.set(.timedOut)
                p.terminate()
                return false
            }
            // The agent exits by itself after its report; give it a moment.
            if collector.isFinished {
                if let f = finishedAt, Date().timeIntervalSince(f) > 10 {
                    p.terminate()
                    return false
                }
                if finishedAt == nil { finishedAt = Date() }
            }
            return true
        }
        watchdog.start()
        readLines(pipe.fileHandleForReading, into: collector.feed)
        p.waitUntilExit()
        return verdict.value ?? .exited(p.terminationStatus)
    }

    /// Calls `tick` about once a second on its own queue until it returns
    /// false. The tick's state lives in this (unchecked) object only.
    final class Watchdog: @unchecked Sendable {
        private let queue: DispatchQueue
        private let tick: () -> Bool
        init(_ label: String, tick: @escaping () -> Bool) {
            queue = DispatchQueue(label: label)
            self.tick = tick
        }
        func start() { schedule() }
        private func schedule() {
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                if tick() { schedule() }
            }
        }
    }

    final class Verdict: @unchecked Sendable {
        private let lock = NSLock()
        private var v: HostStatus?
        func set(_ s: HostStatus) { lock.withLock { if v == nil { v = s } } }
        var value: HostStatus? { lock.withLock { v } }
    }

    /// Reads a stream to its end, line by line.
    static func readLines(_ h: FileHandle, into feed: (String) -> Void) {
        var buffer = Data()
        while true {
            let d = h.availableData
            if d.isEmpty { break }
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0A) {
                feed(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer = Data(buffer[(nl + 1)...])
            }
        }
        if !buffer.isEmpty { feed(String(decoding: buffer, as: UTF8.self)) }
    }

    /// Adds a host run's results and errors to the outcome.
    static func collect(_ c: HostRunCollector, status: HostStatus, hostName: String, into outcome: inout Outcome) {
        for part in c.parts {
            let results = collapseRepetitions(part.parser.results, mode: part.target.repetition?.mode)
            outcome.results += results
            outcome.targets.append(.init(target: part.target, results: results, selected: !part.target.only.isEmpty,
                                         starts: Dictionary(part.parser.results.map { ($0.name, part.parser.startIndex(of: $0.name)) },
                                                            uniquingKeysWith: { a, _ in a }),
                                         output: c.hostOutput + part.output))
        }
        outcome.errors += c.errors
        guard !c.finished else { return }
        let culprit = c.running.map { " (while running \($0))" } ?? ""
        switch status {
        case .noAgent:
            outcome.errors.append("\(hostName) did not load Ycode's test agent. A host built with the hardened runtime needs the \"Allow DYLD Environment Variables\" and \"Disable Library Validation\" exceptions for its test builds (ENABLE_HARDENED_RUNTIME, specs/ide/testing.md).")
        case .timedOut:
            outcome.errors.append("\(hostName) did not finish its tests in time\(culprit).")
        case .couldNotStart(let why):
            outcome.errors.append("\(hostName) could not be started: \(why)")
        case .exited(let code):
            outcome.errors.append("\(hostName) exited with status \(code) before its tests finished\(culprit).")
        }
    }
}
