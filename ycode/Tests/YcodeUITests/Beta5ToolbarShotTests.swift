import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let b5Ycode = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// B5-TOOLBAR screenshots of the macOS IDE, rendered offscreen into
/// `.build-ide/b5-shots/` (the Linux walk's are `YCODE_IDE_TOOLBAR5`'s):
/// the window at 1400, 1100, 900 and 817 points, and while building at
/// 1400 and 1100, light and dark. The "»" menu itself is not opened (no
/// menu may reach a display); its entries are listed in a text file.
@MainActor
@Suite(.serialized) struct Beta5ToolbarShotTests {
    static let out = b5Ycode.appendingPathComponent(".build-ide/b5-shots")

    @Test func shots() throws {
        let t = Beta5ToolbarTests()
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [String] = []
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let (wc, session, dir) = try t.window("shots-\(name)")
            defer { try? FileManager.default.removeItem(at: dir); wc.window?.orderOut(nil) }
            let w = try #require(wc.window)
            w.appearance = NSAppearance(named: appearance)
            NSApp.setActivationPolicy(.accessory)
            w.orderBack(nil)
            func shot(_ file: String) {
                w.contentView?.superview?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                UISpacingProbeTests.shot(w, Self.out.appendingPathComponent("toolbar-\(file)-\(name).png"))
            }
            for width in [1400, 1100, 900, 817] {
                w.setFrame(NSRect(x: 40, y: 40, width: CGFloat(width), height: 880), display: true)
                wc.fitToolbar()
                shot("w\(width)")
                lines.append("\(name) \(width): visible \(t.visible(wc)) overflow \(wc.overflowedToolbarItems)")
            }
            wc.updateOverflowMenuForms()
            for item in w.toolbar?.items ?? [] where wc.overflowedToolbarItems.contains(item.itemIdentifier.rawValue) {
                let f = item.menuFormRepresentation
                lines.append("\(name) » \(f?.title ?? "-") glyph \(f?.image != nil) \(f?.submenu?.items.map(\.title) ?? [])")
            }
            session.noteToolActivity(.building(WorkspaceSession.BuildActivityText.progress(done: 40, total: 76)))
            for width in [1400, 1100] {
                w.setFrame(NSRect(x: 40, y: 40, width: CGFloat(width), height: 880), display: true)
                wc.fitToolbar()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                shot("building-w\(width)")
                lines.append("\(name) building \(width): \"\(wc.activityView.shownStatus)\" stop \(wc.runStopControl?.isEnabled(forSegment: 1) ?? false)")
            }
            session.noteToolActivity(.idle)
        }
        try lines.joined(separator: "\n").write(to: Self.out.appendingPathComponent("toolbar.txt"), atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }
}
