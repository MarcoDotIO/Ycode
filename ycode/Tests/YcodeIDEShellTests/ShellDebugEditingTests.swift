import Foundation
import Testing
import YcodeBuild
@testable import YcodeDebug
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// A debug adapter for the editing gestures, in the DAP specification's
/// shapes: a loop in `main.swift` whose line-2 breakpoint (id 1) is hit
/// `hits` times (`count` = 2, 3, …) before the program exits. It answers
/// `evaluate` (watch and repl), `setVariable`, `readMemory`,
/// `disassemble`, and records what it was sent.
final class EditingScriptedAdapter: DAPTransport, @unchecked Sendable {
    let file: String
    private var receiving: (@Sendable (Data?) -> Void)?
    private var decoder = DAPFraming.Decoder()
    private let lock = NSRecursiveLock()
    private var seq = 2000
    private(set) var requests: [(command: String, arguments: JSON)] = []
    var hits = 1
    /// The stop is in a runtime function without source (a Swift error).
    var sourceless = false
    private var count = 2
    private var overrides: [String: String] = [:]

    init(file: String, hits: Int = 1) {
        self.file = file
        self.hits = hits
    }

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }

    func arguments(of command: String) -> [JSON] { lock.withLock { requests.filter { $0.command == command }.map(\.arguments) } }

    private func emit(_ msg: [String: JSON]) {
        seq += 1
        var m = msg
        m["seq"] = .number(Double(seq))
        receiving?(DAPFraming.frame(JSON.object(m).encoded()))
    }

    private func value(_ name: String, _ fallback: String) -> String { overrides[name] ?? fallback }

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        for raw in decoder.append(data) {
            guard let req = try? JSON.decode(raw), req["type"]?.string == "request", let cmd = req["command"]?.string else { continue }
            let args = req["arguments"] ?? .null
            requests.append((cmd, args))
            var body: JSON = [:]
            var after: [(String, JSON)] = []
            var success = true
            let stop: (String, JSON) = ("stopped", ["reason": "breakpoint", "threadId": 1, "hitBreakpointIds": [1], "description": "breakpoint 1.1"])
            switch cmd {
            case "initialize":
                body = ["supportsReadMemoryRequest": true, "supportsSetVariable": true, "supportsDisassembleRequest": true,
                        "exceptionBreakpointFilters": [["filter": "cpp_throw", "label": "C++ Throw"], ["filter": "cpp_catch", "label": "C++ Catch"],
                                                       ["filter": "swift_throw", "label": "Swift Throw"]]]
                after = [("initialized", [:])]
            case "launch": after = [("process", ["systemProcessId": 4242])]
            case "setBreakpoints":
                let list = args["breakpoints"]?.array ?? []
                body = ["breakpoints": .array(list.enumerated().map { ["id": .number(Double($0.offset + 1)), "verified": true, "line": $0.element["line"] ?? 0] })]
            case "setFunctionBreakpoints", "setExceptionBreakpoints":
                body = ["breakpoints": .array((args["breakpoints"]?.array ?? args["filters"]?.array ?? []).enumerated().map { _ in ["verified": true] })]
            case "configurationDone": after = [stop]
            case "threads": body = ["threads": [["id": 1, "name": "Thread 1"]]]
            case "stackTrace":
                let main: JSON = ["id": 9, "name": "main", "line": 2, "column": 1, "source": ["path": .string(file)],
                                  "instructionPointerReference": "0x1004"]
                body = ["stackFrames": sourceless ? [["id": 8, "name": "swift_willThrow", "line": 1, "column": 0,
                                                      "instructionPointerReference": "0x1004"], main] : [main]]
            case "scopes": body = ["scopes": [["name": "Locals", "variablesReference": 5, "expensive": false]]]
            case "variables":
                switch args["variablesReference"]?.int {
                case 5: body = ["variables": [["name": "count", "value": .string(value("count", "\(count)")), "type": "Int", "variablesReference": 0,
                                               "memoryReference": "0x1000"],
                                              ["name": "stats", "value": "Demo.Stats", "type": "Demo.Stats", "variablesReference": 7]]]
                case 7: body = ["variables": [["name": "round", "value": .string(value("round", "1")), "type": "Int", "variablesReference": 0]]]
                default: body = ["variables": []]
                }
            case "evaluate":
                let e = args["expression"]?.string ?? ""
                switch (args["context"]?.string ?? "", e) {
                case (_, "count"): body = ["result": .string(value("count", "\(count)")), "type": "Int", "variablesReference": 0]
                case (_, "count * 2"): body = ["result": .string("\((Int(value("count", "\(count)")) ?? 0) * 2)"), "type": "Int", "variablesReference": 0]
                case ("repl", "bt"): body = ["result": "* thread #1, frame #0: main at main.swift:2\n", "variablesReference": 0]
                case ("repl", _) where e.hasPrefix("expression -- ") && e.contains(" = "):
                    // LLDB's assignment: "<path> = <value>".
                    let parts = e.dropFirst("expression -- ".count).components(separatedBy: " = ")
                    overrides[parts[0].split(separator: ".").last.map(String.init) ?? parts[0]] = parts[1]
                    body = ["result": "() $R0 = {}\n", "variablesReference": 0]
                default:
                    success = false
                    body = ["error": ["id": 1, "format": "error: use of undeclared identifier"]]
                }
            case "setVariable":
                let name = args["name"]?.string ?? "", v = args["value"]?.string ?? ""
                if name == "round" {
                    // As Swift 6.4's lldb-dap answers for Swift integers.
                    success = false
                    body = ["error": ["id": 3, "format": "Invalid encoding."]]
                } else {
                    overrides[name] = v
                    body = ["value": .string(v)]
                }
            case "readMemory":
                let offset = args["offset"]?.int ?? 0, n = args["count"]?.int ?? 0
                let bytes = (0..<n).map { UInt8(truncatingIfNeeded: offset + $0 + 0x41) }
                body = ["address": .string(String(format: "0x%llx", 0x1000 + offset)), "data": .string(Data(bytes).base64EncodedString())]
            case "disassemble":
                body = ["instructions": [["address": "0x1000", "instruction": "pushq %rbp"],
                                         ["address": "0x1004", "instruction": "movq %rsp, %rbp", "symbol": "main"],
                                         ["address": "0x1008", "instruction": "retq"]]]
            case "continue":
                hits -= 1
                if hits > 0 {
                    count += 1
                    after = [("continued", ["threadId": 1]), stop]
                } else {
                    after = [("continued", ["threadId": 1]), ("exited", ["exitCode": 0]), ("terminated", [:])]
                }
            case "next": after = [("continued", ["threadId": 1]), ("stopped", ["reason": "step", "threadId": 1])]
            case "disconnect": after = [("terminated", [:])]
            default: break
            }
            var response: [String: JSON] = ["type": "response", "request_seq": req["seq"]!, "command": .string(cmd), "success": .bool(success), "body": body]
            if !success { response["message"] = .string(cmd == "setVariable" ? "Invalid encoding." : "error: use of undeclared identifier") }
            emit(response)
            for (event, b) in after { emit(["type": "event", "event": .string(event), "body": b]) }
        }
    }

    func close() { receiving?(nil) }
}

@MainActor
final class FakePasteboard: DebugPasteboard {
    var strings: [String] = []
    func setString(_ s: String) { strings.append(s) }
}

@MainActor
@Suite(.serialized) struct ShellDebugEditingTests {
    func model(_ pkg: TempPackage) throws -> WorkspaceShellModel {
        try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
    }

    func wait(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition(), "timed out waiting for \(what)")
    }

    // MARK: The breakpoint editor

    @Test func theEditorSetsConditionIgnoreCountActionsAndContinue() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let d = m.debug
        let main = pkg.path("Sources/Demo/main.swift")
        d.gutterClick(file: main, line: 2)
        d.editBreakpoint(file: main, line: 2, anchor: CGRect(x: 0, y: 40, width: 30, height: 16))
        #expect(d.breakpointEditorTitle == "main.swift:2")
        // A trailing space stays while typing.
        d.editorCondition = "count == "
        d.editorCondition = "count == 3"
        d.editorIgnoreCount = "2"
        #expect(d.editorIgnoreCount == "2")
        d.addBreakpointAction()
        d.setBreakpointActionText("count is @count@", at: 0)
        d.addBreakpointAction(after: 0)
        d.setBreakpointActionKind(.command, at: 1)
        d.setBreakpointActionText("bt", at: 1)
        d.editorAutoContinue = true
        var b = try #require(d.breakpoints.breakpoint(file: main, line: 2))
        #expect(b.condition == "count == 3" && b.ignoreCount == 2 && b.autoContinue)
        #expect(b.actions == [.log("count is @count@"), .debuggerCommand("bt")])
        // Two actions: Ycode runs them; the adapter gets the condition and ignore count.
        #expect(b.dap == SourceBreakpoint(line: 2, condition: "count == 3", hitCondition: "2") && b.runsActionsInIDE)
        #expect(d.marks(for: main).breakpoints[2]?.isCustomized == true)
        #expect(d.breakpointRows.last?.title == "line 2 [count == 3]")
        // One log action that continues is lldb-dap's log point, in its syntax.
        d.removeBreakpointAction(at: 1)
        b = try #require(d.breakpoints.breakpoint(file: main, line: 2))
        #expect(b.dap.logMessage == "count is {count}" && !b.runsActionsInIDE)
        // %H needs Ycode.
        d.setBreakpointActionText("hit %H", at: 0)
        #expect(d.breakpoints.breakpoint(file: main, line: 2)?.runsActionsInIDE == true)
        // A kind change keeps the text between message and command.
        d.setBreakpointActionKind(.command, at: 0)
        #expect(d.editorActions == [.debuggerCommand("hit %H")])
        d.closeBreakpointEditor()
        #expect(d.breakpointEditor == nil)
        // The navigator's Edit Breakpoint opens it for the row.
        let row = try #require(d.breakpointRows.last)
        d.editBreakpointRow(row.id)
        #expect(d.breakpointEditor?.target == .line(file: main, line: 2) && d.breakpointEditor?.anchor == nil)
        d.noteBreakpointRowFrame(row.id, CGRect(x: 10, y: 100, width: 250, height: 22))
        #expect(d.breakpointEditor?.anchor == CGRect(x: 10, y: 100, width: 250, height: 22))
    }

    @Test func actionsAndOptionsArePersisted() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let main = pkg.path("Sources/Demo/main.swift")
        let a = try model(pkg)
        a.debug.restoreBreakpoints()
        a.debug.gutterClick(file: main, line: 2)
        a.session.breakpoints.edit(file: main, line: 2) { $0.actions = [.log("x"), .debuggerCommand("bt"), .sound("bell")]; $0.autoContinue = true }
        a.session.breakpoints.symbolic = [.init(name: "report")]
        let b = try model(pkg)
        b.debug.restoreBreakpoints()
        #expect(b.debug.breakpoints.breakpoint(file: main, line: 2)?.actions == [.log("x"), .debuggerCommand("bt"), .sound("bell")])
        #expect(b.debug.breakpoints.breakpoint(file: main, line: 2)?.autoContinue == true)
        #expect(b.debug.breakpoints.symbolic.map(\.name) == ["report"])
    }

    @Test func messagePartsAndTheAdapterForm() {
        #expect(BreakpointMessage.parts("i=@i@ {j} %B #%H") == [.text("i="), .expression("i"), .text(" "), .expression("j"), .text(" "),
                                                                 .breakpointName, .text(" #"), .hitCount])
        #expect(BreakpointMessage.parts("a@b, {c") == [.text("a@b, {c")])
        #expect(BreakpointMessage.dapLogMessage("v=@v@") == "v={v}")
        #expect(BreakpointMessage.needsIDE("%H") && !BreakpointMessage.needsIDE("@x@"))
    }

    @Test func topLevelCodeAfterFunctionsBelongsToNone() {
        let text = "func check(_ v: Int) throws {\n    if v > 4 { throw E.big }\n}\n\nfor i in 1...5 {\n    report(i)\n}\n"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(SourceSymbolLocator.symbol(in: lines, line: 2)?.name == "check(_:)")
        #expect(SourceSymbolLocator.symbol(in: lines, line: 6) == nil)
    }

    // MARK: The "+" menu

    @Test func plusMenuAddsSymbolicSwiftErrorAndExceptionBreakpoints() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let d = m.debug
        d.addSymbolicBreakpoint()
        #expect(m.navigator == .breakpoints && d.breakpointEditor?.target == .symbolic(index: 0) && d.breakpointEditor?.focusesSymbol == true)
        #expect(d.breakpointRows.map(\.title).contains("Symbol"))
        d.editorSymbol = "report"
        d.editorCondition = "count > 2"
        d.closeBreakpointEditor()
        #expect(d.breakpoints.symbolic == [.init(name: "report", condition: "count > 2")])
        #expect(d.breakpointRows.map(\.title).contains("report [count > 2]"))
        // Left without a symbol, the new row goes away.
        d.addSymbolicBreakpoint()
        d.closeBreakpointEditor()
        #expect(d.breakpoints.symbolic.count == 1)

        #expect(m.isEnabled(.createSwiftErrorBreakpoint))
        m.perform(.createSwiftErrorBreakpoint)
        #expect(d.breakpoints.exceptionFilters == ["swift_throw"] && !m.isEnabled(.createSwiftErrorBreakpoint))
        #expect(d.breakpointRows.map(\.title).contains("Swift errors"))
        d.addExceptionBreakpoint()
        #expect(d.breakpoints.exceptionFilters.contains("cpp_throw"))
        #expect(d.breakpointEditor?.target == .exception(filter: "cpp_throw") && d.breakpointEditorTitle == "Exception Breakpoint")
        d.editorBreaksOnCatch = true
        #expect(d.breakpoints.exceptionFilters.contains("cpp_catch") && !d.breakpoints.exceptionFilters.contains("cpp_throw"))
        #expect(d.breakpointEditor?.target == .exception(filter: "cpp_catch"))
        d.closeBreakpointEditor()

        // The session sends them as function and exception breakpoints.
        let adapter = EditingScriptedAdapter(file: pkg.path("Sources/Demo/main.swift"))
        await m.session.debug(program: pkg.path(".build/debug/Demo"), adapter: adapter)
        await wait("the configuration") { !adapter.arguments(of: "configurationDone").isEmpty }
        #expect(adapter.arguments(of: "setFunctionBreakpoints").last?["breakpoints"]?.array?.first?["name"]?.string == "report")
        #expect(adapter.arguments(of: "setFunctionBreakpoints").last?["breakpoints"]?.array?.first?["condition"]?.string == "count > 2")
        let filters = adapter.arguments(of: "setExceptionBreakpoints").last?["filters"]?.array?.compactMap(\.string) ?? []
        #expect(Set(filters) == ["swift_throw", "cpp_catch"])
        m.perform(.stop)
        await wait("the end") { !m.debug.isDebugging }
    }

    // MARK: Actions Ycode runs

    @Test func actionsRunAtEachHitAndContinue() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let main = pkg.path("Sources/Demo/main.swift")
        m.debug.gutterClick(file: main, line: 2)
        m.session.breakpoints.edit(file: main, line: 2) {
            $0.actions = [.log("count is @count@ (%B, hit %H)"), .debuggerCommand("bt")]
            $0.autoContinue = true
        }
        let adapter = EditingScriptedAdapter(file: main, hits: 2)
        await m.session.debug(program: pkg.path(".build/debug/Demo"), adapter: adapter)
        await wait("the exit") { !m.debug.isDebugging && m.console.contains("exit code") }
        #expect(m.console.contains("count is 2 (main.swift:2, hit 1)\n"))
        #expect(m.console.contains("count is 3 (main.swift:2, hit 2)\n"))
        #expect(m.console.contains("frame #0: main at main.swift:2"))
        // Never shown as paused; the log's expression was evaluated as a watch.
        #expect(m.session.stopCount == 0)
        #expect(adapter.arguments(of: "evaluate").contains { $0["context"]?.string == "watch" && $0["expression"]?.string == "count" })
        #expect(adapter.arguments(of: "continue").count == 2)
    }

    @Test func aLogMessageThatStopsLogsThenShowsTheStop() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let main = pkg.path("Sources/Demo/main.swift")
        m.debug.gutterClick(file: main, line: 2)
        m.session.breakpoints.edit(file: main, line: 2) { $0.actions = [.log("at {count}")] }
        let adapter = EditingScriptedAdapter(file: main)
        await m.session.debug(program: pkg.path(".build/debug/Demo"), adapter: adapter)
        await wait("the stop") { m.debug.isPaused && !m.debug.variables.isEmpty }
        #expect(m.console.contains("at 2\n"))
        #expect(m.debug.marks(for: main).annotation == "Thread 1: breakpoint 1.1 (1)")
        m.perform(.stop)
        await wait("the end") { !m.debug.isDebugging }
    }

    // MARK: Variables view

    @Test func watchEditCopyAndViewMemory() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let d = m.debug
        let pasteboard = FakePasteboard()
        d.pasteboard = pasteboard
        let main = pkg.path("Sources/Demo/main.swift")
        d.gutterClick(file: main, line: 2)
        let adapter = EditingScriptedAdapter(file: main)
        await m.session.debug(program: pkg.path(".build/debug/Demo"), adapter: adapter)
        await wait("the stop") { d.isPaused && !d.variables.isEmpty }

        // Add Expression…: listed first, evaluated as a watch.
        d.beginAddingExpression()
        d.expressionText = "count * 2"
        d.commitExpression()
        await wait("the watch") { d.variableRows.first?.text == "count * 2: Int = 4" }
        #expect(d.variableRows.first?.isWatch == true && d.variableRows.first?.badge == nil)
        // Watch "count" adds the variable; a second time it is not added again.
        let count = try #require(d.variableRows.first { $0.name == "count" && !$0.isWatch })
        d.watch(count)
        d.watch(count)
        await wait("the second watch") { d.variableRows.filter(\.isWatch).map(\.name) == ["count * 2", "count"] }
        #expect(d.watchExpressions == ["count * 2", "count"])

        // Edit Value: setVariable in the frame's scope; the view reloads.
        d.beginEditing(count)
        #expect(d.editingVariable == count.id && d.editText == "2")
        d.editText = "7"
        d.commitEditing()
        await wait("the new value") { d.variableRows.first { $0.name == "count" && !$0.isWatch }?.value == "7" }
        #expect(adapter.arguments(of: "setVariable").last?["variablesReference"]?.int == 5)
        await wait("the watches again") { d.variableRows.first?.value == "14" }
        // A child is set in its aggregate.
        let stats = try #require(d.variableRows.first { $0.name == "stats" })
        d.setVariableExpanded(stats, true)
        await wait("the children") { d.variableRows.contains { $0.name == "round" } }
        let round = try #require(d.variableRows.first { $0.name == "round" })
        #expect(d.expression(of: round) == "stats.round")
        d.beginEditing(round)
        d.editText = "5"
        d.commitEditing()
        // The adapter cannot set it; LLDB assigns it by its path.
        await wait("the child's value") { d.variableRows.first { $0.name == "round" }?.value == "5" }
        #expect(adapter.arguments(of: "setVariable").last?["variablesReference"]?.int == 7)
        #expect(adapter.arguments(of: "evaluate").contains { $0["expression"]?.string == "expression -- stats.round = 5" })
        // A watch expression's own row is not editable.
        d.beginEditing(try #require(d.variableRows.first))
        #expect(d.editingVariable == nil)

        // Copy and Copy Value.
        let edited = try #require(d.variableRows.first { $0.name == "count" && !$0.isWatch })
        d.copy(edited)
        d.copyValue(edited)
        #expect(pasteboard.strings == ["(Int) count = 7", "7"])

        // View Memory of "count": its memory reference, a page of 256 bytes.
        #expect(m.isEnabled(.viewMemory))
        d.viewMemory(of: edited)
        await wait("the memory") { d.memoryBrowser?.block != nil }
        let lines = d.memoryBrowser?.lines ?? []
        #expect(d.memoryBrowser?.title == "Memory of \"count\"")
        #expect(lines.count == 16)
        #expect(lines.first == .init(address: "0x0000000000001000", hex: "41 42 43 44 45 46 47 48  49 4a 4b 4c 4d 4e 4f 50",
                                     ascii: "ABCDEFGHIJKLMNOP"))
        d.pageMemory(forward: true)
        await wait("the next page") { d.memoryBrowser?.lines.first?.address == "0x0000000000001100" }
        #expect(adapter.arguments(of: "readMemory").last?["memoryReference"]?.string == "0x1000")
        #expect(adapter.arguments(of: "readMemory").last?["offset"]?.int == 256)
        d.closeMemoryBrowser()

        // Delete Expression.
        d.deleteWatch(try #require(d.variableRows.first))
        await wait("one watch") { d.variableRows.filter(\.isWatch).map(\.name) == ["count"] }
        m.perform(.stop)
        await wait("the end") { !d.isDebugging }
        // The watch expressions stay for the next run.
        #expect(d.watchExpressions == ["count"])
    }

    @Test func aFrameWithoutSourceShowsItsDisassembly() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let d = m.debug
        let main = pkg.path("Sources/Demo/main.swift")
        d.gutterClick(file: main, line: 2)
        let adapter = EditingScriptedAdapter(file: main)
        adapter.sourceless = true
        await m.session.debug(program: pkg.path(".build/debug/Demo"), adapter: adapter)
        await wait("the disassembly") { d.isPaused && d.showsDisassembly }
        #expect(d.disassemblyTitle == "swift_willThrow (disassembly)" && !d.alwaysShowsDisassembly)
        // The user frame shows its source again.
        d.selectDebugRow(ShellDebugModel.frameRowID(9))
        await wait("the source") { !d.showsDisassembly }
        m.perform(.stop)
        await wait("the end") { !d.isDebugging }
    }

    // MARK: Debug Workflow and the gutter

    @Test func debugWorkflowTogglesAndDisassembly() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let d = m.debug
        #expect(d.isChecked(.toggleNavigateToSourceOnPause) == true && d.isChecked(.toggleAlwaysShowDisassembly) == false)
        #expect(d.isChecked(.stepOver) == nil)
        #expect(ShellCommand.toggleAlwaysShowDisassembly.title(in: m.menuContext) == "Always Show Disassembly")
        #expect(ShellCommand.viewMemory.title(in: m.menuContext) == "View Memory")
        #expect(ShellCommand.viewMemory.menuCommand != nil && ShellCommand.createSymbolicBreakpoint.menuCommand != nil)
        #expect(!m.isEnabled(.viewMemory))
        m.perform(.toggleNavigateToSourceOnPause)
        #expect(d.isChecked(.toggleNavigateToSourceOnPause) == false)
        m.perform(.toggleNavigateToSourceOnPause)

        let main = pkg.path("Sources/Demo/main.swift")
        d.gutterClick(file: main, line: 2)
        await m.session.debug(program: pkg.path(".build/debug/Demo"), adapter: EditingScriptedAdapter(file: main))
        await wait("the stop") { d.isPaused && !d.variables.isEmpty }
        m.perform(.toggleAlwaysShowDisassembly)
        await wait("the disassembly") { d.showsDisassembly }
        #expect(d.disassemblyLines == ["0x1000  pushq %rbp", "0x1004  movq %rsp, %rbp    ; main", "0x1008  retq"])
        #expect(d.disassemblyPCIndex == 1 && d.disassemblyTitle == "main (disassembly)")
        m.perform(.toggleAlwaysShowDisassembly)
        await wait("the source again") { !d.showsDisassembly }
        // The gutter's context menu belongs to the breakpoint under the pointer.
        d.pointerInGutter(file: main, line: 2)
        #expect(d.gutterMenuBreakpoint(file: main)?.line == 2)
        d.pointerInGutter(file: main, line: 1)
        #expect(d.gutterMenuBreakpoint(file: main) == nil)
        d.revealInBreakpointNavigator(file: main, line: 2)
        #expect(m.navigator == .breakpoints && d.breakpointSelection == d.breakpointRows.last?.id)
        m.perform(.stop)
        await wait("the end") { !d.isDebugging }
    }
}
