import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_TESTS=<prefix>: a walk through testing (B2-SCM, issue #16) on a
// Swift package with XCTest and Swift Testing tests: the Test navigator,
// Product ▸ Test from the menu, the results, the failures in the Issue
// navigator and the editor, a gutter diamond and a navigator row's run
// button, and the run's report. Writes <prefix>-tests-<state>.png.
extension ShellDriver {
    #if os(Linux)
    static func testsWalk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("tests: no workspace"); return }
        let t = w.testing
        func shot(_ name: String) async {
            await pause(0.7)
            let failed = t.results.values.filter { $0 == .failed }.count, passed = t.results.values.filter { $0 == .passed }.count
            say("tests \(name): tests=\(t.tests.count) passed=\(passed) failed=\(failed) issues=\(w.issueCounts.errors)E "
                + "activity=\"\(w.activityText)\" " + OpenViewsAutomation.screenshot(to: "\(prefix)-tests-\(name).png"))
        }
        func waitRun() async {
            await pause(0.5)
            for _ in 0..<2400 where w.isBusy || t.running != nil { await pause(0.25) }
            await pause(0.5)
        }
        func clickNavigatorRow(_ title: String) async {
            let texts = OpenViewsAutomation.texts().filter { !$0.inPopup && $0.text == title && inNavigator($0.frame) }
            guard let f = texts.last?.frame else { say("tests: no row \(title)"); return }
            await OpenViewsAutomation.click(at: CGPoint(x: f.minX + 10, y: f.midY))
            await pause(0.5)
        }
        await click("selector 5")
        await t.discovered()
        await shot("navigator")
        // Product ▸ Test with the pointer.
        await clickText("Product", inPopup: false)
        await clickText("Test", inPopup: true)
        await waitRun()
        await shot("results")
        say("tests log: \(w.buildLog.suffix(4).joined(separator: " | "))")
        // The failures in the Issue navigator.
        await click("selector 4")
        await shot("issues")
        // A failing test's line: its diamond and the failure in the editor.
        await click("selector 5")
        await clickNavigatorRow("testGreetAllFails()")
        await shot("gutter")
        // The diamond of a passing test runs it alone.
        if let test = t.tests.first(where: { $0.name == "testCustomGreeting" }) {
            w.open(test.file, line: test.line)
            await pause(0.6)
            say("tests: diamond at line \(test.line): \(String(describing: w.testDiamonds[test.line]))")
            w.runTests(atLine: test.line)
            await waitRun()
            await shot("diamond-run")
        }
        // The selected row's run button.
        await clickNavigatorRow("greetsByName()")
        await pause(0.4)
        await shot("row-selected")
        await click("test run greetsByName()")
        await waitRun()
        await shot("row-run")
        // The report.
        await click("selector 8")
        await pause(0.4)
        await shot("reports")
        if let row = t.reportRows.first(where: { $0.id.hasPrefix("report:") && !$0.id.contains("/") }) {
            await clickNavigatorRow(row.title)
            if t.shownReport == nil { t.selectReport(row.id) }
        }
        await shot("report")
        if let tests = t.reportRows.first(where: { $0.id.hasSuffix("/Log") }) {
            t.selectReport(tests.id)
            await shot("report-log")
        }
        say("tests walk done: \(t.results.count) results, \(t.reports.count) reports")
    }
    #endif
}
