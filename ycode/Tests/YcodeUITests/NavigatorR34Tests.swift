import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeDebug
@testable import YcodeUI

/// Stale issues (reference-ui-5.md §5.3.2, N10) and the Debug navigator's
/// process row (§11.6, D3).
@MainActor
@Suite struct StaleIssuesAndProcessRowTests {
    func d(_ msg: String, _ file: String?) -> Diagnostic {
        Diagnostic(severity: .warning, message: msg, location: file.map { .init(file: $0, line: 1) })
    }

    @Test func nextBuildReplacesIssuesOfFilesItCompiled() {
        var m = IssueNavigatorModel()
        let a = d("a", "/p/A.swift"), b = d("b", "/p/B.swift"), n = d("n", nil)
        m.finishBuild([a, b, n], full: false, compiledFiles: ["A.swift", "B.swift"])
        // During the next build the earlier issues stay, shown stale.
        m.startBuild()
        #expect(m.entries(fresh: []).map(\.isStale) == [true, true, true])
        #expect(m.capsuleCounts(fresh: []).warnings == 3)
        // It compiled A only: A's issue is gone, B's stays stale, the
        // file-less one is gone.
        m.finishBuild([], full: false, compiledFiles: ["A.swift"])
        #expect(!m.isBuilding)
        #expect(m.stale == [b])
        // A later build that compiles B drops it.
        m.finishBuild([], full: false, compiledFiles: ["B.swift"])
        #expect(m.stale.isEmpty)
        // Unknown compile set: every unreported issue goes.
        m.finishBuild([a], full: false, compiledFiles: [])
        m.finishBuild([], full: false, compiledFiles: nil)
        #expect(m.stale.isEmpty)
    }

    @Test func compiledFilesFromTheLog() {
        let swiftpm = ["Building for debugging...", "[3/7] Compiling Demo main.swift other.swift", "[5/7] Linking Demo", "Build complete!"]
        #expect(IssueNavigatorModel.compiledFiles(inLog: swiftpm, isPackage: true) == ["main.swift", "other.swift"])
        let xcb = ["SwiftCompile normal arm64 /p/App/View.swift (in target 'App' from project 'App')",
                   "CompileC /p/b/x.o /p/App/x.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler (in target 'App' from project 'App')"]
        #expect(IssueNavigatorModel.compiledFiles(inLog: xcb, isPackage: false) == ["View.swift", "x.c"])
        #expect(IssueNavigatorModel.compiledFiles(inLog: ["Build complete!"], isPackage: true) == nil)
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
