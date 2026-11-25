import Foundation
import SwiftUI
import YcodeDeviceModel
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// Device Hub's walk (OpenViews only), started from ShellDriver:
//
//   YCODE_IDE_DEVICEHUB=<p>  open Device Hub with the pointer from the menu
//                           bar (Product ▸ Destination ▸ Manage Devices…; then
//                           closed and reopened with Ycode ▸ Open Developer Tool ▸
//                           Device Hub), select a device, Start it from the
//                           canvas, wait for its live screen, press Home, tap
//                           the screen, Home again, Rotate, Screenshot, show
//                           Info and Settings, open the row's menu and More
//                           Actions, then Shut Down. Photographs
//                           <p>-hub-*.png; prints one "hub: …" line per check
//                           and "hub: ok" or "hub: FAILED …".
//   YCODE_IDE_HUB_STANDIN=1 the hub's host is the in-process stand-in
//                           (`DeviceHubStandInBackend`: a drawn screen, no
//                           simulator); otherwise the paired hosts of the link.
//   YCODE_IDE_HUB_DEVICE=<name>  the device to start (default: the first stopped one).
//   YCODE_IDE_HUB_WAIT=<s>  how long to wait for the live screen (default 300).

#if os(Linux)
@MainActor
enum DeviceHubDriver {
    static var say: (String) -> Void { ShellDriver.say }
    static var window: Int { OpenViewsAutomation.windowIndex(sceneID: ShellAppModel.deviceHubWindowID) ?? 1 }
    static func frame(_ name: String) -> CGRect? { OpenViewsAutomation.identifiedFrames(window)[name] }

    static func click(_ name: String, button: Int = 1, at: CGPoint? = nil) async -> Bool {
        guard let f = frame(name) else { say("hub: no target \(name)"); return false }
        await OpenViewsAutomation.click(at: at ?? CGPoint(x: f.midX, y: f.midY), window: window, button: button)
        await ShellDriver.pause(0.5)
        return true
    }

    static func shot(_ prefix: String, _ name: String, popups: Bool = false) async {
        await ShellDriver.pause(0.6)
        let path = "\(prefix)-hub-\(name).png"
        say("hub \(name): " + (popups ? OpenViewsAutomation.screenshotWithPopups(window, to: path) : OpenViewsAutomation.screenshot(window, to: path)))
    }

    /// A menu path with the pointer from the workspace (or Welcome) window's menu bar.
    static func choose(_ path: [String]) async -> Bool {
        await ShellDriver.clickText(path[0], inPopup: false)
        for (i, item) in path.dropFirst().enumerated() {
            let next = i + 2 < path.count ? path[i + 2] : nil
            guard let t = OpenViewsAutomation.texts().first(where: { $0.inPopup && $0.text == item }) else {
                say("hub: menu has no \(item): \(OpenViewsAutomation.texts().filter(\.inPopup).map(\.text))")
                OpenViewsAutomation.press(.escape)
                return false
            }
            if item != path.last {
                // A submenu opens on hover (B4-TOOLKIT), else on a click.
                OpenViewsAutomation.move(to: CGPoint(x: t.frame.midX, y: t.frame.midY))
                await ShellDriver.pause(0.6)
                if let next, !OpenViewsAutomation.texts().contains(where: { $0.inPopup && $0.text == next }) {
                    await OpenViewsAutomation.click(at: CGPoint(x: t.frame.midX, y: t.frame.midY))
                }
            } else {
                await OpenViewsAutomation.click(at: CGPoint(x: t.frame.midX, y: t.frame.midY))
            }
            await ShellDriver.pause(0.5)
        }
        return true
    }

    static func waitFor(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > end { return false }
            await ShellDriver.pause(0.25)
        }
        return true
    }

    static func run(_ app: ShellAppModel, prefix: String) async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            say("hub: \(what) \(ok ? "yes" : "NO")")
            if !ok { failures.append(what) }
        }
        let hub = app.deviceHub
        let standIn = ShellDriver.env["YCODE_IDE_HUB_STANDIN"] == "1" ? DeviceHubStandInBackend() : nil
        if let standIn { hub.backend = standIn }
        say("hub: host \(standIn == nil ? "the link's paired hosts" : "stand-in")")

        // Product ▸ Destination ▸ Manage Devices… with the pointer.
        let opened = await choose(["Product", "Destination", "Manage Devices…"])
        let shownByMenu = opened ? await waitFor(5) { OpenViewsAutomation.windowIndex(sceneID: ShellAppModel.deviceHubWindowID) != nil } : false
        if !shownByMenu {
            say("hub: the menu path did not open the hub; using the command")
            app.performMenuAction("showDevices:")
        }
        check(shownByMenu, "Manage Devices… opens Device Hub")
        check(await waitFor(5) { OpenViewsAutomation.windowIndex(sceneID: ShellAppModel.deviceHubWindowID) != nil }, "hub window shown")
        check(await waitFor(20) { hub.loaded }, "devices listed")
        if let s = OpenViewsAutomation.windowSize(window) { say("hub: window \(s.points.width)x\(s.points.height) pt") }
        say("hub: devices \(hub.devices.map { "\($0.name)=\($0.state)" }) offline \(hub.offlineHosts)")
        check(!hub.devices.isEmpty, "the host's simulators listed")
        await shot(prefix, "open")

        // The device: start it from the canvas's Start.
        let wanted = ShellDriver.env["YCODE_IDE_HUB_DEVICE"]
        guard let d = hub.devices.first(where: { wanted == nil ? $0.isStopped : $0.name == wanted }) ?? hub.devices.first else {
            say("hub: FAILED no device"); return
        }
        check(await click("hub row \(d.name)"), "row \(d.name) clicked")
        check(hub.selectedID == d.id, "row selects \(d.name)")
        await shot(prefix, "stopped")
        if hub.selected?.isStopped == true {
            check(await click("hub start"), "Start clicked")
            await shot(prefix, "starting")
        }
        let wait = Double(ShellDriver.env["YCODE_IDE_HUB_WAIT"] ?? "") ?? 300
        let t0 = Date()
        let live = await waitFor(wait) {
            if hub.selected?.isRunning != true { hub.refresh() }
            return hub.screens[d.id]?.picture != nil && hub.screens[d.id]?.isLive == true && hub.screens[d.id]?.problem == nil
        }
        check(live, "live screen in the canvas")
        say(String(format: "hub: live after %.1f s", Date().timeIntervalSince(t0)))
        await ShellDriver.pause(2)
        await shot(prefix, "live")
        guard live, let screen = hub.screens[d.id] else { say("hub: FAILED \(failures)"); return }
        let before = screen.frames

        // Home, a tap on the screen, Home again.
        check(await click("hub control home"), "Home clicked")
        await shot(prefix, "home")
        // The canvas's origin: the Home control's frame less its place in the canvas (DeviceControlsLayout).
        let canvasW = screen.session.windowWidth, canvasH = screen.session.windowHeight
        let groups = DeviceControlsLayout.groups(.init(showsHome: true, rotates: d.spec.rotates))
        let homeRect = DeviceControlsLayout.controlRects(groups, canvasWidth: canvasW, canvasHeight: canvasH).first { $0.0 == .home }?.1
        if let h = frame("hub control home"), let homeRect {
            let s = CGRect(x: h.minX - homeRect.minX, y: h.minY - homeRect.minY, width: canvasW, height: canvasH)
            let l = screen.layout.screen
            await OpenViewsAutomation.click(at: CGPoint(x: s.minX + l.x + l.width * 0.15, y: s.minY + l.y + l.height * 0.2), window: window)
            await ShellDriver.pause(1.5)
            await shot(prefix, "tapped")
            check(await click("hub control home"), "Home clicked again")
            await ShellDriver.pause(1)
        }
        // The stand-in redraws on every touch; a real home screen may not change
        // where the walk taps (Home on the home screen draws nothing new).
        if standIn != nil { check(screen.frames > before, "new pictures after the input (\(screen.frames - before))") } else {
            say("hub: new pictures after the input: \(screen.frames - before)")
        }
        say("hub: banner \(hub.banner ?? "none"); the device received \(standIn?.received(d.id) ?? [])")
        if let standIn {
            let got = standIn.received(d.id)
            check(got.contains("button home") && got.contains("touch"), "the device received Home and the touch")
        }
        // Rotate: the device turns, or the banner says it does not.
        check(await click("hub control rotateLeft"), "Rotate clicked")
        await ShellDriver.pause(1.5)
        say("hub: rotate → banner \(hub.banner ?? "none"), canRotate \(screen.canRotate)")
        await shot(prefix, "rotated")
        if screen.canRotate { _ = await click("hub control rotateLeft"); _ = await click("hub control rotateLeft"); _ = await click("hub control rotateLeft") }
        // Screenshot.
        let shots = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-hub-walk-\(getpid())")
        screen.captureDirectory = shots
        check(await click("hub control screenshot"), "Screenshot clicked")
        check(await waitFor(10) { hub.banner == "Screenshot Saved" }, "Screenshot Saved")
        say("hub: screenshot files \((try? FileManager.default.contentsOfDirectory(atPath: shots.path)) ?? [])")
        try? FileManager.default.removeItem(at: shots)

        // The inspector: Settings (read over the stream), Info.
        _ = await click("hub tab settings")
        _ = await waitFor(10) { hub.settings != nil }
        check(hub.settings != nil, "Settings read from the device")
        await shot(prefix, "settings")
        _ = await click("hub tab info")
        check(hub.infoRows.first { $0.0 == "State" }?.1 == "Booted", "Info says Booted")
        await shot(prefix, "info")
        _ = await click("hub tab settings")

        // The row's menu and More Actions.
        _ = await click("hub row \(d.name)", button: 3)
        let rowMenu = OpenViewsAutomation.texts(window).filter(\.inPopup).map(\.text)
        check(rowMenu.contains("Shut Down") && rowMenu.contains("Restart"), "row menu has Shut Down and Restart \(rowMenu)")
        await shot(prefix, "row-menu", popups: true)
        OpenViewsAutomation.press(.escape, window: window)
        await ShellDriver.pause(0.4)
        _ = await click("hub more")
        let more = OpenViewsAutomation.texts(window).filter(\.inPopup).map(\.text)
        check(more.contains("Shut Down"), "More Actions has Shut Down \(more)")
        await shot(prefix, "more", popups: true)
        if let t = OpenViewsAutomation.texts(window).first(where: { $0.inPopup && $0.text == "Shut Down" }) {
            await OpenViewsAutomation.click(at: CGPoint(x: t.frame.midX, y: t.frame.midY), window: window)
        } else {
            OpenViewsAutomation.press(.escape, window: window)
            hub.shutDown(d)
        }
        check(await waitFor(180) { hub.refresh(); return hub.devices.first { $0.id == d.id }?.isStopped == true }, "Shut Down stops it")
        await ShellDriver.pause(1)
        await shot(prefix, "shut-down")

        // Open Developer Tool ▸ Device Hub brings the hub forward too.
        let before2 = OpenViewsAutomation.windowCount
        let viaTool = await choose(["Ycode", "Open Developer Tool", "Device Hub"])
        check(viaTool && OpenViewsAutomation.windowCount == before2, "Open Developer Tool ▸ Device Hub shows the same hub")
        say(failures.isEmpty ? "hub: ok" : "hub: FAILED \(failures)")
    }
}
#endif
