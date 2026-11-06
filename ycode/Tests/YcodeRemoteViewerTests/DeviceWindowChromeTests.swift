import Foundation
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeRemoteViewer

/// The Linux device window's chrome (specs/ide/device-hub.md §4.4, §11.1,
/// §11.2; council round 3 rows 65 and 67): the floating capsules' sizes and
/// place, the controls' order, state and help (Record disabled: not in this
/// beta), the current pose, the device centred above the capsules, More
/// Actions, light and dark.
struct DeviceWindowChromeTests {
    struct Refused: Error {}

    func session(_ spec: DeviceFrameSpec, foldable: Bool = false, live: Bool = true, posture: String? = nil,
                 spatial: Bool = false) -> RemoteDeviceSession {
        let s = RemoteDeviceSession(client: DisplayStreamClient(settings: DisplayClientHello(client: "t"), connect: { throw Refused() }))
        let p = spec.panels[0]
        var h = DisplayServerHello(deviceName: "Ycode", model: spec.modelIdentifier, pixelWidth: p.pixelWidth, pixelHeight: p.pixelHeight,
                                   scale: p.scale, encodings: ["jpeg"], touch: true, keyboard: true, buttons: ["home", "lock"],
                                   rotation: foldable, foldable: foldable ? true : nil, displays: foldable ? ["LCD", "LCD-1"] : nil)
        h.deviceType = spec.typeID
        h.osVersion = "iOS 27.1"
        if spatial { h.spatial = true }
        s.post(.hello(h))
        if live { s.post(.status(DisplayStatus(phase: "live", uptimeMilliseconds: 1000, guestFrames: 1))) }
        if let posture {
            s.post(.displayState(DisplayPanelState(display: "LCD", pixelWidth: p.pixelWidth, pixelHeight: p.pixelHeight, scale: p.scale,
                                                   rotation: 0, hingeAngle: 0, targetAngle: nil, posture: posture, orientation: "portrait")))
        }
        s.drain()
        s.windowWidth = 460
        s.windowHeight = 900
        return s
    }

    @Test func capsulesFloatAtTheBottomWithTheMeasuredSizes() {
        let s = session(.iPhoneDuo, foldable: true)
        let caps = s.controlCapsules
        #expect(caps.map(\.width) == [108, 145.5] && caps.allSatisfy { $0.height == 36.5 })
        #expect(caps[0].y + caps[0].height == 900 - 8 && caps[1].x - (caps[0].x + caps[0].width) == 7.5)
        #expect(abs((caps[0].x + caps[1].x + caps[1].width) / 2 - 230) < 0.001)
        // The divider between Rotate and the poses.
        #expect(s.controlDividers == [caps[1].x + 38.75])
        // The device centred between the top and the capsules (§11.2).
        let l = s.layout
        let top = l.originY, bottom = l.originY + Double(l.geometry.size.height) * l.scale
        #expect(abs((top + bottom) / 2 - (900 - ViewerLayout.controlBar) / 2) < 0.5 || top == ViewerLayout.margin)
        #expect(bottom <= caps[0].y)
        #expect(ViewerLayout.controlBar == 44.5)
    }

    @Test func controlsAreInTheSpecsOrderWithTheirState() {
        let s = session(.iPhoneDuo, foldable: true, posture: "halfOpen")
        let c = s.controls
        #expect(c.map(\.command) == [.home, .screenshot, .recordScreen, .rotateLeft, .poseClosed, .posePartiallyOpen, .poseOpen])
        // Left to right on the pitch, each 34 wide.
        #expect(zip(c, c.dropFirst()).allSatisfy { $1.rect.x > $0.rect.x } && c.allSatisfy { $0.rect.width == 34 })
        // Record is not in this beta: disabled, and its tooltip says so.
        let record = c.first { $0.command == .recordScreen }!
        #expect(!record.enabled && record.help == "Record Screen is not in this beta")
        let others = c.filter { $0.command != .recordScreen }
        #expect(others.allSatisfy { $0.enabled })
        // The current pose is highlighted.
        let lit = c.filter { $0.highlighted }.map { $0.command }
        #expect(lit == [.posePartiallyOpen])
        #expect(s.control(at: c[1].rect.x + 17, c[1].rect.y + 18)?.command == .screenshot)
        #expect(s.control(at: 5, 5) == nil)
    }

    @Test func otherDevicesHaveTheirOwnCapsules() {
        let phone = session(.iPhone18Pro)
        #expect(phone.controlGroups == [[.home, .screenshot, .recordScreen], [.rotateLeft]])
        // The server does not turn it: Rotate is shown, disabled.
        #expect(phone.controls.first { $0.command == .rotateLeft }?.enabled == false)
        let watch = session(.appleWatchSeries12_46mm)
        #expect(watch.controlGroups == [[.screenshot, .recordScreen]] && watch.controlCapsules.map(\.width) == [74])
        let vision = session(.visionPro, spatial: true)
        #expect(vision.controlGroups == [[.home, .screenshot, .recordScreen], [.resetCamera]])
        // Not live yet: every control waits.
        let booting = session(.iPhone18Pro, live: false)
        #expect(booting.controls.allSatisfy { !$0.enabled })
    }

    @Test func moreActionsHoldsTheOtherCommands() {
        let s = session(.iPhone18Pro)
        let items = s.moreItems(muted: false, statusLine: false)
        #expect(items.filter { !$0.isSeparator }.map(\.title) == ["Lock", "Volume Up", "Volume Down", "Rotate Right", "Mute Sound",
                                                                   "Zoom to Fit", "Point Accurate", "Pixel Accurate", "Hide Bezels",
                                                                   "Show Frame Rate", "Refresh Display"])
        #expect(items.first { $0.title == "Zoom to Fit" }?.checked == true)
        #expect(items.first { $0.title == "Rotate Right" }?.enabled == false)
        #expect(s.moreItems(muted: nil, statusLine: true).contains { $0.title.contains("Mute") } == false)
        // The circle at the top right; the menu under it; hits skip separators.
        let more = DeviceWindowChrome.moreButton(windowWidth: 460)
        #expect(more.x + more.width == 452 && more.y == 8 && more.width == 30)
        let r = DeviceWindowChrome.menuRect(items: items, windowWidth: 460)
        #expect(r.x + r.width == 452 && r.y == 44)
        #expect(DeviceWindowChrome.menuItem(at: r.x + 20, r.y + 4 + 11, items: items, windowWidth: 460) == 0)
        #expect(DeviceWindowChrome.menuItem(at: 5, 5, items: items, windowWidth: 460) == nil)
        // A tooltip above its control, inside the window.
        let t = DeviceWindowChrome.tooltipRect(for: s.controls[2].rect, text: "Record Screen is not in this beta", windowWidth: 460)
        #expect(t.y + t.height < s.controls[2].rect.y && t.x >= 4 && t.x + t.width <= 456)
    }

    @Test func appearanceFollowsTheArgumentThenOpenViewsThenTheDesktop() {
        #expect(ViewerAppearance.resolve(argument: "dark", environment: ["OV_COLOR_SCHEME": "light"], settingsFileText: nil, systemDark: false) == .dark)
        #expect(ViewerAppearance.resolve(argument: nil, environment: ["OV_COLOR_SCHEME": "dark"], settingsFileText: nil, systemDark: false) == .dark)
        #expect(ViewerAppearance.resolve(argument: nil, environment: [:], settingsFileText: "# x\ncolor-scheme = prefer-dark\n", systemDark: false) == .dark)
        #expect(ViewerAppearance.resolve(argument: nil, environment: [:], settingsFileText: "contrast = high", systemDark: true) == .dark)
        #expect(ViewerAppearance.resolve(argument: nil, environment: [:], settingsFileText: nil, systemDark: nil) == .light)
        #expect(ViewerAppearance.settingsFilePath(environment: ["XDG_CONFIG_HOME": "/c"]) == "/c/openviews/settings.conf")
        // The light glass of §11.1.
        #expect(ViewerPalette.light.glassBottom == ViewerColor(0xFAFAFA) && ViewerPalette.light.rimTop == ViewerColor(0xEBEBEB)
                && ViewerPalette.light.accent == ViewerColor(0x007AFF) && ViewerPalette.light.canvas == ViewerColor(0xFFFFFF))
        #expect(ViewerPalette.dark.glyph == ViewerColor(0xFFFFFF))
    }
}
