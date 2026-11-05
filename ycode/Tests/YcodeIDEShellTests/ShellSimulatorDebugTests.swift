import Foundation
import Testing
import YcodeBuild
@testable import YcodeDebug
@testable import YcodeIDECore
@testable import YcodeIDEShell
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// lldb-dap attached to a simulator app's stub, in the DAP specification's
/// shapes: the attach stops the app (a signal), Continue runs it, and a
/// "tap" (`tap()`) stops it at the button handler's breakpoint with the
/// handler's variables.
final class StubScriptedAdapter: DAPTransport, @unchecked Sendable {
    let file: String
    private var receiving: (@Sendable (Data?) -> Void)?
    private var decoder = DAPFraming.Decoder()
    private let lock = NSRecursiveLock()
    private var seq = 2000
    private(set) var commands: [String] = []
    private(set) var attachArguments: JSON = .null
    private(set) var disconnectArguments: JSON = .null
    private(set) var breakpointLines: [Int] = []
    var line = 72

    init(file: String) { self.file = file }

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }

    private func emit(_ msg: [String: JSON]) {
        seq += 1
        var m = msg
        m["seq"] = .number(Double(seq))
        receiving?(DAPFraming.frame(JSON.object(m).encoded()))
    }

    private func event(_ name: String, _ body: JSON) { emit(["type": "event", "event": .string(name), "body": body]) }

    /// The user taps the app's button: the breakpoint in its handler stops it.
    func tap() {
        lock.lock()
        defer { lock.unlock() }
        line = 72
        event("stopped", ["reason": "breakpoint", "threadId": 1, "hitBreakpointIds": [1]])
    }

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        for raw in decoder.append(data) {
            guard let req = try? JSON.decode(raw), req["type"]?.string == "request", let cmd = req["command"]?.string else { continue }
            commands.append(cmd)
            let args = req["arguments"] ?? .null
            var body: JSON = [:]
            var after: [(String, JSON)] = []
            switch cmd {
            case "initialize": after = [("initialized", [:])]
            case "attach":
                attachArguments = args
                after = [("process", ["systemProcessId": 384, "name": "TapCounter"]),
                         ("stopped", ["reason": "signal", "description": "signal SIGCHLD", "threadId": 1])]
            case "setBreakpoints":
                let list = args["breakpoints"]?.array ?? []
                if args["source"]?["path"]?.string == file { breakpointLines = list.compactMap { $0["line"]?.int } }
                body = ["breakpoints": .array(list.enumerated().map { ["id": .number(Double($0.offset + 1)), "verified": true, "line": $0.element["line"] ?? 0] })]
            case "threads": body = ["threads": [["id": 1, "name": "Thread 1 queue = com.apple.main-thread"]]]
            case "stackTrace":
                body = ["stackFrames": [["id": 9, "name": "CounterController.buttonTapped(_:)", "line": .number(Double(line)), "column": 1,
                                         "source": ["path": .string(file)]],
                                        ["id": 10, "name": "@objc CounterController.buttonTapped(_:)", "line": 0, "column": 0],
                                        ["id": 11, "name": "-[UIApplication sendAction:to:from:forEvent:]", "line": 0, "column": 0]]]
            case "scopes": body = ["scopes": [["name": "Locals", "variablesReference": 5, "expensive": false]]]
            case "variables":
                switch args["variablesReference"]?.int {
                case 5: body = ["variables": [["name": "sender", "value": "0x0000000280c01200", "type": "UIButton", "variablesReference": 0],
                                              ["name": "step", "value": .string(line == 72 ? "1" : "1"), "type": "Int", "variablesReference": 0],
                                              ["name": "self", "value": "0x0000000281d04000", "type": "TapCounter.CounterController", "variablesReference": 7]]]
                case 7: body = ["variables": [["name": "tally", "value": "TapCounter.Tally", "type": "TapCounter.Tally", "variablesReference": 0]]]
                default: body = ["variables": []]
                }
            case "next":
                line += 1
                after = [("continued", ["threadId": 1]), ("stopped", ["reason": "step", "threadId": 1])]
            case "continue": after = [("continued", ["threadId": 1])]
            case "disconnect":
                disconnectArguments = args
                after = [("terminated", [:])]
            default: break
            }
            emit(["type": "response", "request_seq": req["seq"]!, "command": .string(cmd), "success": true, "body": body])
            for (e, b) in after { event(e, b) }
        }
    }

    func close() { receiving?(nil) }
}

/// A Unix socket that accepts connections and holds them (a stub that is up).
final class ListeningStub: @unchecked Sendable {
    let path: String
    let fd: Int32

    init() {
        path = "/tmp/yssd-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        fd = socket(AF_UNIX, StubForward.streamType, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        _ = listen(fd, 8)
    }

    func remove() {
        _ = shutdown(fd, Int32(SHUT_RDWR))
        unlink(path)
    }
}

@MainActor final class Flag { var on = false }

/// Run under the debugger on a simulator host on this computer
/// (ShellSimulatorDebug, WorkspaceSession.attachToSimulatorStub).
@MainActor
@Suite(.serialized) struct ShellSimulatorDebugTests {
    @Test nonisolated func onlyAHostOnThisComputerIsDebugged() {
        #expect(ShellSimulatorDebug.isThisMachine("127.0.0.1", interfaceAddresses: []))
        #expect(ShellSimulatorDebug.isThisMachine("localhost", interfaceAddresses: []))
        #expect(ShellSimulatorDebug.isThisMachine("[::1]", interfaceAddresses: []))
        #expect(ShellSimulatorDebug.isThisMachine("192.0.2.7", interfaceAddresses: ["192.0.2.7"]))
        #expect(ShellSimulatorDebug.isThisMachine("simhost.example.com", interfaceAddresses: [], hostName: "simhost"))
        #expect(!ShellSimulatorDebug.isThisMachine("192.0.2.8", interfaceAddresses: ["192.0.2.7"], hostName: "pc"))
        #expect(!ShellSimulatorDebug.isThisMachine("simhost.example.com", interfaceAddresses: [], hostName: "pc"))
        #expect(ShellSimulatorDebug.localAddresses().contains("127.0.0.1"))
        #expect(ShellSimulatorDebug.isEnabled(environment: [:]))
        #expect(!ShellSimulatorDebug.isEnabled(environment: ["YCODE_IDE_SIM_DEBUGGER": "0"]))
    }

    @Test nonisolated func theLaunchLineGivesThePid() {
        let line = "ycode-simd: app: ylaunch: launched org.ycode.samples.debug.TapCounter pid 384"
        #expect(ShellSimulatorDebug.launchedPID(line, bundleID: "org.ycode.samples.debug.TapCounter") == 384)
        #expect(ShellSimulatorDebug.launchedPID(line, bundleID: nil) == 384)
        #expect(ShellSimulatorDebug.launchedPID(line, bundleID: "other.app") == nil)
        #expect(ShellSimulatorDebug.launchedPID("ycode-simd: app: ylaunch: launching org.x", bundleID: nil) == nil)
    }

    @Test nonisolated func linuxLLDBKeepsTheStubsStopsStopped() {
        #if os(Linux)
        #expect(WorkspaceSession.hostSignalCommands == ["process handle -s true -p false -n true SIGCHLD",
                                                        "process handle -s true -p true -n true SIGUSR1"])
        #else
        #expect(WorkspaceSession.hostSignalCommands.isEmpty)
        #endif
    }

    func wait(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition(), "timed out waiting for \(what)")
    }

    /// A TapCounter.app with its Info.plist.
    static func app(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("TapCounter.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "org.ycode.samples.debug.TapCounter", "CFBundleExecutable": "TapCounter"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        FileManager.default.createFile(atPath: app.appendingPathComponent("TapCounter").path, contents: Data())
        return app
    }

    @Test func attachStopsAtTheButtonHandlerShowsVariablesContinuesAndDetaches() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let file = pkg.path("Sources/Demo/main.swift")
        m.debug.gutterClick(file: file, line: 2)
        let stub = ListeningStub()
        defer { stub.remove() }
        let app = try Self.app(in: pkg.url)
        let adapter = StubScriptedAdapter(file: file)
        let launched = Flag()
        let attach = Task {
            await m.session.attachToSimulatorStub(socketPath: stub.path, app: app, device: "tc (thor)", adapter: adapter,
                                                  waitForLaunch: { while !launched.on { try? await Task.sleep(nanoseconds: 5_000_000) }; return true })
        }
        // Until the device launched the app: "Launching TapCounter", Stop enabled.
        await wait("launching") { m.activityText == "Launching TapCounter" }
        #expect(m.isBusy && m.isEnabled(.stop))
        launched.on = true
        let result = await attach.value
        #expect(result == .attached)
        // lldb-dap attached through the loopback forward with the build's executable and the stub's lldb settings.
        let port = try #require(adapter.attachArguments["gdb-remote-port"]?.int)
        #expect(port > 0 && adapter.attachArguments["gdb-remote-hostname"]?.string == "127.0.0.1")
        #expect(adapter.attachArguments["program"]?.string == app.appendingPathComponent("TapCounter").path)
        let pre = adapter.attachArguments["preRunCommands"]?.array?.compactMap(\.string) ?? []
        #expect(pre.contains("settings set target.enable-trampoline-support false"))
        #expect(pre.contains { $0.hasPrefix("settings set target.exec-search-paths") && $0.contains("TapCounter.app") })
        // The attach stop was resumed once; the app runs.
        #expect(adapter.commands.contains("continue"))
        #expect(adapter.breakpointLines == [2])
        await wait("running") { m.activityText == "Running TapCounter on tc (thor)" }
        #expect(m.session.isDebuggingSimulatorStub && !m.debug.isPaused)

        // A tap stops in the handler: frames, variables, the activity.
        adapter.tap()
        await wait("the breakpoint") { m.debug.isPaused && !m.debug.variables.isEmpty }
        #expect(m.activityText == "Paused TapCounter")
        #expect(m.debug.frames.first?.name == "CounterController.buttonTapped(_:)")
        #expect(m.debug.variableRows.map(\.name) == ["sender", "step", "self"])
        // Continue: it runs again.
        m.perform(.pauseOrContinue)
        await wait("continued") { !m.debug.isPaused && m.activityText == "Running TapCounter on tc (thor)" }

        // Stop detaches: the app runs on on the device.
        m.stop()
        await wait("the end") { !m.session.isDebuggingSimulatorStub && !m.debug.isDebugging }
        #expect(adapter.disconnectArguments["terminateDebuggee"]?.bool == false)
    }

    @Test func noStubNoAttach() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let app = try Self.app(in: pkg.url)
        let adapter = StubScriptedAdapter(file: "")
        let r = await m.session.attachToSimulatorStub(socketPath: "/nonexistent/tc.debug.sock", app: app, device: "tc", adapter: adapter, waitSeconds: 0.3)
        #expect(r == .failed("no debug stub"))
        #expect(adapter.commands.isEmpty && !m.debug.isDebugging)
        #expect(m.session.console.contains("could not reach the app on tc"))
        // A launch that never comes (the device stopped): nothing attaches.
        let r2 = await m.session.attachToSimulatorStub(socketPath: "/nonexistent/tc.debug.sock", app: app, device: "tc", adapter: adapter,
                                                       waitForLaunch: { false })
        #expect(r2 == .failed("not launched") && m.session.console.contains("TapCounter did not launch on tc"))
        #expect(!m.isBusy)
    }
}
