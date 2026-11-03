import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

/// reference-ui-2.md §5 (step durations, All | Recent), §6.5 (coverage)
/// and §9 (console metadata columns).
struct ReportLooseEndsTests {
    func report(_ log: [String], times: [TimeInterval] = [], duration: TimeInterval = 0) -> BuildReport {
        var r = BuildReport(title: "Build Demo", date: Date(), succeeded: true, log: log, errorCount: 0, warningCount: 0)
        r.context.scheme = "Demo"
        r.context.containerKind = "Package"
        r.context.logTimes = times
        r.context.duration = duration
        return r
    }

    @MainActor @Test func buildLogViewScope() {
        let first = report(["[1/2] Compiling Demo a.swift", "[2/2] Compiling Demo b.swift"])
        var second = report(["[1/1] Compiling Demo b.swift"])
        second.context.carriedOver = BuildLogModel.carriedOver(from: first, into: second)
        let v = BuildLogView(report: second)
        v.kind.selectedSegment = 0
        #expect(v.shownSections.flatMap(\.steps).count == 2)
        v.scope.selectedSegment = 1
        #expect(v.shownSections.flatMap(\.steps).count == 1)
    }
}
