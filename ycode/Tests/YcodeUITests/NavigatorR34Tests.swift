import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeDebug
@testable import YcodeIDECore
@testable import YcodeUI

/// Stale issues (reference-ui-5.md §5.3.2, N10) and the Debug navigator's
/// process row (§11.6, D3).
@MainActor
@Suite struct StaleIssuesAndProcessRowTests {
    func d(_ msg: String, _ file: String?) -> Diagnostic {
        Diagnostic(severity: .warning, message: msg, location: file.map { .init(file: $0, line: 1) })
    }

    @Test func processRowButtonsEnergyBarAndRunningBlocks() {
        var g = ProcessGauges()
        g.cpuPercent = 70
        #expect(g.energyImpact == "Very High" && g.energyLevel == 1)
        g.cpuPercent = 0
        #expect(g.energyLevel == 0)
        g.cpuPercent = 30
        let threads = [DebugThread(id: 1, name: "Thread 1 queue = com.apple.main-thread"), DebugThread(id: 2, name: "Thread 2")]
        let rows = DebugNavigatorRows.debugTree(process: DebugProcessInfo(product: "Demo", pid: 7, gauges: g), threads: threads,
                                                stoppedThread: nil, frames: [], byQueue: true, runningBlocksOnly: true)
        let root = rows[0]
        #expect(root.rowButtons.map(\.toolTip) == ["Pause or continue the process", "Stop the process"])
        #expect(root.rowButtons.map(\.action) == ["pauseOrContinue:", "stopProduct:"])
        #expect(root.children.first { $0.title == "Energy Impact" }?.level == 0.6)
        #expect(root.children.filter { $0.badge == nil }.map(\.title) == ["com.apple.main-thread"])
        let all = DebugNavigatorRows.debugTree(process: nil, threads: threads, stoppedThread: nil, frames: [], byQueue: true, runningBlocksOnly: false)
        #expect(all.map(\.title) == ["com.apple.main-thread", "Threads"])

        // The navigator's third toggle drives it (on by default).
        let nav = NavigatorAreaController()
        _ = nav.view
        nav.showThreadsByQueue = true
        nav.setDebugState(threads: threads, stoppedThread: nil, frames: [])
        #expect(nav.toggleValue(6, 2) && nav.rows(6).map(\.title) == ["com.apple.main-thread"])
        nav.setToggle(6, 2, false)
        #expect(nav.rows(6).map(\.title) == ["com.apple.main-thread", "Threads"])
    }
}
