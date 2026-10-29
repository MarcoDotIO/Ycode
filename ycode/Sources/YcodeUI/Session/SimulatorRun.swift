import Foundation
import YcodeBuild
import YcodeDebug
import YcodeSubprocess

/// `xcrun simctl` for running apps on Mac simulators. Never opens the
/// Simulator app: devices are booted headless. See `specs/ide/run.md`.
public struct Simctl: Sendable {
    /// Runs `xcrun simctl <args>` and returns (status, stdout+stderr).
    public var run: @Sendable ([String]) -> (Int32, String)
    /// The program and leading arguments of the streamed `launch` (tests
    /// put a stand-in here).
    public var launchCommand = ["/usr/bin/xcrun", "simctl"]

    public init(run: @escaping @Sendable ([String]) -> (Int32, String) = Simctl.xcrun) { self.run = run }

    public static let xcrun: @Sendable ([String]) -> (Int32, String) = { args in
        MainThreadGuard.blockingCall("simctl \(args.first ?? "")")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl"] + args
        // Output goes to a file, not a pipe: processes simctl starts may
        // keep a pipe open long after simctl itself has exited.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-simctl-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let h = try? FileHandle(forWritingTo: file) else { return (127, "no temporary file") }
        p.standardOutput = h
        p.standardError = h
        guard (try? p.run()) != nil else { return (127, "xcrun not found") }
        p.waitUntilExit()
        try? h.close()
        return (p.terminationStatus, (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    @discardableResult
    func checked(_ args: [String]) throws -> String {
        let (s, out) = run(args)
        guard s == 0 else { throw Failure(description: "simctl \(args.first ?? ""): \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return out
    }

    /// Boots the device (if needed) and waits until it has finished booting.
    public func boot(_ udid: String) throws { try checked(["bootstatus", udid, "-b"]) }
    public func install(_ udid: String, app: URL) throws { try checked(["install", udid, app.path]) }
    public func terminate(_ udid: String, bundleID: String) { _ = run(["terminate", udid, bundleID]) }
    public func shutdown(_ udid: String) { _ = run(["shutdown", udid]) }

    /// The launch: app stdout/stderr redirected to files (which Ycode
    /// follows), any running copy replaced; simctl returns at once and
    /// prints `<bundle id>: <pid>`.
    public static func launchArguments(udid: String, bundleID: String, waitForDebugger: Bool, arguments: [String] = []) -> [String] {
        ["launch", "--console", "--terminate-running-process"] + (waitForDebugger ? ["--wait-for-debugger"] : []) + [udid, bundleID] + arguments
    }

    /// `"<bundle id>: <pid>"`, the first line `simctl launch` prints.
    public static func launchedPID(_ line: String, bundleID: String) -> Int? {
        guard line.hasPrefix(bundleID + ":") else { return nil }
        return Int(line.dropFirst(bundleID.count + 1).trimmingCharacters(in: .whitespaces))
    }
}

/// An application bundle's identity (Info.plist).
public struct AppBundle: Equatable, Sendable {
    public var url: URL
    public var bundleID: String
    public var executable: String
    /// The executable inside the bundle (flat iOS layout or macOS
    /// `Contents/MacOS`).
    public var executableURL: URL {
        let flat = url.appendingPathComponent(executable)
        return FileManager.default.fileExists(atPath: flat.path) ? flat : url.appendingPathComponent("Contents/MacOS/\(executable)")
    }

    public init?(url: URL) {
        let candidates = [url.appendingPathComponent("Info.plist"), url.appendingPathComponent("Contents/Info.plist")]
        guard let data = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String else { return nil }
        self.url = url
        bundleID = id
        executable = plist["CFBundleExecutable"] as? String ?? url.deletingPathExtension().lastPathComponent
    }
}

/// A long-running child process whose output lines are delivered on the
/// main actor.
final class StreamingProcess: @unchecked Sendable {
    let process = Process()
    private let pipe = Pipe()
    private var buffer = Data()
    private let lock = NSLock()

    init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = pipe
        process.standardError = pipe
    }

    /// Starts; `onLine` gets each line (without the newline), `onExit` the status.
    func start(onLine: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32) -> Void) throws {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            let lines = self.take(d)
            Task { @MainActor in lines.forEach(onLine) }
        }
        process.terminationHandler = { [weak self] p in
            let rest = self?.flush() ?? []
            let status = p.terminationStatus
            Task { @MainActor in
                rest.forEach(onLine)
                onExit(status)
            }
        }
        try process.run()
    }

    private func take(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var out: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            out.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return out
    }

    private func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let rest = String(decoding: buffer, as: UTF8.self)
        buffer = Data()
        return rest.isEmpty ? [] : [rest]
    }

    var isRunning: Bool { process.isRunning }
    func signal(_ s: Int32) { if process.isRunning { kill(process.processIdentifier, s) } }
}

/// What is running on a simulator (Mac or remote).
@MainActor
public final class SimulatorRunState {
    public enum Target: Equatable, Sendable { case mac(udid: String), remote(destination: String) }
    public let target: Target
    public let app: AppBundle
    public internal(set) var pid: Int?
    /// The remote shell's pid (remote runs), for Stop.
    public internal(set) var remotePID: Int?
    public internal(set) var exitStatus: Int32?
    /// Stop was asked for (remote runs: the launcher is saving the device).
    public internal(set) var stopRequested = false
    /// The IDE closed the connection itself after the stop had finished.
    public internal(set) var closedByIDE = false
    /// The remote simulator this run uses (its settings at the start).
    var remote: RemoteSimulator?
    var process: StreamingProcess?

    init(target: Target, app: AppBundle) {
        self.target = target
        self.app = app
    }
}

extension WorkspaceSession {
    /// Runs an app on a Mac simulator: boot (headless), install, launch with
    /// its output in the console; with `debug`, launch waiting for the
    /// debugger and attach lldb-dap to the app's process.
    public func runOnSimulator(app appURL: URL, udid: String, debug: Bool, simctl: Simctl = Simctl(), adapter: DAPTransport? = nil) async {
        guard let app = AppBundle(url: appURL) else { appendConsole("Ycode: \(appURL.lastPathComponent) is not an application bundle.\n"); return }
        let state = SimulatorRunState(target: .mac(udid: udid), app: app)
        simulatorRun = state
        // reference-ui-6.md §3.3: "Launching <product>" while the simulator
        // boots, the app installs and launches; no separate boot text.
        let device = destination.flatMap { $0.identifier == udid ? $0.name : nil } ?? "Simulator"
        runningProduct = app.executable
        runningDeviceName = device
        setActivity(.running(RunActivityText.launching(app.executable)))
        do {
            try await Task.detached { try simctl.boot(udid) }.value
            appendConsole("Ycode: simulator \(udid) is booted.\n")
            try await Task.detached { try simctl.install(udid, app: appURL) }.value
            appendConsole("Ycode: installed \(app.bundleID).\n")
        } catch {
            appendConsole("Ycode: \(error)\n")
            simulatorRun = nil
            setActivity(.finished("Run failed"))
            return
        }
        // simctl stays attached with the app's output (`--console`); the
        // app's pid comes from the host process list (simulator apps are
        // host processes).
        // Scheme arguments follow the bundle id; environment variables reach
        // the app through simctl's SIMCTL_CHILD_ prefix.
        let o = launchOptions
        var env: [String: String]?
        if !o.environment.isEmpty {
            env = ProcessInfo.processInfo.environment
            for (k, v) in o.environment { env?["SIMCTL_CHILD_" + k] = v }
        }
        let proc = StreamingProcess(executable: simctl.launchCommand[0],
                                    arguments: Array(simctl.launchCommand.dropFirst()) + Simctl.launchArguments(udid: udid, bundleID: app.bundleID, waitForDebugger: debug, arguments: o.arguments),
                                    environment: env)
        state.process = proc
        do {
            try proc.start(onLine: { [weak self, weak state] line in
                guard let self, let state else { return }
                if let pid = Simctl.launchedPID(line, bundleID: app.bundleID) { if state.pid == nil { state.pid = pid }; return }
                self.appendConsole(line + "\n", kind: .target)
            }, onExit: { [weak self, weak state] status in
                state?.exitStatus = status
                guard let self else { return }
                self.appendConsole("Program ended with exit code: \(status)\n")
                if self.simulatorRun === state { self.simulatorRun = nil }
                if self.debugClient == nil { self.setActivity(.finished(RunActivityText.finished(app.executable, on: device))) }
            })
        } catch {
            appendConsole("Ycode: \(error)\n")
            simulatorRun = nil
            return
        }
        let marker = "/\(appURL.lastPathComponent)/\(app.executable)"
        // A cold or contended simulator can take far longer than a few
        // seconds to start the app, so poll until the run ends (2 min cap).
        for _ in 0..<1200 where state.pid == nil && simulatorRun === state && state.exitStatus == nil {
            if let pid = await Task.detached(operation: { Self.newestProcess(matching: marker) }).value { state.pid = pid; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The app is up (or never reported a pid): under the debugger,
        // "Configuring Debugger Actions" until it is attached and resumed.
        guard simulatorRun === state, state.exitStatus == nil else { return }
        if debug, let pid = state.pid {
            setActivity(.running(RunActivityText.configuringDebugger))
            await attachToSimulatorApp(pid: pid, executable: app.executableURL.path, adapter: adapter)
        }
        // A breakpoint may already have stopped the app.
        guard simulatorRun === state, state.exitStatus == nil else { return }
        if case .paused = activity { return }
        setActivity(.running(RunActivityText.running(app.executable, on: device)))
    }

    /// The newest host process whose command line contains `marker` (`pgrep -n -f`).
    nonisolated static func newestProcess(matching marker: String) -> Int? {
        MainThreadGuard.blockingCall("pgrep -f")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-n", "-f", marker]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Int(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Attaches lldb-dap to a simulator app by pid (lldb picks the
    /// simulator platform from the executable).
    func attachToSimulatorApp(pid: Int, executable: String, adapter: DAPTransport?) async {
        let transport: DAPTransport
        if let adapter { transport = adapter } else {
            guard let path = await Task.detached(operation: { LLDBDAP.locate() }).value else { appendConsole("Ycode: lldb-dap was not found.\n"); return }
            transport = ProcessTransport(executable: path)
        }
        do {
            let client = try DAPClient(transport: transport)
            debugClient = client
            Task { [weak self] in
                for await e in client.events { await self?.handle(e) }
                self?.sessionEnded()
            }
            try await client.initialize()
            attachingSimulatorApp = true
            defer { attachingSimulatorApp = false }
            try await client.attach(pid: pid, program: executable, waitFor: false, threadFormat: DebugThread.format)
            // Attaching stops the app (it was waiting for the debugger):
            // resume it once so it runs to the breakpoints.
            for _ in 0..<100 where stoppedThread == nil { try? await Task.sleep(for: .milliseconds(100)) }
            attachingSimulatorApp = false
            if stoppedThread != nil { await continueOrPause() }
        } catch {
            appendConsole("Ycode: attach failed: \(error)\n")
        }
    }

    /// Stop for simulator runs: terminate the app (Mac) or signal the
    /// remote process; also ends the debug session.
    public func stopSimulatorRun(simctl: Simctl = Simctl(), remote: RemoteSimulator? = nil) {
        guard let run = simulatorRun else { return }
        switch run.target {
        case .mac(let udid):
            // Off the main actor and after the debugger lets go: `simctl
            // terminate` waits for the app to exit, which a process stopped
            // under the debugger never does.
            let client = debugClient, bundleID = run.app.bundleID, process = run.process
            Task.detached {
                if let client { try? await client.disconnect(terminate: true); client.close() }
                simctl.terminate(udid, bundleID: bundleID)
                process?.signal(SIGTERM)
            }
            return
        case .remote:
            stopRemoteRun(run, remote: run.remote ?? remote)
        }
        if let c = debugClient { Task { try? await c.disconnect(terminate: true); c.close() } }
    }

    /// Stop for the remote simulator (`run.md` §Remote, `snapshot.md`
    /// §12.2): SIGINT to the launcher's pid through ssh, the signal it
    /// turns into the save at the stop (ycode-simd ends the app, saves the
    /// device and exits). The connection stays open meanwhile, so the
    /// launcher's report reaches the console; it is closed once the
    /// launcher reports the save, when the signal could not be delivered,
    /// after `stopGrace`, or at a second Stop. Stop before the remote pid
    /// is known sends the signal when it arrives; Stop during the upload
    /// ends the run before it launches.
    func stopRemoteRun(_ run: SimulatorRunState, remote: RemoteSimulator?) {
        if run.stopRequested {
            // A second Stop: do not wait for the save any longer.
            run.process?.signal(SIGINT)
            return
        }
        run.stopRequested = true
        guard run.process != nil else { return }
        guard let remote else { run.process?.signal(SIGINT); return }
        setActivity(.running(RemoteSimulator.stoppingStatus(app: run.app.executable, saves: remote.settings.warmBoot)))
        if let pid = run.remotePID { sendRemoteStop(run, pid: pid, remote: remote) }
    }

    /// Delivers the stop signal off the main actor; closes the connection
    /// when that fails, or after the grace time.
    func sendRemoteStop(_ run: SimulatorRunState, pid: Int, remote: RemoteSimulator) {
        let process = run.process
        Task { [weak self] in
            let status = await Task.detached { remote.signalRemote(pid, signal: "INT") }.value
            if status != 0 {
                self?.appendConsole("Ycode: the stop signal did not reach \(remote.settings.destination) (ssh status \(status)); closing the connection.\n", kind: .debugger)
                process?.signal(SIGINT)
                return
            }
            try? await Task.sleep(for: .seconds(remote.stopGrace))
            if process?.isRunning == true {
                self?.appendConsole("Ycode: Ycode Simulator did not end \(Int(remote.stopGrace)) s after Stop; closing the connection.\n", kind: .debugger)
                process?.signal(SIGINT)
            }
        }
    }
}
