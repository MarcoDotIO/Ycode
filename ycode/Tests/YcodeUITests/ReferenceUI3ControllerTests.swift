import XCTest
@testable import YcodeUI

/// Drives the reference-ui-3 controllers: asset catalog filter and Color Set
/// inspector edits (§3), the new-file icon grid (§5.3), and the Organizer
/// toolbar (§6).
@MainActor
final class ReferenceUI3ControllerTests: XCTestCase {
    func tempCatalog() throws -> AssetCatalog {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xcassets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AssetCatalog(url: dir)
    }

    func testAssetFilter() throws {
        let c = try tempCatalog()
        try c.addColorSet(named: "AccentColor")
        try c.addImageSet(named: "Logo")
        try c.addMacAppIconSet()
        let e = AssetCatalogEditorController(url: c.url)
        _ = e.view
        XCTAssertEqual(e.sets.count, 3)
        e.filterField.stringValue = "acc"
        _ = e.filterField.target?.perform(e.filterField.action, with: e.filterField)
        XCTAssertEqual(e.filter, "acc")
        XCTAssertEqual(e.sets.map(\.name), ["AccentColor"])
        XCTAssertEqual(e.selected?.name, "AccentColor")
        e.setFilter("")
        XCTAssertEqual(e.sets.count, 3)
    }

    func entries(_ set: AssetCatalog.AssetSet) -> [[String: Any]] {
        AssetCatalog.readContents(set.url)["colors"] as? [[String: Any]] ?? []
    }

    func testColorInspectorWritesContents() throws {
        let c = try tempCatalog()
        let set = try c.addColorSet(named: "Accent")
        let e = AssetCatalogEditorController(url: c.url)
        _ = e.view
        e.select("Accent")
        let iphone = try XCTUnwrap(e.inspectorControls["iPhone"] as? NSButton)
        iphone.state = .on
        _ = iphone.target?.perform(iphone.action, with: iphone)
        XCTAssertEqual(Set(entries(set).map { $0["idiom"] as? String }), ["universal", "iphone"])
        XCTAssertEqual((e.inspectorControls["iPhone"] as? NSButton)?.state, .on)

        let popup = try XCTUnwrap(e.inspectorControls["Appearances"] as? NSPopUpButton)
        popup.selectItem(withTitle: "Any, Dark")
        _ = popup.target?.perform(popup.action, with: popup)
        XCTAssertEqual(entries(set).filter(AssetCatalog.isDark).count, 2)
        XCTAssertEqual((e.inspectorControls["Appearances"] as? NSPopUpButton)?.titleOfSelectedItem, "Any, Dark")

        try e.setInspectorCheckbox("High Contrast", on: true)
        XCTAssertEqual(entries(set).count, 8)
        XCTAssertEqual((e.inspectorControls["High Contrast"] as? NSButton)?.state, .on)
        try e.setInspectorCheckbox("High Contrast", on: false)
        try e.setInspectorAppearances("None")
        try e.setInspectorCheckbox("iPhone", on: false)
        XCTAssertEqual(entries(set).count, 1)
        // The last device cannot be turned off.
        try e.setInspectorCheckbox("Universal", on: false)
        XCTAssertEqual(entries(set).count, 1)
        let text = try String(contentsOf: set.url.appendingPathComponent("Contents.json"), encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("}\n"))
    }

    func testNewFileGrid() throws {
        let s = NewFileSheetController(platform: "iOS")
        _ = s.view
        let grid = try XCTUnwrap(s.grid)
        XCTAssertEqual(grid.headers.first?.stringValue, "Source")
        XCTAssertEqual(grid.tiles.count, s.sections.reduce(0) { $0 + $1.entries.count })
        XCTAssertEqual(grid.tiles.first?.entry.title, "Swift File")
        XCTAssertTrue(grid.tiles.first?.isSelected == true)
        let tile = try XCTUnwrap(grid.tiles.first { $0.entry.title == "SwiftUI View" })
        tile.onClick?(tile.entry)
        XCTAssertEqual(s.selectedEntry?.title, "SwiftUI View")
        XCTAssertEqual(grid.tiles.filter(\.isSelected).map(\.entry.title), ["SwiftUI View"])
        var chosen: String?
        s.onNext = { chosen = $0.title }
        tile.onDoubleClick?(tile.entry)
        XCTAssertEqual(chosen, "SwiftUI View")
        s.setFilter("metal")
        XCTAssertEqual(grid.tiles.map(\.entry.title), ["Metal File"])
        XCTAssertEqual(grid.headers.map(\.stringValue), ["Source"])
    }

    func testOrganizerHistoryAndBell() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let o = OrganizerController(archivesDirectory: dir)
        _ = o.view
        XCTAssertFalse(o.backButton.isEnabled)
        o.showPage("Overview", section: "Insights")
        o.showPage("Hangs", section: "Reports")
        XCTAssertEqual(o.pageTitle.stringValue, "Hangs")
        XCTAssertTrue(o.backButton.isEnabled)
        XCTAssertFalse(o.forwardButton.isEnabled)
        o.backButton.performClick(nil)
        XCTAssertEqual(o.page, "Overview")
        o.goBack()
        XCTAssertEqual(o.page, "Archives")
        XCTAssertFalse(o.canGoBack)
        o.forwardButton.performClick(nil)
        XCTAssertEqual(o.page, "Overview")
        o.showPage("Memory", section: "Metrics")
        XCTAssertFalse(o.canGoForward)
        XCTAssertEqual(o.history.map(\.page), ["Archives", "Overview", "Memory"])
        XCTAssertFalse(o.notificationsShown)
        o.bellButton.performClick(nil)
        XCTAssertTrue(o.notificationsShown)
        o.bellButton.performClick(nil)
        XCTAssertFalse(o.notificationsShown)
    }
}
