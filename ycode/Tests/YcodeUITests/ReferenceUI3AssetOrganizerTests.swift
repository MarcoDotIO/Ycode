import XCTest
@testable import YcodeUI

/// specs/ide/reference-ui-3.md §3 (asset catalog) and §6 (Organizer).
@MainActor
final class ReferenceUI3AssetOrganizerTests: XCTestCase {
    func tempCatalog() throws -> AssetCatalog {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xcassets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AssetCatalog(url: dir)
    }

    func testTypeLabels() {
        XCTAssertEqual(AssetCatalog.Kind.appIconSet.typeLabel, "App Icon")
        XCTAssertEqual(AssetCatalog.Kind.colorSet.typeLabel, "Color")
    }

    func testIOSSingleSizeIcon() throws {
        let c = try tempCatalog()
        let set = try c.addIOSAppIconSet()
        let slots = AssetCatalog.slots(of: set)
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].boxLabel, "1024x1024px")
        XCTAssertEqual(slots[0].captions, ["iOS", "1,024pt"])
        let i = AssetCatalog.inspector(for: set)
        XCTAssertEqual(i.title, "App Icon")
        XCTAssertEqual(i.rows.map(\.label), ["Name", "iOS", "macOS", "watchOS", "Appearances", "Gamut"])
        XCTAssertEqual(i.rows.map { $0.value ?? "" }, ["AppIcon", "Single Size", "None", "None", "None", "Any"])
    }

    func testColorSetInspector() throws {
        let c = try tempCatalog()
        let set = try c.addColorSet(named: "Accent")
        let i = AssetCatalog.inspector(for: set)
        XCTAssertEqual(i.title, "Color Set")
        XCTAssertEqual(i.rows.first?.value, "Accent")
        XCTAssertEqual(i.rows[1], .init("Universal", checked: true))
        XCTAssertEqual(i.rows[2], .init("iPhone", checked: false))
        XCTAssertEqual(i.rows.map(\.label).suffix(4), ["Appearances", "High Contrast", "Gamut", "Localization"])
        XCTAssertEqual(i.rows.filter { $0.checked != nil }.count, 10)
    }

    func testAddMenu() {
        let m = AssetCatalog.addMenu()
        XCTAssertEqual(Array(m.prefix(4).compactMap(\.title)), ["Image Set", "Color Set", "Symbol Image Set", "Data Set"])
        XCTAssertEqual(m.compactMap(\.title).suffix(4), ["Folder", "Folder with Namespace", "Folder from Selection", "Import…"])
        guard case let .submenu(_, ios)? = m.first(where: { $0.title == "iOS" }) else { return XCTFail() }
        XCTAssertTrue(ios.contains(.item("Sticker", enabled: false)))
        XCTAssertTrue(ios.contains(.item("Sticker Pack", enabled: true)))
        guard case let .submenu(_, ios2)? = AssetCatalog.addMenu(insideStickerPack: true).first(where: { $0.title == "iOS" }) else { return XCTFail() }
        XCTAssertTrue(ios2.contains(.item("Sticker", enabled: true)))
        XCTAssertEqual(m.compactMap(\.title).filter { ["macOS", "watchOS", "tvOS", "visionOS", "AR and Textures"].contains($0) }.count, 5)
    }

    func testEditorAddsIOSIcon() throws {
        let c = try tempCatalog()
        let e = AssetCatalogEditorController(url: c.url)
        _ = e.view
        let set = try e.addSet(kind: 3)
        XCTAssertEqual(e.selected?.name, set.name)
        XCTAssertEqual(set.kind, .appIconSet)
    }

    func testOrganizerSidebar() {
        XCTAssertEqual(OrganizerSidebar.sections.map(\.title), ["Products", "Insights", "Reports", "Metrics"])
        XCTAssertEqual(OrganizerSidebar.sections[2].pages.count, 6)
        XCTAssertEqual(OrganizerSidebar.sections[3].pages.count, 8)
        let e = OrganizerSidebar.emptyState(page: "Overview", version: "1.0")
        XCTAssertEqual(e.title, "No Overview Data")
        XCTAssertEqual(e.message, "There is no overview data available for version 1.0.")
    }

    func testOrganizerPageSwitch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let o = OrganizerController(archivesDirectory: dir)
        o.showPage("Overview", section: "Insights")
        XCTAssertEqual(o.page, "Overview")
        XCTAssertEqual(o.emptyTitle.stringValue, "No Overview Data")
        XCTAssertEqual(o.emptyView?.isHidden, false)
        o.showPage("Archives", section: "Products")
        XCTAssertEqual(o.emptyView?.isHidden, true)
    }
}
