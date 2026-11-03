import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
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
}
