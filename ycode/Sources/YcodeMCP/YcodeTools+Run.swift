import Foundation
import YcodeAssistant
import YcodeBuild
import YcodeIDECore

extension YcodeMCPHost {
    var runTools: [MCPTool] {
        let simulatorArg = Schema.string("The Ycode Simulator destination's name or id (default: the first; see simulator_list).")
        let execute = MCPToolAnnotations(readOnly: false)
        return [
            tool("run", "Run",
                 "Builds the scheme and runs its product: on this computer (the program's output is captured; see run_output), or, for a Ycode Simulator destination, installs and launches the app on the remote device.",
                 input: Schema.object([
                     "workspace": Schema.workspace, "scheme": Schema.string("The scheme (default: the selected one)."),
                     "destination": Schema.string("A run destination's name or id (default: the selected one)."),
                     "arguments": Schema.array(Schema.str, "Command-line arguments (programs on this computer)."),
                     "waitSeconds": Schema.integer("Wait this long for output or for the app to launch before answering (default 5, at most 120).", minimum: 0),
                 ]),
                 output: Schema.output(["runId": Schema.str, "state": Schema.str, "output": Schema.anyArray]), annotations: execute) { h, call in
                try await h.run(call)
            },
            tool("run_output", "Run output",
                 "A run's state and its latest output lines (the program's, or the simulator launcher's and the app's console).",
                 input: Schema.object(["runId": Schema.string("The run (default: the latest)."),
                                       "tail": Schema.integer("Only the last N lines (default 100).", minimum: 1)]),
                 output: Schema.output(["runId": Schema.str, "state": Schema.str, "output": Schema.anyArray])) { h, call in
                try h.runOutput(call)
            },
            tool("stop", "Stop",
                 "Stops a run (default: the latest): the program on this computer, or the app on the Ycode Simulator (the device is saved for the next run when warm boot is on).",
                 input: Schema.object(["runId": Schema.string("The run (default: the latest).")]),
                 output: Schema.output(["runId": Schema.str, "state": Schema.str]), annotations: execute) { h, call in
                try await h.stop(call)
            },
            tool("simulator_list", "List simulators",
                 "The Ycode Simulator devices on the remote simulator host (device type and runtime) and whether each is running. Empty when no host is set up.",
                 input: Schema.object([:]), output: Schema.output(["simulators": Schema.anyArray, "configured": Schema.bool])) { h, _ in
                h.simulatorList()
            },
            tool("simulator_boot", "Boot simulator",
                 "Starts a Ycode Simulator device without an app (as Device Hub's Start). Use simulator_screenshot to see it.",
                 input: Schema.object(["simulator": simulatorArg]),
                 output: Schema.output(["simulator": Schema.str, "state": Schema.str]), annotations: execute) { h, call in
                try await h.simulatorBoot(call)
            },
            tool("simulator_launch_app", "Install and launch app",
                 "Installs a built app bundle (.app) on a Ycode Simulator device and launches it (the device boots, or restores, first). To build and launch a scheme's app in one step, use run with the simulator as destination.",
                 input: Schema.object(["simulator": simulatorArg, "appPath": Schema.string("The .app bundle (absolute, or relative to the workspace folder)."),
                                       "waitSeconds": Schema.integer("Wait this long for the app to launch (default 60, at most 600).", minimum: 0)],
                                      required: ["appPath"]),
                 output: Schema.output(["runId": Schema.str, "state": Schema.str, "output": Schema.anyArray]), annotations: execute) { h, call in
                try await h.simulatorLaunch(call)
            },
            tool("simulator_shutdown", "Shut down simulator",
                 "Shuts a Ycode Simulator device down (it is saved for the next start when warm boot is on).",
                 input: Schema.object(["simulator": simulatorArg]),
                 output: Schema.output(["simulator": Schema.str, "state": Schema.str]), annotations: execute) { h, call in
                try await h.simulatorShutdown(call)
            },
            tool("simulator_screenshot", "Simulator screenshot",
                 "A PNG of a running Ycode Simulator device's screen, as an image.",
                 input: Schema.object(["simulator": simulatorArg,
                                       "display": Schema.string("Which panel: active (default), LCD or LCD-1 (a foldable's inner panel).", oneOf: ["active", "LCD", "LCD-1"])])) { h, call in
                try await h.simulatorScreenshot(call)
            },
            tool("simulator_logs", "Simulator logs",
                 "The Ycode Simulator launcher's and the app's latest console lines.",
                 input: Schema.object(["tail": Schema.integer("Only the last N lines (default 100).", minimum: 1)]),
                 output: Schema.output(["lines": Schema.anyArray])) { h, call in
                let lines = h.simulatorLines(tail: call.int("tail") ?? 100)
                return MCPToolResult(content: [.textBlock(lines.isEmpty ? "No simulator output yet." : lines.joined(separator: "\n"))],
                                     structured: ["lines": .strings(lines)])
            },
        ]
    }

    // MARK: Runs on this computer

    func run(_ call: MCPToolCall) async throws -> MCPToolResult {
        let s = try session(for: call)
        try applyScheme(call.string("scheme"), destination: call.string("destination"), to: s)
        let wait = Double(min(max(call.int("waitSeconds") ?? 5, 0), 120))
        delegate?.mcpHostSaveAll()
        let result = await reportingActivity(call.progress) { await s.build(.build) }
        guard result.status == .succeeded else {
            let root = Self.folder(of: s.model).path
            return .error("The build failed (\(result.errorCount) errors); nothing was run.\n"
                          + result.issues.filter { $0.severity == .error }.prefix(20).map(\.description).joined(separator: "\n"),
                          structured: ["issues": .array(result.issues.prefix(100).map { Self.issueJSON($0, relativeTo: root) })])
        }
        let request = s.model.buildRequest(scheme: s.scheme, destination: s.destination, action: .build)
        let engine = s.engine
        guard let exe = await Task.detached(operation: { engine.executablePath(for: request) }).value else {
            throw MCPToolError("the scheme's product could not be found after the build (no executable product?)")
        }
        if let d = s.destination, d.isYcodeRemoteSimulator {
            guard let app = Self.appBundlePath(fromExecutable: exe) else { throw MCPToolError("\(exe) is not inside an app bundle") }
            return try await launchOnSimulator(app: URL(fileURLWithPath: app), destination: d, session: s, wait: max(wait, 30))
        }
        return try await launchHost(exe, arguments: call.strings("arguments") ?? [], directory: Self.folder(of: s.model), wait: wait)
    }

    /// `<…>/App.app` from the bundle's executable (`App.app/App` or
    /// `App.app/Contents/MacOS/App`).
    nonisolated static func appBundlePath(fromExecutable p: String) -> String? {
        if let r = p.range(of: ".app/", options: .backwards) { return String(p[..<r.lowerBound]) + ".app" }
        return p.hasSuffix(".app") ? p : nil
    }

    func launchHost(_ exe: String, arguments: [String], directory: URL, wait: Double) async throws -> MCPToolResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = arguments
        p.currentDirectoryURL = directory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let id = "run-\(runOrder.count + 1)"
        let run = HostRun(id: id, executable: exe, process: p)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { run.append(d) }
        }
        p.terminationHandler = { proc in
            // The output still in the pipe, then the status.
            pipe.fileHandleForReading.readabilityHandler = nil
            if case let rest?? = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { run.append(rest) }
            run.finish(proc.terminationStatus)
        }
        do { try p.run() } catch { throw MCPToolError("cannot launch \(exe): \(error.localizedDescription)") }
        runs[id] = run
        runOrder.append(id)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline, run.status == nil { try? await Task.sleep(for: .milliseconds(100)) }
        return runResult(id)
    }

    func runResult(_ id: String, tail: Int = 100) -> MCPToolResult {
        if let r = runs[id] {
            let state = r.status.map { "exited with status \($0)" } ?? "running (pid \(r.process.processIdentifier))"
            let out = r.output(tail: tail)
            return MCPToolResult(content: [.textBlock("\(id): \((r.executable as NSString).lastPathComponent) \(state)\n" + out.joined(separator: "\n"))],
                                 structured: ["runId": .string(id), "state": .string(state), "output": .strings(out),
                                              "exitStatus": r.status.map { .int(Int($0)) } ?? .null])
        }
        // A simulator run: the session's run state and console.
        let state = simulatorState()
        let out = simulatorLines(tail: tail)
        return MCPToolResult(content: [.textBlock("\(id): \(state)\n" + out.joined(separator: "\n"))],
                             structured: ["runId": .string(id), "state": .string(state), "output": .strings(out)])
    }

    func latestRun(_ call: MCPToolCall) throws -> String {
        if let id = call.string("runId") {
            guard runs[id] != nil || id.hasPrefix("sim-") else { throw MCPToolError("no run \(id)") }
            return id
        }
        guard let last = runOrder.last else { throw MCPToolError("nothing has been run yet") }
        return last
    }

    func runOutput(_ call: MCPToolCall) throws -> MCPToolResult {
        runResult(try latestRun(call), tail: call.int("tail") ?? 100)
    }

    func stop(_ call: MCPToolCall) async throws -> MCPToolResult {
        let id = try latestRun(call)
        if let r = runs[id] {
            if r.status == nil {
                r.process.interrupt()
                for _ in 0..<30 where r.status == nil { try? await Task.sleep(for: .milliseconds(100)) }
                if r.status == nil { r.process.terminate() }
            }
            return runResult(id)
        }
        guard let s = session else { throw MCPToolError("no workspace is open") }
        if let run = s.simulatorRun {
            s.stopSimulatorRun(remote: run.remote)
            for _ in 0..<600 where s.simulatorRun === run { try? await Task.sleep(for: .milliseconds(250)) }
        }
        return runResult(id)
    }

    // MARK: The Ycode Simulator (remote)

    func remoteSettings() throws -> RemoteSimulatorSettings {
        guard let r = remoteSimulator, r.isConfigured else {
            throw MCPToolError("no Ycode Simulator host is set up. In the IDE: Settings ▸ Components ▸ Simulator Host. For `ycode mcp`: --simulator-config <file.json> or the YCODE_MCP_SIM_* variables (see `ycode mcp --help`).")
        }
        return r
    }

    func remote(named name: String?) throws -> RemoteSimulator {
        let settings = try remoteSettings()
        let all = RemoteSimulator.all(settings)
        guard let name else { return all.first ?? RemoteSimulator(settings: settings, target: nil) }
        if let r = all.first(where: { $0.destination.identifier == name || $0.destination.name == name || $0.remoteDevicePath.hasSuffix("/" + name) }) {
            return r
        }
        if let r = all.first(where: { $0.destination.name.lowercased().hasPrefix(name.lowercased()) }) { return r }
        throw MCPToolError("no Ycode Simulator \"\(name)\"; there are: \(all.map(\.destination.name).joined(separator: ", "))")
    }

    func simulatorList() -> MCPToolResult {
        guard let settings = remoteSimulator, settings.isConfigured else {
            return MCPToolResult(content: [.textBlock("No Ycode Simulator host is set up.")], structured: ["simulators": [], "configured": false])
        }
        let list: [AnyJSON] = RemoteSimulator.all(settings).map { r in
            ["name": .string(r.destination.name), "id": .optional(r.destination.identifier), "runtime": .optional(r.runtimeVersion),
             "device": .string((r.remoteDevicePath as NSString).lastPathComponent),
             "running": .bool(RemoteDeviceSessions.shared.isRunning(r) || session?.simulatorRun?.remote?.remoteDevicePath == r.remoteDevicePath)]
        }
        return MCPToolResult(content: [.textBlock(list.map { "\($0["name"]?.string ?? "")\($0["running"] == .bool(true) ? " (running)" : "")" }.joined(separator: "\n"))],
                             structured: ["simulators": .array(list), "configured": true])
    }

    func noteSimulator(_ line: String) {
        simulatorLog.append(line)
        if simulatorLog.count > 5000 { simulatorLog.removeFirst(simulatorLog.count - 5000) }
    }

    func simulatorLines(tail: Int) -> [String] {
        var lines = simulatorLog
        if let s = session {
            lines += s.consoleEntries.map(\.text).joined().components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        return Array(lines.suffix(tail))
    }

    func simulatorState() -> String {
        guard let s = session else { return "idle" }
        switch s.activity {
        case .running(let t): return t
        case .finished(let t): return t
        case .building(let t): return t
        default: return s.simulatorRun == nil ? "idle" : "running"
        }
    }

    func simulatorBoot(_ call: MCPToolCall) async throws -> MCPToolResult {
        let r = try remote(named: call.string("simulator"))
        let sessions = RemoteDeviceSessions.shared
        sessions.output = { [weak self] line in self?.noteSimulator(line) }
        let name = r.destination.name
        if sessions.isRunning(r) {
            return .structured(["simulator": .string(name), "state": "running"], summary: "\(name) is running already.")
        }
        guard sessions.start(r) else { throw MCPToolError("\(name) could not be started (is it running a launched app? stop it first)") }
        return .structured(["simulator": .string(name), "state": "booting"],
                           summary: "\(name) is starting (a warm restore takes seconds, a cold boot a minute or more); take a screenshot to see it.")
    }

    func simulatorShutdown(_ call: MCPToolCall) async throws -> MCPToolResult {
        let r = try remote(named: call.string("simulator"))
        let name = r.destination.name
        if let s = session, let run = s.simulatorRun, run.remote?.remoteDevicePath == r.remoteDevicePath {
            s.stopSimulatorRun(remote: r)
            for _ in 0..<600 where s.simulatorRun === run { try? await Task.sleep(for: .milliseconds(250)) }
        }
        await RemoteDeviceSessions.shared.shutDown(r)
        return .structured(["simulator": .string(name), "state": "shut down"], summary: "\(name) is shut down.")
    }

    func simulatorLaunch(_ call: MCPToolCall) async throws -> MCPToolResult {
        let r = try remote(named: call.string("simulator"))
        var path = (try call.require("appPath") as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let s = session { path = Self.folder(of: s.model).appendingPathComponent(path).path }
        guard AppBundle(url: URL(fileURLWithPath: path)) != nil else { throw MCPToolError("\(path) is not an app bundle (no Info.plist with a bundle identifier)") }
        let s: WorkspaceSession
        if let open = session {
            s = open
        } else {
            // No workspace: a session over the app's folder holds the run.
            s = WorkspaceSession(model: try Self.placeholderModel(near: URL(fileURLWithPath: path)))
            session = s
            observe(s)
        }
        let wait = Double(min(max(call.int("waitSeconds") ?? 60, 0), 600))
        return try await launchOnSimulator(app: URL(fileURLWithPath: path), destination: r.destination, session: s, wait: wait, remote: r)
    }

    /// A minimal workspace model for runs made without an open workspace.
    static func placeholderModel(near app: URL) throws -> WorkspaceModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-mcp-run-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = dir.appendingPathComponent("Package.swift")
        if !FileManager.default.fileExists(atPath: manifest.path) {
            try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Run\")\n".write(to: manifest, atomically: true, encoding: .utf8)
        }
        _ = app
        return try WorkspaceModel(url: dir)
    }

    func launchOnSimulator(app: URL, destination: Destination, session s: WorkspaceSession, wait: Double, remote: RemoteSimulator? = nil) async throws -> MCPToolResult {
        let r = try remote ?? self.remote(named: destination.identifier ?? destination.name)
        guard let bundle = AppBundle(url: app) else { throw MCPToolError("\(app.path) is not an app bundle") }
        if let run = s.simulatorRun {
            s.stopSimulatorRun(remote: run.remote)
            for _ in 0..<600 where s.simulatorRun === run { try? await Task.sleep(for: .milliseconds(250)) }
        }
        noteSimulator("ycode mcp: installing \(bundle.bundleID) on \(r.destination.name)")
        await s.runOnRemoteSimulator(app: app, remote: r)
        let id = "sim-\(runOrder.count + 1)"
        runOrder.append(id)
        let deadline = Date().addingTimeInterval(wait)
        let running = WorkspaceSession.RunActivityText.running(bundle.executable, on: r.destination.name)
        while Date() < deadline, s.simulatorRun != nil, s.activity != .running(running) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return runResult(id)
    }

    func simulatorScreenshot(_ call: MCPToolCall) async throws -> MCPToolResult {
        let r = try remote(named: call.string("simulator"))
        let display = call.string("display") ?? "active"
        let result = await Task.detached { r.screenshot(display: display) }.value
        switch result {
        case .success(let png):
            return MCPToolResult(content: [.imageBlock(png), .textBlock("\(r.destination.name), \(display) display, \(png.count) bytes.")])
        case .failure(let e):
            throw MCPToolError(e.description)
        }
    }
}
