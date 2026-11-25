import AppKit
import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeDeviceUI
@testable import YcodeIDECore
@testable import YcodeUI

/// Device Hub and the Mac's simctl simulators (`specs/ide/device-hub.md`,
/// "Ycode decisions (2026-11-17)", "The Mac's own simulators"), offscreen
/// with a fake simctl, a fake `open` and a fake Launch Services lookup: Start
/// boots the device and opens the simulator viewer (Device Hub by bundle id,
/// else Simulator on the device); with no viewer the device stays booted and
/// the banner says so; while it runs, the canvas shows its picture with the
/// status capsule and Show in Viewer, Screenshot acts through simctl and the
/// other controls say the viewer has them; Shut Down, Restart and Erase from
/// the status view, the row's menu and More Actions; the poll follows
/// simctl's states; failures show their message. Nothing is booted or
/// opened, and the UI names no Apple product.
@MainActor
@Suite(.serialized) struct DeviceHubSimctlTests {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        private var calls: [[String]] = []
        private var answers: [String: (Int32, String)] = [:]
        /// The answer to a command (`"simctl boot"`), under the lock: the hub's poll runs simctl off the main thread.
        func answer(_ key: String, _ value: (Int32, String)?) { lock.withLock { answers[key] = value } }
        func run(_ tool: String, _ args: [String]) -> (Int32, String) {
            lock.withLock {
                calls.append([tool] + args)
                return answers[([tool] + args.prefix(1)).joined(separator: " ")] ?? (0, "")
            }
        }
        var recorded: [[String]] { lock.withLock { calls } }
        /// The commands the hub's actions ran, without the 2-second poll's
        /// `simctl list` (which a slow run lets in between them).
        var actions: [[String]] { recorded.filter { !($0.count > 1 && $0[0] == "simctl" && $0[1] == "list") } }
    }

    static let udid = "B5DE41CE-0000-4000-8000-00000000A17E"
    static let row = DeviceRow(name: "iPhone 17", identifier: udid, platform: "iOS", osVersion: "27.2", state: "Shutdown",
                               model: "iPhone 17", isAvailable: true)
    static let open = ["open", "-b", "com.apple.dt.Devices"]
    static let openSimulator = ["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]

    /// `installed`: the bundle ids the fake Launch Services finds (Device Hub by default).
    func makeHub(_ t: TestDefaults, state: String = "Shutdown",
                 installed: Set<String> = ["com.apple.dt.Devices"]) -> (DevicesController, NSWindow, Recorder) {
        _ = NSApplication.shared
        var r = Self.row
        r.state = state
        let hub = DevicesController(devices: [], simulators: [r])
        hub.defaults = t.defaults
        let rec = Recorder()
        hub.simctlControl = SimctlDeviceControl(simctl: Simctl(run: { rec.run("simctl", $0) }), open: { rec.run("open", $0) },
                                                isInstalled: { installed.contains($0) })
        let w = hub.makeWindow()
        w.isExcludedFromWindowsMenu = true
        w.setFrameAutosaveName("")
        hub.splitView.autosaveName = nil
        w.setContentSize(NSSize(width: 1100, height: 800))
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        w.orderBack(nil)
        w.contentView?.layoutSubtreeIfNeeded()
        hub.select(row: 0)
        w.contentView?.layoutSubtreeIfNeeded()
        return (hub, w, rec)
    }

    @Test func startBootsAndOpensTheViewerThenShowsTheStatus() async throws {
        let t = TestDefaults("hub-simctl-start")
        defer { t.remove() }
        let (hub, w, rec) = makeHub(t)
        defer { w.close() }
        // Stopped: its picture with Start where the controls float.
        #expect(hub.canvas.stateDescription == "stopped")
        #expect(!hub.canvas.statusActionCapsule.isHidden && hub.canvas.statusActionButton.title == "Start")
        // The status view's Start.
        click(hub.canvas.statusActionButton)
        await hub.lifecycleTask?.value
        #expect(rec.actions == [["simctl", "boot", Self.udid], Self.open])
        #expect(hub.selected?.state == "Booted")
        #expect(hub.canvas.lastBannerText == nil, "a start that shows the device needs no banner")
        // Running in the simulator viewer: the capsule names it, its state and Show in Viewer.
        #expect(hub.canvas.stateDescription == "elsewhere: Running in the simulator viewer")
        let texts = try #require(hub.canvas.elsewhereTexts)
        #expect(texts.title == "iPhone 17" && texts.detail == "Running in the simulator viewer" && texts.action == "Show in Viewer")
        let capsule = try #require(hub.canvas.elsewhereCapsule)
        #expect(capsule.superview === hub.canvas && !capsule.isHidden && capsule.frame.width > 150)
        // The capsule sits over the device, the controls under it.
        #expect(capsule.frame.maxY < hub.canvas.controls.frame.minY)
        // Screenshot acts; the other controls say why not.
        #expect(hub.canvas.controls.button(for: .screenshot)?.toolTip == "Screenshot")
        #expect(DevicesController.simctlRunningReason == "The simulator viewer has these controls.")
        #expect(hub.canvas.controls.button(for: .home)?.toolTip == "Home. The simulator viewer has these controls.")
        hub.canvas.perform(.home)
        #expect(hub.canvas.lastBannerText == DevicesController.simctlRunningReason)
        // Show in Viewer opens it again.
        click(hub.canvas.elsewhereActionButton)
        await hub.simctlTask?.value
        #expect(rec.actions.last == Self.open && rec.actions.count == 3)
        Self.expectNoAppleProductNames(hub)
        DeviceHubSimctlTests.shot(w, "mac-hub-simctl-running.png")
    }

    @Test func withOnlySimulatorStartOpensItOnTheDevice() async throws {
        let t = TestDefaults("hub-simctl-sim-only")
        defer { t.remove() }
        let (hub, w, rec) = makeHub(t, installed: ["com.apple.iphonesimulator"])
        defer { w.close() }
        click(hub.canvas.statusActionButton)
        await hub.lifecycleTask?.value
        #expect(rec.actions == [["simctl", "boot", Self.udid], Self.openSimulator])
        #expect(hub.selected?.state == "Booted" && hub.canvas.stateDescription == "elsewhere: Running in the simulator viewer")
        click(hub.canvas.elsewhereActionButton)
        await hub.simctlTask?.value
        #expect(rec.actions.last == Self.openSimulator)
        Self.expectNoAppleProductNames(hub)
    }

    @Test func withNoViewerTheDeviceStaysBootedAndTheBannerSaysSo() async throws {
        let t = TestDefaults("hub-simctl-no-viewer")
        defer { t.remove() }
        let (hub, w, rec) = makeHub(t, installed: [])
        defer { w.close() }
        click(hub.canvas.statusActionButton)
        await hub.lifecycleTask?.value
        // Not a start failure: booted, the row and the canvas say so, nothing opened.
        #expect(rec.actions == [["simctl", "boot", Self.udid]])
        #expect(hub.selected?.state == "Booted")
        #expect(hub.canvas.stateDescription == "elsewhere: Running in the simulator viewer")
        #expect(hub.canvas.lastBannerText == "No simulator viewer is installed. The device is running without a screen.")
        // Show in Viewer says the same and opens nothing.
        hub.canvas.showBanner("")
        click(hub.canvas.elsewhereActionButton)
        await hub.simctlTask?.value
        #expect(rec.actions.count == 1 && hub.canvas.lastBannerText == SimctlDeviceControl.noViewerMessage)
        DeviceHubSimctlTests.shot(w, "mac-hub-simctl-no-viewer.png")
    }

    /// The hub's own words for a Mac simulator never name Apple's apps.
    static func expectNoAppleProductNames(_ hub: DevicesController) {
        var words = [DevicesController.showInViewerTitle, DevicesController.simctlRunningReason, DevicesController.simctlStoppedReason,
                     SimctlDeviceControl.noViewerMessage] + ["Booted", "Shutdown", "Booting", "Shutting Down"].map(DevicesController.simctlStateText)
        if let e = hub.canvas.elsewhereTexts { words += [e.detail, e.action] }
        words += hub.contextMenu(forRow: 0).items.map(\.title)
        for w in words {
            #expect(!w.contains("Simulator app") && !w.contains("Device Hub") && !w.contains("Xcode") && !w.contains("Show in Simulator"), "\(w)")
        }
    }

    @Test func screenshotGoesThroughSimctl() async throws {
        let t = TestDefaults("hub-simctl-shot")
        defer { t.remove() }
        let (hub, w, rec) = makeHub(t, state: "Booted")
        defer { w.close() }
        hub.canvas.perform(.screenshot)
        await hub.simctlTask?.value
        let call = try #require(rec.actions.last)
        #expect(Array(call.prefix(4)) == ["simctl", "io", Self.udid, "screenshot"])
        #expect(call.last?.hasSuffix(".png") == true && call.last?.contains("Screenshot iPhone 17") == true)
        #expect(hub.canvas.lastBannerText == "Screenshot Saved")
        // A refusal: the banner reads as a whole sentence.
        rec.answer("simctl io", (22, "An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=22):\nInvalid argument"))
        hub.canvas.perform(.screenshot)
        await hub.simctlTask?.value
        #expect(hub.canvas.lastBannerText == "Could not take a screenshot of the simulator: Invalid argument")
    }

    @Test func theRowsMenuAndMoreActionsShutDownRestartAndErase() async throws {
        let t = TestDefaults("hub-simctl-menus")
        defer { t.remove() }
        let (hub, w, rec) = makeHub(t, state: "Booted")
        defer { w.close() }
        let menu = hub.contextMenu(forRow: 0)
        #expect(menu.items.map(\.title) == ["Shut Down", "Restart", "", "Show in Viewer", "", DevicesController.eraseTitle])
        #expect(menu.items.first { $0.title == DevicesController.eraseTitle }?.isEnabled == false, "erase needs a shut-down device")
        // More Actions holds the same lifecycle items (DeviceHubToolbar.moreItems).
        #expect((hub.lifecycleItems(for: hub.selected!) + hub.simctlShowItems(for: hub.selected!)).map(\.title)
                == ["Shut Down", "Restart", "", "Show in Viewer", ""])
        // Restart: shutdown, boot, the simulator viewer.
        await hub.restart(hub.selected!)?.value
        #expect(rec.actions == [["simctl", "shutdown", Self.udid], ["simctl", "boot", Self.udid], Self.open])
        #expect(hub.selected?.state == "Booted")
        // Shut Down from the menu item.
        let shut = try #require(hub.contextMenu(forRow: 0).items.first { $0.title == "Shut Down" })
        _ = shut.target?.perform(shut.action, with: shut)
        await hub.lifecycleTask?.value
        #expect(rec.actions.last == ["simctl", "shutdown", Self.udid] && hub.selected?.state == "Shutdown")
        #expect(hub.canvas.stateDescription == "stopped")
        // Erase, behind the hub's confirmation.
        var asked: [String] = []
        hub.confirmErase = { asked.append($0.name); return true }
        let erase = try #require(hub.contextMenu(forRow: 0).items.first { $0.title == DevicesController.eraseTitle })
        #expect(erase.isEnabled)
        await hub.erase(row: 0)?.value
        #expect(asked == ["iPhone 17"] && rec.actions.last == ["simctl", "erase", Self.udid])
        #expect(hub.canvas.lastBannerText == "Erased")
    }

    @Test func thePollFollowsSimctlAndFailuresShowTheirMessage() async throws {
        let t = TestDefaults("hub-simctl-poll")
        defer { t.remove() }
        let (hub, w, rec) = makeHub(t)
        defer { w.close() }
        rec.answer("simctl list", (0, """
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": [{"name": "iPhone 17", "udid": "\(Self.udid)", "state": "Booted", "isAvailable": true}]}}
        """))
        hub.pollSimctl()
        for _ in 0..<100 where hub.selected?.state != "Booted" { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(hub.selected?.state == "Booted" && hub.canvas.stateDescription.hasPrefix("elsewhere"))
        // A failed start.
        rec.answer("simctl list", nil)
        await hub.shutDown(hub.selected!)?.value
        rec.answer("simctl boot", (148, "Invalid device: \(Self.udid)"))
        await hub.start(hub.selected!)?.value
        #expect(hub.canvas.lastBannerText == "Could not start the simulator: Invalid device: \(Self.udid)")
        #expect(hub.selected?.state == "Shutdown")
    }

    @Test func withoutSimctlsControlTheRowStaysReadOnly() throws {
        let t = TestDefaults("hub-simctl-off")
        defer { t.remove() }
        let (hub, w, _) = makeHub(t, state: "Booted")
        defer { w.close() }
        hub.simctlControl = nil
        hub.select(row: 0)
        #expect(hub.canvas.stateDescription == "stopped" && hub.canvas.unavailableControlsReason == DeviceCanvasView.notOperatedReason)
        #expect(hub.contextMenu(forRow: 0).items.isEmpty)
    }

    @Test func theHubWithoutAWorkspaceOperatesSimctlSimulators() throws {
        let t = TestDefaults("hub-simctl-standalone")
        defer { t.remove() }
        let hub = DevicesController(devices: [], simulators: [Self.row])
        let rec = Recorder()
        hub.configureStandalone(defaults: t.defaults, simctl: SimctlDeviceControl(simctl: Simctl(run: { rec.run("simctl", $0) }), open: { rec.run("open", $0) },
                                                                                    isInstalled: { _ in false }))
        #expect(hub.simctlControl != nil && hub.isSimctlOperated(Self.row))
        #expect(hub.canStart(Self.row))
    }

    /// The button's action, sent as a click sends it (without `performClick`'s
    /// highlight, which runs the run loop inside the test).
    func click(_ b: NSButton) {
        guard let a = b.action else { return }
        NSApp.sendAction(a, to: b.target, from: b)
    }

    static func shot(_ w: NSWindow, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_B5_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
