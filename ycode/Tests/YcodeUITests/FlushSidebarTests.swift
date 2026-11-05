import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

/// The plain sidebar item that macOS 26 uses instead of the system's
/// floating sidebar (`FlushSidebar`, `specs/ide/metrics.md` §14.1), forced on
/// whatever system runs the tests: the workspace window must measure as with
/// the system's sidebar item.
@MainActor
@Suite(.serialized) struct FlushSidebarTests {
    func forced(_ body: () throws -> Void) rethrows {
        FlushSidebar.forced = true
        defer { FlushSidebar.forced = nil }
        try body()
    }

    @Test func workspaceMeasuresMeetTheSpecWithThePlainItem() throws {
        try forced {
            try UISpacingTests().withWindow { wc, win in
                #expect(wc.navigatorItem.behavior != .sidebar)
                #expect(win.toolbar?.items.contains { $0 is NSTrackingSeparatorToolbarItem && $0.itemIdentifier == FlushSidebar.trackingSeparatorID } == true)
                let r = try #require(LayoutProbe.Recorder(window: win))
                LayoutProbe.measureWorkspace(wc, into: r)
                #expect(r.measures.count > 40)
                for m in r.measures where m.ok == false {
                    Issue.record("\(m.name) = \(m.value), spec \(m.op) \(m.spec ?? 0) (\(m.source))")
                }
                // The navigator covers its divider: the editor starts at its edge.
                #expect(abs((r.frames["editor.area"]?.x ?? 0) - Double(WorkspaceWindowController.navigatorWidth)) <= 0.5)
                // Hiding and showing the navigator keeps working.
                wc.setLeftPane(codingAssistant: false)
                #expect(wc.navigatorItem.isCollapsed)
                wc.setLeftPane(codingAssistant: false)
                #expect(!wc.navigatorItem.isCollapsed)
            }
        }
    }
}
