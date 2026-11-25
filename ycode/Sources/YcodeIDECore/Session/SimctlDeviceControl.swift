#if canImport(AppKit)
import AppKit
#endif
import Foundation
import YcodeSubprocess

/// The Mac's simulator viewer: the app that shows a simctl simulator's
/// screen (`specs/ide/device-hub.md`, "Ycode decisions (2026-11-17)", "The
/// Mac's own simulators"). Ycode's UI calls it "the simulator viewer" and
/// names neither app.
public enum SimulatorViewer: String, Sendable, CaseIterable {
    /// Xcode 27 and later: found first.
    case deviceHub = "com.apple.dt.Devices"
    /// Xcode 26 and earlier.
    case simulator = "com.apple.iphonesimulator"

    public var bundleIdentifier: String { rawValue }

    /// `/usr/bin/open`'s arguments that show `udid` in this viewer: the
    /// first by its bundle id with no arguments (it lists the booted device),
    /// the second on the device.
    public func openArguments(_ udid: String) -> [String] {
        switch self {
        case .deviceHub: ["-b", bundleIdentifier]
        case .simulator: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
        }
    }

    /// The first viewer `installed` (a Launch Services lookup by bundle id)
    /// finds, in the spec's order; nil when there is none.
    public static func find(_ installed: (String) -> Bool) -> SimulatorViewer? {
        allCases.first { installed($0.bundleIdentifier) }
    }
}

/// Device Hub's lifecycle commands for the Mac's own simulators, the ones
/// `xcrun simctl list` reports (`specs/ide/device-hub.md` "Ycode decisions
/// (2026-11-17)"): Start boots the device and opens the simulator viewer
/// (`SimulatorViewer`), Shut Down and Restart act through simctl, Erase
/// erases a shut-down device. Their screens show in the viewer, not in the
/// hub; with no viewer installed the device runs without a screen. Only
/// Apple's public command-line interface is used: `simctl boot`,
/// `shutdown`, `erase`, `io <udid> screenshot`, `list -j devices`, and
/// `open` with the viewer's arguments.
///
/// Every command goes through injected runners (simctl's and `open`'s) and
/// an injected app lookup, so tests check the exact arguments without
/// booting or opening anything.
public struct SimctlDeviceControl: Sendable {
    /// Runs `xcrun simctl <args>`: (status, output).
    public var simctl: Simctl
    /// Runs `/usr/bin/open <args>`: (status, output).
    public var open: @Sendable ([String]) -> (Int32, String)
    /// Whether Launch Services finds an app with this bundle id.
    public var isInstalled: @Sendable (String) -> Bool
    /// Whether the picture at a path is entirely black (a screen that is off).
    public var isBlackImage: @Sendable (String) -> Bool

    public init(simctl: Simctl = Simctl(), open: @escaping @Sendable ([String]) -> (Int32, String) = SimctlDeviceControl.openCommand,
                isInstalled: @escaping @Sendable (String) -> Bool = SimctlDeviceControl.launchServicesFinds,
                isBlackImage: @escaping @Sendable (String) -> Bool = SimctlDeviceControl.imageIsBlack) {
        self.simctl = simctl
        self.open = open
        self.isInstalled = isInstalled
        self.isBlackImage = isBlackImage
    }

    /// The arguments of each command (tests compare them).
    public static func bootArguments(_ udid: String) -> [String] { ["boot", udid] }
    public static func shutdownArguments(_ udid: String) -> [String] { ["shutdown", udid] }
    public static func eraseArguments(_ udid: String) -> [String] { ["erase", udid] }
    public static func screenshotArguments(_ udid: String, to path: String) -> [String] { ["io", udid, "screenshot", path] }
    public static let listArguments = ["list", "-j", "devices"]

    /// The banner when Start booted the device and no viewer is installed:
    /// not a failure, the device runs without a screen.
    public static let noViewerMessage = "No simulator viewer is installed. The device is running without a screen."

    /// The viewer this Mac has now (looked up at each use: one may be
    /// installed or removed while the hub is open).
    public var viewer: SimulatorViewer? { SimulatorViewer.find(isInstalled) }

    /// What simctl prints when the device is already in the state asked for:
    /// boot on a booted device and shutdown on a shut-down one succeed.
    static func alreadyInState(_ output: String, _ state: String) -> Bool {
        output.contains("current state: \(state)")
    }

    /// What Start did: whether the device is booted, and the banner's text
    /// (nil after a start that showed the device in the viewer).
    public struct StartResult: Equatable, Sendable {
        public var booted: Bool
        public var message: String?
        public init(booted: Bool, message: String?) {
            self.booted = booted
            self.message = message
        }
    }

    /// Start: boots the device, then opens the simulator viewer. A booted
    /// device stays booted when there is no viewer or it does not open.
    public func start(_ udid: String) -> StartResult {
        let (s, out) = simctl.run(Self.bootArguments(udid))
        guard s == 0 || Self.alreadyInState(out, "Booted") else { return StartResult(booted: false, message: Self.failure("start", out)) }
        let (shown, message) = show(udid)
        return StartResult(booted: true, message: shown ? nil : message)
    }

    /// Shut Down.
    public func shutDown(_ udid: String) -> (Bool, String) {
        let (s, out) = simctl.run(Self.shutdownArguments(udid))
        guard s == 0 || Self.alreadyInState(out, "Shutdown") else { return (false, Self.failure("shut down", out)) }
        return (true, "Shut down")
    }

    /// Restart: Shut Down, then Start.
    public func restart(_ udid: String) -> StartResult {
        let (ok, message) = shutDown(udid)
        guard ok else { return StartResult(booted: false, message: message) }
        return start(udid)
    }

    /// Show in Viewer: opens the simulator viewer on the device (false with
    /// `noViewerMessage` when none is installed).
    public func show(_ udid: String) -> (Bool, String) {
        guard let viewer else { return (false, Self.noViewerMessage) }
        let (o, out) = open(viewer.openArguments(udid))
        return o == 0 ? (true, "Shown") : (false, Self.failure("show", out, program: "the simulator viewer"))
    }

    /// Erase All Content and Settings (the device must be shut down).
    public func erase(_ udid: String) -> (Bool, String) {
        let (s, out) = simctl.run(Self.eraseArguments(udid))
        return s == 0 ? (true, "Erased") : (false, Self.failure("erase", out))
    }

    /// The simulators as simctl lists them now (state included); nil when
    /// the list could not be read.
    public func list() -> [DeviceRow]? {
        let (s, out) = simctl.run(Self.listArguments)
        guard s == 0 else { return nil }
        return DevicesList.simulators(simctlJSON: Data(out.utf8))
    }

    /// A failure in a sentence, "Could not <action> the simulator: <the
    /// output's last line>". `action` is a whole phrase that reads before
    /// "the simulator": "start", "shut down", "erase", "show", "take a
    /// screenshot of".
    static func failure(_ action: String, _ output: String, program: String = "simctl") -> String {
        let last = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return "Could not \(action) the simulator" + (last.isEmpty ? "." : ": \(last)") + (program == "simctl" ? "" : " (\(program))")
    }

    /// Launch Services' lookup by bundle id (macOS); Linux has no viewer.
    public static let launchServicesFinds: @Sendable (String) -> Bool = { id in
        #if canImport(AppKit)
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        #else
        false
        #endif
    }

    /// `/usr/bin/open` with output in a file (as `Simctl.xcrun`).
    public static let openCommand: @Sendable ([String]) -> (Int32, String) = { args in
        MainThreadGuard.blockingCall("open \(args.first ?? "")")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-open-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let h = try? FileHandle(forWritingTo: file) else { return (127, "no temporary file") }
        p.standardOutput = h
        p.standardError = h
        guard (try? p.runWithSignalsUnblocked()) != nil else { return (127, "open not found") }
        p.waitUntilExit()
        try? h.close()
        return (p.terminationStatus, (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }
}
