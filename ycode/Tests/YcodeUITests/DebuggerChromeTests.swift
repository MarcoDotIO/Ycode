import AppKit
import Foundation
import Testing
@testable import YcodeDebug
@testable import YcodeUI

/// An in-memory adapter for reference-ui-4.md §5/§6: a breakpoint stop
/// with `hitBreakpointIds`, queue-named threads, user and system frames,
/// argument and local variables, a kill without an exit event.
private final class ChromeAdapter: DAPTransport, @unchecked Sendable {
    var receiving: (@Sendable (Data?) -> Void)?
    var decoder = DAPFraming.Decoder()
    private let lock = NSRecursiveLock()
    private var seq = 900
    let source: String
    init(source: String) { self.source = source }

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }
    func close() { receiving?(nil) }

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
            let args = req["arguments"] ?? .null
            var body: JSON = [:]
            var after: [(String, JSON)] = []
            var end = false
            switch cmd {
            case "initialize": after = [("initialized", [:])]
            case "setBreakpoints":
                let bps = args["breakpoints"]?.array ?? []
                body = ["breakpoints": .array(bps.map { ["id": 3, "verified": true, "line": $0["line"] ?? 0] })]
            case "configurationDone":
                after = [("process", ["systemProcessId": .number(Double(getpid()))]),
                         ("stopped", ["reason": "breakpoint", "threadId": 11, "hitBreakpointIds": [3], "description": "breakpoint 3.1"])]
            case "threads": body = ["threads": [["id": 11, "name": "Thread 1 queue = com.apple.main-thread"],
                                                ["id": 12, "name": "Thread 2 queue = com.apple.root.default-qos"]]]
            case "stackTrace": body = ["stackFrames": [
                ["id": 1, "name": "Shape.area(scale:)", "line": 4, "source": ["path": .string(source)]],
                ["id": 2, "name": "main", "line": 9, "source": ["path": .string(source)]],
                ["id": 3, "name": "start", "line": 0],
                ["id": 4, "name": "_pthread_start", "line": 0],
            ]]
            case "scopes": body = ["scopes": [["name": "Locals", "variablesReference": 20, "expensive": false]]]
            case "variables": body = ["variables": [["name": "self", "value": "{...}", "type": "Shape", "variablesReference": 0],
                                                    ["name": "scale", "value": "2", "type": "Int", "variablesReference": 0],
                                                    ["name": "total", "value": "8", "type": "Int", "variablesReference": 0]]]
            case "disconnect": after = [("terminated", [:])]; end = true
            default: break
            }
            emit(["type": "response", "request_seq": req["seq"]!, "command": .string(cmd), "success": true, "body": body])
            for (n, b) in after { emit(["type": "event", "event": .string(n), "body": b]) }
            if end { receiving?(nil) }
        }
    }
}

@MainActor
@Suite(.serialized, .heavyIntegration) struct DebuggerChromeTests {
    // MARK: Pure rules

    @Test func titlesAndAnnotation() {
        #expect(DebugPresentation.runningTitle("Shapes") == "Running Shapes")
        #expect(DebugPresentation.pausedTitle("Shapes") == "Paused Shapes")
        #expect(DebugPresentation.finishedTitle("Shapes") == "Finished running Shapes")
        #expect(DebugPresentation.stopAnnotation(thread: 1, breakpointID: "1.1", hits: 2, reason: nil) == "Thread 1: breakpoint 1.1 (2)")
        #expect(DebugPresentation.stopAnnotation(thread: 3, breakpointID: nil, hits: nil, reason: "step") == "Thread 3: step")
    }

    @Test func threadRowsAndTruncation() {
        let main = DebugThread(id: 9, name: "Thread 1 queue = com.apple.main-thread")
        #expect(DebugPresentation.threadRow(main) == "Thread 1  Queue: com.apple.main-thread (serial)")
        let g = DebugThread(id: 10, name: "Thread 4 queue = com.apple.root.default-qos")
        #expect(DebugPresentation.threadRow(g) == "Thread 4  Queue: com.apple.root.default-qos (concurrent)")
        #expect(DebugPresentation.threadRow(DebugThread(id: 5, name: "Thread 5")) == "Thread 5")
        #expect(DebugPresentation.truncateMiddle("com.example.long.queue.name", max: 11) == "com.e…_name".replacingOccurrences(of: "_", with: "."))
    }

    @Test func frameGroupingCollapsesSystemFrames() throws {
        func f(_ id: Int, _ file: String?) -> StackFrame {
            var j: [String: JSON] = ["id": .number(Double(id)), "name": .string("f\(id)"), "line": 1]
            if let file { j["source"] = ["path": .string(file)] }
            return StackFrame(.object(j))
        }
        let rows = DebugPresentation.groupFrames([f(0, "/u/a.swift"), f(1, "/u/b.swift"), f(2, nil), f(3, "/usr/lib/x.c"), f(4, nil)])
        #expect(rows.count == 4)
        #expect(rows[2] == .separator)
        if case .frame(let i, _, let user) = rows[3] { #expect(i == 2 && !user) } else { Issue.record("no system frame") }
        // Without user frames, everything is listed.
        #expect(DebugPresentation.groupFrames([f(0, nil), f(1, nil)]).count == 2)
    }

    @Test func variableBadges() {
        #expect(DebugPresentation.badge(name: "self", scope: "Locals", frameName: "f()") == "A")
        #expect(DebugPresentation.badge(name: "scale", scope: "Locals", frameName: "Shape.area(scale:)") == "A")
        #expect(DebugPresentation.badge(name: "b", scope: "Locals", frameName: "add(int a, int b)") == "A")
        #expect(DebugPresentation.badge(name: "total", scope: "Locals", frameName: "Shape.area(scale:)") == "L")
        let v = Variable(name: "x", value: "3", type: "Int", variablesReference: 0)
        #expect(DebugPresentation.variableRow(badge: "L", v) == "L x: Int = 3")
    }

    @Test func gaugesFormattingAndSampling() throws {
        #expect(ProcessGauges.bytes(0) == "Zero KB")
        #expect(ProcessGauges.bytes(512 * 1024) == "512 KB")
        #expect(ProcessGauges.bytes(12.3 * 1024 * 1024) == "12 MB")
        let g = ProcessGauges()
        #expect(g.rows.map(\.0) == ["CPU", "Memory", "Energy Impact", "Disk", "Network"])
        #expect(g.rows.map(\.1) == ["0%", "Zero KB", "Zero", "Zero KB/s", "Zero KB/s"])
        let sampler = ProcessGaugeSampler(pid: getpid())
        let s = try #require(sampler.sample())
        #expect(s.memoryBytes > 1024 * 1024)
    }

    @Test func enclosingSymbol() {
        let swift = "struct Shape {\n    func area(scale: Int, _ k: Int) -> Int {\n        return 1\n    }\n}\nfunc top() {\n  print(1)\n}\n"
            .split(separator: "\n", omittingEmptySubsequences: false)
        #expect(SourceSymbolLocator.symbol(in: swift, line: 3)?.name == "area(scale:_:)")
        #expect(SourceSymbolLocator.symbol(in: swift, line: 3)?.method == true)
        #expect(SourceSymbolLocator.symbol(in: swift, line: 7)?.name == "top()")
        #expect(SourceSymbolLocator.symbol(in: swift, line: 7)?.method == false)
        let c = "int add(int a, int b) {\n    return a + b;\n}\n".split(separator: "\n", omittingEmptySubsequences: false)
        #expect(SourceSymbolLocator.symbol(in: c, line: 2)?.name == "add")
    }

    // MARK: Session and window

    @Test func pausedSessionChrome() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Shapes\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = dir.appendingPathComponent("Shapes.swift").path
        try "struct Shape {\n    func area(scale: Int) -> Int {\n        let total = 4\n        return total * scale\n    }\n}\n"
            .write(toFile: source, atomically: true, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        session.breakpoints.click(file: source, line: 4)
        let adapter = ChromeAdapter(source: source)
        await session.debug(program: "/tmp/prod/Shapes", adapter: adapter)
        #expect(await waitUntil(30) { session.stoppedThread == 11 && !session.variables.isEmpty })

        // Activity and stop annotation.
        #expect(session.activity == .paused("Paused Shapes"))
        #expect(session.stopAnnotation?.text == "Thread 1: breakpoint 3.1 (1)")
        #expect(wc.editor.stopAnnotationText == "Thread 1: breakpoint 3.1 (1)")
        // The Debug navigator is selected on the stop.
        #expect(wc.navigator.selectedIndex == 6)

        // Process row, gauges, thread rows, frame grouping.
        let root = try #require(wc.navigator.rows(6).first)
        #expect(root.title == "Shapes  PID \(getpid())")
        #expect(root.children.prefix(5).map(\.title) == ["CPU", "Memory", "Energy Impact", "Disk", "Network"])
        let threads = wc.navigator.debugThreadRows
        #expect(threads.map(\.title) == ["Thread 1  Queue: com.apple.main-thread (serial)", "Thread 2  Queue: com.apple.root.default-qos (concurrent)"])
        #expect(threads[0].middleTruncation)
        let frames = threads[0].children
        #expect(frames.map(\.title) == ["0 Shape.area(scale:)", "1 main", frames[2].title, "2 start"])
        #expect(frames[2].isSeparator && frames[3].dimmed && frames[0].symbol == "person.fill")

        // Debug bar: path, extra buttons, branch.
        #expect(wc.debugArea.shownPath == "Shapes › Thread 1 › 0 Shape.area(scale:)")
        let tips = wc.debugArea.barButtonViews.map { $0.toolTip ?? "" }
        for t in ["Enable Backtrace in Editor", "Debug View Hierarchy", "Debug Memory Graph", "Environment Overrides", "Simulate Location"] {
            #expect(tips.contains(t))
        }
        #expect(wc.debugArea.barButtonViews.filter { !$0.isHidden }.count == DebugAreaController.barButtons.count)
        wc.debugArea.setBranch("feature/observe")
        #expect(wc.debugArea.branchLabel.stringValue == "feature/observe" && !wc.debugArea.branchView.isHidden)

        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "debugger-chrome.png")

        // Variables: A/L badges.
        #expect(wc.debugArea.variableRowText("self") == "A self: Shape = {...}")
        #expect(wc.debugArea.variableRowText("scale") == "A scale: Int = 2")
        #expect(wc.debugArea.variableRowText("total") == "L total: Int = 8")
        #expect(!wc.debugArea.isLoadingVariables)

        // Breakpoint navigator: root, file group, row with symbol, ID and marker.
        wc.navigator.select(7)
        let bpRoot = try #require(wc.navigator.rows(7).first)
        #expect(bpRoot.title == "\(session.model.displayName)  1 Breakpoint")
        let row = try #require(wc.navigator.breakpointGroups.first { $0.title == "Shapes.swift" }?.children.first)
        #expect(row.title == "area(scale:)  4", "\(row.title) \(row.detail ?? "")")
        #expect(row.title == "area(scale:)  4" && row.detail == "ID 3.1" && row.enabledMarker == true && row.symbol == "m.square.fill")
        wc.navigator.onToggleBreakpointEnabled?(source, 4)
        #expect(session.breakpoints.breakpoint(file: source, line: 4)?.isEnabled == false)
        #expect(wc.navigator.breakpointGroups.first { $0.title == "Shapes.swift" }?.children.first?.enabledMarker == false)
        #expect(wc.navigator.addMenuTitles == ["Swift Error Breakpoint", "Exception Breakpoint…", "Symbolic Breakpoint…",
                                               "Runtime Issue Breakpoint…", "Constraint Error Breakpoint", "Test Failure Breakpoint"])
        wc.addSpecialBreakpoint(.testFailure)
        #expect(session.breakpoints.symbolic.map(\.name) == ["XCTFail"])
        #expect(!wc.navigator.recentToggle.isHidden && !wc.navigator.sourceControlToggle.isHidden)
        // reference-ui-5.md §5.2: Modified breakpoints, then Enabled breakpoints.
        wc.navigator.sourceControlToggle.performClick(nil)
        #expect(wc.navigator.breakpointFilter.enabledOnly)
        #expect(!wc.navigator.breakpointGroups.contains { $0.title == "Shapes.swift" })

        // Stopping while paused: the kill lines, then Finished running.
        session.stop()
        #expect(await waitUntil(30) { session.debugClient == nil })
        let console = session.consoleText(.all)
        #expect(console.contains("Debug session ended with code 9: killed\n"))
        #expect(console.contains("Program ended with exit code: 9"))
        #expect(session.activity == .finished("Finished running Shapes"))
        #expect(wc.navigator.rows(6).isEmpty)
    }
}
