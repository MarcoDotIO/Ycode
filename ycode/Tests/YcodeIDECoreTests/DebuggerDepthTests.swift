import Foundation
import Testing
import YcodeDebug
@testable import YcodeIDECore

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(10))) struct DebuggerDepthTests {
    @Test func consoleFilterModel() {
        #expect(ConsoleEntry.Filter.all.includes(.target) && ConsoleEntry.Filter.debugger.includes(.input))
        #expect(!ConsoleEntry.Filter.debugger.includes(.target) && !ConsoleEntry.Filter.target.includes(.debugger))
        let t = DebugThread(id: 1, name: "Thread 1 name = worker queue = com.example.q")
        #expect(t.queue == "com.example.q")
        #expect(WorkspaceSession.sameAddress("0x0000000100003F40", "0x100003f40"))
    }
}
