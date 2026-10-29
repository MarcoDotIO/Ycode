// The device windows' model (specs/ide/device-hub.md, "Ycode
// implementation"): frame geometry, zoom math, compact window layout, the
// hub's sidebar (sections, filter, search, sort), canvas states, commands
// and their key equivalents, capture file names.

import Foundation
import Testing
@testable import YcodeDeviceModel

@Suite struct FrameGeometryTests {
    @Test func aPhoneFrameIsConcentricWithItsScreen() {
        let g = DeviceFrameGeometry(spec: .iPhone18Pro)
        let b = DeviceFrameGeometry.band(.phone), m = DeviceFrameGeometry.protrusion
        // 1206 × 2622 @3 = 402 × 874 points.
        #expect(g.screen == CGRect(x: m + b, y: m + b, width: 402, height: 874))
        #expect(g.body == CGRect(x: m, y: m, width: 402 + 2 * b, height: 874 + 2 * b))
        #expect(g.size == CGSize(width: 402 + 2 * b + 2 * m, height: 874 + 2 * b + 2 * m))
        #expect(g.screenRadii == CornerRadii(all: 62) && g.bodyRadii == CornerRadii(all: 62 + b))
        // Action and volume on the left edge, the side button on the right.
        #expect(g.buttons.map(\.kind) == [.action, .volumeUp, .volumeDown, .side])
        for btn in g.buttons where btn.kind != .side { #expect(btn.rect.minX < g.body.minX && btn.rect.maxX > g.body.minX) }
        let side = g.buttons.last!.rect
        #expect(side.maxX > g.body.maxX && side.minX < g.body.maxX)
        #expect(g.hinge == nil && g.shadedArea == nil)
    }

    @Test func buttonsAreHitWithSlackAndTheBandIsKnown() {
        let g = DeviceFrameGeometry(spec: .iPhone18Pro)
        let vol = g.buttons.first { $0.kind == .volumeUp }!.rect
        #expect(g.button(at: CGPoint(x: vol.midX, y: vol.midY)) == .volumeUp)
        #expect(g.button(at: CGPoint(x: vol.minX - 2, y: vol.midY)) == .volumeUp)
        #expect(g.button(at: CGPoint(x: g.screen.midX, y: g.screen.midY)) == nil)
        #expect(g.isOnBand(CGPoint(x: g.body.minX + 2, y: g.body.midY)) && !g.isOnBand(CGPoint(x: g.screen.midX, y: g.screen.midY)))
    }

    @Test func turningSwapsTheShapeAndCarriesTheButtons() {
        let up = DeviceFrameGeometry(spec: .iPhone18Pro)
        let left = DeviceFrameGeometry(spec: .iPhone18Pro, clockwiseQuarterTurns: DeviceOrientation.landscapeLeft.clockwiseQuarterTurns)
        #expect(left.size == CGSize(width: up.size.height, height: up.size.width))
        #expect(left.screen.width == up.screen.height && left.screen.height == up.screen.width)
        // Landscape left: the top of the device is on the left, so the
        // buttons of the left edge are on the bottom edge.
        let vol = left.buttons.first { $0.kind == .volumeUp }!.rect
        #expect(vol.maxY > left.body.maxY && vol.width > vol.height)
        // Four quarter turns come back.
        #expect(DeviceFrameGeometry(spec: .iPhone18Pro, clockwiseQuarterTurns: 4) == up)
        // Right then left = none.
        let right = DeviceFrameGeometry(spec: .iPhone18Pro, clockwiseQuarterTurns: 1)
        #expect(right.buttons.first { $0.kind == .volumeUp }!.rect.minY < right.body.minY)
    }

    @Test func cornerRadiiTurnWithTheDevice() {
        let r = CornerRadii(topLeft: 1, topRight: 2, bottomRight: 3, bottomLeft: 4)
        #expect(r.turned(1) == CornerRadii(topLeft: 4, topRight: 1, bottomRight: 2, bottomLeft: 3))
        #expect(r.turned(4) == r && r.turned(-1) == r.turned(3))
        // The Duo's cover has small corners on its hinge side.
        let cover = DeviceFrameGeometry(spec: .iPhoneDuo)
        #expect(cover.screenRadii.topLeft == 8 && cover.screenRadii.topRight == 59)
    }

    @Test func theDuoOpenIsWideAndPartiallyOpenShowsTheHinge() {
        let open = DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 1, posture: .openFlat)
        // The inner panel 2007 × 2853 @3 is held turned: 951 × 669 points.
        #expect(open.screen.size == CGSize(width: 951, height: 669))
        #expect(open.hinge == nil && open.screenRadii == CornerRadii(all: 55))
        let half = DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 1, posture: .halfOpen)
        let h = try! #require(half.hinge)
        #expect(h.from.x == half.body.midX && h.from.y == half.body.minY && h.to.y == half.body.maxY)
        #expect(half.shadedArea?.width == half.screen.width / 2)
        // Closed: the cover, portrait.
        let closed = DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 0, posture: .closed)
        #expect(closed.screen.size == CGSize(width: 466, height: 678))
    }

    @Test func withoutBezelsOnlyTheScreen() {
        let g = DeviceFrameGeometry(spec: .iPhone18Pro, bezels: false)
        #expect(g.size == CGSize(width: 402, height: 874) && g.body == g.screen && g.buttons.isEmpty)
        let vision = DeviceFrameGeometry(spec: .visionPro)
        #expect(vision.buttons.isEmpty && vision.size == CGSize(width: 1920, height: 1080))
        let pad = DeviceFrameGeometry(spec: .iPadA16)
        #expect(pad.buttons.map(\.kind) == [.top, .volumeUp, .volumeDown])
        #expect(Double(pad.body.width - pad.screen.width) == 2 * DeviceFrameGeometry.band(.pad), "\(pad.body) \(pad.screen)")
    }

    @Test func specsMatchTheHello() {
        #expect(DeviceFrameSpec.matching(typeID: "ipad-a16", pixelWidth: 1, pixelHeight: 1, scale: 1) == .iPadA16)
        #expect(DeviceFrameSpec.matching(model: "iPhone19,2", pixelWidth: 1, pixelHeight: 1, scale: 3) == .iPhone18Pro)
        #expect(DeviceFrameSpec.matching(pixelWidth: 1398, pixelHeight: 2034, scale: 3) == .iPhoneDuo)
        let other = DeviceFrameSpec.matching(pixelWidth: 2000, pixelHeight: 3000, scale: 2)
        #expect(other.typeID == "unknown" && other.family == .pad && other.panels[0].pointSize == CGSize(width: 1000, height: 1500))
        #expect(DeviceFrameSpec.iPhoneDuo.isFoldable && !DeviceFrameSpec.iPhone18Pro.isFoldable && !DeviceFrameSpec.visionPro.hasFrame)
    }
}

@Suite struct ZoomTests {
    @Test func fitLeavesTheMarginAndKeepsTheAspect() {
        let s = DeviceZoom.fit(CGSize(width: 400, height: 800), in: CGSize(width: 600, height: 448), margin: 24)
        #expect(abs(s - 0.5) < 1e-9)
        #expect(DeviceZoom.fit(CGSize(width: 10, height: 10), in: CGSize(width: 1000, height: 1000)) == 4)
    }

    @Test func stepsGoToTheNextOne() {
        #expect(DeviceZoom.zoomIn(from: 1) == 1.25 && DeviceZoom.zoomOut(from: 1) == 0.75)
        #expect(DeviceZoom.zoomIn(from: 0.6) == 2.0 / 3 && DeviceZoom.zoomOut(from: 0.6) == 0.5)
        #expect(DeviceZoom.zoomIn(from: 4) == 4 && DeviceZoom.zoomOut(from: 0.25) == 0.25)
    }

    @Test func physicalSizeFollowsThePixelDensities() {
        // 3 pixels a point at 460 per inch: one point is 3/460 inch; on a
        // display of 110 points per inch that is 0.717 points.
        let s = DeviceZoom.physical(panel: DeviceFrameSpec.iPhone18Pro.panels[0], displayPointsPerInch: 110)
        #expect(abs(s - 3.0 / 460 * 110) < 1e-9)
        #expect(DeviceZoom.displayPointsPerInch(pointWidth: 1512, millimetresWide: 345.4) != nil)
        #expect(DeviceZoom.displayPointsPerInch(pointWidth: 1512, millimetresWide: 0) == nil)
    }

    @Test func zoomModesAreStored() {
        for m in [DeviceZoomMode.fit, .actual, .scale(0.75)] { #expect(DeviceZoomMode(storedValue: m.storedValue) == m) }
        #expect(DeviceZoomMode(storedValue: "x") == nil)
    }
}

@Suite struct CompactLayoutTests {
    @Test func widthDecidesAndTheHeightFollows() {
        let device = CGSize(width: 432, height: 904)
        let c = CompactWindowLayout.constrainedContentSize(device: device, proposed: CGSize(width: 400, height: 9999))
        let scale = (400 - 2 * CompactWindowLayout.sideMargin) / 432
        #expect(c.width == 400 && c.height == (904 * scale + CompactWindowLayout.chromeHeight()).rounded())
        // Never narrower than the minimum.
        let narrow = CompactWindowLayout.constrainedContentSize(device: device, proposed: CGSize(width: 10, height: 10))
        #expect(Double(narrow.width) == CompactWindowLayout.minimumWidth, "\(narrow)")
        let r = CompactWindowLayout.deviceRect(device: device, contentWidth: 400)
        #expect(r.minX == CompactWindowLayout.sideMargin && r.minY == CompactWindowLayout.toolbarHeight + CompactWindowLayout.topGap)
    }

    @Test func rotatingReshapesAtTheSameScale() {
        let portrait = CGSize(width: 432, height: 904), landscape = CGSize(width: 904, height: 432)
        let before = CompactWindowLayout.contentSize(device: portrait, scale: 0.5)
        let after = CompactWindowLayout.rotatedContentSize(oldDevice: portrait, newDevice: landscape, contentWidth: Double(before.width))
        #expect(after.width > after.height && after.width == (904 * 0.5 + 2 * CompactWindowLayout.sideMargin).rounded())
        // A default iPhone window is tall (the reference's was 296 × 620; Ycode's is wider for its toolbar).
        let s = CompactWindowLayout.defaultScale(device: portrait)
        let size = CompactWindowLayout.contentSize(device: portrait, scale: s)
        #expect(size.width == CompactWindowLayout.minimumWidth && size.height > 550 && size.height < 800)
    }
}

@Suite struct HubSidebarTests {
    static let devices = [
        HubDevice(id: "a", name: "iPhone Duo (Ycode)", platform: "iOS", osVersion: "27.1", family: .phone, isSimulator: true, isRunning: true),
        HubDevice(id: "b", name: "iPad (A16) (Ycode)", platform: "iOS", osVersion: "27.1", family: .pad, isSimulator: true, isRunning: false),
        HubDevice(id: "c", name: "Test iPhone", platform: "iOS", osVersion: "26.4.1", family: .phone, isSimulator: false,
                  model: "iPhone 12 Pro Max", isRunning: false, isAvailable: false),
        HubDevice(id: "d", name: "iPhone 18 Pro (Ycode)", platform: "iOS", osVersion: "27.0", family: .phone, isSimulator: true, isRunning: false),
    ]

    @Test func sectionsByAvailability() {
        let m = HubSidebarModel(devices: Self.devices)
        #expect(m.rows == [.header("Available", collapsed: false), .device(Self.devices[1]), .device(Self.devices[3]), .device(Self.devices[0]),
                           .header("Unavailable", collapsed: false), .device(Self.devices[2])])
        #expect(Self.devices[2].subtitle == "iPhone 12 Pro Max" && Self.devices[0].subtitle == "Simulator")
        #expect(Self.devices[2].shortVersion == "26.4" && Self.devices[0].osTitle == "iOS 27.1")
    }

    @Test func filterSearchSortAndCollapse() {
        var m = HubSidebarModel(devices: Self.devices)
        m.filter = .physical
        #expect(m.visible.map(\.id) == ["c"] && m.rows.first == .header("Unavailable", collapsed: false))
        m.filter = .simulators
        #expect(Set(m.visible.map(\.id)) == ["a", "b", "d"])
        m.sort = .osVersion
        #expect(m.visible.map(\.id) == ["b", "a", "d"])
        m.filter = .all
        m.sort = .name
        m.search = "duo"
        #expect(m.visible.map(\.id) == ["a"] && !m.showsNoResults)
        m.search = "pixel "
        #expect(m.showsNoResults && m.noResultsTitle == "No Results for “pixel”" && m.rows.isEmpty)
        m.search = ""
        m.toggle(section: "Available")
        #expect(m.rows == [.header("Available", collapsed: true), .header("Unavailable", collapsed: false), .device(Self.devices[2])])
        #expect(m.rowIndex(of: "a") == nil && m.rowIndex(of: "c") == 2)
        #expect(HubFilter.allCases.map(\.rawValue) == ["All Devices", "Simulators", "Physical Devices"])
    }

    @Test func canvasStates() {
        let d = Self.devices
        #expect(HubCanvasState.of(selection: [], starting: []) == .noSelection)
        #expect(HubCanvasState.of(selection: [d[0], d[1]], starting: []).message == "Multiple Devices Selected")
        #expect(HubCanvasState.of(selection: [d[0]], starting: []) == .running(d[0]))
        #expect(HubCanvasState.of(selection: [d[1]], starting: []) == .stopped(d[1]))
        #expect(HubCanvasState.of(selection: [d[1]], starting: ["b"]) == .starting(d[1]))
        #expect(HubCanvasState.noSelection.message == "No Selection")
    }
}

@Suite struct CommandTests {
    @Test func screenshotIsShiftCommandS() {
        let e = DeviceCommand.screenshot.keyEquivalent!
        #expect(e.key == "s" && e.modifiers == [.command, .shift])
        #expect(DeviceCommand.bound(to: "S", modifiers: [.command, .shift]) == .screenshot)
        #expect(DeviceCommand.bound(to: "s", modifiers: [.command]) == nil)
        #expect(DeviceCommand.bound(to: "h", modifiers: [.command, .shift]) == .home)
        #expect(DeviceCommand.bound(to: DeviceKeyModifiers.leftArrow, modifiers: [.command]) == .rotateLeft)
        #expect(DeviceCommand.bound(to: "=", modifiers: [.command]) == .zoomIn)
        // No two commands share a key equivalent.
        let keys = DeviceCommand.allCases.compactMap { c in c.keyEquivalent.map { "\($0.key)|\($0.modifiers.rawValue)" } }
        #expect(Set(keys).count == keys.count)
    }

    @Test func menusFollowTheReference() {
        #expect(DeviceCommand.controlsMenu.compactMap { $0?.title } == ["Home", "Lock", "App Switcher", "Action Button", "Rotate Left",
                                                                        "Rotate Right", "Screenshot", "Record Screen", "Volume Up", "Volume Down"])
        #expect(DeviceCommand.zoomMenu.map(\.title) == ["Zoom In", "Zoom Out", "Zoom to Fit", "Physical Size"])
        #expect(DevicePosture.allCases.map(\.title) == ["Closed", "Partially Open", "Open"])
        #expect(DevicePosture.preset(angle: 90) == .halfOpen && DevicePosture.preset(angle: 45) == nil)
    }

    @Test func rotationCyclesAndOrientationsHaveStreamCodes() {
        var o = DeviceOrientation.portrait
        o = o.rotated(left: true)
        #expect(o == .landscapeLeft)
        #expect(o.rotated(left: true) == .landscapeRight && o.rotated(left: false) == .portrait)
        #expect(DeviceOrientation.portrait.rotated(left: false) == .landscapeRight)
        #expect(DeviceOrientation(streamName: "landscape-right") == .landscapeRight && DeviceOrientation(streamName: nil) == .portrait)
        #expect(DeviceOrientation.allCases.map(\.streamCode) == [1, 2, 3, 4, 5, 6])
        #expect(DeviceOrientation.faceUp.clockwiseQuarterTurns == 0 && DeviceOrientation.landscapeLeft.clockwiseQuarterTurns == 3)
    }

    @Test func captureNames() {
        let d = Date(timeIntervalSince1970: 1_793_000_000)
        let utc = TimeZone(identifier: "UTC")!
        #expect(DeviceCaptureNames.recording(device: "iPhone Duo", at: d, timeZone: utc) == "Screen Recording iPhone Duo 2026-10-26 at 07.33.20.mov")
        #expect(DeviceCaptureNames.screenshot(device: "A/B", at: d, timeZone: utc) == "Screenshot A-B 2026-10-26 at 07.33.20.png")
    }
}
