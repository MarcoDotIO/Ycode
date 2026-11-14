import Foundation
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeRemoteViewer

/// Council round 7 in the Linux device window (`specs/ide/device-hub.md`
/// §15, rows 170–175), one to one with the macOS hub: Zoom to Fit fits the
/// iPhone's and the iPad's silhouette to the free height in both window
/// sizes, the iPad has its tablet outline, the subtitle says iPadOS, the
/// toolbar draws the layout glyph without a separator after Capture Keyboard
/// and keeps the tabs (none selected) with the inspector hidden, and the
/// capsules' glyphs stay at full contrast.
struct DeviceWindowR7Tests {
    let chrome = DeviceWindowChromeTests()

    /// A connected session in the framed window whose canvas is `w` × `h`
    /// window points less the toolbar (the inspector hidden).
    func framed(_ spec: DeviceFrameSpec, _ w: Double, _ h: Double, osVersion: String = "iOS 27.2") -> RemoteDeviceSession {
        let s = RemoteDeviceSession(client: DisplayStreamClient(settings: DisplayClientHello(client: "t"), connect: { throw WindowFitTests.Refused() }))
        let p = spec.panels[0]
        var hello = DisplayServerHello(deviceName: "Ycode", model: spec.modelIdentifier, pixelWidth: p.pixelWidth, pixelHeight: p.pixelHeight,
                                       scale: p.scale, encodings: ["jpeg"], touch: true, keyboard: true, buttons: ["home", "lock"], rotation: false)
        hello.deviceType = spec.typeID
        hello.osVersion = osVersion
        s.post(.hello(hello))
        s.drain()
        s.hubFit = true
        s.windowWidth = w
        s.windowHeight = h - DeviceWindowFrame.toolbarHeight
        return s
    }

    /// The body in window points (the canvas starts under the toolbar).
    func body(_ s: RemoteDeviceSession) -> ViewerRect {
        var b = s.layout.window(s.layout.geometry.body)
        b.y += DeviceWindowFrame.toolbarHeight
        return b
    }

    @Test func theIPhoneAndTheIPadFillTheFreeHeight() {
        for (spec, w, h, bw, bh) in [(DeviceFrameSpec.iPhone18Pro, 1100.0, 800.0, 324.5, 674.5), (.iPhone18Pro, 1400, 900, 371.5, 772.5),
                                     (.iPadA16, 1100, 800, 485.5, 671), (.iPadA16, 1400, 900, 556, 769)] {
            let b = body(framed(spec, w, h))
            #expect(abs(b.width - bw) <= 1 && abs(b.height - bh) <= 1, "\(spec.name) at \(w): \(b.width) × \(b.height)")
            // Centred between y 52 and H − 44 (404, 454) and on the canvas.
            #expect(abs(b.y + b.height / 2 - (52 + (h - 96) / 2)) <= 1, "\(spec.name) at \(w): centre y \(b.y + b.height / 2)")
            #expect(abs(b.x + b.width / 2 - w / 2) <= 0.5)
        }
        // The Duo keeps its box through the 1269-point box: 0.608 at 1400 × 900.
        let duo = framed(.iPhoneDuo, 1400, 900)
        #expect(abs(duo.layout.scale - 0.608) < 0.002, "\(duo.layout.scale)")
    }

    @Test func theIPadIsDrawnAsATablet() {
        let g = framed(.iPadA16, 1100, 800).geometry
        #expect(g.body.size == CGSize(width: 940, height: 1300) && g.screenRadii == CornerRadii(all: 19) && g.bodyRadii == CornerRadii(all: 83))
        #expect(g.bandRingRects.map(\.color) == [DeviceFrameGeometry.Palette.edge, DeviceFrameGeometry.Palette.greyBand, DeviceFrameGeometry.Palette.inner])
        #expect(g.buttons.filter(\.flush).map(\.kind) == [.volumeUp, .volumeDown])
    }

    @Test func theSubtitleSaysIPadOSForAnIPad() {
        #expect(framed(.iPadA16, 1100, 800).osTitle == "iPadOS 27.2")
        #expect(framed(.iPhone18Pro, 1100, 800).osTitle == "iOS 27.2")
    }

    @Test func theToolbarsGlyphsAndSeparators() {
        // The resize toggle: Ycode's layout glyph, dimmed.
        #expect(DeviceWindowFrame.Item.resizeMode.symbol == DeviceWindowFrame.layoutSymbol)
        #expect(DeviceChromeRequest.disabledItems == [.resizeMode])
        let shown = DeviceWindowFrame(width: 1100, height: 800, inspectorShown: true)
        let hidden = DeviceWindowFrame(width: 1100, height: 800, inspectorShown: false)
        func request(_ f: DeviceWindowFrame) -> DeviceChromeRequest {
            DeviceChromeRequest(frame: f, title: "iPad Air", subtitle: "iPadOS 27.2", dark: true, scaleMode: .fit, capturesKeyboard: false,
                                inspectorTab: .settingsTab, inspector: .standard(note: nil), pixelDensity: 2)
        }
        // Shown: the settings tab selected, one separator in the tabs (file │ info).
        let rs = request(shown)
        #expect(rs.selectedItems == [.settingsTab, .zoomFit])
        let tabs = shown.capsules.last!.rect
        let inTabs = shown.separators(selected: rs.selectedItems).filter { $0 > tabs.x && $0 < tabs.x + tabs.width }
        #expect(inTabs == [tabs.x + 2 * DeviceWindowFrame.segmentWidth])
        // No separator inside Capture Keyboard's capsule.
        let capture = shown.capsules[0].rect
        #expect(!shown.separators(selected: rs.selectedItems).contains { $0 > capture.x && $0 < capture.x + capture.width })
        // Zoom to Fit selected: one separator in the zoom capsule (Actual │ In).
        let zoom = shown.capsules[1].rect
        #expect(shown.separators(selected: rs.selectedItems).filter { $0 > zoom.x && $0 < zoom.x + zoom.width } == [zoom.x + 3 * 36])
        // Hidden: the tabs stay at the toolbar's right end, none selected,
        // two separators; the other capsules move left of them.
        let rh = request(hidden)
        #expect(rh.selectedItems == [.zoomFit])
        let t = hidden.capsules.last!
        #expect(t.items == DeviceWindowFrame.tabs && abs(t.rect.x + t.rect.width - (1100 - DeviceWindowFrame.trailingInset)) < 1e-9)
        #expect(hidden.capsules[2].rect.x + hidden.capsules[2].rect.width <= t.rect.x - DeviceWindowFrame.groupGap + 1e-9)
        #expect(hidden.separators(selected: rh.selectedItems).filter { $0 > t.rect.x }.count == 2)
        #expect(hidden.rect(of: .infoTab) != nil && hidden.item(at: t.rect.x + 18, 26) == .settingsTab)
    }

    @Test func theCapsulesStayAtFullContrast() {
        // Before the display is live (a preview or a booting device), every
        // control but Record is drawn enabled with the reason in its tooltip.
        let booting = chrome.session(.iPadA16, live: false)
        let c = booting.controls
        let shownEnabled = c.filter { $0.command != .recordScreen }.allSatisfy { $0.enabled }
        #expect(shownEnabled)
        #expect(booting.controlsUnavailableReason != nil)
        #expect(c.first { $0.command == .home }?.help == "Home. " + (booting.controlsUnavailableReason ?? ""))
        // Live: no reason; Record still disabled with its own.
        let live = chrome.session(.iPadA16)
        #expect(live.controlsUnavailableReason == nil && live.controls.first { $0.command == .home }?.help == "Home")
        #expect(live.controls.first { $0.command == .recordScreen }?.enabled == false)
        // A preview says it is a picture only.
        let s = RemoteDeviceSession(client: DisplayStreamClient(settings: DisplayClientHello(client: "t"), connect: { throw WindowFitTests.Refused() }))
        s.preview(spec: .iPadA16)
        #expect(s.controlsUnavailableReason?.contains("picture") == true)
    }
}
