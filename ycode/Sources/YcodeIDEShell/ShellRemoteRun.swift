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
import YcodeSubprocess

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

    /// The row of a paired host that did not answer (#69): it says so, and
    /// Run on it fails at once with the reason instead of waiting.
    public static func offlineDestination(host: String) -> Destination {
        Destination(name: "\(host) is offline", specifier: "generic/platform=iOS Simulator", platform: "iOS", kind: .simulator,
                    identifier: prefix + host + "/")
    }

    public static func offlineMessage(host: String) -> String {
        "The simulator host \(host) did not answer on Ycode's link. Check that it is on and that ycode-simhost serve runs there, "
            + "then reopen the project; Window ▸ Downloads checks the host."
    }

    /// One group per paired host with its devices (asked with a short
    /// timeout); a host that does not answer keeps its group with one row
    /// saying it is offline.
    public static func destinationGroups(store: LinkStore = LinkStore()) -> [DestinationGroup] {
        guard let client = try? LinkClient(store: store) else { return [] }
        var groups: [DestinationGroup] = []
        for p in store.peers() where p.role == "host" {
            guard let h = LinkHost(p) else { continue }
            guard let c = try? client.control(h) else {
                groups.append(DestinationGroup(title: "Ycode Simulator, \(ExperimentalNotice.label) (\(h.name))", destinations: [offlineDestination(host: h.name)]))
                continue
            }
            defer { c.close() }
            guard let r = try? c.request(LinkRequest(op: "devices")), r.ok, let devices = r.devices else { continue }
            if devices.isEmpty {
                // A host just set up has no devices: offer one that Run makes.
                let info = try? c.request(LinkRequest(op: "info"))
                let row = newDeviceDestination(host: h.name, deviceTypes: info?.deviceTypes ?? [], runtime: info?.runtimes?.first)
                groups.append(DestinationGroup(title: "Ycode Simulator, \(ExperimentalNotice.label) (\(h.name))", destinations: row.map { [$0] } ?? []))
                continue
            }
            groups.append(DestinationGroup(title: "Ycode Simulator, \(ExperimentalNotice.label) (\(h.name))", destinations: devices.map { destination(host: h.name, device: $0) }))
        }
        return groups
    }

    /// The steps of a remote run, for tests: the build command, then the app.
    public static func buildCommand(project: String, scheme: String, derivedData: String, script: String) -> [String] {
        [script, project, scheme, derivedData]
    }

    /// Where Run builds for a simulator host: `$XDG_CACHE_HOME/ycode/remote-run`,
    /// else `~/.cache/ycode/remote-run` (one folder per scheme).
    public static func derivedDataRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let cache = environment["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache")
        return cache.appendingPathComponent("ycode/remote-run")
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
    /// `.build/<config>/` or `.build/out/Products/<config>/` executable.
    public static func toolsRoot(executable: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]) -> URL {
        let exe = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        var dir = exe
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/ycode-ios-build-linux").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return exe
    }

    /// What a started run left for the caller: the device window's process
    /// (Stop ends it), the app as built here, and, for a run under the
    /// debugger, the host's path of the debug stub's socket.
    public struct Started: @unchecked Sendable {
        public var viewer: Process
        public var app: URL
        public var bundleID: String?
        public var host: LinkHost
        public var device: String
        public var debugSocket: String?
    }

    /// Builds, uploads, installs and launches, then opens the device window.
    /// `output` gets console lines; returns the window's process (Stop ends it).
    public static func run(project: String, scheme: String, destination: Destination, packageRoot: URL,
                           output: @escaping @Sendable (String) -> Void,
                           phase: @escaping @Sendable (RemoteRunPhase) -> Void = { _ in },
                           cancel: RemoteRunCancel = RemoteRunCancel()) async throws -> Process {
        try await start(project: project, scheme: scheme, destination: destination, packageRoot: packageRoot, debug: false,
                        output: output, phase: phase, cancel: cancel).viewer
    }

    /// `run`, and with `debug` the app runs with the debug stub (the link's
    /// `run` request with `debug`; ShellSimulatorDebug attaches to it).
    public static func start(project: String, scheme: String, destination: Destination, packageRoot: URL, debug: Bool,
                             output: @escaping @Sendable (String) -> Void,
                             phase: @escaping @Sendable (RemoteRunPhase) -> Void = { _ in },
                             cancel: RemoteRunCancel = RemoteRunCancel()) async throws -> Started {
        guard let (hostName, device) = target(of: destination) else { throw Failure(description: "not a Ycode simulator host destination") }
        guard !device.isEmpty else { throw Failure(description: offlineMessage(host: hostName)) }
        phase(.building)
        let derived = derivedDataRoot().appendingPathComponent(scheme).path
        let script = ProcessInfo.processInfo.environment["YCODE_IOS_BUILD"] ?? packageRoot.appendingPathComponent("scripts/ycode-ios-build-linux").path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw Failure(description: "the iOS Simulator build script was not found at \(script); set YCODE_IOS_BUILD to scripts/ycode-ios-build-linux of Ycode")
        }
        output("Building \(scheme) for the iOS Simulator…\n")
        let status = try await runProcess(buildCommand(project: project, scheme: scheme, derivedData: derived, script: script), output: output,
                                          started: cancel.started)
        guard !cancel.isCancelled else { throw Failure(description: "stopped") }
        guard status == 0 else { throw Failure(description: "the build failed (status \(status))") }
        guard let app = builtApp(derivedData: derived, scheme: scheme) else { throw Failure(description: "no .app in \(derived)") }
        phase(.launching)
        let client = try LinkClient()
        let host = try client.host(named: hostName)
        let c = try client.control(host)
        defer { c.close() }
        _ = try ensureDevice(c, device: device, type: destination.deviceType, host: host.name, output: output)
        let up = try c.upload(app)
        guard up.ok else { throw Failure(description: up.error ?? "upload failed") }
        output("Uploaded \(up.message ?? app.lastPathComponent) to \(host.name)\n")
        guard !cancel.isCancelled else { throw Failure(description: "stopped") }
        // The stub's socket is a path on the host: only a host on this
        // computer can be debugged until the link carries the stub.
        let debug = debug && ShellSimulatorDebug.isThisMachine(host.host)
        let r = try c.request(LinkRequest(op: "run", device: device, app: app.lastPathComponent, bundleID: up.bundleID, debug: debug ? true : nil))
        guard r.ok else { throw Failure(description: r.error ?? "run failed") }
        output("Installing and launching \(r.bundleID ?? "the app") on \(device)…\n")
        let viewer = Process()
        viewer.executableURL = URL(fileURLWithPath: SimRemoteCLI.viewerPath())
        viewer.arguments = SimRemoteCLI.viewerArguments(host: hostName, device: device, extra: [])
        try viewer.runWithSignalsUnblocked()
        watchBoot(host: host, device: device, app: scheme, client: client, output: output, phase: phase)
        return Started(viewer: viewer, app: app, bundleID: r.bundleID ?? up.bundleID, host: host, device: device, debugSocket: r.debugSocket)
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

    static func runProcess(_ argv: [String], output: @escaping @Sendable (String) -> Void,
                           started: (Process) -> Void = { _ in }) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Int32, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            let pipe: SpawnPipe
            do { pipe = try SpawnPipe(childReads: false) } catch { return k.resume(throwing: error) }
            p.standardOutput = pipe.childEnd
            p.standardError = pipe.childEnd
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { output(String(decoding: d, as: UTF8.self)) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                k.resume(returning: proc.terminationStatus)
            }
            do {
                try p.runWithSignalsUnblocked(closingChildEndsOf: pipe)
                started(p)
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                k.resume(throwing: error)
            }
        }
    }
}
