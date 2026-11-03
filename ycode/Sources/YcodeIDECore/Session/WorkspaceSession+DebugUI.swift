import Foundation
import YcodeDebug

/// Debugger UI bookkeeping: activity product, stop annotation and hit
/// counts, adapter breakpoint ids, the process gauges and the
/// end-of-session console lines (specs/ide/reference-ui-4.md §5).
extension WorkspaceSession {
    func beginDebugSession(product: String) {
        runningProduct = product
        runningDeviceName = nil
        exitLinePrinted = false
        killReported = false
        breakpointHits = [:]
        stopAnnotation = nil
    }

    func endDebugSession() {
        // A killed paused process: lldb-dap may end without an exit event.
        if killReported && !exitLinePrinted {
            exitLinePrinted = true
            appendConsole("Program ended with exit code: 9\n", kind: .debugger)
        }
        gaugeTimer?.invalidate()
        gaugeTimer = nil
        gaugeSampler = nil
        stopAnnotation = nil
        notify(.process)
    }

    /// The process row: product, PID and the latest gauges.
    public var debugProcessInfo: DebugProcessInfo? {
        guard debugClient != nil, let product = runningProduct else { return nil }
        return DebugProcessInfo(product: product, pid: debuggedPID, gauges: processGauges)
    }

    /// Samples the debugged process once a second while the session lasts.
    func startGaugeSampling() {
        guard let pid = debuggedPID, gaugeSampler?.pid != Int32(pid) else { return }
        let sampler = ProcessGaugeSampler(pid: Int32(pid))
        gaugeSampler = sampler
        if let g = sampler.sample() { processGauges = g }
        gaugeTimer?.invalidate()
        gaugeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleGauges() }
        }
        notify(.process)
    }

    func sampleGauges() {
        guard let g = gaugeSampler?.sample() else { return }
        processGauges = g
        notify(.process)
    }

    /// Records the stop: hit counts of the breakpoints it hit and the
    /// annotation for the top frame's line.
    func noteStop(_ body: JSON, threadID: Int?, reason: String) {
        stopCount += 1
        var hitID: String?
        if case .array(let ids)? = body["hitBreakpointIds"] {
            for id in ids.compactMap(\.int) {
                let key = "\(id).1"
                breakpointHits[key, default: 0] += 1
                hitID = hitID ?? key
            }
        } else if reason == "breakpoint", let d = lastStopDescription, d.hasPrefix("breakpoint ") {
            // lldb-dap: "breakpoint 1.1".
            let key = String(d.dropFirst("breakpoint ".count).prefix { $0.isNumber || $0 == "." })
            if !key.isEmpty { breakpointHits[key, default: 0] += 1; hitID = key }
        }
        let thread = threads.first { $0.id == threadID }
        let index = thread.map(DebugPresentation.threadIndex) ?? threadID ?? 1
        if let f = frames.first, let file = f.file {
            let text = DebugPresentation.stopAnnotation(thread: index, breakpointID: hitID, hits: hitID.flatMap { breakpointHits[$0] },
                                                        reason: hitID == nil ? reason : nil)
            stopAnnotation = (file, f.line, text)
        } else {
            stopAnnotation = nil
        }
    }

    /// Keeps the adapter's id for each sent line breakpoint ("<id>.1").
    func recordBreakpointIDs(file: String, sent: [SourceBreakpoint], result: [Breakpoint]) {
        for k in breakpointIDs.keys where k.hasPrefix(file + ":") { breakpointIDs[k] = nil }
        for (b, r) in zip(sent, result) {
            if let id = r.id { breakpointIDs["\(file):\(b.line)"] = "\(id).1" }
        }
        notify(.breakpoints)
    }

    /// The path in the debug bar: "<process> › Thread <n> › <index> <function>".
    public var debugBarPath: String {
        guard let product = runningProduct, let t = stoppedThread else { return "" }
        let index = threads.first { $0.id == t }.map(DebugPresentation.threadIndex) ?? t
        let i = frames.firstIndex { $0.id == selectedFrameID } ?? 0
        let f = frames.indices.contains(i) ? " › \(i) \(frames[i].name)" : ""
        return "\(product) › Thread \(index)" + f
    }
}
