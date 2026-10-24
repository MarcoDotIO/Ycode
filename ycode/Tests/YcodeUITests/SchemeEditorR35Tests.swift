import AppKit
import Foundation
import Testing
import YcodeWorkspace
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// reference-ui-5.md §11.3 (P11): the scheme editor's tables.
@MainActor
@Suite struct SchemeEditorR35Tests {
    func editor() throws -> SchemeEditorController {
        _ = NSApplication.shared
        let text = try String(contentsOf: ycodeDir.appendingPathComponent(
            "Tests/YcodeWorkspaceTests/Fixtures/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"), encoding: .utf8)
        let e = SchemeEditorController(scheme: try Scheme(parsing: text, name: "App"), configurations: ["Debug", "Release"])
        e.availableTargets = [
            .init(blueprintIdentifier: "0E0000000000000000000001", buildableName: "App.app", blueprintName: "App", referencedContainer: "container:App.xcodeproj"),
            .init(blueprintIdentifier: "0E0000000000000000000002", buildableName: "AppTests.xctest", blueprintName: "AppTests",
                  referencedContainer: "container:App.xcodeproj"),
        ]
        e.containerDirectoryOverride = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-scheme-r35")
        _ = e.view
        return e
    }

    @Test func buildTargetsTableHasPlusMinusAndFilter() throws {
        let e = try editor()
        e.select(action: 0)
        let t = try #require(e.buildTargetsTable)
        #expect(t.titles == ["App"] && t.table.tableColumns.map(\.title) == ["Targets", "Analyze", "Test", "Run", "Profile", "Archive"])
        #expect(t.filterField.placeholderString == "Filter" && t.plusButton.isEnabled)
        #expect(e.addableBuildTargets.map(\.blueprintName) == ["AppTests"])
        e.addBuildTarget(e.addableBuildTargets[0])
        let t2 = try #require(e.buildTargetsTable)
        #expect(t2.titles == ["App", "AppTests"] && !t2.plusButton.isEnabled)
        #expect(e.scheme.buildEntries[1].actions == [.testing])
        #expect(e.subtitle(forAction: 0) == "2 targets")
        // Filter.
        t2.filterField.stringValue = "tests"
        t2.filterChanged()
        #expect(e.buildTargetsTable?.titles == ["AppTests"] && e.buildTargetsTable?.filterField.stringValue == "tests")
        // − removes the selected row.
        let t3 = try #require(e.buildTargetsTable)
        t3.table.selectRowIndexes([0], byExtendingSelection: false)
        t3.minusClicked()
        #expect(e.scheme.buildEntries.map(\.reference.blueprintName) == ["App"])
    }

    @Test func emptyStatesForArgumentsAndEnvironment() throws {
        let e = try editor()
        e.select(action: 1, tab: 1)
        #expect(e.arguments.emptyLabel.stringValue == "No Arguments")
        #expect(e.environment.emptyLabel.stringValue == "No Environment Variables")
        e.arguments.rows = []
        #expect(!e.arguments.emptyLabel.isHidden)
    }

    @Test func testPlansTableWithSubtitleArrowAndDefault() throws {
        let e = try editor()
        e.select(action: 2)
        // No plans yet: the autocreated row with its subtitle.
        let t = try #require(e.testPlansTable)
        #expect(t.titles == ["App (Autocreated)"] && t.table.tableColumns.map(\.title) == ["Test Plans", "Default"])
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        func cells(_ t: SchemeTable) -> [NSView] { t.rows.flatMap { $0 }.flatMap(all) }
        #expect(cells(t).contains { ($0 as? NSTextField)?.stringValue == "1 test target \u{2014} from the scheme" })
        let dir = try #require(e.containerDirectory)
        e.addTestPlan(file: dir.appendingPathComponent("App/App.xctestplan"))
        e.addTestPlan(file: dir.appendingPathComponent("Smoke.xctestplan"))
        #expect(e.scheme.testPlans.map(\.reference) == ["container:App/App.xctestplan", "container:Smoke.xctestplan"])
        let t2 = try #require(e.testPlansTable)
        #expect(t2.titles == ["App", "Smoke"])
        #expect(cells(t2).contains { ($0 as? NSTextField)?.stringValue == "App/App.xctestplan" })
        // The go-to arrow opens the plan.
        var opened: URL?
        e.onOpenFile = { opened = $0 }
        let arrow = try #require(cells(t2).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "container:Smoke.xctestplan" && $0.toolTip != nil })
        arrow.performClick(nil)
        #expect(opened?.path == dir.appendingPathComponent("Smoke.xctestplan").path)
        e.setDefaultTestPlan("container:Smoke.xctestplan")
        #expect(e.scheme.testPlans.map(\.isDefault) == [false, true])
        let t3 = try #require(e.testPlansTable)
        t3.table.selectRowIndexes([1], byExtendingSelection: false)
        t3.minusClicked()
        #expect(e.scheme.testPlans.map(\.reference) == ["container:App/App.xctestplan"] && e.scheme.testPlans[0].isDefault)
        e.testPlansTable?.filterField.stringValue = "zzz"
        e.testPlansTable?.filterChanged()
        #expect(e.testPlansTable?.titles == [] && e.testPlansTable?.emptyLabel.isHidden == false)
    }
}
