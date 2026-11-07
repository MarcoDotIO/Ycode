import Foundation
import YcodeSubprocess

/// Hosted tests on the Ycode simulator (an iOS-family app's `TEST_HOST`
/// tests on the arm64 Linux host, `specs/ide/run.md` §Remote Ycode
/// simulator): the host app, with its test bundles in `PlugIns/` and
/// Ycode's test agent (built for the simulator) in `Frameworks/`, is copied
/// to the simulator host, installed and launched there by `ycode-simd`
/// with the agent inserted (`--app-env DYLD_INSERT_LIBRARIES=…`,
/// `--app-env YCODE_TEST_PLAN=…`). The app's standard error (where the
/// agent reports and the libraries print) is followed on the host and
/// streamed back over the same ssh connection; when the agent reports the
/// end of the run the simulator is stopped like an IDE run's Stop (a
/// SIGINT: the launcher saves a warm-boot device).
/// See `specs/xcodebuild/test-actions.md`, "Ycode implementation".
public struct RemoteTestHost {
    /// Where the simulator runs. From the environment (the IDE sets these
    /// from Settings ▸ Components ▸ Simulator Host; machine names never go into files):
    ///
    /// | Variable | Meaning |
    /// |---|---|
    /// | `YCODE_SIM_HOST` | ssh destination `user@host` (keys only) |
    /// | `YCODE_SIM_DATA` | remote data directory (apps, devices) |
    /// | `YCODE_SIM_RUNTIME` | remote runtime root |
    /// | `YCODE_SIM_SIMD` | remote `ycode-simd` or launcher (`ycode-sim`) |
    /// | `YCODE_SIM_DEVICE` | device directory name under `<data>/devices` (default `ycode-device`) |
    /// | `YCODE_SIM_OPTIONS` | more `ycode-simd` options, split like a shell |
    /// | `YCODE_SIM_ENV` | `K=V` words for the remote environment (`YCODE_WARM_BOOT=1`) |
    public struct Settings: Equatable, Sendable {
        public var destination: String
        public var dataDirectory: String
        public var runtimeRoot: String
        public var simd: String
        public var device: String = "ycode-device"
        public var options: [String] = []
        public var environment: [String] = []
        public var ssh = HostTool.path("ssh")
        public var rsync = HostTool.path("rsync")
        /// Seconds until the agent must have reported (boot, install, launch).
        public var launchTimeout: Double = 900
        /// Seconds the whole run may take.
        public var timeout: Double = 3600

        public init(destination: String, dataDirectory: String, runtimeRoot: String, simd: String) {
            self.destination = destination
            self.dataDirectory = dataDirectory
            self.runtimeRoot = runtimeRoot
            self.simd = simd
        }

        public static func from(environment env: [String: String]) -> Settings? {
            guard let host = env["YCODE_SIM_HOST"], !host.isEmpty, let data = env["YCODE_SIM_DATA"], !data.isEmpty,
                  let rt = env["YCODE_SIM_RUNTIME"], !rt.isEmpty, let simd = env["YCODE_SIM_SIMD"], !simd.isEmpty else { return nil }
            var s = Settings(destination: host, dataDirectory: data, runtimeRoot: rt, simd: simd)
            if let d = env["YCODE_SIM_DEVICE"], !d.isEmpty { s.device = d }
            s.options = words(env["YCODE_SIM_OPTIONS"] ?? "")
            s.environment = words(env["YCODE_SIM_ENV"] ?? "")
            if let p = env["YCODE_SSH"], !p.isEmpty { s.ssh = p }
            if let p = env["YCODE_RSYNC"], !p.isEmpty { s.rsync = p }
            if let t = env["YCODE_SIM_TEST_LAUNCH_TIMEOUT"].flatMap(Double.init) { s.launchTimeout = t }
            if let t = env["YCODE_SIM_TEST_TIMEOUT"].flatMap(Double.init) { s.timeout = t }
            return s
        }

        public var devicePath: String { dataDirectory + "/devices/" + device }
        public func remoteApp(_ name: String) -> String { dataDirectory + "/test-apps/" + name }
    }

    /// Whether a `-destination` names the Ycode simulator:
    /// `name=Ycode Simulator` (any "Ycode" device name) or
    /// `id=ycode-remote-simulator`, on an iOS-family simulator platform.
    public static func isYcodeSimulator(_ spec: String) -> Bool {
        let (_, fields) = Destinations.parse(spec)
        guard (fields["platform"] ?? "").hasSuffix("Simulator") else { return false }
        return fields["id"] == "ycode-remote-simulator" || (fields["name"] ?? "").contains("Ycode")
    }

    var settings: Settings
    var context: XcodebuildContext

    init(settings: Settings, context: XcodebuildContext) {
        self.settings = settings
        self.context = context
    }

    /// POSIX shell single quoting.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Shell-like words: whitespace separates, quotes group, backslash escapes.
    static func words(_ text: String) -> [String] {
        var out: [String] = [], cur = "", inWord = false
        var quote: Character?
        var escape = false
        for c in text {
            if escape { cur.append(c); escape = false; inWord = true; continue }
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"" { escape = true } else { cur.append(c) }
                continue
            }
            switch c {
            case "\\": escape = true
            case "'", "\"": quote = c; inWord = true
            case " ", "\t", "\n":
                if inWord { out.append(cur); cur = ""; inWord = false }
            default: cur.append(c); inWord = true
            }
        }
        if inWord { out.append(cur) }
        return out
    }

    /// The line prefix of the app's standard error in the stream.
    static let appPrefix = "YCODE-APP|"
    /// The agent's guest path, inside the app.
    static let agentInApp = "@executable_path/Frameworks/libYcodeTestAgent.dylib"

    /// The remote command: removes the app's previous output, prints the
    /// shell's pid, follows the app's standard error (`tail --pid` ends
    /// with the simulator), then becomes `ycode-simd`.
    func command(app remoteApp: String, bundleID: String, plan: TestHostProtocol.Plan) -> String {
        let q = Self.quote
        let err = settings.devicePath + "/data/tmp/ycode-app.err"
        let out = settings.devicePath + "/data/tmp/ycode-app.out"
        let env = settings.environment.isEmpty ? "" : "env " + settings.environment.map(q).joined(separator: " ") + " "
        return "rm -f \(q(err)) \(q(out)); echo YCODE-REMOTE-PID $$; "
            + "( tail --pid=$$ -n +1 -F \(q(err)) 2>/dev/null | sed -u 's/^/\(Self.appPrefix)/' & ); "
            + "exec \(env)\(q(settings.simd)) --device \(q(settings.devicePath)) --runtime-root \(q(settings.runtimeRoot))"
            + settings.options.map { " " + q($0) }.joined()
            + " --install-app \(q(remoteApp)) --launch \(q(bundleID))"
            + " --app-env \(q("DYLD_INSERT_LIBRARIES=" + Self.agentInApp))"
            + " --app-env \(q("YCODE_TEST_PLAN=" + plan.json)) 2>&1"
    }

    var sshOptions: [String] { ["-o", "BatchMode=yes"] }

    func ssh(_ command: String) -> (Int32, String) {
        let r = TestActions.run(settings.ssh, sshOptions + [settings.destination, command], environment: ProcessInfo.processInfo.environment) { _ in }
        return (r.status, r.output)
    }

    /// Runs every target, one simulator run per host app.
    func run(_ targets: [TestTarget], quiet: Bool, outcome: inout TestActions.Outcome) {
        var groups: [(app: String, executable: String, targets: [TestTarget])] = []
        for t in targets {
            if t.isUITest {
                outcome.errors.append("\(t.blueprintName) is a UI test bundle: UI tests on the Ycode simulator need an automation service Ycode does not have yet (specs/ide/testing.md, \"Ycode implementation\").")
                continue
            }
            guard let (app, exe) = TestActions.hostApp(t) else {
                outcome.errors.append("\(t.blueprintName): the test host \(t.testHost ?? "") is not inside an application bundle.")
                continue
            }
            if let i = groups.firstIndex(where: { $0.app == app }) { groups[i].targets.append(t) } else { groups.append((app, exe, [t])) }
        }
        for g in groups { runGroup(app: g.app, targets: g.targets, quiet: quiet, outcome: &outcome) }
    }

    func runGroup(app: String, targets: [TestTarget], quiet: Bool, outcome: inout TestActions.Outcome) {
        let fm = FileManager.default
        let name = URL(fileURLWithPath: app).lastPathComponent
        let hostName = URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
        let sdk = targets.first?.platform ?? "iphonesimulator"
        guard fm.fileExists(atPath: app) else {
            outcome.errors.append("The test host \(app) does not exist; build it with build-for-testing first.")
            return
        }
        guard let agent = TestHostProtocol.agent(sdk: sdk, environment: context.environment, executableDirectory: context.executableDirectory) else {
            outcome.errors.append("\(hostName) needs Ycode's test agent for \(sdk): build it with SimGuestAgents/build-test-agent.sh into \(sdk)/ next to ycodebuild, or set YCODE_TEST_AGENT_\(sdk.uppercased()).")
            return
        }
        guard let bundleID = TestActions.bundleIdentifier(ofApp: app) else {
            outcome.errors.append("\(hostName) has no bundle identifier in its Info.plist.")
            return
        }
        // swift-build embedded the testing libraries in the host when it
        // built it for testing (TestActions.testFrameworkCopying); the
        // simulator runtime has none of them.
        guard fm.fileExists(atPath: app + "/Frameworks/XCTest.framework") else {
            outcome.errors.append("\(hostName) has no testing frameworks in its Frameworks folder: build it with build-for-testing for this destination first.")
            return
        }
        // A copy of the app with the agent, and any bundle not yet in PlugIns.
        let stage = fm.temporaryDirectory.appendingPathComponent("ycodebuild-test-host-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        let staged = stage.appendingPathComponent(name).path
        var bundles: [TestHostProtocol.Plan.Bundle] = []
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            try fm.copyItem(atPath: app, toPath: staged)
            try fm.createDirectory(atPath: staged + "/Frameworks", withIntermediateDirectories: true)
            try fm.copyItem(atPath: agent, toPath: staged + "/Frameworks/libYcodeTestAgent.dylib")
            for t in targets {
                let rel = TestActions.agentBundlePath(t, app: app)
                if rel.hasPrefix("/") {
                    try fm.createDirectory(atPath: staged + "/PlugIns", withIntermediateDirectories: true)
                    let dest = staged + "/PlugIns/" + URL(fileURLWithPath: t.bundlePath).lastPathComponent
                    if !fm.fileExists(atPath: dest) { try fm.copyItem(atPath: t.bundlePath, toPath: dest) }
                    bundles.append(.init(path: URL(fileURLWithPath: t.bundlePath).lastPathComponent, module: t.moduleName, only: t.only, skip: t.skip))
                } else {
                    guard fm.fileExists(atPath: t.bundlePath) else {
                        outcome.errors.append("The test bundle \(t.bundlePath) does not exist; build it with build-for-testing first.")
                        return
                    }
                    bundles.append(.init(path: rel, module: t.moduleName, only: t.only, skip: t.skip))
                }
            }
        } catch {
            outcome.errors.append("Could not prepare \(hostName) for testing: \(error)")
            return
        }
        // Upload.
        let remoteApp = settings.remoteApp(name)
        let (mk, mkOut) = ssh("mkdir -p \(Self.quote(settings.dataDirectory + "/test-apps"))")
        guard mk == 0 else {
            outcome.errors.append("Could not reach the simulator host \(settings.destination) (ssh \(mk)): \(mkOut.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        let sync = TestActions.run(settings.rsync, ["-az", "--delete", "-e", ([settings.ssh] + sshOptions).joined(separator: " "),
                                                    staged + "/", "\(settings.destination):\(remoteApp)/"],
                                   environment: ProcessInfo.processInfo.environment) { _ in }
        guard sync.status == 0 else {
            outcome.errors.append("Could not copy \(name) to \(settings.destination) (rsync \(sync.status)): \(sync.output)")
            return
        }
        var plan = TestHostProtocol.Plan(bundles: bundles, repetition: targets.first?.repetition)
        plan.launchTimeout = 120
        let collector = HostRunCollector(session: plan.session, targets: targets) { line in if !quiet { context.console.out(line) } }
        let tail = SimulatorLines()
        let status = runRemote(command(app: remoteApp, bundleID: bundleID, plan: plan), collector: collector, simulator: tail)
        TestActions.collect(collector, status: status, hostName: hostName, into: &outcome)
        if !collector.isFinished {
            let last = tail.lines.suffix(12)
            if !last.isEmpty { outcome.errors.append("The Ycode simulator's last lines:\n\t\t" + last.joined(separator: "\n\t\t")) }
        }
    }

    /// The simulator's own lines (not the app's), the last ones kept.
    final class SimulatorLines: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []
        private(set) var failure: String?
        func add(_ l: String) {
            lock.withLock {
                kept.append(l)
                if kept.count > 200 { kept.removeFirst(kept.count - 200) }
                if failure == nil, l.contains("app install: failed") || l.contains("app launch: failed") || l.contains("ylaunch: error") { failure = l }
            }
        }
        var lines: [String] { lock.withLock { kept } }
        var failed: String? { lock.withLock { failure } }
    }

    /// Runs the remote command; stops the simulator once the agent reports
    /// the end of the run (or a launch fails, or a timeout passes).
    func runRemote(_ command: String, collector: HostRunCollector, simulator: SimulatorLines) -> TestActions.HostStatus {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.ssh)
        p.arguments = sshOptions + [settings.destination, command]
        p.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .couldNotStart("\(error)") }
        let pid = PIDBox()
        let verdict = TestActions.Verdict()
        let started = Date()
        var stoppedAt: Date?
        let watchdog = TestActions.Watchdog("ycodebuild.remote-test.watchdog") { [self] in
            guard p.isRunning else { return false }
            // Stopping: the launcher saves the device and ends; do not wait forever.
            if let at = stoppedAt {
                if Date().timeIntervalSince(at) > 150 {
                    p.terminate()
                    return false
                }
                return true
            }
            let elapsed = Date().timeIntervalSince(started)
            var stop = false
            if collector.isFinished {
                stop = true
            } else if let failure = simulator.failed {
                verdict.set(.couldNotStart(failure))
                stop = true
            } else if !collector.isAgentLoaded && elapsed > settings.launchTimeout {
                verdict.set(.noAgent)
                stop = true
            } else if elapsed > settings.timeout {
                verdict.set(.timedOut)
                stop = true
            }
            if stop {
                stoppedAt = Date()
                if let n = pid.value { _ = ssh("kill -INT \(n)") } else { p.terminate() }
            }
            return true
        }
        watchdog.start()
        TestActions.readLines(pipe.fileHandleForReading) { line in
            if line.hasPrefix(Self.appPrefix) {
                collector.feed(String(line.dropFirst(Self.appPrefix.count)))
            } else if line.hasPrefix("YCODE-REMOTE-PID "), let n = Int(line.dropFirst("YCODE-REMOTE-PID ".count)) {
                pid.set(n)
            } else {
                simulator.add(line)
            }
        }
        p.waitUntilExit()
        return verdict.value ?? .exited(p.terminationStatus)
    }

    final class PIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Int?
        func set(_ n: Int) { lock.withLock { v = n } }
        var value: Int? { lock.withLock { v } }
    }
}
