import Foundation
import YcodeDebug

/// The Debug menu's session commands (`specs/ide/reference-ui-5.md`
/// §2.10, §10.2): Continue To Current Line, the instruction and thread
/// steps, and the adapter's test-failure filter.
extension WorkspaceSession {
    /// Continue To Current Line (⌃⌘C): a temporary breakpoint at `line`,
    /// then `continue`. The breakpoint is removed at the next stop.
    public func continueToLine(file: String, line: Int) async {
        guard let c = debugClient, let t = stoppedThread else { return }
        temporaryBreakpoint = (file, line)
        await syncBreakpoints()
        try? await c.continue(threadID: t)
        clearStopState()
        setActivity(.running(runningActivityTitle))
    }

    /// Step Over / Into / Out with the DAP options: Step … Instruction
    /// sends `granularity: "instruction"`; Step … Thread sends
    /// `singleThread: true` (only the selected thread runs).
    public func step(_ kind: String, instruction: Bool, singleThread: Bool) async {
        guard let c = debugClient, let t = stoppedThread else { return }
        let command = kind == "in" ? "stepIn" : (kind == "out" ? "stepOut" : "next")
        let granular = instruction || (alwaysShowDisassembly && kind != "out")
        try? await c.step(command, threadID: t, granularity: granular ? "instruction" : nil, singleThread: singleThread)
    }

    /// The adapter's exception filter for test failures, when it offers
    /// one (Create Test Failure Breakpoint is disabled otherwise).
    public var testFailureFilter: String? {
        debugClient?.exceptionFilters.first { f in
            let text = (f.id + " " + f.label).lowercased()
            return text.contains("test") && text.contains("fail")
        }?.id
    }
}
