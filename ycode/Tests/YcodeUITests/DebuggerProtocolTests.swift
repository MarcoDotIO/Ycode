import AppKit
import Foundation
import Testing
@testable import YcodeDebug
@testable import YcodeUI

/// An in-memory DAP adapter (protocol shapes per the DAP specification),
/// so the debugger-depth flows are checked even where no process can be
/// launched under a real debugger.
final class ScriptedAdapter: DAPTransport, @unchecked Sendable {
    var receiving: (@Sendable (Data?) -> Void)?
    var decoder = DAPFraming.Decoder()
    private(set) var requests: [JSON] = []
    var pc = 0x1000
    var a = "2"
    var watchArmed = false
    private var seq = 1000

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }

    func event(_ name: String, _ body: JSON) {
        seq += 1
        receiving?(DAPFraming.frame(JSON.object(["seq": .number(Double(seq)), "type": "event", "event": .string(name), "body": body]).encoded()))
    }

    private let lock = NSRecursiveLock()

    func send(_ data: Data) {
        // Requests arrive from several tasks at once.
        lock.lock()
        defer { lock.unlock() }
        for raw in decoder.append(data) {
            let req = try! JSON.decode(raw)
            guard req["type"]?.string == "request", let cmd = req["command"]?.string else { continue }
            requests.append(req)
            let args = req["arguments"] ?? .null
            var body: JSON? = nil
            var after: [(String, JSON)] = []
            let hex = { (n: Int) in JSON.string(String(format: "0x%llx", n)) }
            switch cmd {
            case "initialize": body = ["supportsConfigurationDoneRequest": true, "supportsDataBreakpoints": true, "supportsDisassembleRequest": true]
                after = [("initialized", [:])]
            case "configurationDone", "attach", "launch":
                if cmd != "launch" { after = [("stopped", ["reason": "breakpoint", "threadId": 1])] }
            case "threads": body = ["threads": [["id": 1, "name": "Thread 1 queue = com.apple.main-thread"], ["id": 2, "name": "Thread 2 name = worker queue = com.example.work"]]]
            case "stackTrace": body = ["stackFrames": [["id": 9, "name": "add", "line": 5, "column": 5, "source": ["path": "/tmp/depth.c"],
                                                        "instructionPointerReference": hex(pc)]]]
            case "scopes": body = ["scopes": [["name": "Locals", "variablesReference": 5, "expensive": false]]]
            case "variables": body = ["variables": [["name": "a", "value": .string(a), "type": "int", "variablesReference": 0],
                                                    ["name": "s", "value": "0", "type": "int", "variablesReference": 0]]]
            case "evaluate":
                let e = args["expression"]?.string ?? ""
                body = ["result": .string(e == "a * 2" ? String((Int(a) ?? 0) * 2) : "(int) $0 = 42\n"), "variablesReference": 0]
            case "setVariable": a = args["value"]?.string ?? a; body = ["value": .string(a)]
            case "dataBreakpointInfo": body = ["dataId": "0x16fdff000/4", "description": "4 bytes at 0x16fdff000 s", "accessTypes": ["read", "write", "readWrite"]]
            case "setDataBreakpoints": watchArmed = true; body = ["breakpoints": .array((args["breakpoints"]?.array ?? []).map { _ in ["verified": true] })]
            case "disassemble":
                let off = args["instructionOffset"]?.int ?? 0
                body = ["instructions": .array((0..<(args["instructionCount"]?.int ?? 0)).map { i in
                    ["address": hex(pc + (off + i) * 4), "instruction": .string(i % 2 == 0 ? "add w0, w0, w1" : "ldr w8, [sp]"), "symbol": "add"]
                })]
            case "next", "stepIn":
                if args["granularity"]?.string == "instruction" { pc += 4 }
                after = [("stopped", ["reason": "step", "threadId": 1])]
            case "continue":
                after = watchArmed ? [("stopped", ["reason": "data breakpoint", "threadId": 1])] : [("exited", ["exitCode": 0]), ("terminated", [:])]
            case "disconnect": after = [("terminated", [:])]
            default: body = [:]
            }
            seq += 1
            var resp: [String: JSON] = ["seq": .number(Double(seq)), "type": "response", "request_seq": req["seq"]!, "command": .string(cmd), "success": true]
            if let body { resp["body"] = body }
            receiving?(DAPFraming.frame(JSON.object(resp).encoded()))
            for (n, b) in after { event(n, b) }
        }
    }

    func close() { receiving?(nil) }
}

@MainActor
@Suite(.serialized, .heavyIntegration) struct DebuggerProtocolTests {
    @Test func depthFlowsOverDAP() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-dap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"D\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        let adapter = ScriptedAdapter()
        await session.attach(to: "4242", adapter: adapter)
        #expect(await waitUntil(60) { session.stoppedThread == 1 && !session.variables.isEmpty })
        let attach = try #require(adapter.requests.first { $0["command"]?.string == "attach" })
        #expect(attach["arguments"]?["pid"]?.int == 4242 && attach["arguments"]?["threadFormat"]?.string == DebugThread.format)

        // Console: evaluate in the repl context, echoed after the prompt.
        wc.debugArea.consoleField.stringValue = "p 6 * 7"
        await wc.debugArea.submitConsoleLine()
        let eval = try #require(adapter.requests.last { $0["command"]?.string == "evaluate" })
        #expect(eval["arguments"]?["context"]?.string == "repl" && eval["arguments"]?["frameId"]?.int == 9)
        #expect(session.consoleText(.debugger).contains("(lldb) p 6 * 7\n(int) $0 = 42"))
        wc.debugArea.setFilter(.target)
        #expect(wc.debugArea.consoleFilter == .target)
        wc.debugArea.setFilter(.all)

        // setVariable, watch expressions, print description.
        #expect(await session.setValue("7", of: "a") == "7")
        let setVar = try #require(adapter.requests.last { $0["command"]?.string == "setVariable" })
        #expect(setVar["arguments"]?["variablesReference"]?.int == 5 && setVar["arguments"]?["name"]?.string == "a")
        session.watchExpressions = ["a * 2"]
        #expect(await waitUntil(60) { session.watchValues.first?.value == "14" })
        #expect(wc.debugArea.roots.first?.variable.name == "a * 2")
        _ = await session.printDescription(of: "s")
        #expect(session.consoleHistory.last == "po s")

        // Threads by queue.
        #expect(session.threadsByQueue.map(\.queue) == ["com.apple.main-thread", "com.example.work"])
        wc.toggleThreadsByQueue(nil)
        #expect(wc.navigator.debugThreadRows.map(\.title) == ["com.apple.main-thread", "com.example.work"])

        // Disassembly and instruction stepping.
        wc.toggleAlwaysShowDisassembly(nil)
        #expect(await waitUntil(60) { session.disassemblyPCIndex == 8 })
        #expect(wc.editor.text.contains("0x1000  add w0, w0, w1"))
        #expect(wc.editor.gutter.marks.currentLine == 9)
        await session.step("over")
        let step = try #require(adapter.requests.last { $0["command"]?.string == "next" })
        #expect(step["arguments"]?["granularity"]?.string == "instruction")
        #expect(await waitUntil(60) { session.disassemblyPCIndex.map { session.disassembly[$0].address } == "0x1004" })
        wc.toggleAlwaysShowDisassembly(nil)

        // Watchpoint: dataBreakpointInfo + setDataBreakpoints, navigator row, stop.
        let w = await session.watch("s")
        #expect(w?.verified == true && w?.accessType == "write")
        let set = try #require(adapter.requests.last { $0["command"]?.string == "setDataBreakpoints" })
        #expect(set["arguments"]?["breakpoints"]?.array?.first?["dataId"]?.string == "0x16fdff000/4")
        #expect(wc.navigator.breakpointGroups.first { $0.title == "Watchpoints" }?.children.first?.title == "s (write)")
        await session.continueOrPause()
        #expect(await waitUntil(60) { if case .paused(let s) = session.activity { return s.contains("data breakpoint") }; return false })
        session.stop()
        #expect(await waitUntil(60) { session.debugClient == nil })
    }

    /// Regression (runWithSwiftBuild): the launch request carries a unique
    /// LLVM_PROFILE_FILE outside the product directory, alongside the
    /// scheme's own variables, and the program's cwd defaults to its folder.
    @Test func launchRequestEnvironment() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-dapenv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"D\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let adapter = ScriptedAdapter()
        await session.debug(program: "/tmp/prod/Tool", adapter: adapter)
        let launch = try #require(adapter.requests.first { $0["command"]?.string == "launch" })
        let env = (launch["arguments"]?["env"]?.array ?? []).compactMap(\.string)
        let profile = try #require(env.first { $0.hasPrefix("LLVM_PROFILE_FILE=") })
        #expect(profile.hasSuffix(".profraw") && !profile.contains("/tmp/prod/"))
        #expect(launch["arguments"]?["cwd"]?.string == "/tmp/prod")
    }
}
