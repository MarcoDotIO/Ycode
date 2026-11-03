// The headset onboarding's checklist (specs/ide/device-hub.md §I.12): what
// must be in place on the workstation that runs the headset viewer and on
// the headset, each with its state, the reason and the exact fix. Portable:
// the macOS hub, the Linux shell and `ycode sim headset check` show the same
// list. Everything here only looks: a check runs read-only commands through
// a `HeadsetCommandRunner`; a fix is text for the user to run, or an action
// that runs only when the user clicks it. Nothing ever runs sudo.
//
// WiVRn and its headset client are external GPLv3 programs, never bundled
// with Ycode; what is said about them comes from WiVRn's user documentation
// and from its running server's public D-Bus properties (§I.12 sources).

import Foundation
import YcodeSubprocess
#if canImport(Glibc)
import Glibc
#endif

/// A shell command's result on the viewer host.
public struct HeadsetCommandResult: Sendable, Equatable {
    public var status: Int32
    public var output: String
    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
    public var ok: Bool { status == 0 }
    /// The shell's "command not found".
    public var notFound: Bool { status == 127 }
}

/// Runs a shell command line on the viewer host. Stand-ins answer in tests.
public protocol HeadsetCommandRunner: Sendable {
    func run(_ command: String) async -> HeadsetCommandResult
}

/// Where the viewer runs: this machine (Linux), or a Linux PC reached by ssh
/// with a key (the hub on a Mac: WiVRn does not run on macOS).
public enum HeadsetViewerHost: Sendable, Equatable {
    case thisMachine
    case ssh(String)
    case none

    public var title: String {
        switch self {
        case .thisMachine: "This machine"
        case .ssh(let d): d
        case .none: "Not chosen"
        }
    }
}

/// How the headset reaches WiVRn on the workstation.
public enum HeadsetConnectionKind: String, Sendable, CaseIterable, Codable {
    case usb, wifi
    public var title: String { self == .usb ? "USB cable" : "Wi-Fi" }
}

/// What the user chose for the headset; one set per Ycode installation.
public struct HeadsetSettings: Sendable, Equatable, Codable {
    /// The ssh destination of the viewer host (empty: this machine on Linux, none on a Mac).
    public var viewerHost = ""
    /// The viewer on that host: a path, or a name on its PATH.
    public var viewerPath = "ycode-xr-viewer"
    public var connection = HeadsetConnectionKind.usb
    /// The ssh destination of the simulator host as the viewer host sees it
    /// (empty: the same destination the hub uses).
    public var simulatorHostFromViewer = ""
    /// More options for the viewer (`xr-viewer.md` §7), split at spaces.
    public var viewerOptions = "--foveate"

    public init() {}

    static let key = "Ycode.headset.settings"

    public static func load(_ d: UserDefaults) -> HeadsetSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(HeadsetSettings.self, from: data) else { return HeadsetSettings() }
        return s
    }

    public func save(_ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }

    /// The viewer host these settings name when the hub runs on `platform`.
    public func host(hubIsLinux: Bool) -> HeadsetViewerHost {
        let dest = viewerHost.trimmingCharacters(in: .whitespaces)
        if !dest.isEmpty { return .ssh(dest) }
        return hubIsLinux ? .thisMachine : .none
    }
}

/// A check's state.
public enum HeadsetCheckState: String, Sendable, Equatable {
    case ok, missing, unknown
}

/// The one way to put a check right.
public enum HeadsetFix: Sendable, Equatable {
    /// A command the user runs in a terminal on the viewer host (shown with a Copy button; never run by Ycode).
    case command(String)
    /// Words: something done by hand, on the headset or a phone.
    case instructions(String)
    /// Offers "Install on Headset…"; runs `adb install` only after the user read `HeadsetClientPackage`.
    case installClient(HeadsetClientPackage)
    /// Offers "Connect" (the WiVRn dashboard's way: `adb reverse` and the `wivrn+tcp://` link).
    case connect
}

/// WiVRn's headset client as Ycode offers to install it.
public struct HeadsetClientPackage: Sendable, Equatable {
    public var version: String
    public var url: String
    /// The release's published SHA-256, when Ycode knows it.
    public var sha256: String?
    public static let license = "GPLv3"
    public static let storeURL = "https://www.meta.com/experiences/7959676140827574/"

    /// The published digests of the releases Ycode has looked at (GitHub's release API).
    static let knownDigests = ["26.9": "1df6649ec77224fcc821af0ab4897222bdf3d7eb6ce6ad636461336724111331"]

    public init(version: String) {
        self.version = version
        url = "https://github.com/WiVRn/WiVRn/releases/download/v\(version)/WiVRn-release.apk"
        sha256 = Self.knownDigests[version]
    }

    /// What the confirmation shows before anything is downloaded.
    public var explanation: String {
        "WiVRn's headset app, version \(version), from WiVRn's own releases:\n\(url)\n\n"
            + "WiVRn is a separate program (\(Self.license)); it is not part of Ycode and Ycode does not bundle it. "
            + "The app is downloaded on the viewer host and installed with adb install. "
            + (sha256 == nil ? "Ycode does not know this release's checksum, so the download is not verified."
                             : "The download is checked against the release's published SHA-256.")
            + " You can install it from the Meta Store instead: \(Self.storeURL)"
    }
}

/// The checklist's items, in their order.
public enum HeadsetCheckID: String, Sendable, CaseIterable {
    case viewerHost, vulkan, openXRLoader, openXRRuntime, wivrnInstalled, wivrnRunning, xrViewer, simulatorRoute
    case adb, headsetUSB, clientApp, clientVersion
    case handTracking, eyeTracking
    case connection

    public var title: String {
        switch self {
        case .viewerHost: "Viewer host"
        case .vulkan: "GPU with Vulkan"
        case .openXRLoader: "OpenXR loader"
        case .openXRRuntime: "OpenXR runtime"
        case .wivrnInstalled: "WiVRn server installed"
        case .wivrnRunning: "WiVRn server running"
        case .xrViewer: "ycode-xr-viewer"
        case .simulatorRoute: "Route to the simulator"
        case .adb: "adb"
        case .headsetUSB: "Headset on USB"
        case .clientApp: "WiVRn app on the headset"
        case .clientVersion: "App and server versions"
        case .handTracking: "Hand tracking"
        case .eyeTracking: "Eye tracking"
        case .connection: "Headset connected to WiVRn"
        }
    }
}

/// One line of the checklist.
public struct HeadsetCheck: Sendable, Equatable, Identifiable {
    public let id: HeadsetCheckID
    public var state: HeadsetCheckState
    public var reason: String
    public var fix: HeadsetFix?
    public var title: String { id.title }

    public init(_ id: HeadsetCheckID, _ state: HeadsetCheckState, _ reason: String, fix: HeadsetFix? = nil) {
        self.id = id
        self.state = state
        self.reason = reason
        self.fix = fix
    }
}

/// The onboarding's steps: each groups some checks.
public enum HeadsetSetupStep: Int, Sendable, CaseIterable {
    case viewerHost, workstation, headset, tracking, connect

    public var title: String {
        switch self {
        case .viewerHost: "Viewer Host"
        case .workstation: "Workstation"
        case .headset: "Headset"
        case .tracking: "Tracking"
        case .connect: "Connect"
        }
    }

    public var checks: [HeadsetCheckID] {
        switch self {
        case .viewerHost: [.viewerHost]
        case .workstation: [.vulkan, .openXRLoader, .openXRRuntime, .wivrnInstalled, .wivrnRunning, .xrViewer, .simulatorRoute]
        case .headset: [.adb, .headsetUSB, .clientApp, .clientVersion]
        case .tracking: [.handTracking, .eyeTracking]
        case .connect: [.connection]
        }
    }

    public var summary: String {
        switch self {
        case .viewerHost: "The headset view runs on a Linux PC with a GPU, next to the headset."
        case .workstation: "What the viewer host needs. Ycode only looks; system packages are yours to install."
        case .headset: "A Meta Quest in developer mode with WiVRn's app, the same version as the server."
        case .tracking: "What the headset gives the simulator: your hands and, on a Quest Pro, your eyes."
        case .connect: "The headset joins WiVRn; then View in Headset moves the running device to it."
        }
    }
}

/// Status of the hub's capsule (device-hub.md §I.12).
public enum HeadsetStatus: String, Sendable, Equatable {
    case notSetUp = "Not Set Up"
    case ready = "Ready"
    case inHeadset = "In Headset"
}

/// A full round of checks.
public struct HeadsetReport: Sendable, Equatable {
    public var checks: [HeadsetCheck]
    /// `adb -s` of the headset; the app's package; the server's version (for the actions).
    public var serial: String?
    public var clientPackage: String?
    public var serverVersion: String?
    public var viewerHasControl = false

    public init(checks: [HeadsetCheck]) { self.checks = checks }

    public func check(_ id: HeadsetCheckID) -> HeadsetCheck? { checks.first { $0.id == id } }
    public func checks(in step: HeadsetSetupStep) -> [HeadsetCheck] { step.checks.compactMap(check) }

    /// Checks whose failure stops View in Headset. A connection that has not
    /// happened yet does not: View in Headset connects first. Eye tracking
    /// is optional (selection falls back to a controller or the head).
    static let optional: Set<HeadsetCheckID> = [.connection, .eyeTracking, .handTracking]

    public var isReady: Bool {
        checks.allSatisfy { Self.optional.contains($0.id) || $0.state == .ok || ($0.state == .unknown && !$0.blocksWhenUnknown) }
    }

    public var isConnected: Bool { check(.connection)?.state == .ok }
    public var status: HeadsetStatus { isReady ? .ready : .notSetUp }

    /// The first check to look at (the first step with a blocking problem).
    public var firstProblemStep: HeadsetSetupStep {
        for s in HeadsetSetupStep.allCases where checks(in: s).contains(where: { !Self.optional.contains($0.id) && $0.state != .ok && $0.blocksWhenUnknown }) { return s }
        return .connect
    }
}

extension HeadsetCheck {
    /// An unknown state that cannot be told apart from a problem. The checks
    /// that may be unknown and still work: over Wi-Fi the USB items, and a
    /// runtime that WiVRn will take over when the headset connects.
    var blocksWhenUnknown: Bool {
        switch id {
        case .headsetUSB, .adb, .clientApp, .clientVersion, .openXRRuntime, .vulkan, .simulatorRoute: state != .unknown
        default: true
        }
    }
}

/// The route from the viewer host to the device's display socket.
public enum HeadsetRoute: Sendable, Equatable {
    /// Ycode's link: the viewer host is paired with the simulator host.
    case link(device: String, host: String?)
    /// An ssh forward from the viewer host to the device's socket on the simulator host.
    case sshSocket(destination: String, socket: String)
}

/// Runs the checks. Only read-only commands are used (`adb shell pm list`,
/// `dumpsys`, `getprop`, `busctl get-property`).
public struct HeadsetChecker: Sendable {
    public var host: HeadsetViewerHost
    public var settings: HeadsetSettings
    public var route: HeadsetRoute?
    public var runner: any HeadsetCommandRunner

    public init(host: HeadsetViewerHost, settings: HeadsetSettings, route: HeadsetRoute?, runner: any HeadsetCommandRunner) {
        self.host = host
        self.settings = settings
        self.route = route
        self.runner = runner
    }

    /// The WiVRn client's package names, by how it was installed (WiVRn's README).
    public static let clientPackages = ["org.meumeu.wivrn.github", "org.meumeu.wivrn", "org.meumeu.wivrn.github.nightly",
                                        "org.meumeu.wivrn.github.nighly", "org.meumeu.wivrn.github.testing", "org.meumeu.wivrn.local"]
    public static let wivrnManifest = "/usr/share/openxr/1/openxr_wivrn.json"
    /// USB vendor id of Meta's headsets.
    public static let metaVendor = "2833"

    /// A read of the WiVRn server's D-Bus property (empty when there is no server).
    public static func busProperty(_ name: String) -> String {
        "XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}\" busctl --user get-property io.github.wivrn.Server /io/github/wivrn/Server io.github.wivrn.Server \(name)"
    }

    /// The commands' words, kept together so that tests and the spec name them.
    public enum Command {
        public static let uname = "uname -s"
        public static let vulkan = "vulkaninfo --summary 2>/dev/null"
        public static let loader = "{ ldconfig -p 2>/dev/null || /sbin/ldconfig -p; } | grep libopenxr_loader.so.1"
        public static let runtime = "cat \"${XR_RUNTIME_JSON:-$HOME/.config/openxr/1/active_runtime.json}\" 2>/dev/null || cat /etc/openxr/1/active_runtime.json 2>/dev/null"
        public static let manifest = "test -f \(wivrnManifest)"
        public static let server = "wivrn-server --version 2>&1"
        public static let serverRunning = "pgrep -x wivrn-server"
        public static let adb = "command -v adb"
        public static let devices = "adb devices -l"
        public static let usb = "lsusb -d \(metaVendor):"
    }

    public func run() async -> HeadsetReport {
        var report = HeadsetReport(checks: [])
        let hostCheck = await checkHost()
        report.checks.append(hostCheck)
        guard hostCheck.state == .ok else {
            for id in HeadsetCheckID.allCases where id != .viewerHost {
                report.checks.append(HeadsetCheck(id, .unknown, "Choose the viewer host first."))
            }
            return report
        }
        report.checks.append(await checkVulkan())
        report.checks.append(await checkLoader())
        let server = await checkServer()
        report.serverVersion = server.version
        report.checks.append(await checkRuntime())
        report.checks.append(server.check)
        report.checks.append(await checkServerRunning(installed: server.check.state == .ok))
        let viewer = await checkViewer()
        report.viewerHasControl = viewer.hasControl
        report.checks.append(viewer.check)
        report.checks.append(await checkRoute())
        let adb = await checkADB()
        report.checks.append(adb)
        let usb = await checkUSB(adbPresent: adb.state == .ok)
        report.serial = usb.serial
        report.checks.append(usb.check)
        let client = await checkClient(serial: usb.serial, serverVersion: server.version)
        report.clientPackage = client.package
        report.checks.append(client.app)
        report.checks.append(client.version)
        let bus = await readBus()
        let permissions = await readPermissions(serial: usb.serial, package: client.package)
        let model = usb.model
        report.checks.append(checkHands(bus: bus, permissions: permissions))
        report.checks.append(checkEyes(bus: bus, permissions: permissions, model: model))
        report.checks.append(checkConnection(bus: bus, serial: usb.serial, package: client.package))
        return report
    }

    // MARK: The viewer host

    func checkHost() async -> HeadsetCheck {
        switch host {
        case .none:
            return HeadsetCheck(.viewerHost, .missing,
                                "WiVRn does not run on macOS, so the headset view runs on a Linux PC. Name one you reach with an ssh key.",
                                fix: .instructions("Enter its ssh destination, such as user@workstation. Ycode logs in with a key only and never asks for a password."))
        case .thisMachine, .ssh:
            let r = await runner.run(Command.uname)
            if r.ok, r.output.trimmed == "Linux" { return HeadsetCheck(.viewerHost, .ok, "\(host.title) (Linux)") }
            if r.ok {
                return HeadsetCheck(.viewerHost, .missing, "\(host.title) runs \(r.output.trimmed); WiVRn needs Linux.",
                                    fix: .instructions("Name a Linux PC as the viewer host."))
            }
            guard case .ssh(let d) = host else { return HeadsetCheck(.viewerHost, .unknown, "Could not look at this machine.") }
            return HeadsetCheck(.viewerHost, .missing, "Could not log in to \(d) with an ssh key.", fix: .command("ssh-copy-id \(d)"))
        }
    }

    // MARK: The workstation

    func checkVulkan() async -> HeadsetCheck {
        let r = await runner.run(Command.vulkan)
        if r.notFound || (!r.ok && r.output.isEmpty) {
            return HeadsetCheck(.vulkan, .unknown, "vulkaninfo is not installed, so the GPU could not be checked.", fix: .command("sudo apt install vulkan-tools"))
        }
        var gpus: [(name: String, type: String)] = []
        var type = ""
        for line in r.output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("deviceType") { type = t.afterEquals }
            if t.hasPrefix("deviceName") { gpus.append((t.afterEquals, type)) }
        }
        if let g = gpus.first(where: { $0.type.contains("DISCRETE") }) ?? gpus.first(where: { $0.type.contains("INTEGRATED") }) {
            return HeadsetCheck(.vulkan, .ok, g.name)
        }
        let fix = HeadsetFix.command("sudo ubuntu-drivers install")
        if gpus.isEmpty { return HeadsetCheck(.vulkan, .missing, "No Vulkan device was found.", fix: fix) }
        return HeadsetCheck(.vulkan, .missing, "Only a software renderer (\(gpus[0].name)): install your GPU's Vulkan driver.", fix: fix)
    }

    func checkLoader() async -> HeadsetCheck {
        let r = await runner.run(Command.loader)
        return r.ok ? HeadsetCheck(.openXRLoader, .ok, "libopenxr_loader.so.1")
            : HeadsetCheck(.openXRLoader, .missing, "The Khronos OpenXR loader is not installed.", fix: .command("sudo apt install libopenxr-loader1"))
    }

    func checkRuntime() async -> HeadsetCheck {
        let active = await runner.run(Command.runtime)
        let manifest = await runner.run(Command.manifest).ok
        if active.ok, active.output.localizedCaseInsensitiveContains("wivrn") { return HeadsetCheck(.openXRRuntime, .ok, "active_runtime.json names WiVRn") }
        if manifest {
            // wivrn-server makes itself the active runtime while a headset is
            // connected, and the viewer can name its manifest for itself.
            let what = active.ok ? "Another runtime is active now." : "No runtime is active now."
            return HeadsetCheck(.openXRRuntime, .ok, "\(what) WiVRn takes over while the headset is connected, and the viewer names WiVRn's manifest for itself; your configuration stays as it is.")
        }
        return HeadsetCheck(.openXRRuntime, .missing, "WiVRn's runtime manifest is not installed.", fix: .command("sudo apt install wivrn-server"))
    }

    func checkServer() async -> (check: HeadsetCheck, version: String?) {
        let r = await runner.run(Command.server)
        guard r.ok else {
            return (HeadsetCheck(.wivrnInstalled, .missing, "wivrn-server is not installed.", fix: .command("sudo apt install wivrn-server wivrn-dashboard")), nil)
        }
        let version = r.output.split(whereSeparator: \.isWhitespace).last.map(String.init)
        return (HeadsetCheck(.wivrnInstalled, .ok, version.map { "WiVRn \($0)" } ?? "Installed"), version)
    }

    func checkServerRunning(installed: Bool) async -> HeadsetCheck {
        guard installed else { return HeadsetCheck(.wivrnRunning, .missing, "wivrn-server is not installed.") }
        let r = await runner.run(Command.serverRunning)
        return r.ok ? HeadsetCheck(.wivrnRunning, .ok, "Running")
            : HeadsetCheck(.wivrnRunning, .missing, "wivrn-server is not running.", fix: .command("systemctl --user start wivrn"))
    }

    func checkViewer() async -> (check: HeadsetCheck, hasControl: Bool) {
        let path = settings.viewerPath.isEmpty ? "ycode-xr-viewer" : settings.viewerPath
        let r = await runner.run("\(path.shellQuoted) --help 2>&1")
        let build = "Build it on the viewer host (swift build -c release --product ycode-xr-viewer in ycode/) or copy it there, then name its path."
        guard r.ok || r.output.contains("usage: ycode-xr-viewer") else {
            return (HeadsetCheck(.xrViewer, .missing, "\(path) was not found on the viewer host.", fix: .instructions(build)), false)
        }
        guard r.output.contains("--state-file") else {
            return (HeadsetCheck(.xrViewer, .missing, "\(path) is too old for switching: it has no --state-file.", fix: .instructions(build)), false)
        }
        return (HeadsetCheck(.xrViewer, .ok, path), true)
    }

    func checkRoute() async -> HeadsetCheck {
        switch route {
        case .none:
            return HeadsetCheck(.simulatorRoute, .unknown, "Select a running visionOS device to check the route.")
        case .link(let device, let host):
            return HeadsetCheck(.simulatorRoute, .ok, "Ycode's link to \(device)" + (host.map { " on \($0)" } ?? ""))
        case .sshSocket(let destination, _):
            let r = await runner.run("ssh -o BatchMode=yes -o ConnectTimeout=5 \(destination.shellQuoted) true")
            return r.ok ? HeadsetCheck(.simulatorRoute, .ok, "ssh to \(destination) with a key")
                : HeadsetCheck(.simulatorRoute, .missing, "The viewer host cannot log in to \(destination) with an ssh key.",
                               fix: .command("ssh-copy-id \(destination)"))
        }
    }

    // MARK: The headset

    func checkADB() async -> HeadsetCheck {
        let r = await runner.run(Command.adb)
        if r.ok { return HeadsetCheck(.adb, .ok, r.output.trimmed) }
        if settings.connection == .wifi {
            return HeadsetCheck(.adb, .unknown, "Not needed over Wi-Fi, but without it Ycode cannot see the headset's app or settings.", fix: .command("sudo apt install adb"))
        }
        return HeadsetCheck(.adb, .missing, "adb is not installed.", fix: .command("sudo apt install adb"))
    }

    /// One line of `adb devices -l`.
    struct ADBDevice { var serial: String; var state: String; var model: String? }

    static func parseDevices(_ text: String) -> [ADBDevice] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count >= 2, !line.hasPrefix("*"), !words[0].hasPrefix("emulator-") else { return nil }
            // "no permissions (…)" is more than one word.
            let state = words[1] == "no" ? "no permissions" : words[1]
            let model = words.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }
            return ADBDevice(serial: words[0], state: state, model: model)
        }
    }

    func checkUSB(adbPresent: Bool) async -> (check: HeadsetCheck, serial: String?, model: String?) {
        let usb = await runner.run(Command.usb)
        let onUSB = usb.ok && !usb.output.trimmed.isEmpty
        guard adbPresent else {
            if settings.connection == .wifi { return (HeadsetCheck(.headsetUSB, .unknown, "Connecting over Wi-Fi."), nil, nil) }
            return (HeadsetCheck(.headsetUSB, onUSB ? .unknown : .missing, onUSB ? "A headset is on USB; adb is needed to talk to it." : "Not connected."), nil, nil)
        }
        let list = await runner.run(Command.devices)
        let all = Self.parseDevices(list.output)
        // A Quest when several are listed.
        let d = all.first { $0.model?.contains("Quest") == true } ?? all.first
        let plug = "Connect the headset to the viewer host with a USB cable."
        switch d?.state {
        case "device":
            let name = d?.model?.replacingOccurrences(of: "_", with: " ") ?? d!.serial
            return (HeadsetCheck(.headsetUSB, .ok, name), d?.serial, d?.model)
        case "unauthorized":
            return (HeadsetCheck(.headsetUSB, .missing, "Unauthorized.", fix: .instructions("Put the headset on and accept Allow USB debugging (Always allow from this computer).")), nil, nil)
        case "no permissions":
            return (HeadsetCheck(.headsetUSB, .missing, "adb may not open the USB device.", fix: .command("sudo apt install android-sdk-platform-tools-common && sudo usermod -aG plugdev $USER")), nil, nil)
        case .some(let other):
            return (HeadsetCheck(.headsetUSB, .missing, "adb says \(other).", fix: .instructions("Unplug the cable and plug it in again.")), nil, nil)
        case .none:
            if onUSB {
                return (HeadsetCheck(.headsetUSB, .missing, "A headset is on USB but adb does not list it: developer mode is needed.",
                                     fix: .instructions("Turn on developer mode in the Meta Horizon app on your phone (Devices ▸ your headset ▸ Headset Settings ▸ Developer Mode; it needs a verified Meta developer account), then plug the cable in again. A charge-only cable does not work.")), nil, nil)
            }
            if settings.connection == .wifi { return (HeadsetCheck(.headsetUSB, .unknown, "Connecting over Wi-Fi; no headset on USB."), nil, nil) }
            return (HeadsetCheck(.headsetUSB, .missing, "Not connected.", fix: .instructions(plug)), nil, nil)
        }
    }

    func checkClient(serial: String?, serverVersion: String?) async -> (app: HeadsetCheck, version: HeadsetCheck, package: String?) {
        guard let serial else {
            let why = settings.connection == .wifi ? "Over Wi-Fi Ycode cannot read the headset; start WiVRn's app there and check it matches the server." : "Connect the headset to check."
            return (HeadsetCheck(.clientApp, .unknown, why), HeadsetCheck(.clientVersion, .unknown, why), nil)
        }
        let listed = await runner.run("adb -s \(serial.shellQuoted) shell pm list packages")
        let installed = listed.output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("package:") ? String(t.dropFirst(8)) : nil
        }
        let found = Self.clientPackages.filter(installed.contains)
        let install: HeadsetFix? = serverVersion.map { .installClient(HeadsetClientPackage(version: $0)) }
        guard !found.isEmpty else {
            let fix = install ?? .instructions("Install WiVRn's app from the Meta Store: \(HeadsetClientPackage.storeURL)")
            return (HeadsetCheck(.clientApp, .missing, "WiVRn's app is not on the headset.", fix: fix),
                    HeadsetCheck(.clientVersion, .unknown, "No app to compare."), nil)
        }
        var versions: [(package: String, version: String)] = []
        for p in found {
            let d = await runner.run("adb -s \(serial.shellQuoted) shell dumpsys package \(p) | grep -m1 versionName")
            if let v = d.output.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines), d.ok { versions.append((p, v)) }
        }
        // The client must be the server's version (WiVRn's README): take the one that is.
        let matching = versions.first { $0.version == serverVersion }
        let pick = matching ?? versions.first ?? (found[0], "")
        let app = HeadsetCheck(.clientApp, .ok, pick.package)
        guard let serverVersion else { return (app, HeadsetCheck(.clientVersion, .unknown, "The server's version is not known."), pick.package) }
        if pick.version.isEmpty { return (app, HeadsetCheck(.clientVersion, .unknown, "The app's version could not be read."), pick.package) }
        if pick.version == serverVersion { return (app, HeadsetCheck(.clientVersion, .ok, "\(serverVersion) on both"), pick.package) }
        return (app, HeadsetCheck(.clientVersion, .missing, "The app is \(pick.version), the server \(serverVersion); they must be the same version.", fix: install), pick.package)
    }

    // MARK: Tracking and connection

    /// What the running server says; nil where it says nothing.
    struct BusState { var connected: Bool?; var hands: Bool?; var eyes: Bool?; var systemName: String? }

    func readBus() async -> BusState {
        func bool(_ name: String) async -> Bool? {
            let r = await runner.run(Self.busProperty(name))
            guard r.ok else { return nil }
            return r.output.contains("true") ? true : r.output.contains("false") ? false : nil
        }
        var s = BusState()
        s.connected = await bool("HeadsetConnected")
        if s.connected == true {
            s.hands = await bool("HandTracking")
            s.eyes = await bool("EyeGaze")
            let n = await runner.run(Self.busProperty("SystemName"))
            if n.ok, let a = n.output.firstIndex(of: "\""), let b = n.output.lastIndex(of: "\""), a < b {
                s.systemName = String(n.output[n.output.index(after: a)..<b])
            }
        }
        return s
    }

    /// Runtime permission → granted, from `dumpsys package`.
    func readPermissions(serial: String?, package: String?) async -> [String: Bool] {
        guard let serial, let package else { return [:] }
        let d = await runner.run("adb -s \(serial.shellQuoted) shell dumpsys package \(package) | grep -E 'TRACKING.*granted='")
        var out: [String: Bool] = [:]
        for line in d.output.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let colon = t.firstIndex(of: ":") else { continue }
            let granted = t[colon...].contains("granted=true")
            let name = String(t[..<colon])
            // A later, per-user line is the one that counts.
            out[name] = granted
        }
        return out
    }

    // The menu names are from Meta's public pages, which differ by software
    // version (device-hub.md §I.12 Evidence); not checked on a headset.
    static let handsHelp = "On the headset: Settings ▸ Movement tracking ▸ Hand and body tracking (the name varies by software version); and allow it for WiVRn when its app asks."
    static let eyesHelp = "On the headset: Settings ▸ Movement tracking ▸ Eye tracking (Settings ▸ Hands and eyes on some software versions); then Settings ▸ Privacy and safety ▸ App permissions ▸ Eye Tracking, on for WiVRn."

    func checkHands(bus: BusState, permissions: [String: Bool]) -> HeadsetCheck {
        if bus.hands == true { return HeadsetCheck(.handTracking, .ok, "The connected headset offers it.") }
        if bus.hands == false { return HeadsetCheck(.handTracking, .missing, "The connected headset does not offer it.", fix: .instructions(Self.handsHelp)) }
        if let p = permissions["com.oculus.permission.HAND_TRACKING"] ?? permissions["horizonos.permission.HAND_TRACKING"] {
            return p ? HeadsetCheck(.handTracking, .unknown, "WiVRn may use it; the headset's own setting can only be seen once it connects.", fix: .instructions(Self.handsHelp))
                : HeadsetCheck(.handTracking, .missing, "WiVRn has no permission for it.", fix: .instructions(Self.handsHelp))
        }
        return HeadsetCheck(.handTracking, .unknown, "Cannot be read without the headset.", fix: .instructions(Self.handsHelp))
    }

    func checkEyes(bus: BusState, permissions: [String: Bool], model: String?) -> HeadsetCheck {
        if bus.eyes == true { return HeadsetCheck(.eyeTracking, .ok, "The connected headset offers it.") }
        let name = (bus.systemName ?? model ?? "").replacingOccurrences(of: "_", with: " ")
        if !name.isEmpty, !name.contains("Quest Pro") {
            return HeadsetCheck(.eyeTracking, .unknown, "\(name) has no eye tracking; a controller or the head selects instead.")
        }
        if let p = permissions["com.oculus.permission.EYE_TRACKING"] ?? permissions["horizonos.permission.EYE_TRACKING"], !p {
            return HeadsetCheck(.eyeTracking, .missing, "WiVRn has no permission for eye tracking.", fix: .instructions(Self.eyesHelp))
        }
        if bus.eyes == false { return HeadsetCheck(.eyeTracking, .missing, "The connected headset does not offer it.", fix: .instructions(Self.eyesHelp)) }
        return HeadsetCheck(.eyeTracking, .unknown, "WiVRn may use it; the headset's own setting can only be seen once it connects.", fix: .instructions(Self.eyesHelp))
    }

    func checkConnection(bus: BusState, serial: String?, package: String?) -> HeadsetCheck {
        if bus.connected == true { return HeadsetCheck(.connection, .ok, bus.systemName ?? "Connected") }
        if bus.connected == nil { return HeadsetCheck(.connection, .unknown, "The WiVRn server does not answer.") }
        if settings.connection == .usb, serial != nil, package != nil {
            return HeadsetCheck(.connection, .missing, "Not connected yet.", fix: .connect)
        }
        return HeadsetCheck(.connection, .missing, "Not connected yet.", fix: .instructions("Start WiVRn's app on the headset and choose this computer."))
    }
}

/// The actions the user can click. Each returns the exact command it runs.
public enum HeadsetActions {
    /// USB, as WiVRn's documentation shows it: the port reversed, then the app opened on the server's link.
    public static func connectCommand(serial: String, package: String) -> String {
        let s = serial.shellQuoted
        return "adb -s \(s) reverse tcp:9757 tcp:9757 && adb -s \(s) shell am start -a android.intent.action.VIEW -d wivrn+tcp://localhost \(package.shellQuoted)"
    }

    /// Downloads WiVRn's own release on the viewer host, checks it, `adb install`s it, removes it.
    public static func installCommand(serial: String, package p: HeadsetClientPackage) -> String {
        let verify = p.sha256.map { " && echo \"\($0)  $d/WiVRn-release.apk\" | sha256sum -c -" } ?? ""
        return "d=$(mktemp -d) && curl -fL --retry 2 -o \"$d/WiVRn-release.apk\" \(p.url.shellQuoted)\(verify)"
            + " && adb -s \(serial.shellQuoted) install -r \"$d/WiVRn-release.apk\"; rc=$?; rm -rf \"$d\"; exit $rc"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    fileprivate var afterEquals: String {
        guard let i = firstIndex(of: "=") else { return "" }
        return self[index(after: i)...].trimmingCharacters(in: .whitespaces)
    }
    /// One shell word.
    public var shellQuoted: String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !isEmpty, unicodeScalars.allSatisfy({ safe.contains($0) }) { return self }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A command on this machine (`/bin/sh -c`).
public struct LocalHeadsetRunner: HeadsetCommandRunner {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 15) { self.timeout = timeout }

    public func run(_ command: String) async -> HeadsetCommandResult {
        await HeadsetProcess.run("/bin/sh", ["-c", command], timeout: timeout)
    }
}

/// A command on the viewer host through ssh: a key only (`BatchMode`), one
/// shared connection for the checks' many short commands.
public struct SSHHeadsetRunner: HeadsetCommandRunner {
    public var destination: String
    public var ssh: String
    public var timeout: TimeInterval

    public init(destination: String, ssh: String = HostTool.path("ssh"), timeout: TimeInterval = 15) {
        self.destination = destination
        self.ssh = ssh
        self.timeout = timeout
    }

    public var arguments: [String] {
        // A short path: a Unix socket's holds 104 bytes with ssh's temporary suffix
        // (macOS's temporary directory is too long). ssh makes the socket 0600.
        let control = "/tmp/ycode-\(getuid())-%C"
        return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ControlMaster=auto", "-o", "ControlPath=\(control)", "-o", "ControlPersist=60", destination]
    }

    public func run(_ command: String) async -> HeadsetCommandResult {
        // ssh's own failure (255) must not look like the command's answer.
        var r = await HeadsetProcess.run(ssh, arguments + ["--", command], timeout: timeout)
        if r.status == 255 { r.output = "" }
        return r
    }
}

/// One command, with `posix_spawn` and not Foundation's `Process`: on Linux a
/// `Process` reports its exit only once everything that inherited its internal
/// descriptors has closed them, and a command here may leave the headset viewer
/// running detached. The command's end is the end: its exit, then what is left in
/// the pipe. The pipe's write end is close-on-exec but for the child's stdout.
enum HeadsetProcess {
    static func run(_ program: String, _ arguments: [String], timeout: TimeInterval) async -> HeadsetCommandResult {
        await withCheckedContinuation { (k: CheckedContinuation<HeadsetCommandResult, Never>) in
            DispatchQueue.global().async { k.resume(returning: blocking(program, arguments, timeout: timeout)) }
        }
    }

    private static func blocking(_ program: String, _ arguments: [String], timeout: TimeInterval) -> HeadsetCommandResult {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return HeadsetCommandResult(status: 127) }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        defer { close(fds[0]) }
        #if os(Linux)
        var fa = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #else
        var fa: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #endif
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let argv = ([program] + arguments).map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + env { free(p) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, program, &fa, &attr, argv, env)
        close(fds[1])
        guard spawned == 0 else { return HeadsetCommandResult(status: 127) }
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)

        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        func drain() {
            while true {
                let n = read(fds[0], &buffer, buffer.count)
                guard n > 0 else { return }
                data += buffer[0..<n]
            }
        }
        let start = Date()
        var signalled = 0
        var status: Int32 = 0
        while true {
            var p = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, 20)
            drain()
            if waitpid(pid, &status, WNOHANG) == pid { break }
            let waited = Date().timeIntervalSince(start)
            if waited > timeout, signalled == 0 { kill(pid, SIGTERM); signalled = 1 }
            if waited > timeout + 2, signalled == 1 { kill(pid, SIGKILL); signalled = 2 }
        }
        drain()
        let signal = status & 0x7f
        return HeadsetCommandResult(status: signal == 0 ? (status >> 8) & 0xff : 128 + signal, output: String(decoding: data, as: UTF8.self))
    }
}
