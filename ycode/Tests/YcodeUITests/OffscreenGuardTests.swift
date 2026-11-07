import AppKit
import CYcodeTestOffscreen
import Foundation
import Testing

private let onScreenRun = ProcessInfo.processInfo.environment["YCODE_TESTS_ON_SCREEN"] == "1"

/// The offscreen guard (`Tests/CYcodeTestOffscreen`, README "Nothing on
/// screen"): no window, sheet, alert, panel or menu of a test process
/// reaches a display. Each check asks AppKit (the frame against every
/// `NSScreen`) and the window server (`CGWindowListCopyWindowInfo` against
/// every active display). The guard's sentinel watches the whole run the
/// same way and fails the process at exit if a window was ever on a display;
/// `noWindowOfThisProcessHasBeenOnADisplay` reports it as a test as well.
@MainActor
@Suite(.serialized, .disabled(if: onScreenRun, "YCODE_TESTS_ON_SCREEN=1 shows windows on purpose"))
struct OffscreenGuardTests {
    func touchesAScreen(_ r: NSRect) -> Bool { NSScreen.screens.contains { $0.frame.intersects(r) } }

    /// The window server lists this window on a display.
    func serverShows(_ w: NSWindow) -> Bool {
        YcodeOffscreenWindowsOnDisplays().contains { $0.hasPrefix("window \(w.windowNumber) ") }
    }

    func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// A window at (40, 40), on the main display were it not for the guard
    /// (never made without it).
    func window(_ style: NSWindow.StyleMask = [.titled, .closable, .resizable]) throws -> NSWindow {
        try #require(YcodeOffscreenIsActive(), "the guard is not installed: no window is made")
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 300), styleMask: style, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isExcludedFromWindowsMenu = true
        return w
    }

    func expectOff(_ w: NSWindow, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!touchesAScreen(w.frame), "\(what): \(w.frame) touches a screen", sourceLocation: sourceLocation)
        #expect(!serverShows(w), "\(what): the window server shows it on a display", sourceLocation: sourceLocation)
    }

    @Test func theGuardIsInstalled() {
        #expect(YcodeOffscreenIsActive())
    }

    /// Every way of ordering a window in, from a frame at (40, 40) on the
    /// main display: the window is visible, keeps its size, and is off
    /// every display.
    @Test(arguments: ["makeKeyAndOrderFront", "orderFront", "orderFrontRegardless", "orderBack", "orderWindow", "isVisible", "showWindow"])
    func aWindowOrderedInStaysOffEveryDisplay(_ how: String) throws {
        let w = try window()
        defer { w.orderOut(nil) }
        let size = w.frame.size
        switch how {
        case "makeKeyAndOrderFront": w.makeKeyAndOrderFront(nil)
        case "orderFront": w.orderFront(nil)
        case "orderFrontRegardless": w.orderFrontRegardless()
        case "orderBack": w.orderBack(nil)
        case "orderWindow": w.order(.above, relativeTo: 0)
        case "isVisible": w.setIsVisible(true)
        default: NSWindowController(window: w).showWindow(nil)
        }
        pump()
        #expect(w.isVisible && w.frame.size == size)
        expectOff(w, how)
    }

    /// A visible window given a place on a display (an origin, a top-left
    /// point, a frame, the centre, a zoom) stays off every display.
    @Test func aVisibleWindowMovedOntoADisplayStaysOff() throws {
        let w = try window()
        defer { w.orderOut(nil) }
        w.orderFront(nil)
        w.setFrameOrigin(NSPoint(x: 40, y: 40))
        expectOff(w, "setFrameOrigin")
        w.setFrameTopLeftPoint(NSPoint(x: 100, y: 500))
        expectOff(w, "setFrameTopLeftPoint")
        w.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: true)
        #expect(w.frame.size == NSSize(width: 500, height: 400))
        expectOff(w, "setFrame")
        w.setFrame(NSRect(x: 10, y: 10, width: 520, height: 400), display: true, animate: false)
        expectOff(w, "setFrame animate")
        w.center()
        expectOff(w, "center")
        w.zoom(nil)
        pump()
        expectOff(w, "zoom")
        // Relative moves of a window off the displays are kept as asked.
        let before = w.frame
        w.setFrameOrigin(NSPoint(x: before.minX + 10, y: before.minY - 20))
        #expect(w.frame.origin == NSPoint(x: before.minX + 10, y: before.minY - 20))
    }

    /// A document window's appear and close animations (AppKit draws them
    /// on a display even for a window off every display) do not run: the
    /// window server never shows the window while it orders in or out, and
    /// the window keeps its animation behaviour.
    /// ("far": a workspace-sized window put at (−6000, −6000) by the test,
    /// as the council suites do.)
    @Test(arguments: ["orderOut", "close", "far"])
    func orderingAnimationsNeverReachADisplay(_ how: String) throws {
        let w = try window()
        w.animationBehavior = .documentWindow
        if how == "far" { w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false) }
        var seen: [String] = []
        func watch(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                seen += YcodeOffscreenWindowsOnDisplays()
                pump(0.02)
            }
        }
        if how == "far" { w.orderBack(nil) } else { w.makeKeyAndOrderFront(nil) }
        watch(0.5)
        if how == "close" { w.close() } else { w.orderOut(nil) }
        watch(0.6)
        #expect(seen.isEmpty, "\(seen)")
        #expect(!w.isVisible && w.animationBehavior == .documentWindow)
    }

    /// AppKit's constraint to a screen is off: a frame off every display is
    /// kept as given.
    @Test func framesOffTheDisplaysAreNotConstrained() throws {
        let w = try window()
        let far = NSRect(x: -6000, y: -6000, width: 420, height: 300)
        #expect(w.constrainFrameRect(far, to: NSScreen.main) == far)
        #expect(YcodeOffscreenParkedFrame(far) == far)
        let parked = YcodeOffscreenParkedFrame(NSRect(x: 40, y: 40, width: 420, height: 300))
        #expect(parked.size == NSSize(width: 420, height: 300) && parked.minY == 40 && !touchesAScreen(parked))
    }

    /// A sheet on a window, and a panel, are off every display too.
    @Test func sheetsAndPanelsStayOff() async throws {
        let w = try window()
        defer { w.orderOut(nil) }
        w.orderFront(nil)
        let sheet = try window([.titled])
        w.beginSheet(sheet, completionHandler: nil)
        pump(0.4)
        #expect(sheet.isVisible)
        expectOff(sheet, "sheet")
        w.endSheet(sheet)
        let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil) }
        panel.orderFront(nil)
        pump()
        expectOff(panel, "panel")
    }

    /// App-modal alerts and panels are never shown: they answer Cancel at
    /// once, and the guard notes them. Menus do not pop up.
    @Test func modalAlertsPanelsAndMenusAreNotShown() throws {
        try #require(YcodeOffscreenIsActive(), "the guard is not installed: nothing is shown")
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "Offscreen guard check"
        alert.addButton(withTitle: "OK")
        #expect(alert.runModal() == .cancel)
        #expect(YcodeOffscreenSuppressed().contains("NSAlert runModal \"Offscreen guard check\""))
        #expect(NSSavePanel().runModal() == .cancel)
        let menu = NSMenu(title: "Offscreen guard menu")
        menu.addItem(withTitle: "Item", action: nil, keyEquivalent: "")
        #expect(!menu.popUp(positioning: nil, at: .zero, in: nil))
        #expect(YcodeOffscreenSuppressed().contains { $0.contains("Offscreen guard menu") })
    }

    /// No window of this process is on a display now, and none has been
    /// since the guard's sentinel started (the exit check covers the rest of
    /// the run).
    @Test func noWindowOfThisProcessHasBeenOnADisplay() throws {
        let w = try window()
        defer { w.orderOut(nil) }
        w.orderFront(nil)  // starts the sentinel if nothing has yet
        pump(0.5)
        #expect(YcodeOffscreenWindowsOnDisplays().isEmpty, "\(YcodeOffscreenWindowsOnDisplays())")
        #expect(YcodeOffscreenViolations().isEmpty, "\(YcodeOffscreenViolations())")
    }
}
