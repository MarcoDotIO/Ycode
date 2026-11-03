import Foundation
import Testing
import YcodeDebug
@testable import YcodeIDECore

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct BreakpointEditingTests {
    @Test func dapMapping() {
        var b = BreakpointStore.Breakpoint(file: "/a.c", line: 3, isEnabled: true)
        #expect(!b.isCustomized && b.dap == SourceBreakpoint(line: 3))
        b.condition = "a == 3"
        b.ignoreCount = 2
        #expect(b.dap == SourceBreakpoint(line: 3, condition: "a == 3", hitCondition: "2"))
        b.actions = [.log("a={a}")]
        #expect(b.dap.logMessage == nil) // logging without continuing still stops
        b.autoContinue = true
        #expect(b.dap.logMessage == "a={a}" && b.isCustomized)
        var s = BreakpointStore()
        s.symbolic = [.init(name: "add", condition: "a == 4"), .init(name: "off", isEnabled: false)]
        #expect(s.effectiveFunctionBreakpoints == [FunctionBreakpoint(name: "add", condition: "a == 4")])
        s.isActive = false
        #expect(s.effectiveFunctionBreakpoints.isEmpty)
    }
}
