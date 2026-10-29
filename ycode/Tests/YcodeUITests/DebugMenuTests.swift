import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeDebug
@testable import YcodeUI

/// A recording in-memory adapter: stops after `configurationDone` and
/// after every `continue`, `next` and `stepIn`; offers a test-failure
/// exception filter.
private final class MenuAdapter: DAPTransport, @unchecked Sendable {
    var receiving: (@Sendable (Data?) -> Void)?
    var decoder = DAPFraming.Decoder()
    private var log: [JSON] = []
    private let lock = NSRecursiveLock()
    private var seq = 700
    let source: String

    init(source: String) { self.source = source }

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }
    func close() { receiving?(nil) }
    var requests: [JSON] { lock.withLock { log } }
    func all(_ cmd: String) -> [JSON] { requests.filter { $0["command"]?.string == cmd } }

    private func emit(_ o: [String: JSON]) {
        seq += 1
        var o = o
        o["seq"] = .number(Double(seq))
        receiving?(DAPFraming.frame(JSON.object(o).encoded()))
    }

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        for raw in decoder.append(data) {
            let req = try! JSON.decode(raw)
            guard req["type"]?.string == "request", let cmd = req["command"]?.string else { continue }
            log.append(req)
            var body: JSON = [:]
            var after: [(String, JSON)] = []
            switch cmd {
            case "initialize":
                body = ["exceptionBreakpointFilters": [["filter": "swift_throw", "label": "Swift Throw"],
                                                       ["filter": "test_failure", "label": "Test Failures"]]]
                after = [("initialized", [:])]
            case "configurationDone", "continue", "next", "stepIn": after = [("stopped", ["reason": cmd == "configurationDone" ? "breakpoint" : "step", "threadId": 1])]
            case "threads": body = ["threads": [["id": 1, "name": "Thread 1"]]]
            case "stackTrace": body = ["stackFrames": [["id": 1, "name": "main", "line": 4, "source": ["path": .string(source)]]]]
            case "scopes": body = ["scopes": [["name": "Locals", "variablesReference": 10, "expensive": false]]]
            case "variables": body = ["variables": [["name": "x", "value": "1", "variablesReference": 0]]]
            case "setBreakpoints": body = ["breakpoints": .array((req["arguments"]?["breakpoints"]?.array ?? []).indices.map { ["id": .number(Double($0 + 1)), "verified": true] })]
            case "disconnect": after = [("terminated", [:])]
            default: break
            }
            emit(["type": "response", "request_seq": req["seq"]!, "command": .string(cmd), "success": true, "body": body])
            for (n, b) in after { emit(["type": "event", "event": .string(n), "body": b]) }
        }
    }
}

@MainActor
@Suite struct DebugMenuTests {
    func workspace() throws -> (WorkspaceSession, WorkspaceWindowController, String) {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-dbgmenu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/M"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"M\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let src = dir.appendingPathComponent("Sources/M/main.swift").standardizedFileURL.path
        try "let a = 1\nlet b = 2\nprint(a + b)\nprint(a)\nprint(b)\n".write(toFile: src, atomically: true, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.open(path: src, line: 3)
        return (session, wc, src)
    }

    func item(_ action: String, title: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: "")
    }

    /// Every Debug menu command the table lists as available is one the
    /// window performs.
    @Test func availableDebugCommandsAreImplemented() throws {
        let (_, wc, _) = try workspace()
        func walk(_ items: [MenuItemSpec]) -> [MenuCommand] {
            items.flatMap { i -> [MenuCommand] in
                switch i {
                case .command(let c): [c]
                case .submenu(_, let sub): walk(sub)
                default: []
                }
            }
        }
        let commands = walk(CommandTable.debugMenu)
        let available = commands.filter(\.isAvailable).map(\.title)
        let mine = ["Continue To Current Line", "Step Over Thread", "Step Into Thread", "Enable Breakpoints at Current Line",
                  "Create Column Breakpoint", "Delete Column Breakpoints at Current Line", "Create Swift Error Breakpoint",
                  "Create Exception Breakpoint…", "Create Symbolic Breakpoint…", "Create Test Failure Breakpoint", "Delete All Breakpoints",
                  "Copy Row with Visible Metadata", "Copy Row with All Metadata", "Copy Row without Metadata", "Jump To Source",
                  "Reload Console", "Select Last Output", "Navigate to Source File when Process Pauses",
                  "Synchronize Insertion Point to Program Counter", "Debug Executable…"]
        for t in mine { #expect(available.contains(t), "\(t)") }
        for c in commands where c.isAvailable && mine.contains(c.title) {
            #expect(wc.responds(to: NSSelectorFromString(c.action)), "\(c.title) → \(c.action)")
        }
        // The unsupported ones stay listed and disabled.
        #expect(!commands.first { $0.title == "Step Over and Follow Program Counter" }!.isAvailable)
        #expect(!commands.first { $0.title == "View Memory" }!.isAvailable)
    }

    @Test func breakpointCommandsAtTheCaret() throws {
        let (session, wc, src) = try workspace()
        wc.editor.textView.setSelectedRange(NSRange(location: 14, length: 0))  // line 2, column 5
        #expect(wc.debugCaret?.line == 2 && wc.debugCaret?.column == 5)
        #expect(!wc.validateMenuItem(item("toggleBreakpointsEnabledAtCurrentLine:")))
        #expect(!wc.validateMenuItem(item("deleteColumnBreakpointsAtCurrentLine:")))
        wc.toggleBreakpointAtCurrentLine(nil)
        #expect(session.breakpoints.breakpoint(file: src, line: 2) != nil)
        let toggle = item("toggleBreakpointsEnabledAtCurrentLine:", title: "Enable Breakpoints at Current Line")
        #expect(MenuTitles.title(generic: "Enable Breakpoints at Current Line", in: wc.menuContext) == "Disable Breakpoints at Current Line")
        #expect(wc.validateMenuItem(toggle))
        wc.toggleBreakpointsEnabledAtCurrentLine(nil)
        #expect(session.breakpoints.breakpoint(file: src, line: 2)?.isEnabled == false)
        #expect(MenuTitles.title(generic: "Enable Breakpoints at Current Line", in: wc.menuContext) == "Enable Breakpoints at Current Line")
        wc.toggleBreakpointsEnabledAtCurrentLine(nil)

        wc.createColumnBreakpoint(nil)
        #expect(session.breakpoints.breakpoints(file: src, line: 2).compactMap(\.column) == [5])
        #expect(wc.validateMenuItem(item("deleteColumnBreakpointsAtCurrentLine:")))
        wc.deleteColumnBreakpointsAtCurrentLine(nil)
        #expect(session.breakpoints.breakpoints(file: src, line: 2).count == 1)

        wc.createSwiftErrorBreakpoint(nil)
        #expect(session.breakpoints.exceptionFilters == ["swift_throw"])
        #expect(!wc.validateMenuItem(item("createSwiftErrorBreakpoint:")))
        wc.createExceptionBreakpoint(nil)
        #expect(session.breakpoints.exceptionFilters == ["swift_throw", "objc_throw", "cpp_throw"])
        // No adapter offering a test-failure filter: disabled.
        #expect(!wc.validateMenuItem(item("createTestFailureBreakpoint:")))

        // Delete All asks first; the window is off screen here, so the
        // command leaves everything in place.
        #expect(wc.validateMenuItem(item("deleteAllBreakpoints:")))
        let alert = wc.deleteAllBreakpointsAlert()
        #expect(alert.messageText == "Are you sure you want to delete all breakpoints?")
        #expect(alert.buttons.map(\.title) == ["Delete", "Cancel"])
        wc.deleteAllBreakpoints(nil)
        #expect(!session.breakpoints.isEmpty)
        session.breakpoints.removeAll()
        #expect(!wc.validateMenuItem(item("deleteAllBreakpoints:")))
    }

    @Test func continueToLineAndSteppingOptions() async throws {
        let (session, wc, src) = try workspace()
        let adapter = MenuAdapter(source: src)
        await session.attach(to: "55", adapter: adapter)
        #expect(await waitUntil(30) { session.stoppedThread == 1 && !session.variables.isEmpty })
        #expect(wc.validateMenuItem(item("createTestFailureBreakpoint:")))
        wc.createTestFailureBreakpoint(nil)
        #expect(session.breakpoints.exceptionFilters == ["test_failure"])
        #expect(await waitUntil(30) { adapter.all("setExceptionBreakpoints").last?["arguments"]?["filters"] == ["test_failure"] })

        // Continue To Current Line: a temporary breakpoint at the caret's
        // line, then continue; the next stop removes it.
        wc.editor.textView.setSelectedRange(NSRange(location: 20, length: 0))  // line 3
        #expect(wc.validateMenuItem(item("continueToCurrentLine:")))
        let before = adapter.all("setBreakpoints").count
        await session.continueToLine(file: src, line: 3)
        let sent = adapter.all("setBreakpoints")[before...]
        #expect(sent.first?["arguments"]?["breakpoints"] == [["line": 3]])
        #expect(sent.first?["arguments"]?["source"]?["path"]?.string == src)
        #expect(adapter.all("continue").count == 1)
        #expect(await waitUntil(30) { session.stoppedThread == 1 && session.temporaryBreakpoint == nil })
        #expect(await waitUntil(30) { adapter.all("setBreakpoints").last?["arguments"]?["breakpoints"] == [] })

        // Step … Thread: singleThread; Step … Instruction: granularity.
        await session.step("over", instruction: false, singleThread: true)
        #expect(adapter.all("next").last?["arguments"]?["singleThread"] == true)
        #expect(adapter.all("next").last?["arguments"]?["granularity"] == nil)
        #expect(await waitUntil(30) { session.stoppedThread == 1 })
        await session.step("in", instruction: true, singleThread: false)
        #expect(adapter.all("stepIn").last?["arguments"]?["granularity"]?.string == "instruction")
        #expect(adapter.all("stepIn").last?["arguments"]?["singleThread"] == nil)
        session.stop()
        #expect(await waitUntil(30) { session.debugClient == nil })
    }

    @Test func debugWorkflowToggles() async throws {
        let (session, wc, src) = try workspace()
        #expect(wc.navigatesToSourceOnPause && !wc.synchronizesInsertionPoint)
        let nav = item("toggleNavigateToSourceOnPause:")
        #expect(wc.validateMenuItem(nav) && nav.state == .on)
        wc.toggleNavigateToSourceOnPause(nil)
        #expect(!wc.navigatesToSourceOnPause && wc.validateMenuItem(nav) && nav.state == .off)
        let sync = item("toggleSynchronizeInsertionPoint:")
        #expect(wc.validateMenuItem(sync) && sync.state == .off)

        // With navigation off, a stop in another file leaves the editor alone.
        let other = URL(fileURLWithPath: src).deletingLastPathComponent().appendingPathComponent("other.swift").path
        try "let z = 0\n".write(toFile: other, atomically: true, encoding: .utf8)
        wc.open(path: other, line: 1)
        let adapter = MenuAdapter(source: src)
        await session.attach(to: "56", adapter: adapter)
        #expect(await waitUntil(30) { session.stoppedThread == 1 && !session.variables.isEmpty })
        #expect(wc.editor.fileURL?.path == other)

        // On again, and the stop's file open with the caret elsewhere: the
        // editor scrolls to the line without moving the caret.
        wc.toggleNavigateToSourceOnPause(nil)
        wc.open(path: src, line: 1)
        await session.step("over", instruction: false, singleThread: false)
        #expect(await waitUntil(30) { session.stoppedThread == 1 && session.stopCount >= 2 && wc.editor.gutter.marks.currentLine == 4 })
        #expect(wc.editor.currentLine == 1)
        // Synchronize Insertion Point: the caret follows the program counter.
        wc.toggleSynchronizeInsertionPoint(nil)
        await session.step("over", instruction: false, singleThread: false)
        #expect(await waitUntil(30) { session.stopCount >= 3 && wc.editor.currentLine == 4 })
        session.stop()
        #expect(await waitUntil(30) { session.debugClient == nil })
    }

    @Test func consoleRowsCopyJumpAndSelect() throws {
        let (session, wc, src) = try workspace()
        session.appendConsole("first line\nsecond ", kind: .target)
        session.appendConsole("part\n", kind: .target)
        session.appendConsole("\nmain.swift:3: Fatal error: boom\n", kind: .target)
        session.appendConsole("\nProgram ended with exit code: 1\n")
        let rows = wc.consoleRows
        #expect(rows.map(\.text) == ["first line", "second part", "", "main.swift:3: Fatal error: boom", "", "Program ended with exit code: 1"])
        #expect(rows[1].entry.text == "first line\nsecond ")

        // The caret's row; Copy Row … with and without metadata.
        wc.debugArea.placeConsoleCaret(line: 1)
        #expect(wc.debugArea.selectedConsoleRow == 1)
        wc.copyConsoleRowWithoutMetadata(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "second part")
        var m = ConsoleMetadata()
        m.type = true
        wc.debugArea.setMetadata(m)  // re-renders the console: put the caret back
        wc.debugArea.placeConsoleCaret(line: 1)
        wc.copyConsoleRowWithVisibleMetadata(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "[Target] second part")
        wc.copyConsoleRowWithAllMetadata(nil)
        let all = NSPasteboard.general.string(forType: .string) ?? ""
        #expect(all.contains("[Target] second part") && all.range(of: #"^\d\d:\d\d:\d\d\.\d{3} "#, options: .regularExpression) != nil)
        wc.debugArea.setMetadata(ConsoleMetadata())

        // Jump To Source: only for a row naming a location.
        #expect(!wc.validateMenuItem(item("jumpToConsoleSource:")))
        wc.open(path: URL(fileURLWithPath: src).deletingLastPathComponent().appendingPathComponent("../../Package.swift").standardizedFileURL.path, line: 1)
        wc.debugArea.placeConsoleCaret(line: 3)
        #expect(wc.validateMenuItem(item("jumpToConsoleSource:")))
        wc.jumpToConsoleSource(nil)
        #expect(wc.editor.fileURL?.path == src && wc.editor.currentLine == 3)

        // With the bar's text filter, the shown line maps to its row.
        wc.debugArea.consoleSearch.stringValue = "Fatal"
        wc.reloadConsole(nil)
        wc.debugArea.placeConsoleCaret(line: 0)
        #expect(wc.debugArea.selectedConsoleRow == 3)
        wc.debugArea.consoleSearch.stringValue = ""
        wc.reloadConsole(nil)

        // Select Last Output: the last paragraph.
        #expect(wc.validateMenuItem(item("selectLastConsoleOutput:")))
        wc.selectLastConsoleOutput(nil)
        #expect(wc.debugArea.consoleSelection == "Program ended with exit code: 1")
    }

    @Test func consoleRowParsing() {
        #expect(ConsoleRows.sourceLocation(in: "Shapes/Shapes.swift:12: Fatal error: x")! == ("Shapes/Shapes.swift", 12))
        #expect(ConsoleRows.sourceLocation(in: "/tmp/a.c:7:3: warning: y")! == ("/tmp/a.c", 7))
        #expect(ConsoleRows.sourceLocation(in: "Fatal error: z: file App/Model.swift, line 40")! == ("App/Model.swift", 40))
        #expect(ConsoleRows.sourceLocation(in: "sum=5") == nil)
        #expect(ConsoleRows.sourceLocation(in: "version 1.2:3") == nil)
        let files = ["/w/App/Model.swift", "/w/Other/Model.swift", "/w/App/Sub/View.swift"]
        #expect(ConsoleRows.resolve("App/Model.swift", files: files) == "/w/App/Model.swift")
        #expect(ConsoleRows.resolve("View.swift", files: files) == "/w/App/Sub/View.swift")
        #expect(ConsoleRows.resolve("Missing.swift", files: files) == nil)
        #expect(ConsoleRows.lastParagraph(in: "a\n\nb\nc\n\n") == NSRange(location: 3, length: 3))
        #expect(ConsoleRows.lastParagraph(in: "\n\n") == nil)
        #expect(ConsoleRows.rows([ConsoleEntry(kind: .debugger, text: "x")]).map(\.text) == ["x"])
    }

    @Test func attachToProcessListsTheUsersProcesses() throws {
        let list = RunningProcesses.list()
        #expect(!list.isEmpty)
        #expect(!list.contains { $0.pid == Int(getpid()) })
        #expect(list == list.sorted { ($0.name.lowercased(), $0.pid) < ($1.name.lowercased(), $1.pid) })
        let menu = NSMenu()
        RunningProcesses.fill(menu, target: nil, entries: nil)
        #expect(menu.items.map(\.title) == ["Getting Process List…"])
        RunningProcesses.fill(menu, target: nil, entries: [.init(pid: 12, name: "Demo")])
        #expect(menu.items.map(\.title) == ["Demo (12)"] && menu.items[0].representedObject as? Int == 12)
        #expect(menu.items[0].action == #selector(WorkspaceWindowController.attachToListedProcess(_:)))
    }
}
