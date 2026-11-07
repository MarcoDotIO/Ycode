import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Council round 5, group D (rows 138 and 141) on the shared model both
/// IDEs draw from: the issue summary and the idle activity subtitle.
@MainActor
@Suite struct CouncilR5ChromeShellTests {
    @Test func issueSummaryOrdersKindsAndSizesTheCapsule() {
        let none = IssueSummary()
        #expect(none.isEmpty && none.mostSevere == nil && none.parts.isEmpty)
        let warn = IssueSummary([Diagnostic(severity: .warning, message: "w"), Diagnostic(severity: .note, message: "n")])
        #expect(warn.parts == [.init(kind: .warning, count: 1)] && warn.mostSevere == .warning)
        let both = IssueSummary(errors: 2, warnings: 1, failedTests: 1)
        #expect(both.parts.map(\.kind) == [.error, .warning, .testFailure] && both.mostSevere == .error)
        #expect(IssueSummary.Kind.error.symbol == "xmark.circle.fill" && IssueSummary.Kind.warning.fill == 0xFFE015)
        // G.8: one warning with "1" is 61 wide, an error and a warning 110.5;
        // 36 tall, 7.5 after the scheme capsule.
        let digit: (String) -> Double = { Double($0.count) * 6 }
        #expect(IssueSummary.Capsule.width(warn.parts, symbolsOnly: false, countWidth: digit) == 61)
        #expect(IssueSummary.Capsule.width(IssueSummary(errors: 1, warnings: 1).parts, symbolsOnly: false, countWidth: digit) == 110.5)
        #expect(IssueSummary.Capsule.width(warn.parts, symbolsOnly: true, countWidth: digit) == 50.5)
        #expect(IssueSummary.Capsule.height == 36 && IssueSummary.Capsule.gapAfterScheme == 7.5)
    }

    @Test func linuxModelSummaryAndActivitySubtitle() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        #expect(m.issueSummary.isEmpty && m.activityText == "")
        m.session.isPreparingEditorServices = true
        #expect(m.isPreparingEditorServices && m.activityText == WorkspaceChrome.preparingEditorServicesText)
        m.session.isPreparingEditorServices = false
        #expect(m.activityText == "")
        #expect(WorkspaceChrome.idleActivityText(preparingEditorServices: false) == "")
    }
}
