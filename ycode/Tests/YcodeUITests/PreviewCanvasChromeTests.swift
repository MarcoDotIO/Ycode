import AppKit
import Foundation
import Testing
@testable import YcodeUI

/// reference-ui-4.md §10 and §17: canvas states, header tabs, bottom bar,
/// device menu, settings and placement (no builds).
@MainActor
@Suite struct PreviewCanvasChromeTests {
    func rendered(_ names: [String]) throws -> [PreviewRenderer.Rendered] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 40, height: 30))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 40, height: 30).fill(); img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        var out: [PreviewRenderer.Rendered] = []
        for (i, n) in names.enumerated() {
            for s in [PreviewRenderer.ColorScheme.light, .dark] {
                let u = dir.appendingPathComponent("\(i)-\(s).png")
                try png.write(to: u)
                out.append(.init(name: n, png: u, scheme: s))
            }
        }
        return out
    }

    @Test func tabTitlesFromNameOrViewType() {
        let p = PreviewDiscovery.previews(in: "#Preview(\"Named\") { Text(\"a\") }\n#Preview {\n  @Previewable @State var x = 1\n  Badge(text: \"b\")\n}\n#Preview { 42 }")
        #expect(p.map(\.tabTitle) == ["Named", "Badge", "Preview 2"])
        #expect(p.map(\.isNamed) == [true, false, false])
    }

    @Test func pausedThenTabsThenFrame() throws {
        let c = PreviewCanvasController()
        var refreshed = 0
        c.onRefresh = { refreshed += 1 }
        _ = c.view
        c.setNames(["A", "Preview"])
        c.tabTitles = ["A", "Badge"]
        #expect(c.isPaused && c.headerTabs.isEmpty && c.pausedCapsule.superview != nil)
        c.resume()
        #expect(!c.isPaused && refreshed == 1)
        c.setState(.building)
        #expect(c.headerTabs.map(\.title) == ["A", "Badge"] && c.headerTabs.allSatisfy { $0.badge == "spinner" })
        c.setState(.rendered(try rendered(["A", "Preview"])))
        #expect(c.headerTabs.allSatisfy { $0.badge == "eye" })
        #expect(c.layout == .single && c.framedCount == 1 && c.cardTitles == ["A"])
        c.select(1)
        #expect(c.cardTitles == ["Preview"])
        c.setMode(.variants)
        #expect(c.showsVariants && c.framedCount == 2)
        c.setMode(.grid)
        #expect(c.layout == .grid && c.cardTitles == ["A", "Preview"])
    }

    @Test func renders() throws {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_SHOTS"] else { return }
        func shot(_ c: PreviewCanvasController, _ name: String) throws {
            c.view.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
            c.view.appearance = NSAppearance(named: .aqua)
            c.view.layoutSubtreeIfNeeded()
            let rep = try #require(c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds))
            c.view.cacheDisplay(in: c.view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let c = PreviewCanvasController()
        _ = c.view
        c.setNames(["Small", "Preview"])
        c.tabTitles = ["Small", "Badge"]
        try shot(c, "canvas-paused.png")
        c.resume()
        c.setState(.building)
        try shot(c, "canvas-building.png")
        c.setState(.rendered(try rendered(["Small", "Preview"])))
        try shot(c, "canvas-rendered.png")
    }

    @Test func bottomBar() {
        let c = PreviewCanvasController()
        _ = c.view
        #expect(c.modeButtons.map { $0.toolTip ?? "" } == ["Live", "Selectable", "Grid", "Variants"])
        #expect(c.mode == .live && c.modeButtons[0].state == .on)
        c.setMode(.selectable)
        #expect(c.mode == .selectable && c.modeButtons[0].state == .off && c.modeButtons[1].state == .on)
        #expect(c.zoomTitle == "Fit" && c.zoomPopUp.titleOfSelectedItem == "Fit")
        c.setZoom(0.5)
        #expect(c.zoomPopUp.titleOfSelectedItem == "50%")
        #expect([c.fitButton, c.deviceButton, c.settingsButton].map { $0.toolTip ?? "" } == ["Capture", "Device", "Canvas Settings"])
    }

    @Test func deviceMenuAndSettings() {
        let c = PreviewCanvasController()
        _ = c.view
        let titles = c.deviceMenu().items.map(\.title)
        #expect(titles.first == "Automatic – My Mac" && c.deviceMenu().items.first?.state == .on)
        #expect(titles.contains("iPhone Dynamic Island") && titles.contains("iPad 13-inch") && titles.last == "More")
        #expect(titles.contains("Recent") && titles.contains("Devices"))
        c.chooseDevice("iPad 11-inch")
        #expect(c.deviceMenu().items.first { $0.title == "iPad 11-inch" }?.state == .on)
        #expect(c.settings.on.isEmpty)
        let v = c.settingsView()
        #expect(v.subviews.count == PreviewCanvasSettings.names.count)
        c.setSetting("Color Scheme", true)
        #expect(c.colorScheme == .dark)
    }

    @Test func placement() {
        #expect(CanvasPlacement.placement(forWidth: 1200) == .beside)
        #expect(CanvasPlacement.placement(forWidth: 500) == .below)
        let area = EditorAreaController(first: SourceEditorController())
        area.view.frame = NSRect(x: 0, y: 0, width: 500, height: 700)
        area.showCanvas(PreviewCanvasController())
        area.view.layoutSubtreeIfNeeded()
        #expect(area.canvasPlacement == .below && !area.tab.split.isVertical)
        area.view.frame = NSRect(x: 0, y: 0, width: 1300, height: 700)
        area.view.layoutSubtreeIfNeeded()
        area.viewDidLayout()
        #expect(area.canvasPlacement == .beside && area.tab.split.isVertical)
    }
}
