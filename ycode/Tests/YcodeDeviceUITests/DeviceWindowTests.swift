// The device windows (specs/ide/device-hub.md, "Ycode implementation"):
// the compact window's shape and its reshaping, the canvas's states, the
// control row's groups, the frame's button clicks, Capture Keyboard, the
// feedback banner, the menus and their key equivalents. The session is fed
// through its delegate calls (no server).

#if os(macOS)
import AppKit
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeDeviceUI

@MainActor
@Suite(.serialized) struct DeviceWindowTests {
    /// A session that never connects (port 9 on loopback: not started).
    func session(type: String = "iphone-18-pro") -> DeviceLiveSession {
        let c = ViewerConnection(address: .tcp(host: "127.0.0.1", port: 9), settings: DisplayClientHello(client: "test"))
        return DeviceLiveSession(connection: c, spec: DeviceFrameSpec.named(typeID: type))
    }

    func hello(_ spec: DeviceFrameSpec, foldable: Bool = false) -> DisplayServerHello {
        var h = DisplayServerHello(deviceName: "Ycode", model: spec.modelIdentifier, pixelWidth: spec.panels[0].pixelWidth,
                                   pixelHeight: spec.panels[0].pixelHeight, scale: spec.panels[0].scale, encodings: ["jpeg"],
                                   touch: true, keyboard: true, buttons: ["home", "lock"], rotation: foldable,
                                   foldable: foldable ? true : nil, displays: foldable ? ["LCD", "LCD-1"] : nil)
        h.deviceType = spec.typeID
        h.osVersion = "iOS 27.1"
        return h
    }

    func live(_ s: DeviceLiveSession, _ spec: DeviceFrameSpec, foldable: Bool = false) {
        s.connection(s.connection, hello: hello(spec, foldable: foldable))
        s.connection(s.connection, status: DisplayStatus(phase: "live", uptimeMilliseconds: 1000, guestFrames: 1))
        s.connection(s.connection, image: Self.image(spec.panels[0].pixelWidth / 10, spec.panels[0].pixelHeight / 10),
                     frame: DisplayFrame(sequence: 1, guestFrame: 1, serverNanoseconds: 0, inputSequence: 0, width: 1, height: 1,
                                         encoding: .jpeg, isFull: true, tiles: []), receivedAt: 0)
    }

    static func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func helloNamesTheWindowAndTheFrame() {
        let s = session(type: "unknown-type")
        #expect(s.problemText == "Connecting display")
        live(s, .iPadA16)
        #expect(s.title == "iPad (A16)" && s.subtitle == "iOS 27.1" && s.spec == .iPadA16)
        #expect(s.isLive && s.hasImage && s.problemText == nil)
        s.displayName = "iPad (A16) (Ycode)"
        s.osTitle = "iOS 27.1"
        #expect(s.title == "iPad (A16) (Ycode)")
        #expect(s.frameGeometry(bezels: true).buttons.map(\.kind) == [.top, .volumeUp, .volumeDown])
        s.close()
    }

    @Test func compactWindowKeepsTheDeviceAspectAndReshapesOnRotation() {
        let s = session(type: "iphone-duo")
        live(s, .iPhoneDuo, foldable: true)
        s.connection(s.connection, displayState: DisplayPanelState(display: "LCD", pixelWidth: 1398, pixelHeight: 2034, scale: 3, rotation: 0,
                                                                  hingeAngle: 0, targetAngle: nil, posture: "closed", orientation: "portrait"))
        let w = DeviceWindowController(session: s)
        w.defaults = UserDefaults(suiteName: "ycode-device-window-tests")!
        w.defaults.removePersistentDomain(forName: "ycode-device-window-tests")
        w.initialScale = 0.7
        w.present()
        let win = w.window!
        #expect(win.title == "iPhone Duo" && win.subtitle == "iOS 27.1")
        let portrait = w.canvas.deviceSize
        #expect(portrait.height > portrait.width)
        // The window is the device at 0.7 plus the margins, toolbar and controls.
        let content = win.contentLayoutRect.size, frameH = win.frame.height
        #expect(abs(Double(content.width) - (Double(portrait.width) * 0.7 + 2 * CompactWindowLayout.sideMargin)) <= 1)
        // A drag to another width keeps the aspect.
        let proposed = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 400, height: 300)).size
        let size = w.windowWillResize(win, to: proposed)
        let c = win.contentRect(forFrameRect: NSRect(origin: .zero, size: size)).size
        let scale = CompactWindowLayout.scale(device: portrait, windowWidth: 400)
        #expect(c.width == 400 && abs(Double(c.height) - (Double(portrait.height) * scale + CompactWindowLayout.chromeHeight(toolbar: Double(frameH - content.height)))) <= 2)
        // Opening the device: the inner panel, held wide → a wide window at the same scale.
        s.connection(s.connection, displayState: DisplayPanelState(display: "LCD-1", pixelWidth: 2007, pixelHeight: 2853, scale: 3, rotation: 90,
                                                                  hingeAngle: 180, targetAngle: nil, posture: "openFlat", orientation: "portrait"))
        let open = w.canvas.deviceSize
        #expect(open.width > open.height)
        #expect(win.contentLayoutRect.width > win.contentLayoutRect.height)
        // The pose row: Rotate │ Closed · Partially Open · Open, Open highlighted.
        #expect(w.canvas.controls.groups == [[.home, .screenshot, .recordScreen], [.rotateLeft, .poseClosed, .posePartiallyOpen, .poseOpen]])
        #expect(w.canvas.controls.configuration.posture == .openFlat)
        // Rotating (landscape left) turns the inner panel upright: a tall window.
        s.connection(s.connection, displayState: DisplayPanelState(display: "LCD-1", pixelWidth: 2007, pixelHeight: 2853, scale: 3, rotation: 180,
                                                                  hingeAngle: 180, targetAngle: nil, posture: "openFlat", orientation: "landscape-left"))
        #expect(w.canvas.deviceSize.height > w.canvas.deviceSize.width)
        // Hiding the bezels: the screen alone.
        w.toggleBezels(nil)
        #expect(w.canvas.frameView.geometry.buttons.isEmpty)
        w.toggleBezels(nil)
        // More Actions: bezels, frame rate, refresh.
        #expect(w.moreItems().map(\.title) == ["Hide Bezels", "Show Frame Rate", "Refresh Display"])
        w.close()
        s.close()
    }

    @Test func expandedFormHasTheZoomControls() {
        let s = session()
        live(s, .iPhone18Pro)
        let w = DeviceWindowController(session: s)
        w.defaults = UserDefaults(suiteName: "ycode-device-window-tests2")!
        w.present()
        #expect(w.toolbarDefaultItemIdentifiers(w.window!.toolbar!) == [.flexibleSpace, DeviceWindowController.expandID, DeviceWindowController.moreID])
        w.expand(nil)
        #expect(w.kind == .expanded && w.canvas.mode == .hub)
        #expect(w.toolbarDefaultItemIdentifiers(w.window!.toolbar!).contains(DeviceWindowController.zoomID))
        // Zoom to Fit by default; Zoom In steps up from the fitted scale.
        #expect(w.canvas.zoom == .fit)
        let fitted = w.canvas.effectiveScale
        w.canvas.perform(.zoomIn)
        #expect(w.canvas.effectiveScale == DeviceZoom.zoomIn(from: fitted))
        w.canvas.perform(.zoomToFit)
        #expect(w.canvas.zoom == .fit)
        w.openInNewWindow(nil)
        #expect(w.kind == .compact)
        w.close()
        s.close()
    }

    @Test func canvasStatesAndControls() {
        let canvas = DeviceCanvasView(mode: .hub)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        #expect(canvas.stateDescription == "message: No Selection")
        canvas.showMessage("Multiple Devices Selected")
        #expect(canvas.stateDescription == "message: Multiple Devices Selected")
        var started = false
        canvas.onAction = { started = true }
        canvas.showStopped(spec: .iPhone18Pro, name: "iPhone 18 Pro (Ycode)", os: "iOS 27.0", action: "Start")
        #expect(canvas.stateDescription == "stopped" && canvas.controls.isHidden)
        canvas.layoutSubtreeIfNeeded()
        let start = canvas.subviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews).compactMap { $0 as? NSButton }.first { $0.title == "Start" }
        start?.performClick(nil)
        #expect(started)
        canvas.showStopped(spec: .iPhone18Pro, name: "x", os: "iOS 27.0", action: nil, busy: true)
        #expect(canvas.stateDescription == "starting")
        let s = session()
        canvas.show(session: s)
        #expect(canvas.stateDescription == "connecting: Connecting display" && !canvas.controls.isHidden)
        #expect(!canvas.canPerform(.home))
        live(s, .iPhone18Pro)
        #expect(canvas.stateDescription == "live" && canvas.canPerform(.home) && canvas.canPerform(.screenshot))
        // Not a foldable and the server does not turn it: Rotate is shown but disabled.
        #expect(canvas.controls.groups == [[.home, .screenshot, .recordScreen], [.rotateLeft]])
        #expect(canvas.controls.button(for: .rotateLeft)?.isEnabled == false && canvas.controls.button(for: .home)?.isEnabled == true)
        #expect(!canvas.canPerform(.rotateLeft) && !canvas.canPerform(.poseOpen) && canvas.canPerform(.actionButton))
        // The frame fits the canvas with the control row under it.
        canvas.layoutSubtreeIfNeeded()
        #expect(canvas.frameView.frame.maxY <= canvas.controls.frame.minY)
        #expect(abs(canvas.frameView.frame.midX - canvas.bounds.midX) <= 1)
        // The commands that need no device.
        canvas.perform(.zoomIn)
        #expect(canvas.zoom != .fit)
        canvas.perform(.toggleBezels)
        #expect(!canvas.showsBezels && canvas.frameView.geometry.body == canvas.frameView.geometry.screen)
        canvas.perform(.toggleBezels)
        s.close()
    }

    @Test func frameButtonsPressTheDevice() {
        let canvas = DeviceCanvasView(mode: .hub)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
        let s = session()
        canvas.show(session: s)
        live(s, .iPhone18Pro)
        canvas.layoutSubtreeIfNeeded()
        // A button of the frame is hit at its rectangle (view points).
        let f = canvas.frameView
        let vol = f.geometry.buttons.first { $0.kind == .volumeUp }!.rect
        let p = NSPoint(x: vol.midX * f.scale, y: vol.midY * f.scale)
        #expect(f.hitTest(f.convert(p, to: f.superview)) === f)
        let screenPoint = NSPoint(x: f.geometry.screen.midX * f.scale, y: f.geometry.screen.midY * f.scale)
        #expect(f.hitTest(f.convert(screenPoint, to: f.superview)) === f.screen)
        // Kinds map to the stream's buttons.
        #expect(DeviceLiveSession.displayButton(for: .side) == .lock && DeviceLiveSession.displayButton(for: .volumeDown) == .volumeDown
                && DeviceLiveSession.displayButton(for: .action) == .side && DeviceLiveSession.displayButton(for: .top) == .lock)
        s.close()
    }

    @Test func captureKeyboardShowsTheNoticeAndBannersFade() async throws {
        let canvas = DeviceCanvasView(mode: .hub)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        canvas.setCapturesKeyboard(true)
        #expect(!canvas.capturesKeyboard)  // nothing to capture for
        let s = session()
        canvas.show(session: s)
        var reported: [Bool] = []
        canvas.onCaptureChange = { reported.append($0) }
        canvas.perform(.captureKeyboard)
        #expect(canvas.capturesKeyboard && canvas.frameView.screen.capturesKeyboard && canvas.showsCaptureNotice)
        canvas.perform(.captureKeyboard)
        #expect(!canvas.capturesKeyboard && !canvas.showsCaptureNotice && reported == [true, false])
        canvas.showBanner("Screenshot Saved", seconds: 0.2)
        #expect(canvas.bannerText == "Screenshot Saved")
        try await Task.sleep(for: .milliseconds(500))
        #expect(canvas.bannerText == nil)
        s.close()
    }

    @Test func hingeSliderFollowsTheOptionDrag() {
        let canvas = DeviceCanvasView(mode: .compact)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        let s = session(type: "iphone-duo")
        canvas.show(session: s)
        live(s, .iPhoneDuo, foldable: true)
        canvas.hingeDrag(0)
        #expect(canvas.showsHingeSlider)
        canvas.hingeDrag(60 * DeviceCanvasView.pointsPerDegree)
        canvas.hingeDrag(nil)
        #expect(!canvas.showsHingeSlider)
        s.close()
    }

    @Test func menusCarryTheReferenceLabelsAndKeys() {
        final class Target: DeviceMenuTarget {
            var activeCanvas: DeviceCanvasView?
        }
        let t = Target()
        let canvas = DeviceCanvasView(mode: .hub)
        t.activeCanvas = canvas
        let menus = DeviceMenus(target: t)
        let controls = menus.controlsMenu()
        #expect(controls.items.map(\.title) == ["Home", "Lock", "App Switcher", "Action Button", "", "Rotate Left", "Rotate Right", "",
                                                "Screenshot", "Record Screen", "", "Volume Up", "Volume Down"])
        let shot = controls.items.first { $0.title == "Screenshot" }!
        #expect(shot.keyEquivalent == "s" && shot.keyEquivalentModifierMask == [.command, .shift])
        #expect(menus.viewItems().map(\.title) == ["Zoom In", "Zoom Out", "Zoom to Fit", "Physical Size", "", "Hide Bezels"])
        #expect(menus.deviceItems().map(\.title) == ["Orientation", "Keyboard", "Fold"])
        #expect(menus.deviceItems()[0].submenu!.items.map(\.title) == DeviceOrientation.allCases.map(\.title))
        // Validation: nothing to act on without a device; the record item names its state.
        #expect(!menus.validateMenuItem(shot))
        let s = session()
        canvas.show(session: s)
        live(s, .iPhone18Pro)
        #expect(menus.validateMenuItem(shot))
        let fold = menus.deviceItems()[2].submenu!.items[0]
        _ = menus.validateMenuItem(fold)
        #expect(fold.isHidden)
        s.close()
    }
}
#endif
