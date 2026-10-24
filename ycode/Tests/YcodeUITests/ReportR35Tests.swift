import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeUI

/// reference-ui-5.md §11.3 (P12): every Tests-page filter pop-up works and
/// Coverage rows expand from target to files.
@MainActor
@Suite struct ReportR35Tests {
    func report() -> BuildReport {
        var test = BuildReport(title: "Test Demo", date: Date(), succeeded: false, log: [], errorCount: 1, warningCount: 0)
        test.context.action = "Test"
        test.context.scheme = "Demo"
        test.context.destination = "iPhone 17"
        test.context.tests = [TestOutcome(suite: nil, name: "circleArea", status: .passed),
                              TestOutcome(suite: nil, name: "squareArea", status: .failed,
                                          failures: [Diagnostic(severity: .error, message: "Expectation failed", location: .init(file: "/x/ShapeTests.swift", line: 9))])]
        test.context.coverage = [CoverageItem(name: "Demo", coveredLines: 8, executableLines: 10,
                                              files: [CoverageItem(name: "Shapes.swift", coveredLines: 6, executableLines: 6),
                                                      CoverageItem(name: "Util.swift", coveredLines: 2, executableLines: 4)]),
                                 CoverageItem(name: "DemoTests", coveredLines: 5, executableLines: 5)]
        return test
    }

    func tests(_ v: TestReportView) -> [String] { v.lines.filter { $0.hasSuffix("()") }.map { $0.trimmingCharacters(in: .whitespaces) } }

    @Test func everyFilterPopUpWorks() {
        _ = NSApplication.shared
        let v = TestReportView(report: report(), page: .tests)
        #expect(v.filterPopUps.map(\.title) == ["Failed Tests (1)", "Failed Runs (1)", "iPhone 17", "Test Scheme Action", "Untagged Tests"])
        #expect(v.filterPopUps.allSatisfy { $0.itemArray.dropFirst().allSatisfy { $0.action != nil && $0.target === v } })
        #expect(tests(v) == ["circleArea()", "squareArea()"])
        // Failed Tests.
        v.pickFilter(menu: 0, item: 1)
        #expect(tests(v) == ["squareArea()"] && v.filterPopUps[0].item(at: 2)?.state == .on)
        v.pickFilter(menu: 0, item: 0)
        // Failed Runs.
        v.pickFilter(menu: 1, item: 1)
        #expect(tests(v) == ["squareArea()"] && v.filterPopUps[1].item(at: 2)?.state == .on && v.filterPopUps[1].item(at: 1)?.state == .off)
        v.pickFilter(menu: 1, item: 0)
        // The destination, the configuration and the tag keep the runs that match.
        for menu in 2...4 {
            v.pickFilter(menu: menu, item: 1)
            #expect(tests(v) == ["circleArea()", "squareArea()"], "menu \(menu)")
            #expect(v.filterPopUps[menu].item(at: 2)?.state == .on)
            v.pickFilter(menu: menu, item: 0)
            #expect(v.filterPopUps[menu].item(at: 1)?.state == .on)
        }
        var f = TestReportFilters()
        f.device = "Some Other Device"
        #expect(f.rows(report(), failedOnly: false, text: "").isEmpty)
        // A click on a menu item goes through the same path.
        let item = v.filterPopUps[0].item(at: 2)!
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        #expect(v.failedOnly && tests(v) == ["squareArea()"])
    }

    @Test func coverageRowsExpandFromTargetToFiles() {
        _ = NSApplication.shared
        let v = TestReportView(report: report(), page: .coverage)
        #expect(v.lines.contains("Demo") && !v.lines.contains("        Shapes.swift"))
        v.toggleCoverage("Demo")
        #expect(v.lines.contains("        Shapes.swift") && v.lines.contains("        Util.swift"))
        #expect(v.lines.contains("50.0%") && v.lines.contains("80.0%"))
        v.toggleCoverage("Demo")
        #expect(!v.lines.contains("        Util.swift"))
        // A file filter shows the matching files under their target.
        v.filter.stringValue = "util"
        v.filterChanged()
        #expect(v.lines.contains("        Util.swift") && !v.lines.contains("        Shapes.swift"))
        // Test bundles only when asked.
        v.filter.stringValue = ""
        v.filterChanged()
        #expect(!v.lines.contains("DemoTests"))
        v.showTestBundles.state = .on
        v.filterChanged()
        #expect(v.lines.contains("DemoTests"))
    }
}
