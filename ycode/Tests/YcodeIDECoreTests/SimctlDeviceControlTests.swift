import Foundation
import Testing
@testable import YcodeIDECore

/// Device Hub's commands for the Mac's simctl simulators
/// (`specs/ide/device-hub.md`, "Ycode decisions (2026-11-17)", "The Mac's
/// own simulators"), with fake runners and a fake Launch Services lookup:
/// the viewer chosen (Device Hub first, then Simulator, else none), the
/// exact arguments of boot, shutdown, erase, screenshot and the viewer's
/// open, and how failures and the no-viewer notice read. Nothing is booted
/// or opened.
struct SimctlDeviceControlTests {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var answers: [String: (Int32, String)] = [:]
        func run(_ tool: String, _ args: [String]) -> (Int32, String) {
            lock.withLock {
                calls.append([tool] + args)
                return answers[([tool] + args.prefix(1)).joined(separator: " ")] ?? (0, "")
            }
        }
    }

    static let deviceHub = "com.apple.dt.Devices"
    static let simulatorApp = "com.apple.iphonesimulator"

    /// `installed`: the bundle ids the fake Launch Services finds.
    func control(_ r: Recorder, installed: Set<String> = [Self.deviceHub]) -> SimctlDeviceControl {
        SimctlDeviceControl(simctl: Simctl(run: { r.run("simctl", $0) }), open: { r.run("open", $0) },
                            isInstalled: { installed.contains($0) })
    }

    static let udid = "6A1F2B3C-0000-4000-8000-0123456789AB"
    static let openHub = ["open", "-b", "com.apple.dt.Devices"]
    static let openSimulator = ["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]

    @Test func theViewerIsDeviceHubThenSimulatorThenNone() {
        let r = Recorder()
        #expect(control(r, installed: [Self.deviceHub, Self.simulatorApp]).viewer == .deviceHub)
        #expect(control(r, installed: [Self.deviceHub]).viewer == .deviceHub)
        #expect(control(r, installed: [Self.simulatorApp]).viewer == .simulator)
        #expect(control(r, installed: []).viewer == nil)
        #expect(SimulatorViewer.deviceHub.openArguments(Self.udid) == ["-b", "com.apple.dt.Devices"])
        #expect(SimulatorViewer.simulator.openArguments(Self.udid) == ["-a", "Simulator", "--args", "-CurrentDeviceUDID", Self.udid])
        // The lookup asks by bundle id, in the spec's order.
        var ids: [String] = []
        _ = SimulatorViewer.find { ids.append($0); return false }
        #expect(ids == ["com.apple.dt.Devices", "com.apple.iphonesimulator"])
    }

    @Test func startBootsThenOpensDeviceHubByBundleID() {
        let r = Recorder()
        #expect(control(r).start(Self.udid) == .init(booted: true, message: nil))
        #expect(r.calls == [["simctl", "boot", Self.udid], Self.openHub])
    }

    @Test func startWithOnlySimulatorOpensItOnTheDevice() {
        let r = Recorder()
        #expect(control(r, installed: [Self.simulatorApp]).start(Self.udid) == .init(booted: true, message: nil))
        #expect(r.calls == [["simctl", "boot", Self.udid], Self.openSimulator])
    }

    @Test func startWithNoViewerLeavesTheDeviceBootedAndSaysSo() {
        let r = Recorder()
        let c = control(r, installed: [])
        #expect(c.start(Self.udid) == .init(booted: true, message: SimctlDeviceControl.noViewerMessage))
        #expect(r.calls == [["simctl", "boot", Self.udid]], "nothing is opened without a viewer")
        #expect(SimctlDeviceControl.noViewerMessage == "No simulator viewer is installed. The device is running without a screen.")
        #expect(c.show(Self.udid) == (false, SimctlDeviceControl.noViewerMessage))
        #expect(r.calls.count == 1)
    }

    @Test func startOfABootedDeviceStillShowsIt() {
        let r = Recorder()
        r.answers["simctl boot"] = (149, "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\nUnable to boot device in current state: Booted\n")
        #expect(control(r).start(Self.udid).booted)
        #expect(r.calls.last == Self.openHub)
    }

    @Test func shutDownRestartEraseAndScreenshot() {
        let r = Recorder()
        let c = control(r)
        #expect(c.shutDown(Self.udid) == (true, "Shut down"))
        #expect(r.calls.last == ["simctl", "shutdown", Self.udid])
        r.calls = []
        #expect(c.restart(Self.udid).booted)
        #expect(r.calls == [["simctl", "shutdown", Self.udid], ["simctl", "boot", Self.udid], Self.openHub])
        #expect(c.erase(Self.udid) == (true, "Erased"))
        #expect(r.calls.last == ["simctl", "erase", Self.udid])
        #expect(c.screenshot(Self.udid, to: "/tmp/shot.png") == (true, "Screenshot Saved"))
        #expect(r.calls.last == ["simctl", "io", Self.udid, "screenshot", "/tmp/shot.png"])
        #expect(c.show(Self.udid).0)
        #expect(r.calls.last == Self.openHub)
        #expect(control(r, installed: [Self.simulatorApp]).show(Self.udid).0)
        #expect(r.calls.last == Self.openSimulator)
    }

    @Test func failuresSayWhatCouldNotBeDone() {
        let r = Recorder()
        r.answers["simctl boot"] = (148, "An error was encountered processing the command:\nInvalid device: \(Self.udid)\n")
        let s = control(r).start(Self.udid)
        #expect(!s.booted && s.message == "Could not start the simulator: Invalid device: \(Self.udid)")
        #expect(r.calls.count == 1, "the viewer is not opened after a failed boot")
        r.answers["simctl boot"] = nil
        r.answers["open -b"] = (1, "The application cannot be opened.")
        // Booted although the viewer did not open: not a start failure.
        #expect(control(r).start(Self.udid) == .init(booted: true, message: "Could not show the simulator: The application cannot be opened. (the simulator viewer)"))
        #expect(control(r).show(Self.udid) == (false, "Could not show the simulator: The application cannot be opened. (the simulator viewer)"))
        r.answers["simctl erase"] = (164, "Unable to erase contents and settings in current state: Booted")
        #expect(control(r).erase(Self.udid).1 == "Could not erase the simulator: Unable to erase contents and settings in current state: Booted")
    }

    @Test func theListGivesEachSimulatorsState() throws {
        let r = Recorder()
        r.answers["simctl list"] = (0, """
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
          {"name": "iPhone 17", "udid": "\(Self.udid)", "state": "Booted", "isAvailable": true,
           "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}}
        """)
        let rows = try #require(control(r).list())
        #expect(r.calls.last == ["simctl", "list", "-j", "devices"])
        #expect(rows.map(\.identifier) == [Self.udid] && rows.first?.state == "Booted" && rows.first?.osVersion == "27.2")
        r.answers["simctl list"] = (1, "")
        #expect(control(r).list() == nil)
    }
}
