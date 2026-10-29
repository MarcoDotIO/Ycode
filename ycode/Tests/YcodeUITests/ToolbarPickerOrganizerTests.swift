import XCTest
@testable import YcodeUI
import YcodeBuild

/// Toolbar destination title, the compact New Project picker layout, the
/// new-file grid's sticky headers and the Organizer window toolbar.
@MainActor
final class ToolbarPickerOrganizerTests: XCTestCase {
    func testDestinationTitleIsDestinationName() throws {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        let mac = Destination(name: "My Mac", specifier: "platform=macOS", platform: "macOS", kind: .device)
        wc.setDestinationGroups([DestinationGroup(title: "macOS", destinations: [mac])])
        session.destination = mac
        wc.rebuildDestinationMenu()
        XCTAssertNotEqual(wc.destinationPopUp.titleOfSelectedItem, "NSMenuItem")
        XCTAssertFalse(wc.destinationPopUp.itemTitles.contains("NSMenuItem"))
        XCTAssertEqual(wc.destinationTitle, "My Mac")
    }

    func testPickerRowsPackAtTop() throws {
        let p = NewProjectPickerController()
        // Host it in a window taller than the rows need.
        let w = NSWindow(contentViewController: p)
        w.setContentSize(NSSize(width: 340, height: 600))
        p.view.layoutSubtreeIfNeeded()
        let rows = p.rowViews
        XCTAssertGreaterThan(rows.count, 1)
        let frames = rows.map { p.view.convert($0.bounds, from: $0) }
        // Root is not flipped: each row sits just below the previous one.
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(a.minY - b.maxY, NewProjectPickerController.rowSpacing, accuracy: 0.5)
        }
        let cancel = try XCTUnwrap(p.cancelButton)
        let c = p.view.convert(cancel.bounds, from: cancel)
        XCTAssertLessThan(c.maxY, frames.last!.minY, "Cancel is below the rows")
        XCTAssertGreaterThan(frames.first!.maxY, p.view.bounds.maxY - 60, "the rows start at the top")
    }

    func testStickyHeader() throws {
        let s = NewFileSheetController(platform: "iOS")
        s.view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        s.view.layoutSubtreeIfNeeded()
        let grid = try XCTUnwrap(s.grid)
        XCTAssertTrue(grid.stickyHeader.isHidden)
        guard grid.headers.count > 1 else { return }
        let second = grid.headers[1]
        let y = grid.scroll.documentView!.convert(second.frame, from: second.superview).minY + 10
        grid.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        grid.updateStickyHeader()
        XCTAssertFalse(grid.stickyHeader.isHidden)
        XCTAssertEqual(grid.stickyHeader.label.stringValue, second.stringValue)
    }

    func testOrganizerToolbar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let o = OrganizerController(archivesDirectory: dir)
        let w = NSWindow(contentViewController: o)
        w.isReleasedWhenClosed = false
        o.installToolbar()
        let t = try XCTUnwrap(w.toolbar)
        XCTAssertTrue(t === o.toolbar)
        let views = t.items.compactMap(\.view)
        XCTAssertTrue(views.contains { $0 === o.backButton })
        XCTAssertTrue(views.contains { $0 === o.forwardButton })
        XCTAssertTrue(views.contains { $0 === o.bellButton })
        // swiftlint:disable:next redundant_nil_coalescing - flattens a double optional
        XCTAssertNil(o.backButton.superview.map { $0.isDescendant(of: o.view) ? $0 : nil } ?? nil)
    }
}
