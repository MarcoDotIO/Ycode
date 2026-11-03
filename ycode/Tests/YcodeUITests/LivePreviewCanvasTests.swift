#if os(macOS)
import AppKit
import Foundation
import Testing
import YcodeDeviceUI
import YcodeDisplayStream
@testable import YcodeIDECore
@testable import YcodeUI

/// Live previews in the IDE (specs/ide/previews.md §Live previews, §Live
/// canvas): the canvas layout, the tiles a canvas asks for, the preview
/// device's commands, and the canvas controller's live state. No device.
@MainActor @Suite(.timeLimit(.minutes(30))) struct LivePreviewCanvasTests {
    let phone = CGSize(width: 402, height: 874)

    func tiles(_ n: Int) -> [PreviewLiveTile] {
        let regions = PreviewScreenLayout.regions((0..<n).map { PreviewTile(preview: $0, size: phone) }, screen: phone)
        return regions.enumerated().map { PreviewLiveTile(title: "P\($0.offset)", preview: $0.offset, region: $0.element) }
    }

    @Test func tilesForSingleGridVariantsAndPin() {
        let previews = PreviewDiscovery.previews(in: "#Preview(\"A\") { Text(\"a\") }\n#Preview(\"B\", traits: .landscapeLeft) { Text(\"b\") }\n#Preview(\"C\", traits: .fixedLayout(width: 100, height: 50)) { Text(\"c\") }")
        let titles = previews.map(\.tabTitle)
        let single = WorkspaceWindowController.liveTiles(previews: previews, titles: titles, selected: 0, grid: false, variants: nil,
                                                         base: PreviewVariant(), pinned: nil, screen: phone)
        #expect(single.map(\.title) == ["A"] && single[0].size == phone)
        let grid = WorkspaceWindowController.liveTiles(previews: previews, titles: titles, selected: 0, grid: true, variants: nil,
                                                       base: PreviewVariant(), pinned: nil, screen: phone)
        #expect(grid.map(\.preview) == [0, 1, 2])
        // B's trait turns it; C keeps its fixed size.
        #expect(grid[1].size == CGSize(width: 874, height: 402) && grid[1].variant.orientation == "landscapeLeft")
        #expect(grid[2].size == CGSize(width: 100, height: 50))
        let schemes = WorkspaceWindowController.liveTiles(previews: previews, titles: titles, selected: 0, grid: false, variants: .colorScheme,
                                                          base: PreviewVariant(), pinned: nil, screen: phone)
        #expect(schemes.map(\.variant.colorScheme) == ["light", "dark"] && schemes[1].title == "A — Dark")
        let types = WorkspaceWindowController.liveTiles(previews: previews, titles: titles, selected: 0, grid: false, variants: .dynamicType,
                                                        base: PreviewVariant(colorScheme: "dark"), pinned: nil, screen: phone)
        #expect(types.count == 6 && types.allSatisfy { $0.variant.colorScheme == "dark" } && types.last?.variant.dynamicType == "accessibility5")
        let orient = WorkspaceWindowController.liveTiles(previews: previews, titles: titles, selected: 1, grid: false, variants: .orientation,
                                                         base: PreviewVariant(), pinned: nil, screen: phone)
        #expect(orient.map(\.size) == [phone, CGSize(width: 874, height: 402)])
        let pinned = WorkspaceWindowController.liveTiles(previews: previews, titles: titles, selected: 0, grid: false, variants: nil,
                                                         base: PreviewVariant(), pinned: 2, screen: phone)
        #expect(pinned.map(\.preview) == [2, 0] && pinned[0].title == "C — Pinned")
    }

    @Test func previewDevicesIncludeEveryTypeARuntimeBoots() {
        var s = RemoteSimulatorSettings(destination: "u@h", dataDirectory: "/d", runtimeRoot: "/rt/iOS-27.1/RuntimeRoot", simdPath: "/b/ycode-sim", deviceName: "dev")
        s.runtimeVersion = "27.1"
        let runs = RemoteSimulator.all(s).map(WorkspaceWindowController.previewDeviceTitle)
        let previews = WorkspaceWindowController.previewSimulators(s)
        let titles = previews.map(WorkspaceWindowController.previewDeviceTitle)
        // The run destinations first, then the iPhone 18 Pro that 27.1 also boots.
        #expect(Array(titles.prefix(runs.count)) == runs && !runs.contains("iPhone 18 Pro (Ycode) 27.1"))
        #expect(titles.contains("iPhone 18 Pro (Ycode) 27.1"))
        let pro = previews.first { $0.target?.deviceType.id == "iphone-18-pro" }
        #expect(pro?.previewDevice.remoteDevicePath == "/d/devices/dev-iphone-18-pro-27.1-previews")
        #expect(pro?.target?.deviceTypeArguments == ["--device-type", "iphone-18-pro"])
    }

    @Test func canvasShowsLiveTilesBannersAndAsksForLayouts() {
        let c = PreviewCanvasController()
        c.view.frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        var layouts = 0
        c.onLayoutChange = { layouts += 1 }
        c.setNames(["A", "B"])
        c.resume()
        c.setState(.live(tiles(2)))
        #expect(c.liveTileViews.count == 2 && c.cardTitles == ["P0", "P1"])
        #expect(c.headerTabs.map { $0.badge } == ["eye", "eye"])
        c.setUpdating(true)
        #expect(c.headerTabs.map { $0.badge } == ["spinner", "spinner"] && c.statusText == "Updating…")
        c.setUpdating(false)
        // A failed compile keeps the tiles and adds the banner.
        var opened: PreviewIssue?
        c.onIssue = { opened = $0 }
        let issue = PreviewIssue(file: URL(fileURLWithPath: "/p/ContentView.swift"), line: 14, message: "cannot find 'x' in scope")
        c.setBanner(title: "Compiling the preview failed", issues: [issue])
        #expect(c.liveTileViews.count == 2 && c.bannerView != nil)
        c.bannerView?.clickFirstIssue()
        #expect(opened == issue)
        c.clearBanner()
        #expect(c.bannerView == nil)
        // Grid, variants, device and the settings ask for a new plan.
        c.attach(DeviceLiveSession(connection: ViewerConnection(address: .unix("/nonexistent"), settings: DisplayClientHello(client: "t"))))
        #expect(c.isLiveCanvas)
        let before = layouts
        c.setMode(.grid)
        c.setMode(.variants)
        #expect(c.variantKind == .colorScheme && c.layout == .single)
        c.setMode(.variants)
        #expect(c.variantKind == .orientation)
        c.setVariants(nil)
        c.chooseDevice("iPhone 18 Pro (Ycode) 27.0")
        c.setSetting("Color Scheme", true)
        #expect(layouts == before + 6)
        #expect(c.baseVariant.colorScheme == "dark" && c.baseVariant.dynamicType == nil)
        c.setSetting("Dynamic Type", true)
        #expect(c.baseVariant.dynamicType == "accessibility1")
        // Live mode makes tiles interactive; Selectable reveals instead.
        c.setState(.live(tiles(2)))
        #expect((c.liveTileViews.first as? PreviewLiveTileView)?.interactive == true)
        var revealed: Int?
        c.onRevealPreview = { revealed = $0 }
        c.setMode(.selectable)
        #expect((c.liveTileViews.first as? PreviewLiveTileView)?.interactive == false)
        c.tileClicked(1)
        #expect(revealed == 1 && c.selectedIndex == 1)
        c.attach(nil)
    }

    @Test func liveTilesForwardTouchesInDevicePoints() throws {
        final class Recorder: DeviceInputHandler {
            var touches: [[TouchContact]] = []
            func sendTouch(_ contacts: [TouchContact], label: String?) { touches.append(contacts) }
            func sendKey(usage: UInt16, down: Bool, label: String?) {}
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let t = tiles(2)[1]
        let v = PreviewLiveTileView(tile: t)
        v.frame = NSRect(x: 0, y: 0, width: 201, height: 437)
        window.contentView?.addSubview(v)
        let rec = Recorder()
        v.input = rec
        let local = NSPoint(x: 100.5, y: 218.5)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try #require(NSEvent.mouseEvent(with: type, location: v.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { v.mouseDown(with: e) } else { v.mouseUp(with: e) }
        }
        #expect(rec.touches.map { $0[0].phase } == [.began, .ended])
        #expect(abs(Double(rec.touches[0][0].x) - (t.region.x + t.region.width / 2)) < 0.6)
        // Not interactive (Selectable): no touches.
        v.interactive = false
        let e = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: v.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        v.mouseDown(with: e)
        #expect(rec.touches.count == 2)
    }
}
#endif
