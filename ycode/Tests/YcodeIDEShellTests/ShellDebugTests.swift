import Foundation
import Testing
import YcodeBuild
@testable import YcodeDebug
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// A debug adapter that answers in the DAP specification's shapes: one
/// thread stopped in `main.swift` at line 2 (breakpoint 1), a local Int
/// and a struct with two fields, a step to line 3, then the exit.
final class ShellScriptedAdapter: DAPTransport, @unchecked Sendable {
    let file: String
    private var receiving: (@Sendable (Data?) -> Void)?
    private var decoder = DAPFraming.Decoder()
    private let lock = NSRecursiveLock()
    private var seq = 1000
    private(set) var commands: [String] = []
    private(set) var breakpointLines: [Int] = []
    var line = 2

    init(file: String) { self.file = file }

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }

    private func emit(_ msg: [String: JSON]) {
        seq += 1
        var m = msg
        m["seq"] = .number(Double(seq))
        receiving?(DAPFraming.frame(JSON.object(m).encoded()))
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
            case "launch": after = [("process", ["systemProcessId": .number(Double(ProcessInfo.processInfo.processIdentifier))])]
            case "setBreakpoints":
                let list = args["breakpoints"]?.array ?? []
                if args["source"]?["path"]?.string == file { breakpointLines = list.compactMap { $0["line"]?.int } }
                body = ["breakpoints": .array(list.enumerated().map { ["id": .number(Double($0.offset + 1)), "verified": true, "line": $0.element["line"] ?? 0] })]
            case "configurationDone":
                after = [("output", ["category": "stdout", "output": "hello\n"]),
                         ("stopped", ["reason": "breakpoint", "threadId": 1, "hitBreakpointIds": [1]])]
            case "threads": body = ["threads": [["id": 1, "name": "Thread 1 queue = com.apple.main-thread"]]]
            case "stackTrace":
                body = ["stackFrames": [["id": 9, "name": "main", "line": .number(Double(line)), "column": 1, "source": ["path": .string(file)]],
                                        ["id": 10, "name": "__libc_start_main", "line": 0, "column": 0]]]
            case "scopes":
                body = ["scopes": [["name": "Locals", "variablesReference": 5, "expensive": false],
                                   ["name": "Registers", "variablesReference": 6, "expensive": false]]]
            case "variables":
                switch args["variablesReference"]?.int {
                case 5: body = ["variables": [["name": "count", "value": .string(line == 2 ? "2" : "3"), "type": "Int", "variablesReference": 0],
                                              ["name": "stats", "value": "Demo.Stats", "type": "Demo.Stats", "variablesReference": 7]]]
                case 7: body = ["variables": [["name": "round", "value": "1", "type": "Int", "variablesReference": 0],
                                              ["name": "total", "value": "10", "type": "Int", "variablesReference": 0]]]
                default: body = ["variables": [["name": "rip", "value": "0x1000", "variablesReference": 0]]]
                }
            case "evaluate": body = ["result": .string("(Int) $R0 = \(args["expression"]?.string == "count * 2" ? "4" : "0")"), "variablesReference": 0]
            case "next":
                line = 3
                after = [("continued", ["threadId": 1]), ("stopped", ["reason": "step", "threadId": 1])]
            case "continue": after = [("continued", ["threadId": 1]), ("exited", ["exitCode": 0]), ("terminated", [:])]
            case "disconnect": after = [("terminated", [:])]
            default: break
            }
            emit(["type": "response", "request_seq": req["seq"]!, "command": .string(cmd), "success": true, "body": body])
            for (event, b) in after { emit(["type": "event", "event": .string(event), "body": b]) }
        }
    }

    func close() { receiving?(nil) }
}

@MainActor
@Suite(.serialized) struct ShellDebugTests {
    func model(_ pkg: TempPackage) throws -> WorkspaceShellModel {
        try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
    }

    func wait(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition(), "timed out waiting for \(what)")
    }

    // MARK: Gutter and Breakpoint navigator

    @Test func gutterClicksAddDisableAndDragBreakpoints() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let main = pkg.path("Sources/Demo/main.swift")
        m.debug.gutterClick(file: main, line: 2)
        #expect(m.debug.marks(for: main).breakpoints[2] == .init(isEnabled: true, isCustomized: false))
        // A second click disables it; a third enables it again.
        m.debug.gutterClick(file: main, line: 2)
        #expect(m.debug.marks(for: main).breakpoints[2]?.isEnabled == false)
        m.debug.gutterClick(file: main, line: 2)
        // Dragged along the gutter it moves; out of it, it is deleted.
        m.debug.gutterDrag(file: main, from: 2, to: 1)
        #expect(m.debug.marks(for: main).breakpoints.keys.sorted() == [1])
        m.debug.gutterDrag(file: main, from: 1, to: nil)
        #expect(m.debug.marks(for: main).breakpoints.isEmpty)
        // ⌘Y deactivates them all (drawn pale).
        m.debug.gutterClick(file: main, line: 2)
        m.perform(.toggleBreakpointsActive)
        #expect(m.debug.marks(for: main).breakpointsActive == false)
        #expect(ShellCommand.toggleBreakpointsActive.title(in: m.menuContext) == "Activate Breakpoints")
    }

    @Test func breakpointNavigatorListsFilesLinesAndIDs() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        #expect(m.debug.breakpointRows.isEmpty)
        let main = pkg.path("Sources/Demo/main.swift"), greeting = pkg.path("Sources/DemoCore/Greeting.swift")
        m.debug.gutterClick(file: main, line: 2)
        m.debug.gutterClick(file: greeting, line: 4)
        // Files in path order (Sources/Demo before Sources/DemoCore).
        let rows = m.debug.breakpointRows
        #expect(rows.map(\.title) == ["Demo  2 Breakpoints", "main.swift", "line 2", "Greeting.swift", "line 4"])
        #expect(rows.map(\.level) == [0, 1, 2, 1, 2])
        #expect(rows[2].trailing == "ID 1.1" && rows[4].trailing == "ID 2.1")
        #expect(rows[2].marker == true)
        // The marker disables it; the row stays, dimmed.
        m.debug.toggleBreakpointEnabled(rows[2].id)
        #expect(m.debug.breakpointRows[2].marker == false && m.debug.breakpointRows[2].isDimmed)
        // Selecting a row opens its line.
        m.debug.selectBreakpointRow(rows[4].id)
        #expect(m.document?.path == greeting && m.editor?.buffer.caretLine == 3)
        // Collapsing a file hides its rows; Delete Breakpoint removes one.
        m.debug.setBreakpointRowExpanded(rows[1].id, false)
        #expect(m.debug.breakpointRows.map(\.title) == ["Demo  2 Breakpoints", "main.swift", "Greeting.swift", "line 4"])
        m.debug.deleteBreakpoint(rows[4].id)
        #expect(m.debug.breakpointRows.first?.title == "Demo  1 Breakpoint")
        m.perform(.deleteAllBreakpoints)
        #expect(m.debug.breakpointRows.isEmpty && !m.isEnabled(.deleteAllBreakpoints))
    }

    @Test func createBreakpointAtCurrentLineTogglesTheCaretsLine() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let main = pkg.path("Sources/Demo/main.swift")
        #expect(!m.isEnabled(.toggleBreakpointAtCurrentLine))
        m.open(main, line: 2)
        m.perform(.toggleBreakpointAtCurrentLine)
        #expect(m.debug.breakpoints.breakpoint(file: main, line: 2) != nil)
        #expect(m.menuContext.caretLineBreakpointsEnabled == true)
        #expect(ShellCommand.toggleBreakpointsEnabledAtCurrentLine.title(in: m.menuContext) == "Disable Breakpoints at Current Line")
        m.perform(.toggleBreakpointsEnabledAtCurrentLine)
        #expect(m.debug.breakpoints.breakpoint(file: main, line: 2)?.isEnabled == false)
        m.perform(.toggleBreakpointAtCurrentLine)
        #expect(m.debug.breakpoints.isEmpty)
    }

    @Test func breakpointsPersistWithTheWorkspace() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let main = pkg.path("Sources/Demo/main.swift")
        let a = try model(pkg)
        a.debug.restoreBreakpoints()
        a.debug.gutterClick(file: main, line: 2)
        let b = try model(pkg)
        b.debug.restoreBreakpoints()
        #expect(b.debug.breakpoints.all.map(\.line) == [2])
    }

    // MARK: A debug session

    @Test func aBreakpointStopShowsFramesVariablesAndStepsToTheExit() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let main = pkg.path("Sources/Demo/main.swift")
        m.debug.gutterClick(file: main, line: 2)
        let adapter = ShellScriptedAdapter(file: main)
        #expect(!m.isEnabled(.pauseOrContinue) && !m.isEnabled(.stepOver))
        await m.session.debug(program: pkg.path(".build/debug/Demo"), adapter: adapter)
        await wait("the stop") { m.debug.isPaused && !m.debug.variables.isEmpty && m.navigator == .debug }
        // The breakpoint went to lldb-dap before configurationDone.
        #expect(adapter.breakpointLines == [2])
        #expect(adapter.commands.firstIndex(of: "setBreakpoints")! < adapter.commands.firstIndex(of: "configurationDone")!)

        // The stop: activity, Debug navigator, the line opened and marked.
        #expect(m.activityText == "Paused Demo")
        #expect(m.isDebugAreaShown && m.isNavigatorShown)
        #expect(m.document?.path == main && m.editor?.buffer.caretLine == 1 && m.editor?.buffer.selection.isEmpty == true)
        let marks = m.debug.marks(for: main)
        #expect(marks.pcLine == 2)
        #expect(marks.annotation == "Thread 1: breakpoint 1.1 (1)")
        #expect(m.debug.barPath == "Demo › Thread 1 › 0 main")

        // Debug navigator: the process, gauges, the thread and its frames.
        let rows = m.debug.debugRows
        #expect(rows.first?.title == "Demo  PID \(ProcessInfo.processInfo.processIdentifier)")
        #expect(rows.filter { $0.kind == .gauge }.map(\.title) == ["CPU", "Memory", "Energy Impact", "Disk", "Network"])
        #expect(rows.first { $0.kind == .thread }?.title == "Thread 1  Queue: com.apple.main-thread (serial)")
        #expect(rows.filter { $0.kind == .frame }.map(\.title) == ["0 main", "1 __libc_start_main"])
        #expect(rows.contains { $0.kind == .separator })
        #expect(rows.first { $0.title == "1 __libc_start_main" }?.isDimmed == true)
        #expect(m.debug.debugSelection == rows.first { $0.title == "0 main" }?.id)

        // Variables: badges, types, registers left out; a struct expands.
        var vars = m.debug.variableRows
        #expect(vars.map(\.text) == ["count: Int = 2", "stats: Demo.Stats = Demo.Stats"])
        #expect(vars.map(\.badge) == ["L", "L"])
        #expect(vars[1].isExpandable && !vars[0].isExpandable)
        m.debug.setVariableExpanded(vars[1], true)
        await wait("the children") { m.debug.variableRows.count == 4 }
        vars = m.debug.variableRows
        #expect(vars.map(\.text) == ["count: Int = 2", "stats: Demo.Stats = Demo.Stats", "round: Int = 1", "total: Int = 10"])
        #expect(vars.map(\.level) == [0, 0, 1, 1] && vars[2].badge == nil)
        // The filter and the scope pop-up.
        m.debug.variableFilter = "cou"
        #expect(m.debug.variableRows.map(\.name) == ["count"])
        m.debug.variableFilter = ""

        // Menus while paused: Continue, steps enabled.
        #expect(ShellCommand.pauseOrContinue.title(in: m.menuContext) == "Continue")
        #expect(m.isEnabled(.stepOver) && m.isEnabled(.stepInto) && m.isEnabled(.stepOut))

        // The console: the program's output, then an expression.
        #expect(m.console.contains("hello"))
        m.debug.consoleInput = "count * 2"
        m.debug.submitConsoleLine()
        await wait("the expression") { m.console.contains("$R0 = 4") }
        #expect(m.console.contains("(lldb) count * 2\n"))
        #expect(m.debug.consoleInput.isEmpty)
        m.debug.consoleHistory(older: true)
        #expect(m.debug.consoleInput == "count * 2")
        m.debug.consoleHistory(older: false)
        #expect(m.debug.consoleInput.isEmpty)
        m.debug.consoleFilter = .target
        #expect(m.debug.consoleText == "hello\n")
        m.debug.consoleFilter = .all

        // Step Over: a new stop on line 3, the child still expanded.
        let stops = m.session.stopCount
        m.perform(.stepOver)
        await wait("the step") { m.session.stopCount > stops && m.debug.isPaused && m.debug.marks(for: main).pcLine == 3 }
        await wait("the reloaded children") { m.debug.variableRows.first?.value == "3" && m.debug.variableRows.count == 4 }
        await m.debug.waitForChildren()
        #expect(m.debug.variableRows.map(\.name) == ["count", "stats", "round", "total"])
        #expect(m.editor?.buffer.caretLine == 2)

        // Continue to the exit.
        m.perform(.pauseOrContinue)
        await wait("the exit") { !m.debug.isDebugging && !m.isBusy }
        #expect(m.console.contains("Program ended with exit code: 0"))
        #expect(m.debug.debugRows.isEmpty && m.debug.variableRows.isEmpty)
        #expect(m.debug.marks(for: main).pcLine == nil)
        #expect(m.activityText.hasPrefix("Finished running Demo"))
    }

    @Test func selectingAFrameShowsItsLine() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let main = pkg.path("Sources/Demo/main.swift")
        m.debug.gutterClick(file: main, line: 2)
        await m.session.debug(program: pkg.path(".build/debug/Demo"), adapter: ShellScriptedAdapter(file: main))
        await wait("the stop") { m.debug.isPaused && m.navigator == .debug }
        // A frame without source keeps the editor as it is.
        let system = m.debug.debugRows.first { $0.title == "1 __libc_start_main" }!
        m.debug.selectDebugRow(system.id)
        #expect(m.debug.debugSelection == system.id)
        #expect(m.document?.path == main)
        // Collapsing the thread hides its frames.
        let thread = m.debug.debugRows.first { $0.kind == .thread }!
        m.debug.setDebugRowExpanded(thread.id, false)
        #expect(!m.debug.debugRows.contains { $0.kind == .frame })
        m.perform(.stop)
        await wait("the end") { !m.debug.isDebugging }
        #expect(m.console.contains(DebugPresentation.killedLine))
    }

    @Test func argumentsAreReadFromTheEnclosingDeclaration() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let file = pkg.path("Sources/Demo/Args.swift")
        try """
        struct S {
            init(width w: Int,
                 height: Int) {
                print(w)
            }
            func report(_ values: [Int], label: String) {
                let total = values.count
                print(total)
            }
        }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        #expect(ShellDebugModel.parameterNames(file: file, line: 4) == ["w", "width", "height"])
        #expect(ShellDebugModel.parameterNames(file: file, line: 8) == ["values", "label"])
        #expect(ShellDebugModel.parameterNames(file: file, line: 1) == [])
        #expect(ShellDebugModel.parameterNames(file: file + ".missing", line: 3) == [])
    }

    @Test func systemFramesOnLinuxAreNotUserFrames() {
        func frame(_ file: String?) -> StackFrame {
            var j: [String: JSON] = ["id": 1, "name": "f", "line": 1]
            if let file { j["source"] = ["path": .string(file)] }
            return StackFrame(JSON.object(j))
        }
        #expect(DebugPresentation.isUserFrame(frame("/home/u/P/Sources/P/main.swift")))
        #expect(!DebugPresentation.isUserFrame(frame("./csu/../sysdeps/nptl/libc_start_call_main.h")))
        #expect(!DebugPresentation.isUserFrame(frame("/usr/include/stdio.h")))
        #expect(!DebugPresentation.isUserFrame(frame(nil)))
    }

    @Test func registersAppearOnlyInTheAllVariablesScope() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        #expect(VariableScope.auto.includes("count") && !VariableScope.auto.includes("$rax"))
        #expect(VariableScope.all.includes("$rax"))
        #expect(m.debug.variableScope == .auto)
    }
}
