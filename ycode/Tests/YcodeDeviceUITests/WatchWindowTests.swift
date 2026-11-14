// watchOS W2 (specs/simulator/watchos.md §7.2 W2, §11; specs/ide/device-hub.md
// §4.3, §4.4): a watch in the compact window and the hub's canvas — Ycode's
// watch frame at the watch's size, the crown and side button clickable and
// mapped to the stream's buttons, the control row [Screenshot · Record]
// (no Home, no Rotate), no volume or App Switcher, the bezel toggle and
// zoom, and the sidebar's watch glyph. The session is fed through its
// delegate calls (no server); preferences in a scratch suite.

#if os(macOS)
import AppKit
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeDeviceUI

@MainActor
@Suite(.serialized) struct WatchWindowTests {
    static let watch = DeviceFrameSpec.appleWatchSeries12_46mm

    func liveWatch(_ spec: DeviceFrameSpec = watch) -> DeviceLiveSession {
        let c = ViewerConnection(address: .tcp(host: "127.0.0.1", port: 9), settings: DisplayClientHello(client: "test"))
        let s = DeviceLiveSession(connection: c, spec: nil)
        var h = DisplayServerHello(deviceName: "Ycode", model: spec.modelIdentifier, pixelWidth: spec.panels[0].pixelWidth,
                                   pixelHeight: spec.panels[0].pixelHeight, scale: spec.panels[0].scale, encodings: ["jpeg"],
                                   touch: true, keyboard: true, buttons: ["home", "lock"], rotation: false, foldable: nil, displays: nil)
        h.deviceType = spec.typeID
        h.osVersion = "watchOS 27.0"
        s.connection(s.connection, hello: h)
        s.connection(s.connection, status: DisplayStatus(phase: "live", uptimeMilliseconds: 1000, guestFrames: 1))
        s.connection(s.connection, image: DeviceWindowTests.image(spec.panels[0].pixelWidth / 4, spec.panels[0].pixelHeight / 4),
                     frame: DisplayFrame(sequence: 1, guestFrame: 1, serverNanoseconds: 0, inputSequence: 0, width: 1, height: 1,
                                         encoding: .jpeg, isFull: true, tiles: []), receivedAt: 0)
        return s
    }

    @Test func theHelloGivesTheWatchFrameAndSize() {
        let s = liveWatch()
        #expect(s.spec == Self.watch && s.title == "Apple Watch Series 12 (46mm)" && s.subtitle == "watchOS 27.0")
        #expect(s.shownPointSize == CGSize(width: 208, height: 248) && !s.isFoldable && !s.canRotate)
        let g = s.frameGeometry(bezels: true)
        #expect(g.buttons.map(\.kind) == [.crown, .sideButton] && g.screen.size == CGSize(width: 208, height: 248))
        s.close()
    }

    /// W3b (watchos.md §5.1, §12): on a watch, scrolling turns the crown;
    /// scrolling down (content up) is a positive delta, a wheel line is 10
    /// trackpad points, and the factor scales it. A phone keeps the drag.
    @Test func scrollingTurnsTheCrownOnAWatchOnly() {
        let s = liveWatch()
        #expect(s.scrollsTurnTheCrown)
        #expect(DeviceView.crownDelta(scrollingDeltaY: -3, precise: true, factor: 2) == 6)
        #expect(DeviceView.crownDelta(scrollingDeltaY: 1, precise: false, factor: 2) == -20)
        #expect(DeviceView.crownDelta(scrollingDeltaY: -1, precise: false, factor: 0.5) == 5)
        s.close()
        let p = liveWatch(.iPhone18Pro)
        #expect(!p.scrollsTurnTheCrown)
        p.close()
    }

    @Test func compactWindowShowsTheWatchAtItsSize() {
        let s = liveWatch()
        let w = DeviceWindowController(session: s)
        let suite = "ycode-watch-window-tests"
        w.defaults = UserDefaults(suiteName: suite)!
        w.defaults.removePersistentDomain(forName: suite)
        w.present()
        let win = w.window!
        #expect(win.title == "Apple Watch Series 12 (46mm)" && win.subtitle == "watchOS 27.0")
        // The device in Ycode's frame (276 × 295 points, council round 10 row 249) fills the width less the margins.
        let device = w.canvas.deviceSize
        #expect(device == CGSize(width: 276, height: 295))
        let content = win.contentLayoutRect.size
        let scale = (Double(content.width) - 2 * CompactWindowLayout.sideMargin) / 276
        #expect(abs(Double(w.canvas.frameView.scale) - scale) < 0.02, "\(w.canvas.frameView.scale) \(scale)")
        #expect(Double(content.width) >= CompactWindowLayout.minimumWidth)
        // The drawing is the frame's points at that scale; its screen the watch's.
        #expect(abs(Double(w.canvas.frameView.intrinsicContentSize.width) - 276 * scale) <= 1)
        w.canvas.frameView.layout()
        #expect(abs(Double(w.canvas.frameView.screen.frame.width) - 208 * Double(w.canvas.frameView.scale)) <= 2, "\(w.canvas.frameView.screen.frame) \(w.canvas.frameView.scale)")
        // A drag keeps the aspect.
        let proposed = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 520, height: 200)).size
        let c = win.contentRect(forFrameRect: NSRect(origin: .zero, size: w.windowWillResize(win, to: proposed))).size
        #expect(c.width == 520 && c.height > c.width)
        // The row: Side Button · Digital Crown · Screenshot · Record (round 9 row 234), no Home, no Rotate.
        #expect(w.canvas.controls.groups == [DeviceControlsLayout.watchGroup])
        // Hide Bezels: the screen alone with its 50-point corners.
        w.toggleBezels(nil)
        #expect(w.canvas.frameView.geometry.buttons.isEmpty && w.canvas.deviceSize == CGSize(width: 208, height: 248))
        #expect(w.canvas.frameView.geometry.screenRadii == CornerRadii(all: 50))
        w.toggleBezels(nil)
        #expect(w.canvas.deviceSize == CGSize(width: 276, height: 295))
        // The screen alone at the same scale is narrower than the minimum, so
        // the window stays at the minimum; showing the bezels returns to it.
        #expect(abs(Double(win.contentLayoutRect.width) - CompactWindowLayout.minimumWidth) <= 1, "\(win.contentLayoutRect)")
        // Expanded: at least the expanded form's minimum, even when a
        // smaller size was saved.
        w.defaults.set(["width": 219.0, "height": 420.0], forKey: "YcodeDeviceWindow.expanded.\(Self.watch.typeID)")
        w.switchKind(to: .expanded)
        let expanded = win.contentRect(forFrameRect: win.frame).size
        #expect(expanded.width >= 420 && expanded.height >= 420, "\(win.contentLayoutRect) \(win.frame)")
        w.switchKind(to: .compact)
        #expect(abs(Double(win.contentLayoutRect.width) - CompactWindowLayout.minimumWidth) <= 1, "\(win.contentLayoutRect)")
        w.close()
        s.close()
    }

    @Test func aWindowOpenedBeforeTheHelloTakesTheWatchsOwnSize() {
        // The viewer opens its window before the hello: the default phone first.
        let c = ViewerConnection(address: .tcp(host: "127.0.0.1", port: 9), settings: DisplayClientHello(client: "test"))
        let s = DeviceLiveSession(connection: c, spec: nil)
        let w = DeviceWindowController(session: s)
        let suite = "ycode-watch-window-tests-hello"
        w.defaults = UserDefaults(suiteName: suite)!
        w.defaults.removePersistentDomain(forName: suite)
        w.present()
        let win = w.window!
        #expect(w.canvas.deviceSize.height > 600, "a phone first")
        // The hello names the watch: the window takes the watch's default size, not the phone's scale.
        let spec = Self.watch
        var h = DisplayServerHello(deviceName: "Ycode", model: spec.modelIdentifier, pixelWidth: 416, pixelHeight: 496, scale: 2,
                                   encodings: ["jpeg"], touch: true, keyboard: true, buttons: ["home"], rotation: false, foldable: nil, displays: nil)
        h.deviceType = spec.typeID
        s.connection(s.connection, hello: h)
        #expect(w.canvas.deviceSize == CGSize(width: 276, height: 295))
        #expect(abs(Double(win.contentLayoutRect.width) - CompactWindowLayout.minimumWidth) <= 1, "\(win.contentLayoutRect)")
        #expect(abs(Double(w.canvas.frameView.scale) - CompactWindowLayout.defaultScale(device: CGSize(width: 276, height: 295))) < 0.02)
        w.close()
        s.close()
    }

    @Test func hubCanvasZoomsTheWatchAndOffersOnlyItsCommands() {
        let canvas = DeviceCanvasView(mode: .hub)
        canvas.frame = NSRect(x: 0, y: 0, width: 580, height: 800)
        let s = liveWatch()
        canvas.show(session: s)
        canvas.layoutSubtreeIfNeeded()
        #expect(canvas.stateDescription == "live")
        #expect(canvas.controls.groups == [DeviceControlsLayout.watchGroup])
        #expect(canvas.canPerform(.sideButton) && canvas.canPerform(.digitalCrown))
        #expect(canvas.canPerform(.screenshot) && canvas.canPerform(.recordScreen) && canvas.canPerform(.home) && canvas.canPerform(.lock))
        #expect(!canvas.canPerform(.rotateLeft) && !canvas.canPerform(.volumeUp) && !canvas.canPerform(.volumeDown))
        #expect(!canvas.canPerform(.appSwitcher) && !canvas.canPerform(.actionButton) && !canvas.canPerform(.poseOpen))
        #expect(canvas.canPerform(.physicalSize) && canvas.canPerform(.toggleBezels))
        // Zoom to Fit: the hub's rule (device-hub.md §15.2, row 170), here
        // bound by the canvas's width: the outer box 0.98 × 580 − 16.
        let fit = DeviceZoom.hubFit(geometry: canvas.frameView.geometry, foldable: false, in: canvas.deviceArea.size)
        #expect(abs(Double(canvas.frameView.scale) - fit) < 1e-9)
        #expect(abs(Double(canvas.frameView.geometry.outerBox.width) * fit - (0.98 * 580 - 16)) < 1e-6)
        #expect(canvas.frameView.frame.maxY <= canvas.controls.frame.minY)
        canvas.perform(.zoomOut)
        #expect(canvas.zoom != .fit)
        canvas.perform(.zoomToFit)
        #expect(canvas.zoom == .fit)
        // The crown and the side button are hit on the frame and map to the
        // crown press and the side button (watchos.md §5.2).
        let f = canvas.frameView
        for kind in [DeviceFrameGeometry.ButtonKind.crown, .sideButton] {
            let r = f.geometry.buttons.first { $0.kind == kind }!.rect
            let p = NSPoint(x: (r.maxX - 1.5) * f.scale, y: r.midY * f.scale)
            #expect(f.hitTest(f.convert(p, to: f.superview)) === f, "\(kind)")
        }
        #expect(s.displayButton(for: .crown) == .home && s.displayButton(for: .sideButton) == .side)
        #expect(DeviceLiveSession.displayButton(for: .sideButton) == .lock, "not a watch: Sleep/Wake")
        s.close()
    }

    @Test func anUltraOffersTheActionButton() {
        let ultra = DeviceFrameSpec.named(typeID: "apple-watch-ultra-4-49mm")!
        let canvas = DeviceCanvasView(mode: .hub)
        canvas.frame = NSRect(x: 0, y: 0, width: 580, height: 800)
        let s = liveWatch(ultra)
        canvas.show(session: s)
        #expect(s.spec == ultra && canvas.canPerform(.actionButton))
        #expect(canvas.frameView.geometry.buttons.map(\.kind) == [.crown, .sideButton, .action])
        // §5.2: the Action button's own value once the server lists it; an
        // older server (no "action" in its hello) gets the provisional side.
        #expect(DeviceLiveSession.displayButton(for: .action, watch: true, actionOnTheWire: true) == .action)
        #expect(DeviceLiveSession.displayButton(for: .action, watch: true, actionOnTheWire: false) == .side)
        #expect(DeviceLiveSession.displayButton(for: .action, watch: false, actionOnTheWire: true) == .side, "a phone's Action")
        #expect(s.displayButton(for: .action) == .side, "this stand-in server's hello lists no action")
        s.close()
    }

    @Test func theWatchGlyphIsYcodesOwn() throws {
        #expect(DeviceGlyph.of(.watch) == .watch && DeviceGlyph.of(.phone) == .phone)
        for lit in [false, true] {
            let img = DeviceGlyph.watch.image(height: 17, lit: lit)
            #expect(img.isTemplate && img.size.height == 17 && img.size.width > 8 && img.size.width < 17)
            // It draws something: some pixels are opaque.
            let rep = try #require(img.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let ctx = CGContext(data: nil, width: rep.width, height: rep.height, bitsPerComponent: 8, bytesPerRow: rep.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(rep, in: CGRect(x: 0, y: 0, width: rep.width, height: rep.height))
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            var opaque = 0
            for i in 0..<(rep.width * rep.height) where data[i * 4 + 3] > 128 { opaque += 1 }
            #expect(opaque > 10, "lit \(lit): \(opaque)")
        }
    }
}
#endif
