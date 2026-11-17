import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let b4Ycode = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// B4-PANES screenshots of the macOS IDE, rendered offscreen into
/// `.build-ide/b4-shots/` (the Linux walk's are `YCODE_IDE_PANES4`'s).
@MainActor
@Suite(.serialized) struct Beta4PanesShotTests {
    static let out = b4Ycode.appendingPathComponent(".build-ide/b4-shots")

    /// One view as it draws itself (the glass sidebars of a window kept off
    /// every display are not captured by the window server).
    func renderView(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: Self.out.appendingPathComponent(name))
    }

    /// The window as the window server draws it (kept off every display by
    /// the offscreen guard; `UISpacingProbeTests.shot`).
    func render(_ view: NSView, _ name: String) throws {
        let w = try #require(view.window)
        w.contentView?.layoutSubtreeIfNeeded()
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        UISpacingProbeTests.shot(w, Self.out.appendingPathComponent(name))
    }

    @Test func shots() throws {
        let t = Beta4PanesTests()
        let dir = try t.tempDir("shots")
        defer { try? FileManager.default.removeItem(at: dir) }
        let td = TestDefaults("b4-shots")
        defer { td.remove() }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            // Settings: Editing ▸ Display pushed (P-138), then Components (P-140).
            let settings = SettingsWindowController(prefs: Preferences(defaults: td.defaults), components: [])
            let sw = try #require(settings.window)
            sw.appearance = NSAppearance(named: appearance)
            settings.show(page: "Editing")
            let editing = try #require(settings.pane(TextEditingSettingsPane.self))
            _ = t.drillRow(editing, "Display")?.accessibilityPerformPress()
            try render(try #require(sw.contentView), "settings-display-\(name).png")
            settings.goBack()
            try render(try #require(sw.contentView), "settings-editing-\(name).png")
            sw.setContentSize(NSSize(width: 710, height: 700))
            try render(try #require(sw.contentView), "settings-tall-\(name).png")

            // The workspace: Repositories glyphs (P-047), the filter (P-038),
            // a folder's inspector (P-089), the assistant pane (P-026), the
            // asset list's bar (P-156).
            let wc = try t.window(try t.iosApp(in: dir.appendingPathComponent(name)))
            let w = try #require(wc.window)
            w.appearance = NSAppearance(named: appearance)
            NSApp.setActivationPolicy(.accessory)
            w.setFrame(NSRect(x: 40, y: 40, width: 1400, height: 880), display: true)
            w.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            wc.mainSplit.splitView.setPosition(289.5, ofDividerAt: 0)
            let outline = wc.navigator.outline
            if let row = (0..<outline.numberOfRows).first(where: { r in
                guard let i = outline.item(atRow: r) as? OutlineItem else { return false }
                return i.nodeKind != .file && i.path == nil && i.nodePath != nil
            }) { outline.selectRowIndexes([row], byExtendingSelection: false) }
            w.makeFirstResponder(wc.navigator.filter)
            (wc.navigator.filter.currentEditor() as? NSTextView)?.insertText("Con", replacementRange: NSRange(location: 0, length: 0))
            try renderView(wc.navigator.view, "navigator-folder-filter-\(name).png")
            try renderView(wc.inspector.view, "inspector-folder-\(name).png")
            wc.navigator.select(1)
            try renderView(wc.navigator.view, "navigator-source-control-\(name).png")
            wc.navigator.select(8)
            try renderView(wc.navigator.view, "navigator-reports-\(name).png")
            wc.navigator.select(0)
            w.makeFirstResponder(nil)
            wc.navigator.filter.stringValue = ""
            wc.navigator.filterText = ""
            wc.showCodingAssistant(nil)
            try renderView(wc.navigator.view, "assistant-\(name).png")
            wc.showNavigator(0)
            if let assets = wc.session.model.root.allFiles.first(where: { $0.name == "Assets.xcassets" })?.path {
                wc.open(path: assets, line: nil)
                try renderView(wc.editorArea.view, "asset-bar-\(name).png")
            }
            w.close()
            sw.close()
        }
    }
}
