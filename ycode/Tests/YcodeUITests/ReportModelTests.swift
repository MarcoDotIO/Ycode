import Foundation
import Testing
import YcodeBuild
@testable import YcodeUI

/// specs/ide/reference-ui-2.md §4 (Report navigator), §5 (build log) and
/// §6 (test report pages): the model types behind the views.
struct ReportModelTests {
    func report(_ action: String, scheme: String? = "Demo", at t: TimeInterval, ok: Bool = true, errors: Int = 0,
                log: [String] = [], location: ReportLocation = .local) -> BuildReport {
        var r = BuildReport(title: "\(action) Demo", date: Date(timeIntervalSince1970: t), succeeded: ok, log: log, errorCount: errors, warningCount: 0)
        r.context.action = action
        r.context.scheme = scheme
        r.context.containerName = "Demo"
        r.context.location = location
        return r
    }

    @Test func navigatorGroupsRowsAndOrder() {
        var test = report("Test", at: 300, ok: false, errors: 1)
        test.context.plan = "Demo (Autocreated)"
        test.context.tests = [TestOutcome(suite: nil, name: "a", status: .passed), TestOutcome(suite: nil, name: "b", status: .failed)]
        test.context.coverage = [CoverageItem(name: "Demo", coveredLines: 3, executableLines: 4)]
        let reports = [report("Build", at: 100), test, report("Resolve Packages", scheme: nil, at: 200),
                       report("Build", scheme: "Other", at: 250, ok: false, errors: 2), report("Build", at: 400, location: .cloud)]
        let g = ReportNavigatorModel.groups(reports, dayAndTime: { "T\(Int($0.timeIntervalSince1970))" })
        #expect(g.map(\.title) == ["Demo", "Other", "Package"])
        #expect(g[0].rows.map(\.title) == ["Demo/Demo (Autocreated)", "Build"]) // newest first
        #expect(g[0].rows[0].index == 1 && g[0].rows[0].detail == "T300" && g[0].rows[0].badge == "1")
        #expect(g[0].rows[0].children.map(\.title) == ReportNavigatorModel.testPages)
        #expect(g[0].rows[0].children[1].detail == "75.0%" && g[0].rows[0].children[2].badge == "1")
        #expect(g[0].rows[0].children.allSatisfy { $0.page == $0.title && $0.index == 1 })
        #expect(g[0].rows[1].badge == nil && g[1].rows[0].badge == "2")
        #expect(g[2].isPackage && g[2].rows.map(\.title) == ["Resolve Packages"])
        let cloud = ReportNavigatorModel.groups(reports, location: .cloud)
        #expect(cloud.count == 1 && cloud[0].rows.map(\.index) == [4])
        let recent = ReportNavigatorModel.groups(reports, recentOnly: true, now: Date(timeIntervalSince1970: 250 + 86_400))
        #expect(recent.flatMap(\.rows).map(\.index) == [1, 3])
        #expect(ReportNavigatorModel.defaultPage(test) == "Insights" && ReportNavigatorModel.defaultPage(reports[0]) == "Log")
    }

    @MainActor @Test func navigatorShowsModelRows() throws {
        let nav = NavigatorAreaController()
        _ = nav.view
        nav.setReports([report("Build", at: 100), report("Build", at: 200, ok: false, errors: 1)])
        let g = try #require(nav.rows(8).first)
        #expect(g.title == "Demo" && g.children.map(\.reportIndex) == [1, 0] && g.children[0].badge == "1")
        nav.reportScope.selectedSegment = 1
        nav.setReports([report("Build", at: 100)])
        #expect(nav.rows(8).isEmpty)
    }

    @Test func buildLogSectionsNestStepsAndIssues() {
        var r = report("Build", at: 0, ok: false, errors: 1, log: [
            "[1/4] Compiling Demo main.swift util.swift",
            "/x/Sources/Demo/util.swift:3:1: error: broken",
            "[2/4] Emitting module Demo",
            "[3/4] Linking tool",
            "/x/main.swift:1:1: warning: unused",
            "Build complete!",
        ])
        r.context.containerKind = "Package"
        r.context.configuration = "Debug"
        r.context.destination = "My Mac"
        r.context.sdk = "macOS 27.2"
        r.context.duration = 1.25
        let s = BuildLogModel.sections(r)
        #expect(s.map(\.title) == ["Build target Demo", "Build target tool-product"])
        #expect(s[0].steps.map(\.title) == ["Compiling main.swift util.swift", "Emitting module Demo"])
        #expect(s[0].steps[0].children.map(\.title) == ["Compile main.swift util.swift"])
        // Issues go to the task that compiled their file.
        #expect(s[0].steps[0].badge == "2" && s[0].steps[0].children[0].issues.map(\.message) == ["broken", "unused"])
        #expect(s[1].steps[0].badge == nil)
        #expect(BuildLogModel.subtitle(r.context) == "Package Demo | Configuration Debug | Destination My Mac | SDK macOS 27.2")
        #expect(BuildLogModel.filter(s, messages: .all).flatMap(\.steps).count == 3)
        #expect(BuildLogModel.filter(s, messages: .issues).flatMap(\.steps).count == 1)
        let errors = BuildLogModel.filter(s, messages: .errors)
        #expect(errors.map(\.target) == ["Demo"] && errors[0].steps.count == 1)
        #expect(BuildLogModel.filter(s, messages: .all, text: "Emit").flatMap(\.steps).map(\.title) == ["Emitting module Demo"])
        let f = BuildLogModel.footer(r)
        #expect(f.0.hasPrefix("Build failed ") && f.0.hasSuffix("  1.2 seconds") || f.0.hasSuffix("  1.3 seconds"))
        #expect(f.1 == "1 error, 0 warnings")
        #expect(BuildLogStep(title: "Compiling a.swift", duration: 0.1).displayTitle == "Compiling a.swift  0.1 seconds")
    }

    @Test func buildLogReadsXcodebuildTasks() {
        let r = report("Build", at: 0, log: [
            "SwiftCompile normal arm64 Compiling\\ App.swift /p/App.swift (in target 'App' from project 'App')",
            "/p/App.swift:2:1: warning: var never mutated",
            "Ld /build/App.app/Contents/MacOS/App normal (in target 'App' from project 'App')",
        ])
        let s = BuildLogModel.sections(r)
        #expect(s.map(\.target) == ["App"] && s[0].steps.map(\.title) == ["Compiling App.swift", "Linking normal"] || s[0].steps.first?.title == "Compiling App.swift")
        #expect(s[0].steps[0].warningCount == 1)
        #expect(BuildLogModel.outline(s).contains("    Compile App.swift  [1]"))
    }

    @Test func testReportPages() {
        var r = report("Test", at: 0, ok: false, errors: 1)
        r.context.plan = "Demo (Autocreated)"
        r.context.testTargets = 1
        r.context.testTarget = "DemoTests"
        r.context.destination = "MacBook Pro"
        r.context.sdk = "macOS 27.2"
        r.context.tests = [
            TestOutcome(suite: nil, name: "circleArea", status: .passed, duration: 0.00076),
            TestOutcome(suite: nil, name: "squareArea", status: .failed,
                        failures: [Diagnostic(severity: .error, message: "Expectation failed: (area → 3) == 4\n(area → 3) == 4",
                                              location: .init(file: "/x/ShapeTests.swift", line: 9))], duration: 0.0012),
        ]
        let m = TestReportModel.summary(r)
        #expect(m.title == "Demo/Demo (Autocreated)" && m.builtWith == "Built with macOS 27.2" && m.total == "2 Tests")
        #expect(m.configurations.map(\.name) == ["MacBook Pro macOS 27.2", "Test Scheme Action"] && m.configurations[0].failedShare == 0.5)
        #expect(m.failuresHeader == "Test Failures  1 total failure" && m.failures == ["squareArea()  Expectation failed: (area → 3) == 4"])
        #expect(TestReportModel.testsHeader(r) == "1 failed and 1 passed · Test plan with 1 test target")
        #expect(TestReportModel.filterTitles(r).prefix(2) == ["Failed Tests (1)", "Failed Runs (1)"])
        let rows = TestReportModel.testRows(r)
        #expect(rows.map(\.title) == ["DemoTests", "circleArea()", "squareArea()", "ShapeTests.swift:9: Expectation failed: (area → 3) == 4", "(area → 3) == 4"])
        #expect(rows[1].duration == "0.00076s" && rows[3].kind == .failure && rows[4].kind == .expansion)
        #expect(TestReportModel.testRows(r, failedOnly: true).filter { $0.kind == .test }.map(\.title) == ["squareArea()"])
        #expect(TestReportModel.testRows(r, text: "circle").count == 2)
    }

    @Test func coverageRowsAndExport() throws {
        let json = #"{"data":[{"files":[{"filename":"/p/Sources/Demo/a.swift","summary":{"lines":{"count":10,"covered":8}}},{"filename":"/p/Sources/Demo/b.swift","summary":{"lines":{"count":10,"covered":2}}},{"filename":"/p/Tests/DemoTests/t.swift","summary":{"lines":{"count":5,"covered":5}}}]}]}"#
        let items = CoverageModel.parseLLVMCovExport(Data(json.utf8))
        #expect(items.map(\.name) == ["Demo", "DemoTests"] && items[0].executableLines == 20)
        #expect(CoverageModel.percent(items[0].fraction) == "50.0%")
        #expect(CoverageModel.total(items) == 0.5)
        #expect(CoverageModel.rows(items, showTestBundles: false).map(\.name) == ["Demo"])
        #expect(CoverageModel.rows(items, showTestBundles: true).count == 2)
        #expect(CoverageModel.rows(items, showTestBundles: false, filter: "b.sw").first?.files.map(\.name) == ["b.swift"])
    }

    @Test func runnerDurations() {
        #expect(TestResultParser.parse("Test Case '-[DemoTests.T testA]' passed (0.003 seconds).").first?.duration == 0.003)
        #expect(TestResultParser.parse("✔ Test circleArea() passed after 0.001 seconds.").first?.duration == 0.001)
    }
}
