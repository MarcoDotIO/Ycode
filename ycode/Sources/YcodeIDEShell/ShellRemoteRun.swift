// Run on a Ycode simulator host from the Linux shell (specs/simulator/
// sim-link.md §10, specs/ide/run.md "Remote run from Linux"): each device of
// each paired host (`ycode sim remote pair`) is a run destination; Run
// builds the scheme for the iOS Simulator on this machine
// (scripts/ycode-ios-build-linux, the user's SDK), uploads the app over
// Ycode's link, has the host install and launch it, and opens the device
// window (ycode-sim-viewer --link), which shows the device and plays its
// sound. Stop ends the window. No ssh.

import Foundation
import YcodeBuild
import YcodeIDECore
import YcodeSimLink

public enum ShellRemoteRun {
    /// Destination identifiers: "ycode-link:<host>/<device>".
    public static let prefix = "ycode-link:"

    public static func destination(host: String, device: LinkDeviceInfo) -> Destination {
        let os = URL(fileURLWithPath: device.runtime).deletingLastPathComponent().lastPathComponent
        let version = os.split(separator: "-").dropFirst().first.map(String.init)
        return Destination(name: "\(device.name) (\(host))", specifier: "generic/platform=iOS Simulator", platform: "iOS", kind: .simulator,
                           osVersion: version, identifier: prefix + host + "/" + device.name, deviceType: device.deviceType)
    }

    /// (host, device) of a link destination.
    public static func target(of d: Destination) -> (host: String, device: String)? {
        guard let id = d.identifier, id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return (String(rest[..<slash]), String(rest[rest.index(after: slash)...]))
    }

    /// One group per paired host with its devices (asked with a short
    /// timeout; a host that does not answer is left out).
    public static func destinationGroups(store: LinkStore = LinkStore()) -> [DestinationGroup] {
        guard let client = try? LinkClient(store: store) else { return [] }
        var groups: [DestinationGroup] = []
        for p in store.peers() where p.role == "host" {
            guard let h = LinkHost(p), let c = try? client.control(h) else { continue }
            defer { c.close() }
            guard let r = try? c.request(LinkRequest(op: "devices")), r.ok, let devices = r.devices, !devices.isEmpty else { continue }
            groups.append(DestinationGroup(title: "Ycode Simulator, \(ExperimentalNotice.label) (\(h.name))", destinations: devices.map { destination(host: h.name, device: $0) }))
        }
        return groups
    }

    /// The steps of a remote run, for tests: the build command, then the app.
    public static func buildCommand(project: String, scheme: String, derivedData: String, script: String) -> [String] {
        [script, project, scheme, derivedData]
    }

    /// The built app: `<derived data>/Products/Debug-iphonesimulator/<one>.app`.
    public static func builtApp(derivedData: String, scheme: String) -> URL? {
        let dir = URL(fileURLWithPath: derivedData).appendingPathComponent("Products/Debug-iphonesimulator")
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
        let pick = apps.first { $0 == scheme + ".app" } ?? apps.first
        return pick.map { dir.appendingPathComponent($0) }
    }

    public struct Failure: Error, CustomStringConvertible { public let description: String }

    /// The folder whose `scripts/` holds the iOS build script: next to the
    /// app's executable when packaged, else the `ycode/` folder above a
    /// `.build/<config>/` executable.
    public static func toolsRoot(executable: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]) -> URL {
        let exe = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        for dir in [exe, exe.deletingLastPathComponent(), exe.deletingLastPathComponent().deletingLastPathComponent(),
                    exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()]
        where FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/ycode-ios-build-linux").path) {
            return dir
        }
        return exe
    }

    /// Builds, uploads, installs and launches, then opens the device window.
    /// `output` gets console lines; returns the window's process (Stop ends it).
    public static func run(project: String, scheme: String, destination: Destination, packageRoot: URL,
                           output: @escaping @Sendable (String) -> Void) async throws -> Process {
        guard let (hostName, device) = target(of: destination) else { throw Failure(description: "not a Ycode simulator host destination") }
        let derived = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/ycode/remote-run/" + scheme).path
        let script = ProcessInfo.processInfo.environment["YCODE_IOS_BUILD"] ?? packageRoot.appendingPathComponent("scripts/ycode-ios-build-linux").path
        output("Building \(scheme) for the iOS Simulator…\n")
        let status = try await runProcess(buildCommand(project: project, scheme: scheme, derivedData: derived, script: script), output: output)
        guard status == 0 else { throw Failure(description: "the build failed (status \(status))") }
        guard let app = builtApp(derivedData: derived, scheme: scheme) else { throw Failure(description: "no .app in \(derived)") }
        let client = try LinkClient()
        let host = try client.host(named: hostName)
        let c = try client.control(host)
        defer { c.close() }
        let up = try c.upload(app)
        guard up.ok else { throw Failure(description: up.error ?? "upload failed") }
        output("Uploaded \(up.message ?? app.lastPathComponent) to \(host.name)\n")
        let r = try c.request(LinkRequest(op: "run", device: device, app: app.lastPathComponent, bundleID: up.bundleID))
        guard r.ok else { throw Failure(description: r.error ?? "run failed") }
        output("Installing and launching \(r.bundleID ?? "the app") on \(device)…\n")
        let viewer = Process()
        viewer.executableURL = URL(fileURLWithPath: SimRemoteCLI.viewerPath())
        viewer.arguments = SimRemoteCLI.viewerArguments(host: hostName, device: device, extra: [])
        try viewer.run()
        return viewer
    }

    /// The headset hook (device-hub.md §I.12): a visionOS destination's
    /// device moves to the headset viewer on this machine (over the link)
    /// and back, without a restart. The shell has no device surface of its
    /// own yet: its device window is `ycode-sim-viewer`, which waits while
    /// the headset has the display and takes it back on a click. The words
    /// are `ycode sim headset`'s; `run` carries them out in-process.
    public static func headsetArguments(destination: Destination, toHeadset: Bool, viewerOptions: [String] = []) -> [String]? {
        guard let (host, device) = target(of: destination), destination.deviceType == "vision-pro" || destination.platform == "visionOS" else { return nil }
        return toHeadset ? ["view", device, "--link", "--host", host] + (viewerOptions.isEmpty ? [] : ["--"] + viewerOptions)
            : ["desktop", device, "--link", "--host", host]
    }

    /// View in Headset / Back to Desktop from the shell; `output` gets the lines.
    public static func switchHeadset(destination: Destination, toHeadset: Bool, output: @escaping @Sendable (String) -> Void) async -> Bool {
        guard let args = headsetArguments(destination: destination, toHeadset: toHeadset) else { return false }
        return await HeadsetCLI.main(args, out: output) == 0
    }

    static func runProcess(_ argv: [String], output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Int32, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { output(String(decoding: d, as: UTF8.self)) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                k.resume(returning: proc.terminationStatus)
            }
            do { try p.run() } catch { k.resume(throwing: error) }
        }
    }
}
