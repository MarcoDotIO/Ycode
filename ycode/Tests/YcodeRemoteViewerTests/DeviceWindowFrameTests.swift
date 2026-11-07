import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeRemoteViewer

/// The Linux device window's frame (cross-platform-parity.md §13): a
/// 52-point toolbar, the canvas, the 280-point Settings inspector, laid out
/// as the macOS device window.
struct DeviceWindowFrameTests {
    @Test func regionsMatchTheMacOSDeviceWindow() {
        let f = DeviceWindowFrame(width: 1100, height: 800)
        #expect(f.toolbar == ViewerRect(x: 0, y: 0, width: 1100, height: 52))
        #expect(f.inspector == ViewerRect(x: 820, y: 52, width: 280, height: 748))
        #expect(f.canvas == ViewerRect(x: 0, y: 52, width: 820, height: 748))
        // The capsules float at the canvas's bottom, 8 above the window's, as on macOS.
        let caps = DeviceControlsLayout.capsuleRects(DeviceControlsLayout.groups(.init(foldable: true)), canvasWidth: f.canvas.width,
                                                     canvasHeight: f.canvas.height)
        #expect(abs(Double(caps[0].maxY) + f.canvas.y - 792) < 0.01)
        // Hidden inspector: the canvas takes the whole width; no tabs.
        let g = DeviceWindowFrame(width: 1100, height: 800, inspectorShown: false)
        #expect(g.inspector == nil && g.canvas.width == 1100 && g.rect(of: .settingsTab) == nil)
        #expect(DeviceWindowFrame.windowSize(canvasWidth: 400, canvasHeight: 900) == (680, 952))
    }

    @Test func toolbarItemsInOrderRightAlignedOverTheCanvas() {
        let f = DeviceWindowFrame(width: 1100, height: 800)
        let caps = f.capsules
        #expect(caps.map(\.items) == DeviceWindowFrame.groups + [DeviceWindowFrame.tabs])
        // 36 tall, centred in the band; 8 apart; the last over the canvas
        // ends 10 inside it; the tabs end 10 inside the inspector.
        #expect(caps.allSatisfy { $0.rect.height == 36 && $0.rect.y == 8 })
        #expect(caps[2].rect.x + caps[2].rect.width == 810 && caps[1].rect.x + caps[1].rect.width + 8 == caps[2].rect.x)
        #expect(caps[3].rect.x + caps[3].rect.width == 1090 && caps[3].rect.width == 108)
        // Hit testing.
        let zoomFit = f.rect(of: .zoomFit)!
        #expect(f.item(at: zoomFit.x + 18, zoomFit.y + 18) == .zoomFit)
        #expect(f.item(at: 100, 26) == nil)
        #expect(f.titleWidth > 300)
    }

    @Test func selectedAndDisabledItems() {
        let f = DeviceWindowFrame(width: 900, height: 700)
        var r = DeviceChromeRequest(frame: f, title: "iPhone Duo", subtitle: "iOS 27.1", dark: true, scaleMode: .fit, capturesKeyboard: true,
                                    inspectorTab: .settingsTab, inspector: .standard(note: nil), pixelDensity: 1)
        #expect(r.selectedItems == [.zoomFit, .captureKeyboard, .settingsTab])
        r.scaleMode = .point
        r.capturesKeyboard = false
        r.inspectorTab = .infoTab
        #expect(r.selectedItems == [.zoomActual, .infoTab])
        #expect(DeviceChromeRequest.disabledItems == [.resizeMode])
    }

    /// The Settings cards as the macOS inspector draws them (§11.3): 260
    /// wide, 10 inside, the first 8 down, 10 apart; 9, 1 and 3 rows at a
    /// 43-point pitch.
    @Test func settingsCards() {
        let c = DeviceInspectorContent.standard(note: DeviceInspectorContent.notAvailableNote)
        #expect(c.cards.map(\.count) == [9, 1, 3])
        #expect(c.cards.joined().map(\.label) == ["Appearance", "Liquid Glass", "Color Filter", "Text Size", "Reduce Motion", "Increase Contrast",
                                                  "Show Borders", "Reduce Transparency", "VoiceOver", "Location", "Sound", "Output", "Input"])
        let r = c.cardRects(width: 280)
        #expect(r.map(\.x) == [10, 10, 10] && r.map(\.width) == [260, 260, 260])
        #expect(r[0].y == 8 && r[0].height == 9 * 42 + 8 && r[1].y == r[0].y + r[0].height + 10 && r[1].height == 42)
        #expect(c.cards.joined().allSatisfy { !$0.enabled })
    }

    /// The More Actions menu hangs under the toolbar's button, with Show and
    /// Hide Inspector.
    @Test func moreMenuUnderTheToolbarButton() {
        let anchor = ViewerRect(x: 774, y: -44, width: 36, height: 36)
        let items = [ViewerMenuItem(title: "Lock", shortcut: "Ctrl+L", action: .command(.lock)),
                     ViewerMenuItem(title: "Hide Inspector", shortcut: "Ctrl+Alt+0", action: .inspector)]
        let m = DeviceWindowChrome.menuRect(items: items, windowWidth: 820, anchor: anchor)
        #expect(m.x + m.width == 810 && m.y == -2)
        #expect(DeviceWindowChrome.menuItem(at: m.x + 20, m.y + 4 + 22 + 5, items: items, windowWidth: 820, anchor: anchor) == 1)
    }
}
