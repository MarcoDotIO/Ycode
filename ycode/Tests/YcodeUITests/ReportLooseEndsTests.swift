import Foundation
import Testing
import YcodeBuild
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

    @Test func stepDurationsFromArrivalTimes() {
        let r = report(["[1/3] Compiling Demo a.swift", "[2/3] Compiling Demo b.swift", "[3/3] Linking Demo"],
                       times: [0, 0.5, 1.75], duration: 2)
        let steps = BuildLogModel.sections(r).flatMap(\.steps)
        #expect(steps.map(\.duration) == [0.5, 1.25, 0.25])
        #expect(steps[0].children[0].duration == 0.5)
        #expect(steps[0].displayTitle.hasPrefix("Compiling a.swift  "))
        // Without times (or a mismatched count) there is no duration.
        #expect(BuildLogModel.sections(report(["[1/1] Compiling Demo a.swift"])).flatMap(\.steps).first?.duration == nil)
    }

    @Test func allAddsCarriedOverStepsRecentDoesNot() {
        let first = report(["[1/2] Compiling Demo a.swift", "[2/2] Compiling Demo b.swift"])
        var second = report(["[1/1] Compiling Demo b.swift"])
        second.context.carriedOver = BuildLogModel.carriedOver(from: first, into: second)
        #expect(second.context.carriedOver.flatMap(\.steps).map(\.title) == ["Compiling a.swift"])
        let recent = BuildLogModel.sections(second)
        let all = BuildLogModel.merge(recent, second.context.carriedOver)
        #expect(recent.flatMap(\.steps).map(\.title) == ["Compiling b.swift"])
        #expect(all.flatMap(\.steps).map(\.title) == ["Compiling b.swift", "Compiling a.swift"])
        // A third build carries over through the second.
        let third = report(["[1/1] Linking Demo"])
        #expect(Set(BuildLogModel.carriedOver(from: second, into: third).flatMap(\.steps).map(\.title)) == ["Compiling a.swift", "Compiling b.swift"])
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

    @Test func ycodebuildCoverageSummary() {
        let json = #"{"targets":[{"name":"Calc","coveredLines":3,"executableLines":4,"files":[{"path":"/p/Sources/Calc/Calc.swift","coveredLines":3,"executableLines":4}]}]}"#
        let items = CoverageModel.parseYcodebuildSummary(Data(json.utf8))
        #expect(items == [CoverageItem(name: "Calc", coveredLines: 3, executableLines: 4,
                                       files: [CoverageItem(name: "Calc.swift", coveredLines: 3, executableLines: 4)])])
        #expect(CoverageModel.percent(items[0].fraction) == "75.0%")
    }

    @Test func runnerCoverageFlags() {
        var r = TestRunner()
        r.coverage = true
        #expect(r.command(for: BuildRequest(container: .package("/p"))).args.suffix(2) == ["test", "--enable-code-coverage"])
        let proj = r.command(for: BuildRequest(container: .project("/a/A.xcodeproj"), scheme: "A")).args
        #expect(proj.contains("-enableCodeCoverage") && proj.last == "test")
        #expect(!TestRunner().command(for: BuildRequest(container: .package("/p"))).args.contains("--enable-code-coverage"))
    }

    @Test func pidColumn() {
        var m = ConsoleMetadata()
        #expect(ConsoleMetadata.supportedColumns == [0, 1, 3])
        m.pidTID = true
        let e = [ConsoleEntry(kind: .target, text: "hi\n", pid: 42), ConsoleEntry(kind: .debugger, text: "x\n")]
        #expect(WorkspaceSession.consoleText(e, metadata: m) == "42 hi\nx\n")
        m.type = true
        #expect(WorkspaceSession.consoleText(e, metadata: m) == "42 [Target] hi\n[Debugger] x\n")
    }
}
