import Foundation
import Testing
@testable import YcodeDebug
@testable import YcodeIDECore

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
}
